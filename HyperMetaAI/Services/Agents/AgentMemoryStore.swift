/*
 * Agent Memory Store
 * 长期记忆：用户维护的偏好/要点，随请求注入 Hermes / 自定义 Agent，
 * 让大脑跨会话记住用户（对齐 qwen-audio-agent 的长期记忆设计）。
 * UserDefaults JSON 持久化，纯逻辑便于测试。
 */

import Foundation

/// 一条长期记忆条目
struct AgentMemoryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    /// 记忆内容（用户可读，注入时原样携带）
    var text: String
    var date: Date

    init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}

/// 长期记忆存储（UserDefaults JSON 持久化，上限 20 条）
enum AgentMemoryStore {
    static let key = "agent.memory.entries"
    static let maxCount = 20

    static var entries: [AgentMemoryEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([AgentMemoryEntry].self, from: data)) ?? []
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增一条记忆（去首尾空白；空内容、重复或已达上限返回 false）
    @discardableResult
    static func add(text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !entries.contains(where: { $0.text == text }) else { return false }
        guard entries.count < maxCount else { return false }
        var items = entries
        items.append(AgentMemoryEntry(text: text))
        entries = items
        return true
    }

    static func remove(id: UUID) {
        entries = entries.filter { $0.id != id }
    }

    /// 语音纠正删除：先整条精确匹配，再按包含关系模糊匹配（返回是否删掉）。
    /// 对齐 qwen-audio-agent 的「那条记错了 / 忘掉它」记忆纠正交互。
    @discardableResult
    static func remove(matching text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var items = entries
        if let index = items.firstIndex(where: { $0.text == text }) {
            items.remove(at: index)
            entries = items
            return true
        }
        if let index = items.firstIndex(where: { $0.text.contains(text) }) {
            items.remove(at: index)
            entries = items
            return true
        }
        return false
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 把记忆条目构造成注入大脑的 system prompt（纯逻辑，可测试）
enum AgentMemoryPromptBuilder {
    /// 注入文本长度上限（超长截断，避免挤占上下文）
    static let maxPromptLength = 1_000

    /// 当前记忆的 system prompt；记忆未启用或为空时返回 nil（不注入）
    static func systemPromptForCurrentStore() -> String? {
        guard AgentMemorySettings.enabled else { return nil }
        return makeSystemPrompt(entries: AgentMemoryStore.entries)
    }

    /// 把条目拼成 system prompt；无条目返回 nil；超长时按行截断到上限内
    static func makeSystemPrompt(
        entries: [AgentMemoryEntry],
        maxLength: Int = maxPromptLength
    ) -> String? {
        let lines = entries.map { $0.text }
        guard !lines.isEmpty else { return nil }
        var prompt = "agent.memory.system.prefix".localized + "\n" + lines.joined(separator: "\n")
        guard prompt.count > maxLength else { return prompt }
        let prefix = "agent.memory.system.prefix".localized
        var kept: [String] = []
        var length = prefix.count + 1
        for line in lines {
            let candidate = length + line.count
            guard candidate <= maxLength else { break }
            kept.append(line)
            length = candidate + 1
        }
        guard !kept.isEmpty else {
            return String(prefix.prefix(maxLength))
        }
        return prefix + "\n" + kept.joined(separator: "\n")
    }
}

/// 镜片 Prefs 子菜单的纯映射（记忆 + 规则混合，不依赖 SDK 运行时，可测）。
/// 主菜单动态出现依据 + 按钮短标签 + 播报/展示文本 + 类型图标。
enum AgentPrefsDisplayMapping {
    /// 子菜单条目类型（按钮图标与播报前缀区分）
    enum ItemKind: Equatable {
        case memory
        case rule
    }

    /// 统一的子菜单条目（记忆 / 规则）
    struct Item: Equatable {
        let kind: ItemKind
        let text: String
        let date: Date
    }

    /// 是否有记忆或规则条目（镜片主菜单「Prefs」动态出现的依据）
    static func hasPrefs() -> Bool {
        !AgentMemoryStore.entries.isEmpty || !AgentRuleStore.entries.isEmpty
    }

    /// 记忆 + 规则混合，按更新时间降序取最近 limit 条
    static func recentItems(limit: Int = 6) -> [Item] {
        var items: [Item] = []
        items += AgentMemoryStore.entries.map {
            Item(kind: .memory, text: $0.text, date: $0.date)
        }
        items += AgentRuleStore.entries.map {
            Item(kind: .rule, text: $0.text, date: $0.date)
        }
        return items
            .sorted { $0.date > $1.date }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 按钮短标签：内容截断（超长加省略号），空内容回退「Pref」
    static func menuLabel(for item: Item, maxLength: Int = 8) -> String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Pref" }
        let trimmed = String(text.prefix(maxLength))
        return text.count > maxLength ? trimmed + "…" : trimmed
    }

    /// 播报 / 展示文本：记忆：xxx / 规则：xxx
    static func resultText(for item: Item) -> String {
        let prefix = item.kind == .memory
            ? "agent.prefs.memory.prefix".localized
            : "agent.prefs.rule.prefix".localized
        return String(format: prefix, item.text)
    }

    /// 子菜单按钮图标（MWDATDisplay.IconName 的 rawValue）
    static func iconName(for item: Item) -> String {
        item.kind == .memory ? "heart" : "sliders_horizontal"
    }
}
