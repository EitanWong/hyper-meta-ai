/*
 * Agent Conversation Persister
 * 把 Agent 聊天/语音会话转写持久化为 ConversationRecord（供「记录」页回看）。
 * 纯逻辑，便于单元测试；图片消息与空消息不入库。
 */

import Foundation

enum AgentConversationPersister {

    /// 从记录列表恢复最近一条属于该 Agent 的聊天消息
    /// （记录按时间倒序存储，first 即最新）
    static func loadMessages(
        from records: [ConversationRecord],
        agentName: String
    ) -> [AgentChatMessage] {
        guard let record = records.first(where: { $0.aiModel == agentName }) else {
            return []
        }
        return makeMessages(from: record)
    }

    /// 从记录列表恢复指定 ID 的会话消息（多会话切换用，校验 Agent 标识）
    static func loadMessages(
        from records: [ConversationRecord],
        recordID: UUID,
        agentName: String
    ) -> [AgentChatMessage] {
        guard let record = records.first(where: { $0.id == recordID && $0.aiModel == agentName }) else {
            return []
        }
        return makeMessages(from: record)
    }

    /// 按记录 ID 恢复消息（不校验 Agent 标识；对话详情「在聊天中继续」用，
    /// 支持 agent-ask 等无对应聊天分类的记录水合到聊天页）
    static func loadMessages(
        from records: [ConversationRecord],
        recordID: UUID
    ) -> [AgentChatMessage] {
        guard let record = records.first(where: { $0.id == recordID }) else {
            return []
        }
        return makeMessages(from: record)
    }

    /// 最近一次属于该 Agent 的会话摘要（无记录时返回 nil）
    static func latestSummary(
        from records: [ConversationRecord],
        agentName: String
    ) -> String? {
        guard let record = records.first(where: { $0.aiModel == agentName }) else {
            return nil
        }
        let summary = record.summary
        return summary.isEmpty ? nil : summary
    }

    /// 最近一条属于该 Agent 的记录（记录按时间倒序存储，first 即最新）
    static func latestRecord(
        from records: [ConversationRecord],
        agentName: String
    ) -> ConversationRecord? {
        records.first(where: { $0.aiModel == agentName })
    }

    /// 从 Agent 聊天消息生成记录；无有效文本时返回 nil
    static func makeRecord(
        messages: [AgentChatMessage],
        agentName: String,
        recordID: UUID? = nil,
        language: String = "zh-CN"
    ) -> ConversationRecord? {
        let entries = messages.compactMap { message -> ConversationMessage? in
            guard message.image == nil else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ConversationMessage(
                role: message.role == "user" ? .user : .assistant,
                content: text,
                timestamp: message.timestamp
            )
        }
        return makeRecord(
            entries: entries,
            agentName: agentName,
            recordID: recordID,
            language: language
        )
    }

    /// 从语音会话转写（role/text 元组，.system 已由上层过滤）生成记录
    static func makeRecord(
        transcriptMessages: [(role: String, text: String)],
        agentName: String,
        recordID: UUID? = nil,
        language: String = "zh-CN"
    ) -> ConversationRecord? {
        let entries = transcriptMessages.compactMap { item -> ConversationMessage? in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ConversationMessage(
                role: item.role == "user" ? .user : .assistant,
                content: text
            )
        }
        return makeRecord(
            entries: entries,
            agentName: agentName,
            recordID: recordID,
            language: language
        )
    }

    private static func makeRecord(
        entries: [ConversationMessage],
        agentName: String,
        recordID: UUID?,
        language: String
    ) -> ConversationRecord? {
        guard !entries.isEmpty else { return nil }
        return ConversationRecord(
            id: recordID ?? UUID(),
            messages: entries,
            aiModel: agentName,
            language: language
        )
    }

    private static func makeMessages(from record: ConversationRecord) -> [AgentChatMessage] {
        record.messages.map { message in
            AgentChatMessage(
                role: message.role == .user ? "user" : "assistant",
                text: message.content,
                image: nil
            )
        }
    }
}

// MARK: - 对话记录 → 聊天页打开方式

/// 对话记录 → 聊天页 Agent 打开方式（对话详情「在聊天中继续」用，纯逻辑可测）：
/// OpenClaw 记录 → OpenClaw 聊天；custom.* 记录 → 对应配置的 Hermes 聊天
/// （配置已删除时回退内置 Hermes）；其余（Hermes / 语音历史 / agent-ask）→ Hermes 聊天。
enum ConversationChatKindResolver {
    static let openClawModelName = AgentKind.openclaw.displayName
    static let customPrefix = "custom."

    static func resolve(
        record: ConversationRecord,
        customConfigProvider: (UUID) -> CustomAgentConfig? = { CustomAgentStore.config(for: $0) }
    ) -> (kind: AgentKind, customConfig: CustomAgentConfig?) {
        switch record.aiModel {
        case openClawModelName:
            return (.openclaw, nil)
        case let model where model.hasPrefix(customPrefix):
            let idString = String(model.dropFirst(customPrefix.count))
            if let id = UUID(uuidString: idString),
               let config = customConfigProvider(id) {
                return (.hermes, config)
            }
            return (.hermes, nil)
        default:
            return (.hermes, nil)
        }
    }
}
