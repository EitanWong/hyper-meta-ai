/*
 * Agent Shortcut Store
 * 镜片快捷指令：用户配置的常用指令，回合结束菜单可一键触发。
 * UserDefaults JSON 持久化，上限 8 条，纯逻辑便于测试。
 */

import Foundation

/// 一条镜片快捷指令
struct AgentShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    /// 镜片菜单显示的短标题（建议 ≤ 12 字符）
    var title: String
    /// 触发时发送给 Agent 的指令文本
    var prompt: String

    init(id: UUID = UUID(), title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

/// 镜片快捷指令存储（UserDefaults JSON 持久化）
enum AgentShortcutStore {
    static let key = "agent.shortcuts"
    /// 上限：镜片菜单空间有限，避免滚动层级过深
    static let maxCount = 8

    static var shortcuts: [AgentShortcut] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([AgentShortcut].self, from: data)) ?? []
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增一条快捷指令（标题/指令去首尾空白；空内容或已达上限返回 false）
    @discardableResult
    static func add(title: String, prompt: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !prompt.isEmpty else { return false }
        guard shortcuts.count < maxCount else { return false }
        var items = shortcuts
        items.append(AgentShortcut(title: title, prompt: prompt))
        shortcuts = items
        return true
    }

    static func remove(id: UUID) {
        shortcuts = shortcuts.filter { $0.id != id }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
