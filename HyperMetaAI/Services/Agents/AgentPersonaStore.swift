/*
 * Agent Persona Store
 * 助手画像（ASSISTANT.md 风格，对齐 qwen-audio-agent v1.8 的四层上下文）：
 * 实例级默认人设——名称、关系定位与表达风格，由用户在设置页维护。
 * 优先级低于用户偏好（规则）与长期记忆（事实）：注入顺序为 规则 → 记忆 → 画像，
 * 画像提示词自声明「用户偏好优先」。
 * UserDefaults JSON 持久化，纯逻辑便于测试。
 */

import Foundation

/// 助手画像（实例级默认人设）
struct AgentPersona: Codable, Equatable {
    /// 助手名称（如「Lucky」）
    var name: String
    /// 关系定位（如「你的智能管家」）
    var role: String
    /// 表达风格（如「简洁、自然、温暖」）
    var style: String
    /// 是否注入大脑（关闭后完全不下发）
    var enabled: Bool

    init(name: String = "Lucky", role: String = "", style: String = "", enabled: Bool = true) {
        self.name = name
        self.role = role
        self.style = style
        self.enabled = enabled
    }
}

/// 助手画像存储（UserDefaults JSON 持久化）
enum AgentPersonaStore {
    static let key = "agent.persona.profile"

    /// 默认画像（首次启动 / 数据损坏回退）
    static var defaultPersona: AgentPersona {
        AgentPersona(
            name: "Lucky",
            role: "agent.persona.default.role".localized,
            style: "agent.persona.default.style".localized,
            enabled: true
        )
    }

    static var current: AgentPersona {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let persona = try? JSONDecoder().decode(AgentPersona.self, from: data) else {
                return defaultPersona
            }
            return persona
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 保存画像：名称回退默认名；全部为空时回退默认画像
    static func save(name: String, role: String, style: String, enabled: Bool) {
        var persona = AgentPersona(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            style: style.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled
        )
        if persona.name.isEmpty {
            persona.name = defaultPersona.name
        }
        if persona.role.isEmpty, persona.style.isEmpty {
            persona = defaultPersona
        }
        current = persona
    }

    /// 重置为默认画像
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 画像 system prompt（纯逻辑，可测）：
/// 人设是最弱的一层——先声明用户偏好优先，再给出名称 / 关系定位 / 表达风格。
enum AgentPersonaPromptBuilder {
    /// 注入文本长度上限
    static let maxPromptLength = 300

    /// 当前画像的 system prompt；未启用或名称为空时返回 nil（不注入）
    static func systemPromptForCurrentStore() -> String? {
        makeSystemPrompt(persona: AgentPersonaStore.current)
    }

    /// 把画像拼成 system prompt；未启用 / 名称为空 / 全部字段为空时返回 nil
    static func makeSystemPrompt(
        persona: AgentPersona,
        maxLength: Int = maxPromptLength
    ) -> String? {
        guard persona.enabled else { return nil }
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let role = persona.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = persona.style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty || !style.isEmpty else { return nil }

        var prompt = "agent.persona.system.prefix".localized + name
        if !role.isEmpty {
            prompt += "\n" + String(format: "agent.persona.system.role".localized, role)
        }
        if !style.isEmpty {
            prompt += "\n" + String(format: "agent.persona.system.style".localized, style)
        }
        guard prompt.count > maxLength else { return prompt }
        return String(prompt.prefix(maxLength))
    }

    /// 语音查询播报文本：「我是 Lucky，你的智能管家。」（style 并入结尾）
    static func spokenIdentity(persona: AgentPersona = AgentPersonaStore.current) -> String {
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "Lucky" : name
        let role = persona.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty {
            return String(format: "agent.persona.identity".localized, safeName, role)
        }
        return String(format: "agent.persona.identity.short".localized, safeName)
    }
}

/// 画像语音指令（本地拦截：查询 / 改名，不转发大脑）
enum AgentPersonaCommand: Equatable {
    /// 查询「你叫什么名字 / 你是谁」→ 播报名称与定位
    case query
    /// 改名「以后你叫小舟 / 改名叫 JARVIS」→ 保存名称并确认
    case setName(String)
}

enum AgentPersonaCommandParser {
    static let maxNameLength = 24
    /// 名字含疑问词视为无效（「改名叫什么好呢」不应成为名字）
    static let questionWords = [
        "什么", "怎么", "为啥", "为什么", "哪", "吗", "呢",
        "how", "what", "why",
    ]

    static let queryKeywords = [
        "你叫什么名字", "你是谁", "你的名字是什么", "怎么称呼你",
        "who are you", "what's your name", "what is your name",
    ]
    static let namePrefixes = [
        "以后你叫", "从今往后你叫", "你以后叫", "改名叫", "改成叫",
        "你的名字改成", "以后叫我", "你叫",
    ]

    static func parse(_ text: String) -> AgentPersonaCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if queryKeywords.contains(where: { trimmed.contains($0) }) {
            return .query
        }
        for prefix in namePrefixes {
            guard trimmed.hasPrefix(prefix) else { continue }
            let name = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:。！!？?"))
            guard name.count >= 1, name.count <= maxNameLength else { return nil }
            guard !name.contains("？"), !name.contains("?") else { return nil }
            guard !questionWords.contains(where: { name.contains($0) }) else { return nil }
            return .setName(name)
        }
        return nil
    }
}

/// 画像 / 记忆 / 规则语音指令的本地回复文本（纯构造，可测）。
/// 语音页与聊天页共用，保证双入口话术一致。
enum AgentProfileCommandReply {
    // MARK: 画像

    static func personaSet(name: String) -> String {
        String(format: "agent.persona.renamed".localized, name)
    }

    // MARK: 记忆

    static func memoryRemembered(text: String) -> String {
        String(format: "agent.memory.remembered".localized, text)
    }

    static func memoryDuplicate() -> String {
        "agent.memory.remember.dup".localized
    }

    static func memoryQuery(entries: [String]) -> String {
        entries.isEmpty
            ? "agent.memory.query.empty".localized
            : String(format: "agent.memory.query.content".localized, entries.joined(separator: "、"))
    }

    static func memoryForgot(text: String) -> String {
        String(format: "agent.memory.forgotten".localized, text)
    }

    static func memoryForgetMissing() -> String {
        "agent.memory.forget.missing".localized
    }

    // MARK: 规则

    static func ruleAdded(text: String) -> String {
        String(format: "agent.rules.added".localized, text)
    }

    static func ruleDuplicate(text: String) -> String {
        String(format: "agent.rules.dup".localized, text)
    }

    static func ruleFull() -> String {
        "agent.rules.full".localized
    }

    static func ruleQuery(entries: [String]) -> String {
        entries.isEmpty
            ? "agent.rules.query.empty".localized
            : String(format: "agent.rules.query.content".localized, entries.joined(separator: "、"))
    }

    static func ruleRemoved(text: String) -> String {
        String(format: "agent.rules.removed".localized, text)
    }

    static func ruleRemoveMissing() -> String {
        "agent.rules.removed.missing".localized
    }

    static func ruleCleared() -> String {
        "agent.rules.cleared".localized
    }
}
