/*
 * Hermes Gateway Protocol Models
 * 定义与 Hermes Agent OpenAI 兼容 API Server (/v1/responses) 通信的消息格式
 * 参考: https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server
 */

import Foundation

// MARK: - Responses API Request

struct HermesResponsesRequest: Encodable {
    let model: String
    let input: HermesResponseInput
    let conversation: String?
    let stream: Bool
    let instructions: String?

    static func plainText(
        _ text: String,
        model: String,
        conversation: String?,
        instructions: String? = nil
    ) -> HermesResponsesRequest {
        HermesResponsesRequest(
            model: model,
            input: .text(text),
            conversation: conversation,
            stream: true,
            instructions: instructions
        )
    }

    static func withImage(
        _ text: String,
        jpegBase64: String,
        model: String,
        conversation: String?,
        instructions: String? = nil
    ) -> HermesResponsesRequest {
        let content: [HermesInputContent] = [
            .init(type: "input_text", text: text, imageURL: nil),
            .init(type: "input_image", text: nil, imageURL: "data:image/jpeg;base64,\(jpegBase64)")
        ]
        return HermesResponsesRequest(
            model: model,
            input: .items([
                .init(role: "user", content: content)
            ]),
            conversation: conversation,
            stream: true,
            instructions: instructions
        )
    }
}

enum HermesResponseInput: Encodable {
    case text(String)
    case items([HermesInputItem])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .items(let items):
            try container.encode(items)
        }
    }
}

struct HermesInputItem: Encodable {
    let role: String
    let content: [HermesInputContent]
}

struct HermesInputContent: Encodable {
    let type: String
    let text: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

// MARK: - Responses API Response (non-streaming / final)

struct HermesResponsesResponse: Codable {
    let id: String?
    let status: String?
    let output: [HermesResponseOutputItem]?
    let error: HermesAPIError?

    var assembledText: String {
        guard let output else { return "" }
        return output.compactMap { item -> String? in
            guard item.type == "message" else { return nil }
            return item.content?.compactMap { block in
                block.type == "output_text" ? block.text : nil
            }.joined()
        }.joined()
    }

    /// output 中的 function_call 条目（服务端已执行，供 UI 展示工具生命周期）
    var toolCalls: [HermesToolCallInfo] {
        output?.compactMap { item in
            guard item.type == "function_call",
                  let callID = item.callID,
                  let name = item.name else { return nil }
            return HermesToolCallInfo(callID: callID, name: name, arguments: item.arguments)
        } ?? []
    }

    /// output 中的 function_call_output 条目（工具结果，供 UI 展示）
    var toolResults: [HermesToolResultInfo] {
        output?.compactMap { item in
            guard item.type == "function_call_output",
                  let callID = item.callID,
                  let output = item.output else { return nil }
            return HermesToolResultInfo(callID: callID, output: output.text)
        } ?? []
    }
}

struct HermesResponseOutputItem: Codable {
    let id: String?
    let type: String?
    let name: String?
    let status: String?
    let content: [HermesResponseContentBlock]?
    let callID: String?
    let arguments: String?
    let output: HermesToolOutput?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case status
        case content
        case callID = "call_id"
        case arguments
        case output
    }
}

struct HermesResponseContentBlock: Codable {
    let type: String?
    let text: String?
}

struct HermesAPIError: Codable {
    let code: String?
    let message: String?
}

/// 工具结果输出：非流式为字符串，Hermes 流式/部分批量路径为 input_text 数组
enum HermesToolOutput: Codable, Equatable {
    case text(String)
    case parts([String])

    var text: String {
        switch self {
        case .text(let value): return value
        case .parts(let values): return values.joined(separator: "\n")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let parts = try? container.decode([HermesOutputPart].self) {
            self = .parts(parts.compactMap { $0.text })
        } else {
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .parts(let values):
            try container.encode(values)
        }
    }
}

struct HermesOutputPart: Codable {
    let type: String?
    let text: String?
}

// MARK: - SSE Events (OpenAI Responses streaming format)

struct HermesSSEEvent {
    let type: String
    let json: [String: Any]

    /// item 内层（流式路径的 function_call / function_call_output 均为嵌套结构）
    private var item: [String: Any]? {
        json["item"] as? [String: Any]
    }

    var textDelta: String? {
        json["delta"] as? String
    }

    /// Function call item name（兼容扁平与嵌套 item 两种格式）。
    var functionCallName: String? {
        let isFunctionCall = json["type"] as? String == "function_call"
            || itemType == "function_call"
        guard isFunctionCall else { return nil }
        return json["name"] as? String ?? item?["name"] as? String
    }

    /// 当前事件的 item 类型（function_call / function_call_output / message …）
    var itemType: String? {
        item?["type"] as? String
    }

    /// 事件是否携带 function_call（扁平或嵌套 item）
    var isFunctionCall: Bool {
        json["type"] as? String == "function_call" || itemType == "function_call"
    }

    /// 事件是否携带 function_call_output（扁平或嵌套 item）
    var isFunctionCallOutput: Bool {
        json["type"] as? String == "function_call_output" || itemType == "function_call_output"
    }

    /// function_call 的 call_id（嵌套 item 优先，兼容扁平）
    var functionCallID: String? {
        item?["call_id"] as? String ?? json["call_id"] as? String
    }

    /// function_call 的完整参数 JSON（嵌套 item 优先，兼容扁平）
    var functionCallArguments: String? {
        item?["arguments"] as? String ?? json["arguments"] as? String
    }

    /// function_call_output 的输出：流式路径为 input_text 数组，非流式为字符串
    var functionCallOutput: String? {
        guard isFunctionCallOutput else { return nil }
        if let output = item?["output"] as? String {
            return output
        }
        if let output = json["output"] as? String {
            return output
        }
        if let parts = item?["output"] as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                guard part["type"] as? String == "input_text" else { return nil }
                return part["text"] as? String
            }
            return texts.joined(separator: "\n")
        }
        return nil
    }

    /// Tool progress event emitted by Hermes (`hermes.tool.progress`).
    var toolName: String? {
        guard json["type"] as? String == "hermes.tool.progress" else { return nil }
        if let tool = json["tool"] as? String { return tool }
        if let name = json["name"] as? String { return name }
        return json["tool_name"] as? String
    }

    var isError: Bool {
        json["type"] as? String == "error" || json["type"] as? String == "response.failed"
    }

    var errorMessage: String? {
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let response = json["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return json["message"] as? String
    }
}

enum HermesSSEParser {
    /// Parse a chunk of SSE text (may contain partial lines at the end).
    /// Returns complete events plus any leftover buffer.
    static func parse(chunk: String, into buffer: inout String) -> [HermesSSEEvent] {
        buffer += chunk
        let lines = buffer.components(separatedBy: "\n")
        guard let last = lines.last else { return [] }
        buffer = last.isEmpty ? "" : last

        var events: [HermesSSEEvent] = []
        var eventType: String?
        var dataLines: [String] = []

        for line in lines.dropLast() {
            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                dataLines.append(payload)
            } else if line.isEmpty {
                flush()
            }
        }
        flush()

        func flush() {
            let data = dataLines.joined(separator: "\n")
            defer {
                eventType = nil
                dataLines.removeAll()
            }
            guard !data.isEmpty,
                  let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return
            }
            let type = (json["type"] as? String) ?? eventType
            guard let type else { return }
            events.append(HermesSSEEvent(type: type, json: json))
        }

        return events
    }
}

// MARK: - Stream Accumulator

/// 服务端已启动的工具调用（function_call，含参数）
struct HermesToolCallInfo: Equatable {
    let callID: String
    let name: String
    let arguments: String?
}

/// 服务端已完成的工具结果（function_call_output）
struct HermesToolResultInfo: Equatable {
    let callID: String
    let output: String
}

/// Accumulates streamed text deltas and final completion payloads.
struct HermesStreamAccumulator {
    private(set) var text = ""
    private(set) var toolName: String?
    private(set) var toolCalls: [HermesToolCallInfo] = []
    private(set) var toolResults: [HermesToolResultInfo] = []
    private var knownToolCallIDs = Set<String>()
    private var knownToolResultIDs = Set<String>()

    mutating func apply(_ event: HermesSSEEvent) {
        switch event.type {
        case "response.output_text.delta":
            text += event.textDelta ?? ""
        case "response.output_item.added", "response.output_item.done":
            if let name = event.functionCallName {
                toolName = name
            }
            if event.isFunctionCall,
               let callID = event.functionCallID {
                guard knownToolCallIDs.insert(callID).inserted else { break }
                toolCalls.append(HermesToolCallInfo(
                    callID: callID,
                    name: event.functionCallName ?? "agent.tool.unknown".localized,
                    arguments: event.functionCallArguments
                ))
            }
            if event.isFunctionCallOutput,
               let callID = event.functionCallID,
               let output = event.functionCallOutput {
                guard knownToolResultIDs.insert(callID).inserted else { break }
                toolResults.append(HermesToolResultInfo(callID: callID, output: output))
            }
        case "hermes.tool.progress":
            if let name = event.toolName {
                toolName = name
            }
        case "response.completed":
            if let response = decodeResponse(from: event.json["response"]),
               !response.assembledText.isEmpty {
                text = response.assembledText
            }
        default:
            break
        }
    }

    private func decodeResponse(from value: Any?) -> HermesResponsesResponse? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(HermesResponsesResponse.self, from: data)
    }

    /// 消费完工具结果后清空（避免重复回调）
    mutating func clearToolResults() {
        toolResults = []
    }
}
