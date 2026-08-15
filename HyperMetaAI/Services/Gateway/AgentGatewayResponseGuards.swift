/*
 * Agent Gateway Response Guards
 * 对齐 qwen-audio-agent v1.8.3 server/src/voice/response-guards/ 与
 * server/src/voice/response-lifecycle.mjs：
 *   - action-promise：识别模型「明确承诺执行但未调用工具」的短句并纠偏
 *   - response lifecycle：识别实时协议中证明存在响应的活动事件
 * 纯逻辑，可测。
 */

import Foundation

// MARK: - Action Promise 守卫

/// 识别「好的，我来查一下」这类明确承诺执行但未调用工具的短句。
/// 对齐 JS 正则（非通用意图分类：复合句与已交付答案仍交给模型判断）。
enum AgentGatewayActionPromiseGuard {
    static let id = "action-promise"

    /// 超出该长度不视为承诺短句
    static let maxChars = 40

    /// 指令文案（模型未调用工具时注入纠正）
    static let instructions = [
        "你刚才明确承诺执行，但本轮没有调用工具。",
        "请重新判断：确需执行则立即调用合适工具；否则直接结束，不要再次承诺。"
    ].joined(separator: " ")

    private static let actionPromisePattern = [
        "^",
        "(?:(?:好的?|好|行|明白|收到)[，,\\s]*)?",
        "(?:稍等[，,\\s]*)?",
        "(?:",
        "我(?:来|去|先去|马上|立刻|现在(?:就)?|这就)(?:帮你|替你)?",
        "|让我来",
        "|马上(?:去|来)?",
        "|现在就(?:去|来)?",
        ")",
        "(?:",
        "查(?:一下)?|查询|查找|看(?:一下)?|检查|确认|核实|搜索|排查|调查",
        "|处理|修改|调整|创建|新建|运行|跑(?:一下)?|测试|验证",
        ")",
        "[^，,。；;：:！？!?\\n]{0,28}",
        "[。！!]?",
        "$"
    ].joined()

    private static let confirmationRequestPattern = [
        "[？?]\\s*$",
        "好吗",
        "可以吗",
        "行吗",
        "要不要",
        "需要我",
        "是否需要",
        "要我(?:现在|先)?(?:去|来|帮)"
    ].joined(separator: "|")

    private static let deliveredContentPattern = [
        "(?:[：:]|结果|答案|查到|找到|发现|显示|已经(?:完成|处理|修改|创建|运行|测试)|原因是|因为)"
    ].joined()

    /// 是否属于「承诺执行」短句
    static func promisesAction(_ transcript: String) -> Bool {
        let content = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.count <= maxChars else { return false }
        guard !matches(confirmationRequestPattern, in: content) else { return false }
        guard !matches(deliveredContentPattern, in: content) else { return false }
        return matches(actionPromisePattern, in: content)
    }

    /// 守卫判定（origin=model、无工具调用、未失败/未抑制且命中承诺短句时触发）
    static func matches(
        origin: String,
        hasFunctionCall: Bool,
        failed: Bool,
        suppressed: Bool,
        transcript: String
    ) -> Bool {
        guard origin == "model" else { return false }
        if hasFunctionCall || failed || suppressed { return false }
        return promisesAction(transcript)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - Response Lifecycle

/// 实时响应生命周期工具（对齐 response-lifecycle.mjs）
enum AgentGatewayResponseLifecycle {
    /// 证明存在响应的服务端事件类型集合
    static let responseActivityTypes: Set<String> = [
        "response.created",
        "response.done",
        "response.output_item.added",
        "response.output_item.done",
        "response.content_part.added",
        "response.content_part.done",
        "response.function_call_arguments.delta",
        "response.function_call_arguments.done",
        "response.audio.delta",
        "response.audio.done",
        "response.output_audio.delta",
        "response.output_audio.done",
        "response.audio_transcript.delta",
        "response.audio_transcript.done",
        "response.output_audio_transcript.delta",
        "response.output_audio_transcript.done",
        "response.text.delta",
        "response.text.done",
        "response.output_text.delta",
        "response.output_text.done"
    ]

    /// 从事件字段提取 response_id（response_id / response.id / item.response_id）
    static func realtimeResponseId(
        responseId: String?,
        responseObjectId: String?,
        itemResponseId: String?
    ) -> String {
        if let responseId, !responseId.isEmpty { return responseId }
        if let responseObjectId, !responseObjectId.isEmpty { return responseObjectId }
        return itemResponseId ?? ""
    }

    /// 是否响应活动事件：带 response_id 且类型在活动集合内
    static func isResponseActivityEvent(type: String, responseId: String) -> Bool {
        !responseId.isEmpty && responseActivityTypes.contains(type)
    }
}
