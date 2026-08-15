/*
 * Custom WebSocket Agent Protocol
 * 自定义 Agent 的 WebSocket 接入：客户端发送 chat 请求，服务端以 JSON 事件流式返回。
 *
 * 客户端 → 服务端：
 *   {"type":"chat","model":"...","messages":[...],"tools":[...]}
 *   {"type":"tool_result","call_id":"...","name":"...","content":"..."}
 *   {"type":"pong"}
 * 服务端 → 客户端：
 *   {"type":"delta","content":"..."}                       文本增量
 *   {"type":"done","content":"..."}                        最终全文（结束）
 *   {"type":"tool_call","call_id":"...","name":"...","arguments":"..."}  完整工具调用
 *   {"type":"error","message":"..."}                       错误（结束）
 *   {"type":"ping"}                                        保活
 *
 * 消息构建与服务端事件解析均为纯逻辑，便于单元测试。
 */

import Foundation
import UIKit

/// WebSocket 服务端事件（已解析，可测）
enum CustomWebSocketServerEvent: Equatable {
    case delta(content: String)
    case done(content: String)
    case toolCall(callID: String, name: String, arguments: String)
    case error(message: String)
    case ping
    /// 无法识别的 JSON（忽略不处理）
    case malformed
}

/// WebSocket 协议编解码（纯逻辑，可测）
enum CustomWebSocketCoder {
    /// 构建 chat 请求载荷（OpenAI 形状消息；图片以 data URL 多模态 content 发送）
    static func makeChatPayload(
        model: String,
        text: String,
        image: UIImage? = nil,
        history: [CustomChatTurn] = [],
        systemPrompt: String? = nil,
        toolsJSON: String = ""
    ) -> Data? {
        var messages: [[String: Any]] = history.suffix(20).map { turn in
            ["role": turn.role, "content": turn.text]
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.insert(["role": "system", "content": systemPrompt], at: 0)
        }
        messages.append(["role": "user", "content": userContent(text: text, image: image)])

        var payload: [String: Any] = [
            "type": "chat",
            "model": model,
            "messages": messages,
        ]
        if let tools = toolsArray(from: toolsJSON) {
            payload["tools"] = tools
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// 构建工具执行结果回传
    static func makeToolResultPayload(callID: String, name: String, content: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "type": "tool_result",
            "call_id": callID,
            "name": name,
            "content": content,
        ])
    }

    /// 构建 ping 响应
    static func makePongPayload() -> Data? {
        try? JSONSerialization.data(withJSONObject: ["type": "pong"])
    }

    /// 解析服务端事件文本；非 JSON 返回 .malformed
    static func parseServerEvent(_ text: String) -> CustomWebSocketServerEvent {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return .malformed
        }
        switch type {
        case "delta":
            return .delta(content: json["content"] as? String ?? "")
        case "done":
            return .done(content: json["content"] as? String ?? "")
        case "tool_call":
            return .toolCall(
                callID: json["call_id"] as? String ?? UUID().uuidString,
                name: json["name"] as? String ?? "",
                arguments: json["arguments"] as? String ?? ""
            )
        case "error":
            return .error(message: json["message"] as? String ?? "Unknown error")
        case "ping":
            return .ping
        default:
            return .malformed
        }
    }

    /// 用户消息内容：无图纯文本；有图 OpenAI 多模态 content 数组（data URL）
    private static func userContent(text: String, image: UIImage?) -> Any {
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

    /// 解析配置中的工具声明 JSON 数组；非法或为空返回 nil（不声明工具）
    static func toolsArray(from json: String) -> [Any]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [Any] else {
            return nil
        }
        return array
    }
}

/// 自定义 WebSocket Agent 服务（URLSessionWebSocketTask，支持注入便于测试）
@MainActor
final class CustomWebSocketAgentService {
    static let shared = CustomWebSocketAgentService()

    private let session: URLSession
    private var currentTask: URLSessionWebSocketTask?
    private var currentRun: Task<Void, Never>?
    private let maxToolRoundsDefault = 4

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 健康检查：完成 WebSocket 握手（首帧可接收）即视为在线
    func checkHealth(config: CustomAgentConfig) async -> Bool {
        guard let url = URL(string: config.baseURL) else { return false }
        let task = session.webSocketTask(with: url)
        task.resume()
        let connected = await withCheckedContinuation { continuation in
            var finished = false
            Task {
                do {
                    _ = try await task.receive()
                    if !finished {
                        finished = true
                        continuation.resume(returning: true)
                    }
                } catch {
                    if !finished {
                        finished = true
                        continuation.resume(returning: false)
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !finished {
                    finished = true
                    task.cancel(with: .goingAway, reason: nil)
                    continuation.resume(returning: false)
                }
            }
        }
        task.cancel(with: .goingAway, reason: nil)
        return connected
    }

    /// 发送消息（WebSocket 流式）；toolExecutor 非空时自动完成工具调用 → 本地执行 → 结果回传循环
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
        guard let url = URL(string: config.baseURL) else {
            onError("custom.agent.ws.error.invalidurl".localized)
            return
        }
        guard let payload = CustomWebSocketCoder.makeChatPayload(
            model: config.model,
            text: text,
            image: image,
            history: history,
            systemPrompt: systemPrompt,
            toolsJSON: config.toolsJSON
        ) else {
            onError("custom.agent.ws.error.encode".localized)
            return
        }

        cancel()
        let task = session.webSocketTask(with: url)
        currentTask = task
        task.resume()

        currentRun = Task { [weak self] in
            guard let self else { return }
            do {
                try await task.send(.data(payload))
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                onError("custom.agent.ws.error.disconnected".localized)
                return
            }

            var toolRounds = 0
            var finalText = ""
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    onError("custom.agent.ws.error.disconnected".localized)
                    break
                }
                let textPayload: String
                switch message {
                case .string(let string):
                    textPayload = string
                case .data(let data):
                    textPayload = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }
                switch CustomWebSocketCoder.parseServerEvent(textPayload) {
                case .delta(let content):
                    finalText += content
                    onDelta(content)
                case .done(let content):
                    onComplete(content.isEmpty ? finalText : content)
                    task.cancel(with: .goingAway, reason: nil)
                    self.currentRun = nil
                    return
                case .toolCall(let callID, let name, let arguments):
                    onTool?(name)
                    toolRounds += 1
                    let result: String
                    if let toolExecutor, toolRounds <= maxToolRounds {
                        result = await toolExecutor(
                            CustomToolCall(id: callID, name: name, arguments: arguments)
                        )
                    } else {
                        result = "custom.agent.ws.tools.limit".localized
                    }
                    if let resultPayload = CustomWebSocketCoder.makeToolResultPayload(
                        callID: callID, name: name, content: result
                    ) {
                        try? await task.send(.data(resultPayload))
                    }
                case .error(let message):
                    onError(message)
                    task.cancel(with: .goingAway, reason: nil)
                    self.currentRun = nil
                    return
                case .ping:
                    if let pong = CustomWebSocketCoder.makePongPayload() {
                        try? await task.send(.data(pong))
                    }
                case .malformed:
                    break
                }
            }
        }
    }

    func cancel() {
        currentRun?.cancel()
        currentRun = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
    }
}
