/*
 * Conversation Storage Service
 * 对话记录持久化服务
 */

import Foundation

class ConversationStorage {
    static let shared = ConversationStorage()

    private let userDefaults = UserDefaults.standard
    private let conversationsKey = "savedConversations"
    private let maxConversations = 100 // 最多保存100条对话

    private init() {}

    // MARK: - Save Conversation

    func saveConversation(_ record: ConversationRecord) {
        do {
            var conversations = try decodeStoredConversations()

            // Add new conversation at the beginning
            conversations.insert(record, at: 0)

            // Keep only the most recent maxConversations
            if conversations.count > maxConversations {
                conversations = Array(conversations.prefix(maxConversations))
            }

            let encoded = try JSONEncoder().encode(conversations)
            userDefaults.set(encoded, forKey: conversationsKey)
            print("💾 [Storage] 保存对话成功: \(record.id), 总数: \(conversations.count)")
        } catch {
            // Do not replace an unreadable existing archive with a new empty
            // array. Preserving the original data makes recovery possible.
            print("❌ [Storage] 保存对话失败，保留现有记录: \(error.localizedDescription)")
        }
    }

    // MARK: - Load Conversations

    func loadAllConversations() -> [ConversationRecord] {
        do {
            let conversations = try decodeStoredConversations()
            print("📂 [Storage] 加载对话成功: \(conversations.count) 条")
            return conversations
        } catch {
            print("📂 [Storage] 对话记录解码失败: \(error.localizedDescription)")
            return []
        }
    }

    func loadConversations(limit: Int = 20, offset: Int = 0) -> [ConversationRecord] {
        let allConversations = loadAllConversations()

        guard limit > 0,
              offset >= 0,
              offset < allConversations.count else {
            return []
        }

        let endIndex = min(offset + limit, allConversations.count)
        return Array(allConversations[offset..<endIndex])
    }

    // MARK: - Delete Conversation

    func deleteConversation(_ id: UUID) {
        do {
            var conversations = try decodeStoredConversations()
            conversations.removeAll { $0.id == id }

            let encoded = try JSONEncoder().encode(conversations)
            userDefaults.set(encoded, forKey: conversationsKey)
            print("🗑️ [Storage] 删除对话成功: \(id)")
        } catch {
            print("❌ [Storage] 删除对话失败，保留现有记录: \(error.localizedDescription)")
        }
    }

    func deleteAllConversations() {
        userDefaults.removeObject(forKey: conversationsKey)
        print("🗑️ [Storage] 清空所有对话")
    }

    // MARK: - Get Conversation

    func getConversation(by id: UUID) -> ConversationRecord? {
        return loadAllConversations().first { $0.id == id }
    }

    private func decodeStoredConversations() throws -> [ConversationRecord] {
        guard let data = userDefaults.data(forKey: conversationsKey) else {
            return []
        }
        return try JSONDecoder().decode([ConversationRecord].self, from: data)
    }
}
