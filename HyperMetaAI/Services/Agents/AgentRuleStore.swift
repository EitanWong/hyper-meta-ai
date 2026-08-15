/*
 * Agent Rule Store
 * 个性化规则：用户通过语音 / 设置页维护的恒定行为约束（如「汇报先说结论」），
 * 随请求注入 Hermes / 自定义 Agent / 语音转发大脑，让 Agent 始终遵守（USER.md 风格）。
 * 区别于长期记忆（事实类偏好「我喜欢 X」）：规则是行为约束，不随时间变化。
 * UserDefaults JSON 持久化，纯逻辑便于测试。
 */

import Foundation

/// 一条个性化规则条目
struct AgentRuleEntry: Codable, Equatable, Identifiable {
    var id: UUID
    /// 规则内容（注入时原样携带）
    var text: String
    var date: Date

    init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}

/// 个性化规则存储（UserDefaults JSON 持久化，上限 10 条）
enum AgentRuleStore {
    static let key = "agent.rules.entries"
    static let maxCount = 10

    static var entries: [AgentRuleEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([AgentRuleEntry].self, from: data)) ?? []
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增一条规则（去首尾空白；空内容、重复或已达上限返回 false）
    @discardableResult
    static func add(text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !entries.contains(where: { $0.text == text }) else { return false }
        guard entries.count < maxCount else { return false }
        var items = entries
        items.append(AgentRuleEntry(text: text))
        entries = items
        return true
    }

    static func remove(id: UUID) {
        entries = entries.filter { $0.id != id }
    }

    /// 语音删除：按完整文本匹配（返回是否删掉）
    @discardableResult
    static func remove(text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existed = entries.contains(where: { $0.text == text })
        entries = entries.filter { $0.text != text }
        return existed
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 把规则构造成注入大脑的 system prompt（纯逻辑，可测试）
enum AgentRulePromptBuilder {
    /// 注入文本长度上限（超长截断，避免挤占上下文）
    static let maxPromptLength = 500

    /// 当前规则的 system prompt；无规则时返回 nil（不注入）
    static func systemPromptForCurrentStore() -> String? {
        makeSystemPrompt(entries: AgentRuleStore.entries)
    }

    /// 把条目拼成 system prompt；无条目返回 nil；超长时按行截断到上限内
    static func makeSystemPrompt(
        entries: [AgentRuleEntry],
        maxLength: Int = maxPromptLength
    ) -> String? {
        let lines = entries.map { $0.text }
        guard !lines.isEmpty else { return nil }
        var prompt = "agent.rules.system.prefix".localized + "\n" + lines.joined(separator: "\n")
        guard prompt.count > maxLength else { return prompt }
        let prefix = "agent.rules.system.prefix".localized
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

    /// 语音转发大脑的紧凑前置（「【我的规则】…」）；无规则返回 nil。
    /// 规则是恒定约束，随每条转发消息携带，让转发大脑同样遵守。
    static func voicePrefix(maxLength: Int = 120) -> String? {
        let lines = AgentRuleStore.entries.map { $0.text }
        guard !lines.isEmpty else { return nil }
        let title = "agent.rules.voice.prefix".localized
        var kept: [String] = []
        var length = title.count + 1
        for line in lines {
            let candidate = length + line.count + 1
            if candidate <= maxLength {
                kept.append(line)
                length = candidate
            } else if kept.isEmpty {
                // 单条规则也放不下：截断第一条，保证规则至少随消息携带
                let budget = maxLength - length
                if budget > 0 {
                    kept.append(String(line.prefix(budget)))
                }
                break
            } else {
                break
            }
        }
        guard !kept.isEmpty else { return nil }
        return title + "\n" + kept.joined(separator: "\n")
    }
}

/// 统一 system prompt：四层上下文合并注入（聊天侧 Hermes / 自定义 Agent）。
/// 优先级顺序（对齐 qwen-audio-agent v1.8 的上下文边界）：
/// 用户偏好（规则，行为约束）→ 长期记忆（事实，回答依据）→ 助手画像（人设，最弱层）。
enum AgentSystemPromptBuilder {
    static func build() -> String? {
        let parts = [
            AgentRulePromptBuilder.systemPromptForCurrentStore(),
            AgentMemoryPromptBuilder.systemPromptForCurrentStore(),
            AgentPersonaPromptBuilder.systemPromptForCurrentStore(),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// 规则语音指令
enum AgentRuleCommand: Equatable {
    /// 新增规则（内容）
    case add(String)
    /// 查询全部规则
    case query
    /// 删除规则（按文本匹配）
    case remove(String)
    /// 清空全部
    case clear
}

/// 规则语音指令解析（纯逻辑，可测）：
/// 「以后汇报先说结论」「从现在开始回复要简洁」「规则：用中文回答」→ add
/// 「有什么规则 / 我的规则」→ query；「删掉规则 X」→ remove；「清空规则」→ clear
enum AgentRuleCommandParser {
    static let maxRuleLength = 50

    static let addPrefixes = [
        "以后", "从现在开始", "接下来每次", "记住规则：", "记住规则",
        "设定规则：", "设定规则", "规则：",
    ]
    static let removePrefixes = ["删掉规则", "删除规则", "去掉规则", "取消规则"]
    static let queryKeywords = ["有什么规则", "有哪些规则", "规则列表", "我的规则", "都有哪些规则"]
    static let clearKeywords = ["清空规则", "清空所有规则", "删除全部规则"]

    static func parse(_ text: String) -> AgentRuleCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if clearKeywords.contains(where: { trimmed.contains($0) }) {
            return .clear
        }
        if queryKeywords.contains(where: { trimmed.contains($0) }) {
            return .query
        }
        for prefix in addPrefixes where trimmed.hasPrefix(prefix) {
            let rule = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidRule(rule) else { return nil }
            return .add(rule)
        }
        for prefix in removePrefixes where trimmed.hasPrefix(prefix) {
            let rule = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty else { return nil }
            return .remove(rule)
        }
        return nil
    }

    /// 规则文本校验：2-50 字、非疑问句（「以后怎么办」不应成为规则）
    static func isValidRule(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= maxRuleLength else { return false }
        guard !trimmed.contains("？"), !trimmed.contains("?") else { return false }
        return true
    }
}
