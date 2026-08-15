/*
 * Custom Agent Protocol
 * 自定义 HTTP Agent 接入：OpenAI 兼容 /v1/chat/completions（SSE 流式）
 * 配置存储、SSE 解析、请求构建均为纯逻辑，便于单元测试。
 */

import Foundation
import UIKit

/// 自定义 Agent 接入协议
enum CustomAgentTransport: String, Codable, CaseIterable, Equatable {
    /// OpenAI 兼容 /v1/chat/completions（SSE 流式）
    case http
    /// WebSocket 事件流协议（delta / done / tool_call / error）
    case websocket
}

// MARK: - 配置

/// 自定义 Agent 配置（持久化）
struct CustomAgentConfig: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// 完整服务地址，如 http://192.168.1.10:8000/v1
    var baseURL: String
    var apiKey: String
    var model: String
    /// 可选：OpenAI 工具声明 JSON 数组（function calling），空串表示不声明
    var toolsJSON: String
    /// 接入协议：HTTP（SSE）或 WebSocket
    var transport: CustomAgentTransport

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, model, toolsJSON, transport
    }

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String = "",
        model: String,
        toolsJSON: String = "",
        transport: CustomAgentTransport = .http
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.toolsJSON = toolsJSON
        self.transport = transport
    }

    /// 兼容旧版本：无 toolsJSON 字段的存档仍可解码（默认空）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decode(String.self, forKey: .model)
        toolsJSON = try container.decodeIfPresent(String.self, forKey: .toolsJSON) ?? ""
        transport = try container.decodeIfPresent(CustomAgentTransport.self, forKey: .transport) ?? .http
    }

    /// 配置是否可用于连接：名称、模型与地址均不能为空，协议对应合法 scheme
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        switch transport {
        case .http:
            return scheme == "http" || scheme == "https"
        case .websocket:
            return scheme == "ws" || scheme == "wss"
        }
    }
}

/// 自定义 Agent 配置存储（UserDefaults JSON，最新在前）
enum CustomAgentStore {
    static let storageKey = "custom.agents.configs"

    static var configs: [CustomAgentConfig] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([CustomAgentConfig].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func config(for id: UUID) -> CustomAgentConfig? {
        configs.first { $0.id == id }
    }

    /// 新增/更新配置（同 ID 覆盖并置顶）
    @discardableResult
    static func add(_ config: CustomAgentConfig) -> Bool {
        var all = configs
        all.removeAll { $0.id == config.id }
        all.insert(config, at: 0)
        configs = all
        return true
    }

    @discardableResult
    static func remove(id: UUID) -> Bool {
        let before = configs.count
        configs = configs.filter { $0.id != id }
        return configs.count != before
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

// MARK: - SSE 解析（chat completions 形状）

/// 自定义 Agent 的 SSE 行解析（纯逻辑，可测）
enum CustomChatSSEParser {
    /// 解析一行：返回 data 载荷 JSON 字符串；非 data 行返回 nil；[DONE] 标记结束
    static func parse(line: String) -> (payload: String?, isDone: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return (nil, false) }
        let payload = trimmed
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return (nil, true) }
        return (payload.isEmpty ? nil : payload, false)
    }

    /// 从 chat completions 增量 JSON 提取文本增量（choices[0].delta.content）
    static func textDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else {
            return nil
        }
        return delta["content"] as? String
    }

    /// 从增量 JSON 提取首个工具调用增量（便捷方法，等价于 toolDeltas.first）
    static func toolDelta(from payload: String) -> CustomToolCallDelta? {
        toolDeltas(from: payload).first
    }

    /// 从增量 JSON 提取全部工具调用增量（choices[0].delta.tool_calls，按 index 区分）；
    /// 无工具调用时返回空数组。名称只在首个分片出现，参数分片仅含 arguments。
    static func toolDeltas(from payload: String) -> [CustomToolCallDelta] {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return toolCalls.compactMap { item -> CustomToolCallDelta? in
            guard !(item is NSNull) else { return nil }
            let function = item["function"] as? [String: Any]
            return CustomToolCallDelta(
                index: item["index"] as? Int,
                id: item["id"] as? String,
                name: function?["name"] as? String,
                arguments: function?["arguments"] as? String
            )
        }
    }
}

/// 工具调用增量（SSE 流式分片，逐片携带部分字段）
struct CustomToolCallDelta: Equatable {
    var index: Int?
    var id: String?
    var name: String?
    var arguments: String?
}

/// 完整工具调用（服务端最终累积结果）
struct CustomToolCall: Equatable {
    var id: String
    var name: String
    var arguments: String
}

/// 工具执行结果（回传给 Agent 的 tool 消息）
struct CustomToolResult: Equatable {
    var callID: String
    var name: String
    var content: String
}

/// 多轮上下文中的一轮（role: user / assistant）
struct CustomChatTurn: Equatable {
    var role: String
    var text: String
}

// MARK: - 服务

/// 自定义 Agent 服务：OpenAI 兼容流式聊天（URLSession 可注入，便于测试）
@MainActor
final class CustomAgentService {
    static let shared = CustomAgentService()

    private let session: URLSession
    private var currentTask: Task<Void, Never>?
    /// 最近一次流式错误（由 onErrorProxy 记录，runConversation 读取后回调）
    private var lastStreamError: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 健康检查：GET {base}/models，HTTP 200 视为在线
    func checkHealth(config: CustomAgentConfig) async -> Bool {
        guard let url = URL(string: config.baseURL + "/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// 发送消息（流式）；image 非空时按 OpenAI 多模态 content 数组发送（data URL）；
    /// history 为之前的对话轮次（最新在前调用方已排好序），最多携带最近 20 轮；
    /// toolsJSON 合法时声明 function calling 工具，工具调用分片触发 onTool（首个新工具名）；
    /// toolExecutor 非空时自动完成「调用 → 本地执行 → 结果回传 → 继续生成」循环，
    /// maxToolRounds 限制循环轮数（超限报错）。
    /// onDelta 增量回调，onComplete 最终全文，onError 错误文案
    func sendMessage(
        config: CustomAgentConfig,
        text: String,
        image: UIImage? = nil,
        history: [CustomChatTurn] = [],
        systemPrompt: String? = nil,
        toolExecutor: ((CustomToolCall) async -> String)? = nil,
        maxToolRounds: Int = 4,
        onDelta: @escaping (String) -> Void,
        onTool: ((String) -> Void)? = nil,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        var messages: [[String: Any]] = history.suffix(20).map { turn in
            ["role": turn.role, "content": turn.text]
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.insert(["role": "system", "content": systemPrompt], at: 0)
        }
        messages.append(["role": "user", "content": messageContent(text: text, image: image)])

        lastStreamError = nil
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runConversation(
                config: config,
                messages: messages,
                toolExecutor: toolExecutor,
                maxToolRounds: maxToolRounds,
                onDelta: onDelta,
                onTool: onTool,
                onComplete: onComplete,
                onError: onError
            )
        }
    }

    /// 解析配置中的工具声明 JSON 数组；非法或为空时返回 nil（不声明工具）
    private func toolsArray(from json: String) -> [Any]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [Any] else {
            return nil
        }
        return array
    }

    /// 用户消息内容：无图时纯文本；有图时 OpenAI 多模态 content 数组
    private func messageContent(text: String, image: UIImage?) -> Any {
        guard let image,
              let jpeg = image.jpegData(compressionQuality: 0.7) else {
            return text
        }
        return [
            ["type": "text", "text": text],
            [
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
            ]
        ]
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Conversation Loop

    /// 单轮流式结果
    private struct StreamRound {
        var text: String
        var toolCalls: [CustomToolCall]
    }

    /// 工具调用分片累积器（按 index 区分，参数逐片拼接）
    private struct ToolCallBuilder {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    /// 多轮对话：流式输出 → 工具调用 → 本地执行 → 回传 → 继续，直到无工具调用或超限
    private func runConversation(
        config: CustomAgentConfig,
        messages: [[String: Any]],
        toolExecutor: ((CustomToolCall) async -> String)?,
        maxToolRounds: Int,
        onDelta: @escaping (String) -> Void,
        onTool: ((String) -> Void)?,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async {
        var messages = messages
        var finalText = ""
        for _ in 0..<maxToolRounds {
            guard let request = makeRequest(config: config, messages: messages) else {
                onError("custom.agent.error.invalidrequest".localized)
                return
            }
            guard let round = await streamOnce(
                request: request,
                onDelta: onDelta,
                onTool: onTool
            ) else {
                if let error = lastStreamError {
                    lastStreamError = nil
                    onError(error)
                }
                return // 取消则静默结束
            }
            finalText += round.text
            guard !round.toolCalls.isEmpty else {
                onComplete(finalText)
                return
            }
            guard let toolExecutor else {
                // 未提供执行器：保留已流出的文本结束
                onComplete(finalText)
                return
            }
            messages.append(assistantToolCallsMessage(round.toolCalls))
            for call in round.toolCalls {
                let content = await toolExecutor(call)
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": content
                ])
            }
        }
        onError("custom.agent.error.toolrounds".localized)
    }

    /// 构造单轮请求；地址/序列化失败返回 nil
    private func makeRequest(config: CustomAgentConfig, messages: [[String: Any]]) -> URLRequest? {
        guard let url = URL(string: config.baseURL + "/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": messages
        ]
        if let tools = toolsArray(from: config.toolsJSON) {
            body["tools"] = tools
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = jsonData
        return request
    }

    /// assistant 的工具调用消息（供下一轮 tool 结果回传）
    private func assistantToolCallsMessage(_ calls: [CustomToolCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ]
            }
        ]
    }

    /// 单轮流式请求；出错时回调 onError 并返回 nil（取消返回 nil 不报错）
    private func streamOnce(
        request: URLRequest,
        onDelta: @escaping (String) -> Void,
        onTool: ((String) -> Void)?
    ) async -> StreamRound? {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                onErrorProxy("custom.agent.error.invalidresponse")
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    if Task.isCancelled { return nil }
                    body.append(byte)
                }
                onErrorProxy(errorMessage(body: body, status: http.statusCode))
                return nil
            }

            var text = ""
            var announcedTools: Set<String> = []
            var builders: [Int: ToolCallBuilder] = [:]
            for try await line in bytes.lines {
                if Task.isCancelled { return nil }
                let parsed = CustomChatSSEParser.parse(line: line)
                if parsed.isDone {
                    break
                }
                guard let payload = parsed.payload else { continue }
                for toolDelta in CustomChatSSEParser.toolDeltas(from: payload) {
                    let index = toolDelta.index ?? 0
                    var builder = builders[index] ?? ToolCallBuilder()
                    if let id = toolDelta.id { builder.id = id }
                    if let name = toolDelta.name {
                        if !name.isEmpty, announcedTools.insert(name).inserted {
                            onTool?(name)
                        }
                        builder.name = name
                    }
                    if let arguments = toolDelta.arguments {
                        builder.arguments += arguments
                    }
                    builders[index] = builder
                }
                if let delta = CustomChatSSEParser.textDelta(from: payload) {
                    text += delta
                    onDelta(delta)
                }
            }
            let toolCalls = builders
                .sorted { $0.key < $1.key }
                .compactMap { _, builder -> CustomToolCall? in
                    guard let name = builder.name, !name.isEmpty else { return nil }
                    return CustomToolCall(
                        id: builder.id ?? "",
                        name: name,
                        arguments: builder.arguments
                    )
                }
            return StreamRound(text: text, toolCalls: toolCalls)
        } catch is CancellationError {
            return nil // 主动取消：静默结束
        } catch {
            onErrorProxy("custom.agent.error.stream")
            return nil
        }
    }

    /// streamOnce 内的错误回调（避免闭包签名携带 onError）
    private func onErrorProxy(_ message: String) {
        lastStreamError = message
    }

    /// 非 2xx 时优先透出服务端错误信息
    private func errorMessage(body: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = json["error"] as? [String: Any],
           let detail = message["message"] as? String,
           !detail.isEmpty {
            return "HTTP \(status): \(detail)"
        }
        return "HTTP \(status)"
    }
}

// MARK: - 本地工具执行器

/// 敏感工具审批决策
enum CustomAgentToolDecision: Equatable {
    case allowed
    case denied
    case later
    case timedOut
}

/// 敏感工具审批协调器：镜片审批卡 + 超时兜底。
/// 审计由调用方（CustomAgentLocalTools）统一记录，审批实现可替换注入。
@MainActor
enum CustomAgentToolApprover {
    /// 请求一次审批：展示镜片审批卡（Allow / Deny / Later），
    /// 超时未决策自动返回 .timedOut
    static func request(
        summary: String,
        timeout: TimeInterval = 60
    ) async -> CustomAgentToolDecision {
        let decision: CustomAgentToolDecision = await withCheckedContinuation { continuation in
            var resumed = false
            func resumeOnce(_ value: CustomAgentToolDecision) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            AgentDisplayHub.shared.showPermission(
                summary: summary,
                onAllow: { resumeOnce(.allowed) },
                onDeny: { resumeOnce(.denied) },
                onLater: { resumeOnce(.later) }
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resumeOnce(.timedOut)
            }
        }
        return decision
    }
}

/// 本地工具执行上下文（测试可注入）
struct CustomAgentToolContext {
    var session: QwenVoiceSession
    var captureVision: () async -> UIImage?
    var latestFrame: () -> UIImage?
    var requestApproval: (String) async -> CustomAgentToolDecision

    init(
        session: QwenVoiceSession = .shared,
        captureVision: @escaping () async -> UIImage? = { nil },
        latestFrame: @escaping () -> UIImage? = { nil },
        requestApproval: @escaping (String) async -> CustomAgentToolDecision = { summary in
            await CustomAgentToolApprover.request(summary: summary)
        }
    ) {
        self.session = session
        self.captureVision = captureVision
        self.latestFrame = latestFrame
        self.requestApproval = requestApproval
    }
}

/// 把自定义 Agent 的工具调用映射到 App 内能力，返回给 Agent 的结果文本。
/// 约定：工具名包含 Tool Registry 的 ID（如 voice.reply / task.control / vision.capture）即视为本地工具；
/// 敏感工具（requiresPermission）先走审批（镜片审批卡 + 审计），撤销中的工具被拦截。
@MainActor
enum CustomAgentLocalTools {
    /// 执行一个工具调用，返回结果文本（成功/失败均以文本回传，Agent 可继续）
    static func execute(_ call: CustomToolCall, context: CustomAgentToolContext = CustomAgentToolContext()) async -> String {
        if call.name.contains(AgentToolRegistry.voiceReply.id) {
            return executeVoiceReply(call)
        }
        if call.name.contains(AgentToolRegistry.taskControl.id) {
            return executeTaskControl(context.session)
        }
        if call.name.contains(AgentToolRegistry.visionCapture.id) {
            return await executeVisionCapture(call, context: context)
        }
        if call.name.contains(AgentToolRegistry.listManage.id) {
            return executeListManage(call)
        }
        if call.name.contains(AgentToolRegistry.visionOCR.id) {
            return await executeVisionOCR(context: context)
        }
        if call.name.contains(AgentToolRegistry.visionScene.id) {
            return await executeVisionScene(context: context)
        }
        if call.name.contains(AgentToolRegistry.visionObjects.id) {
            return await executeVisionObjects(context: context)
        }
        return "custom.agent.tool.unavailable".localized(call.name)
    }

    /// 从工具参数 JSON 提取指定键的字符串（纯逻辑，可测）
    static func stringArgument(from arguments: String, key: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func executeVoiceReply(_ call: CustomToolCall) -> String {
        guard let text = stringArgument(from: call.arguments, key: "text") ?? stringArgument(from: call.arguments, key: "content") else {
            return "custom.agent.tool.voicereply.empty".localized
        }
        TTSService.shared.stop()
        TTSService.shared.speak(text)
        return "custom.agent.tool.voicereply.done".localized
    }

    private static func executeTaskControl(_ session: QwenVoiceSession) -> String {
        if let summary = session.taskProgressSummary, !summary.isEmpty {
            return summary
        }
        return "custom.agent.tool.taskcontrol.empty".localized
    }

    /// 本地命名清单读写（用户自有数据，无需授权）：action = query / add / remove / clear
    private static func executeListManage(_ call: CustomToolCall) -> String {
        let action = stringArgument(from: call.arguments, key: "action")?.lowercased() ?? "query"
        guard let list = stringArgument(from: call.arguments, key: "list") else {
            return "custom.agent.tool.list.usage".localized
        }
        switch action {
        case "query", "read":
            let items = AgentListStore.list(named: list)?.items ?? []
            if items.isEmpty {
                return String(format: "agent.list.query.empty".localized, list)
            }
            return String(format: "agent.list.query.content".localized, list, items.joined(separator: "、"))
        case "add", "append":
            guard let item = stringArgument(from: call.arguments, key: "item") else {
                return "custom.agent.tool.list.usage".localized
            }
            if let updated = AgentListStore.addItem(item, to: list) {
                return String(format: "agent.list.added".localized, item, updated.name)
            }
            if AgentListStore.list(named: list)?.items.contains(item) == true {
                return String(format: "agent.list.add.dup".localized, item, list)
            }
            return String(format: "agent.list.add.full".localized, list)
        case "remove", "delete":
            guard let item = stringArgument(from: call.arguments, key: "item") else {
                return "custom.agent.tool.list.usage".localized
            }
            let existed = AgentListStore.list(named: list)?.items.contains(item) ?? false
            AgentListStore.removeItem(item, from: list)
            return existed
                ? String(format: "agent.list.removed".localized, item, list)
                : String(format: "agent.list.item.missing".localized, item, list)
        case "clear":
            AgentListStore.clearItems(named: list)
            return String(format: "agent.list.cleared".localized, list)
        default:
            return "custom.agent.tool.list.usage".localized
        }
    }

    /// 拍照注入视野（敏感）：撤销拦截 → 审批 → 拍照 → 结果文本
    private static func executeVisionCapture(_ call: CustomToolCall, context: CustomAgentToolContext) async -> String {
        let tool = AgentToolRegistry.visionCapture
        guard !AgentRevokeStore.isRevoked(tool.id) else {
            return "custom.agent.tool.revoked".localized
        }
        let summary = "custom.agent.tool.vision.summary".localized
        AgentAuditStore.append(toolID: tool.id, action: .requested, detail: summary)
        let decision = await context.requestApproval(summary)
        let action: AgentAuditAction
        switch decision {
        case .allowed: action = .granted
        case .denied: action = .denied
        case .later: action = .later
        case .timedOut: action = .skipped
        }
        AgentAuditStore.append(toolID: tool.id, action: action, detail: summary)
        guard decision == .allowed else {
            return denialText(for: decision)
        }
        guard let frame = await context.captureVision() else {
            return "custom.agent.tool.vision.noframe".localized
        }
        return "custom.agent.tool.vision.done".localized
    }

    private static func denialText(for decision: CustomAgentToolDecision) -> String {
        switch decision {
        case .allowed: return ""
        case .denied: return "custom.agent.tool.denied".localized
        case .later: return "custom.agent.tool.later".localized
        case .timedOut: return "custom.agent.tool.timedout".localized
        }
    }

    /// 端侧取词：在 App 已持有的最近一帧画面上运行 Apple Vision OCR（离线免费）。
    /// 无画面帧时给出引导（先让用户拍照），不触发敏感权限。
    private static func executeVisionOCR(context: CustomAgentToolContext) async -> String {
        guard let frame = context.latestFrame() else {
            return "custom.agent.tool.vision.frame.missing".localized
        }
        let text = await VisionOCRService.recognizedText(in: frame)
        guard !text.isEmpty else {
            return "agent.vision.ocr.empty".localized
        }
        AgentVisionOCRStore.set(text)
        return text
    }

    /// 端侧场景识别：在 App 已持有的最近一帧画面上运行 Apple Vision 分类 + 动物 + 物体识别（离线免费）。
    private static func executeVisionScene(context: CustomAgentToolContext) async -> String {
        guard let frame = context.latestFrame() else {
            return "custom.agent.tool.vision.frame.missing".localized
        }
        let result = await VisionSceneService.analyze(frame)
        guard !result.isEmpty else {
            return "agent.vision.scene.empty".localized
        }
        let summary = VisionSceneTextProcessor.summaryText(from: result)
        AgentVisionSceneStore.set(summary)
        return summary
    }

    /// 端侧物体识别：在最近一帧上运行 Apple Vision 物体检测，返回物体标签列表（离线免费）。
    private static func executeVisionObjects(context: CustomAgentToolContext) async -> String {
        guard let frame = context.latestFrame() else {
            return "custom.agent.tool.vision.frame.missing".localized
        }
        let result = await VisionSceneService.analyze(frame)
        let summary = VisionSceneTextProcessor.objectSummary(from: result)
        guard !summary.isEmpty else {
            return "agent.vision.objects.empty".localized
        }
        return summary
    }
}
