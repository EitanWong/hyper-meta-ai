/*
 * Agent Memory Extractor
 * 从会话转写中提炼长期记忆候选（纯规则，保守匹配避免误判）：
 *   - 显式指令「帮我记住 X」→ 直接提取 X
 *   - 陈述句模式「我喜欢 / 我住在 / 我叫 …」→ 生成候选，设置页人工审阅后采纳
 * 对齐 qwen-audio-agent 的会话后自动记忆提取设计。
 */

import Foundation

/// 一条待确认记忆候选（设置页人工采纳/忽略）
struct AgentMemoryCandidate: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    /// 来源转写（展示上下文）
    var source: String
    var date: Date

    init(id: UUID = UUID(), text: String, source: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.date = date
    }
}

/// 待确认记忆候选存储（UserDefaults JSON 持久化，上限 10 条）
enum AgentMemoryCandidateStore {
    static let key = "agent.memory.candidates"
    static let maxCount = 10

    static var candidates: [AgentMemoryCandidate] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([AgentMemoryCandidate].self, from: data)) ?? []
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 追加候选（去重：与已有候选、长期记忆重复时跳过）
    static func append(_ newCandidates: [AgentMemoryCandidate]) {
        var existingTexts = Set(
            candidates.map(\.text) + AgentMemoryStore.entries.map(\.text)
        )
        var items = candidates
        for candidate in newCandidates {
            guard !existingTexts.contains(candidate.text) else { continue }
            guard items.count < maxCount else { break }
            items.append(candidate)
            existingTexts.insert(candidate.text)
        }
        candidates = items
    }

    /// 采纳候选：移入长期记忆
    static func accept(id: UUID) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        _ = AgentMemoryStore.add(text: candidate.text)
        candidates = candidates.filter { $0.id != id }
    }

    static func ignore(id: UUID) {
        candidates = candidates.filter { $0.id != id }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 记忆提取的纯逻辑（可测试）
enum AgentMemoryExtractor {
    /// 显式记忆指令前缀（按长度降序匹配，避免短前缀吞句）
    static let rememberPrefixes = [
        "帮我记住：", "请记住：", "帮我记住", "请记住", "记住：",
    ]
    /// 陈述句模式（保守集合：事实/偏好/身份/目标）
    static let statementPatterns = [
        "我喜欢", "我不喜欢", "我讨厌", "我住在", "我家在",
        "我叫", "我的名字是", "我的目标是",
    ]
    /// 候选文本长度限制
    static let maxCandidateLength = 40
    /// 显式记忆指令的文本长度上限
    static let maxRememberLength = 80
    /// 疑问词（命中即跳过）
    static let questionMarks = ["？", "?", "吗", "呢", "怎么", "什么", "哪里", "多少", "为什么", "how", "what", "why"]

    /// 从用户转写列表中提取候选文本（先显式指令，再陈述句模式）
    static func extractCandidates(from texts: [String]) -> [String] {
        var result: [String] = []
        for text in texts {
            if let remembered = explicitRememberTarget(from: text) {
                if !result.contains(remembered) {
                    result.append(remembered)
                }
                continue
            }
            if let statement = statementCandidate(from: text) {
                if !result.contains(statement) {
                    result.append(statement)
                }
            }
        }
        return result
    }

    /// 显式指令「帮我记住 X」→ X；不匹配返回 nil
    static func explicitRememberTarget(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for prefix in rememberPrefixes {
            guard trimmed.hasPrefix(prefix) else { continue }
            let target = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard target.count >= 2, target.count <= maxRememberLength else { return nil }
            return target
        }
        return nil
    }

    /// 陈述句模式候选：整句命中模式、非疑问、非指令、长度合规时返回
    static func statementCandidate(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= maxCandidateLength else { return nil }
        guard !questionMarks.contains(where: { trimmed.contains($0) }) else { return nil }
        guard !trimmed.hasPrefix("帮我"), !trimmed.hasPrefix("请") else { return nil }
        guard let pattern = statementPatterns.first(where: { trimmed.hasPrefix($0) }) else { return nil }
        let remainder = String(trimmed.dropFirst(pattern.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        return trimmed
    }
}

/// 显式记忆指令解析（语音转发路径拦截：直接保存并播报确认，不再转发给大脑）
/// 记忆语音指令：显式「帮我记住 X」→ 存入；「我记住了什么」→ 查询播报
enum AgentMemoryCommand: Equatable {
    case remember(String)
    case query
    /// 纠正删除「忘掉 X / 那条记错了」→ 按文本（精确优先，其次包含）删除
    case forget(String)
}

enum AgentMemoryCommandParser {
    static let queryKeywords = [
        "我记住了什么", "我的记忆", "记忆列表", "记住了什么",
        "记忆有哪些", "有什么记忆", "都记住了什么", "记忆查询",
        "what do you remember", "my memory",
    ]
    /// 纠正删除前缀（按长度降序匹配；不含裸「忘了/忘记」避免误吞「别忘了提醒我」）
    static let forgetPrefixes = [
        "忘掉那条记忆", "删掉那条记忆", "删除那条记忆", "忘掉那条",
        "那条记错了", "记错了", "忘掉", "删掉记忆", "删除记忆", "忘记记忆",
    ]

    static func parse(_ text: String) -> AgentMemoryCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if queryKeywords.contains(where: { trimmed.contains($0) }) {
            return .query
        }
        for prefix in forgetPrefixes {
            guard trimmed.hasPrefix(prefix) else { continue }
            let target = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:。！!？?"))
            guard !target.isEmpty else { return nil }
            return .forget(target)
        }
        guard let target = AgentMemoryExtractor.explicitRememberTarget(from: trimmed) else { return nil }
        return .remember(target)
    }
}
