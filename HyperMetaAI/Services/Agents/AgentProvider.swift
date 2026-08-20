/*
 * Unified Agent Layer
 * 将 OpenClaw / Hermes 等 Agent 统一为同一套功能入口与状态模型
 * 每种 Agent 只负责提供: 连接状态、发送消息(流式)、断开/取消
 */

import Foundation
import UIKit

// MARK: - Agent Kind

enum AgentKind: String, CaseIterable, Identifiable {
    case openclaw
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openclaw: return "OpenClaw"
        case .hermes: return "Hermes"
        }
    }

    var iconName: String {
        switch self {
        case .openclaw: return "link.circle.fill"
        case .hermes: return "wand.and.stars"
        }
    }

    /// 连接状态下可聊天；未连接时仍可进入聊天页查看配置引导
    var subtitle: String {
        switch self {
        case .openclaw: return "Self-improving agent (OpenClaw Gateway)"
        case .hermes: return "Nous Research Hermes Agent"
        }
    }
}

// MARK: - Unified Connection State

enum AgentConnectionState: Equatable {
    case unknown
    case connecting
    case connected
    case waitingForPairing
    case failed(String)

    var isOnline: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }

    static func map(_ state: OpenClawConnectionState) -> AgentConnectionState {
        switch state {
        case .disconnected: return .unknown
        case .connecting: return .connecting
        case .waitingForPairing: return .waitingForPairing
        case .connected: return .connected
        case .error(let message): return .failed(message)
        }
    }

    static func map(_ state: HermesConnectionState) -> AgentConnectionState {
        switch state {
        case .unknown: return .unknown
        case .checking: return .connecting
        case .online: return .connected
        case .offline(let message): return .failed(message)
        }
    }
}

// MARK: - Agent Brain（语音页听写大脑）

/// 语音页的「大脑」：Qwen 原生实时语音，或把听写文本转发给后台 Agent。
enum AgentBrain: String, CaseIterable, Identifiable, Hashable {
    /// 自动路由：只选择当前可用的后台 Agent；无可用后端时进入仅前台模式。
    case auto
    /// 仅使用 Qwen 实时语音前台，不连接或调用后台 Agent。
    case none
    case qwen
    case hermes
    case openclaw
    /// 自定义 HTTP Agent（听写转发；具体配置由 AgentBrainSettings.selectedCustomAgentID 决定）
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .none: return "agent.brain.none".localized
        case .qwen: return "Qwen"
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        case .custom: return "Custom Agent"
        }
    }

    var symbolName: String {
        switch self {
        case .auto: return "sparkles"
        case .none: return "network.slash"
        case .qwen: return "waveform"
        case .hermes: return "wand.and.stars"
        case .openclaw: return "link.circle.fill"
        case .custom: return "globe"
        }
    }

    /// 已解析到可执行后台的具体选择。Auto 必须先经路由解析。
    var isConcreteBackend: Bool {
        switch self {
        case .hermes, .openclaw, .custom: return true
        case .auto, .none, .qwen: return false
        }
    }
}

/// 大脑选择偏好（UserDefaults 持久化）
enum AgentBrainSettings {
    static let key = "agent.brain.selection"
    static let customAgentIDKey = "agent.brain.custom.agent.id"

    static var selected: AgentBrain {
        get {
            AgentBrain(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    /// Custom Agent 大脑使用的具体配置 ID；nil 时回退到配置列表首个
    static var selectedCustomAgentID: UUID? {
        get {
            UserDefaults.standard.string(forKey: customAgentIDKey).flatMap(UUID.init(uuidString:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: customAgentIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: customAgentIDKey)
            }
        }
    }
}

/// 当前可供 Auto 选择的后台 Agent。值类型让路由规则无需真实网络即可测试。
struct AgentBackendAvailability: Equatable {
    var openClawReady: Bool
    var hermesReady: Bool
    var customReady: Bool

    static let none = AgentBackendAvailability(
        openClawReady: false,
        hermesReady: false,
        customReady: false
    )

    var hasReadyBackend: Bool {
        openClawReady || hermesReady || customReady
    }

    func isReady(_ brain: AgentBrain) -> Bool {
        switch brain {
        case .openclaw: return openClawReady
        case .hermes: return hermesReady
        case .custom: return customReady
        case .auto, .none, .qwen: return false
        }
    }

    /// OpenClaw / Hermes 以健康连接为准；自定义后端以已保存的合法配置为准。
    @MainActor
    static var current: AgentBackendAvailability {
        AgentBackendAvailability(
            openClawReady: OpenClawNodeService.shared.connectionState == .connected,
            hermesReady: HermesService.shared.connectionState.isOnline,
            customReady: CustomAgentStore.configs.contains(where: \.isValid)
        )
    }
}

/// The realtime voice frontend must keep one stable output owner for a full
/// provider session. Auto stays on native Qwen; backend transcription mode is
/// entered only for an explicitly selected backend that is ready at connect.
enum AgentVoiceBrainPolicy {
    static func forwardingTarget(
        selection: AgentBrain,
        availability: AgentBackendAvailability
    ) -> AgentBrain? {
        guard selection.isConcreteBackend,
              availability.isReady(selection) else { return nil }
        return selection
    }
}

/// Auto 大脑路由的自定义关键词（UserDefaults 持久化，可配置增删）
enum AgentRoutingSettings {
    static let customTaskKeywordsKey = "agent.routing.task.keywords"
    static let customChatKeywordsKey = "agent.routing.chat.keywords"

    /// 自定义任务型触发词（命中路由 OpenClaw）
    static var customTaskKeywords: [String] {
        get { UserDefaults.standard.stringArray(forKey: customTaskKeywordsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: customTaskKeywordsKey) }
    }

    /// 自定义闲聊触发词（命中路由 Hermes）
    static var customChatKeywords: [String] {
        get { UserDefaults.standard.stringArray(forKey: customChatKeywordsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: customChatKeywordsKey) }
    }

    /// 添加任务词（去除首尾空白、空词与重复返回 false）
    @discardableResult
    static func addTaskKeyword(_ keyword: String) -> Bool {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var words = customTaskKeywords
        guard !words.contains(trimmed) else { return false }
        words.append(trimmed)
        customTaskKeywords = words
        return true
    }

    @discardableResult
    static func removeTaskKeyword(_ keyword: String) -> Bool {
        var words = customTaskKeywords
        guard let index = words.firstIndex(of: keyword) else { return false }
        words.remove(at: index)
        customTaskKeywords = words
        return true
    }

    @discardableResult
    static func addChatKeyword(_ keyword: String) -> Bool {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var words = customChatKeywords
        guard !words.contains(trimmed) else { return false }
        words.append(trimmed)
        customChatKeywords = words
        return true
    }

    @discardableResult
    static func removeChatKeyword(_ keyword: String) -> Bool {
        var words = customChatKeywords
        guard let index = words.firstIndex(of: keyword) else { return false }
        words.remove(at: index)
        customChatKeywords = words
        return true
    }
}

/// Agent 回合错误：分类 + 用户提示 + 兜底恢复动作（纯逻辑，可测）
struct AgentTurnError: Equatable {
    enum Kind: Equatable {
        /// 静音超时（没听到用户说话），回合自动结束
        case idleTimeout
        /// 语音网关不可达/连接失败
        case gatewayUnreachable
        /// 语音前端不可用或休眠
        case voiceUnavailable
        /// 眼镜设备会话意外结束（断开/合上眼镜）
        case deviceDisconnected
        /// 通用错误（网关 error 事件原文）
        case generic
    }

    let kind: Kind
    /// 用户可读提示（本地化 key；generic 为原始消息）
    let messageKey: String
    /// 兜底恢复动作提示（本地化 key，nil 表示无）
    let recoveryKey: String?
}

/// 把会话信号分类为可操作的回合错误（供 UI 降级展示）
enum AgentTurnErrorClassifier {
    /// 网关连接状态 → 回合错误（connected/disconnected/connecting 返回 nil）
    static func classify(connectionState: QwenGatewayConnectionState) -> AgentTurnError? {
        guard case .failed(let message) = connectionState else { return nil }
        let lower = message.lowercased()
        if lower.contains("sleep") || lower.contains("休眠") || lower.contains("unavailable") {
            return AgentTurnError(
                kind: .voiceUnavailable,
                messageKey: "agent.error.voice.unavailable",
                recoveryKey: "agent.error.recovery.wake"
            )
        }
        return AgentTurnError(
            kind: .gatewayUnreachable,
            messageKey: "agent.error.gateway.unreachable",
            recoveryKey: "agent.error.recovery.wake"
        )
    }

    /// 静音超时错误
    static func idleTimeout() -> AgentTurnError {
        AgentTurnError(
            kind: .idleTimeout,
            messageKey: "agent.error.idle.timeout",
            recoveryKey: "agent.error.recovery.tap"
        )
    }

    /// 眼镜设备会话意外结束
    static func deviceDisconnected() -> AgentTurnError {
        AgentTurnError(
            kind: .deviceDisconnected,
            messageKey: "agent.error.device.disconnected",
            recoveryKey: "agent.error.recovery.reconnect"
        )
    }

    /// 网关 error 事件（保留原始消息）
    static func generic(_ message: String) -> AgentTurnError {
        AgentTurnError(kind: .generic, messageKey: message, recoveryKey: nil)
    }
}

/// OpenClaw 聊天事件解析（流式快照 → 增量/最终文本），纯逻辑可测
enum AgentBrainEventParser {
    /// 解析一条 onChatEvent 快照；返回 (是否最终, 文本)
    static func parseOpenClawEvent(_ text: String) -> (isFinal: Bool, text: String) {
        if text.hasPrefix("[[FINAL]]") {
            return (true, String(text.dropFirst("[[FINAL]]".count)))
        }
        return (false, text)
    }
}

/// 语音页历史落盘的 Agent 标识：Custom Agent 大脑按配置 ID 归类（进入 Hub 统一时间线），
/// 其余（Qwen / Hermes / OpenClaw / Auto）统一归 qwen-audio-agent
enum AgentVoiceHistoryNaming {
    static func agentName(brain: AgentBrain, customConfig: CustomAgentConfig?) -> String {
        if brain == .custom, let config = customConfig {
            return "custom." + config.id.uuidString
        }
        return "qwen-audio-agent"
    }
}

/// Marks requests that need current external facts and adds a compact execution
/// contract only for those turns. Keeping this out of ordinary chat avoids extra
/// prompt tokens and preserves realtime first-response latency.
enum AgentWebSearchPolicy {
    private static let explicitSearchSignals = [
        "联网", "上网查", "搜索", "搜一下", "查一下", "查一查", "核实一下",
        "web search", "search online", "look up", "browse the web",
    ]
    private static let volatileSubjects = [
        "天气", "新闻", "股价", "汇率", "金价", "油价", "航班", "列车", "高铁",
        "比赛", "赛程", "比分", "路况", "票价", "价格", "营业时间", "库存",
        "weather", "news", "stock price", "exchange rate", "flight", "schedule",
        "score", "traffic", "opening hours", "availability",
    ]
    private static let freshnessSignals = [
        "最新", "实时", "当前", "今天", "明天", "本周", "刚刚", "最近",
        "latest", "live", "current", "today", "tomorrow", "this week", "recent",
    ]
    private static let timelessKnowledgeSignals = [
        "为什么", "原理", "解释", "是什么", "历史", "如何运作",
        "why", "explain", "what is", "history of", "how does",
    ]

    static func requiresWebSearch(_ text: String) -> Bool {
        let normalized = text.lowercased()
        if explicitSearchSignals.contains(where: normalized.contains) { return true }
        let hasVolatileSubject = volatileSubjects.contains(where: normalized.contains)
        let hasFreshnessSignal = freshnessSignals.contains(where: normalized.contains)
        if !hasFreshnessSignal,
           timelessKnowledgeSignals.contains(where: normalized.contains) {
            return false
        }
        return hasVolatileSubject && (hasFreshnessSignal || normalized.count <= 24)
    }

    static func preparedRequest(
        _ text: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        guard requiresWebSearch(text) else { return text }
        let timestamp = ISO8601DateFormatter().string(from: now)
        return """
        【联网检索要求】并行检索独立事实；优先官方、一手和近期来源；核对发布日期与事件发生时间并交叉验证关键结论；先以【语音结论】开头给一句不含网址的结论，再给要点；链接统一放在末尾来源区并注明检索时间。不要把模型记忆当作实时结果。
        【检索基准时间】\(timestamp)（\(timeZone.identifier)）
        \(text)
        """
    }
}

/// 把听写文本转发给指定大脑（Hermes 流式回调 / OpenClaw 快照回调）。
/// Qwen 与仅前台模式不转发。
@MainActor
final class AgentBrainRouter {
    static let shared = AgentBrainRouter()

    /// 意图路由结果
    enum Route: Equatable {
        /// 实时语音交互（简短闲聊）
        case qwen
        /// 知识问答/推理
        case hermes
        /// 执行型任务（调用工具）
        case openclaw
    }

    /// 内置执行型任务的触发词（命中即路由 OpenClaw）
    private static let defaultTaskKeywords: [String] = [
        "帮我", "请帮我", "帮我查", "帮我订", "帮我买", "帮我发", "帮我设置",
        "帮我打开", "帮我创建", "帮我删除", "帮我搜索", "帮我下载", "帮我上传",
        "帮我写", "帮我把", "帮我做", "查一下", "查一查", "订一个", "订票",
        "买", "发消息", "发邮件", "设置", "设置提醒", "定个闹钟", "创建", "删除",
        "打开", "关闭", "搜索", "下载", "上传", "翻译", "总结", "汇总",
        "生成", "整理", "预订", "查询", "播报",
    ]

    /// 内置简短问候/闲聊（命中即路由 Qwen 原生实时）
    private static let defaultChatGreetings: [String] = [
        "你好", "您好", "嗨", "哈喽", "hello", "hi", "早上好", "中午好",
        "下午好", "晚上好", "晚安", "谢谢", "再见",
    ]

    private let hermesService = HermesService.shared
    private let openClawService = OpenClawNodeService.shared

    private init() {}

    /// 当前选择是否需要关闭 Qwen 输出并把听写转发到后台 Agent。
    static func isForwarding(
        to brain: AgentBrain,
        availability: AgentBackendAvailability? = nil
    ) -> Bool {
        switch brain {
        case .auto:
            return (availability ?? .current).hasReadyBackend
        case .hermes, .openclaw, .custom:
            return true
        case .none, .qwen:
            return false
        }
    }

    /// 纯规则意图路由：根据用户文本推断最佳大脑（可测试）
    static func route(_ text: String) -> Route {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .qwen }
        if AgentWebSearchPolicy.requiresWebSearch(trimmed) {
            return .openclaw
        }
        let taskKeywords = defaultTaskKeywords + AgentRoutingSettings.customTaskKeywords
        if taskKeywords.contains(where: { trimmed.contains($0) }) {
            return .openclaw
        }
        let lowered = trimmed.lowercased()
        let chatKeywords = defaultChatGreetings + AgentRoutingSettings.customChatKeywords
        if trimmed.count <= 6 || chatKeywords.contains(where: { lowered.contains($0) }) {
            return .qwen
        }
        return .hermes
    }

    /// Auto 模式只在已就绪后端中选择；无可用后端时进入仅前台模式。
    /// 任务优先 OpenClaw，普通对话优先 Hermes，缺席时依次回退到其他可用后端。
    static func resolvedBrain(
        _ text: String,
        selection: AgentBrain,
        availability: AgentBackendAvailability? = nil
    ) -> AgentBrain {
        guard selection == .auto else { return selection }
        let ready = availability ?? .current
        let candidates: [AgentBrain]
        switch route(text) {
        case .openclaw:
            candidates = [.openclaw, .hermes, .custom]
        case .qwen, .hermes:
            candidates = [.hermes, .custom, .openclaw]
        }
        return candidates.first(where: ready.isReady) ?? .none
    }

    /// 转发用户文本；Hermes 逐段回调，OpenClaw 通过 onChatEvent 快照回调
    func forward(
        _ text: String,
        to brain: AgentBrain,
        image: UIImage? = nil,
        onDelta: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onTool: ((String) -> Void)? = nil,
        onToolResult: ((String, String) -> Void)? = nil
    ) {
        let requestText = AgentWebSearchPolicy.preparedRequest(text)
        switch brain {
        case .auto:
            break
        case .none:
            break
        case .qwen:
            break
        case .hermes:
            hermesService.sendMessage(
                requestText,
                image: image,
                instructions: AgentSystemPromptBuilder.build(),
                onDelta: onDelta,
                onTool: onTool ?? { _ in },
                onToolResult: onToolResult,
                onComplete: onFinal,
                onError: onError
            )
        case .openclaw:
            openClawService.sendChatMessage(requestText, image: image)
        case .custom:
            guard let config = Self.customAgentConfig() else {
                onError("custom.agent.brain.noconfig".localized)
                return
            }
            CustomAgentService.shared.sendMessage(
                config: config,
                text: requestText,
                image: image,
                systemPrompt: AgentSystemPromptBuilder.build(),
                toolExecutor: { call in
                    await CustomAgentLocalTools.execute(
                        call,
                        context: CustomAgentToolContext(
                            latestFrame: { QwenVoiceSession.shared.latestVisionFrame }
                        )
                    )
                },
                onDelta: onDelta,
                onTool: onTool ?? { _ in },
                onComplete: onFinal,
                onError: onError
            )
        }
    }

    /// 当前 Custom Agent 大脑的配置：优先用户选择，否则取配置列表首个
    static func customAgentConfig() -> CustomAgentConfig? {
        let configs = CustomAgentStore.configs.filter(\.isValid)
        guard !configs.isEmpty else { return nil }
        if let id = AgentBrainSettings.selectedCustomAgentID,
           let config = configs.first(where: { $0.id == id }) {
            return config
        }
        return configs.first
    }

    /// 取消进行中的大脑回复
    func cancel(to brain: AgentBrain) {
        switch brain {
        case .auto:
            // Auto 可能路由到任一转发大脑，全部取消
            hermesService.cancel()
            openClawService.onChatEvent = nil
            CustomAgentService.shared.cancel()
        case .none:
            break
        case .qwen:
            break
        case .hermes:
            hermesService.cancel()
        case .openclaw:
            openClawService.onChatEvent = nil
        case .custom:
            CustomAgentService.shared.cancel()
        }
    }
}
