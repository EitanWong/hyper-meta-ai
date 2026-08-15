import XCTest

@testable import HyperMetaAI

/// 助手画像（ASSISTANT.md 层）：存储 / 提示词 / 语音指令 / 记忆纠正 / 长任务进度播报（纯逻辑）
final class AgentPersonaTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentPersonaStore.reset()
        AgentMemoryStore.clear()
        AgentRuleStore.clear()
    }

    override func tearDown() {
        AgentPersonaStore.reset()
        AgentMemoryStore.clear()
        AgentRuleStore.clear()
        UserDefaults.standard.removeObject(forKey: AgentMemorySettings.enabledKey)
        super.tearDown()
    }

    // MARK: - 存储

    func testDefaultPersona() {
        let persona = AgentPersonaStore.defaultPersona
        XCTAssertEqual(persona.name, "Lucky")
        XCTAssertTrue(persona.enabled)
        XCTAssertFalse(persona.role.isEmpty)
        XCTAssertFalse(persona.style.isEmpty)
    }

    func testSaveAndRoundtrip() {
        AgentPersonaStore.save(
            name: "小舟",
            role: "你的私人助理",
            style: "简洁",
            enabled: true
        )
        let persona = AgentPersonaStore.current
        XCTAssertEqual(persona.name, "小舟")
        XCTAssertEqual(persona.role, "你的私人助理")
        XCTAssertEqual(persona.style, "简洁")
    }

    func testSaveEmptyNameFallsBackToDefault() {
        AgentPersonaStore.save(
            name: "   ",
            role: "你的私人助理",
            style: "简洁",
            enabled: true
        )
        XCTAssertEqual(AgentPersonaStore.current.name, "Lucky")
    }

    func testSaveEmptyRoleAndStyleResetsToDefault() {
        AgentPersonaStore.save(
            name: "小舟",
            role: "",
            style: "",
            enabled: true
        )
        let persona = AgentPersonaStore.current
        XCTAssertEqual(persona.name, "Lucky", "角色与风格均空时回退默认画像")
        XCTAssertFalse(persona.role.isEmpty)
    }

    func testResetRestoresDefaults() {
        AgentPersonaStore.save(
            name: "小舟",
            role: "助理",
            style: "简洁",
            enabled: false
        )
        AgentPersonaStore.reset()
        XCTAssertEqual(AgentPersonaStore.current.name, "Lucky")
        XCTAssertTrue(AgentPersonaStore.current.enabled)
    }

    // MARK: - 提示词构造

    func testPersonaPromptNilWhenDisabled() {
        XCTAssertNil(AgentPersonaPromptBuilder.makeSystemPrompt(
            persona: AgentPersona(name: "Lucky", role: "管家", style: "简洁", enabled: false)
        ))
    }

    func testPersonaPromptNilWhenEmptyFields() {
        XCTAssertNil(AgentPersonaPromptBuilder.makeSystemPrompt(
            persona: AgentPersona(name: "", role: "管家", style: "", enabled: true)
        ))
        XCTAssertNil(AgentPersonaPromptBuilder.makeSystemPrompt(
            persona: AgentPersona(name: "Lucky", role: "", style: "", enabled: true)
        ))
    }

    func testPersonaPromptIncludesNameRoleStyle() {
        let prompt = AgentPersonaPromptBuilder.makeSystemPrompt(
            persona: AgentPersona(name: "小舟", role: "你的私人助理", style: "简洁、自然", enabled: true)
        )
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt!.contains("小舟"))
        XCTAssertTrue(prompt!.contains("你的私人助理"))
        XCTAssertTrue(prompt!.contains("简洁、自然"))
        XCTAssertTrue(prompt!.hasPrefix("agent.persona.system.prefix".localized))
    }

    func testPersonaPromptCapped() {
        let prompt = AgentPersonaPromptBuilder.makeSystemPrompt(
            persona: AgentPersona(
                name: "超长",
                role: String(repeating: "长", count: 500),
                style: "",
                enabled: true
            ),
            maxLength: 200
        )
        XCTAssertNotNil(prompt)
        XCTAssertLessThanOrEqual(prompt!.count, 200)
    }

    func testSpokenIdentity() {
        let text = AgentPersonaPromptBuilder.spokenIdentity(
            persona: AgentPersona(name: "小舟", role: "你的智能管家", style: "简洁", enabled: true)
        )
        XCTAssertTrue(text.contains("小舟"))
        XCTAssertTrue(text.contains("你的智能管家"))

        let short = AgentPersonaPromptBuilder.spokenIdentity(
            persona: AgentPersona(name: "小舟", role: "", style: "", enabled: true)
        )
        XCTAssertTrue(short.contains("小舟"))
    }

    // MARK: - 语音指令解析

    func testPersonaQueryVariants() {
        XCTAssertEqual(AgentPersonaCommandParser.parse("你叫什么名字"), .query)
        XCTAssertEqual(AgentPersonaCommandParser.parse("你是谁"), .query)
        XCTAssertEqual(AgentPersonaCommandParser.parse("你的名字是什么"), .query)
    }

    func testPersonaSetNameVariants() {
        XCTAssertEqual(AgentPersonaCommandParser.parse("以后你叫小舟"), .setName("小舟"))
        XCTAssertEqual(AgentPersonaCommandParser.parse("你以后叫 JARVIS"), .setName("JARVIS"))
        XCTAssertEqual(AgentPersonaCommandParser.parse("改名叫小舟"), .setName("小舟"))
        XCTAssertEqual(AgentPersonaCommandParser.parse("以后叫我阿豪"), .setName("阿豪"))
        XCTAssertEqual(AgentPersonaCommandParser.parse("你叫小舟。"), .setName("小舟"))
    }

    func testPersonaSetNameRejectsEmptyAndQuestion() {
        XCTAssertNil(AgentPersonaCommandParser.parse("以后你叫"))
        XCTAssertNil(AgentPersonaCommandParser.parse("你叫什么？"))
        XCTAssertNil(AgentPersonaCommandParser.parse("改名叫什么好呢"))
    }

    func testPersonaTakesPrecedenceOverRuleParser() {
        // 「以后你叫 X」以「以后」开头，若先走规则解析会被当成规则；
        // 双入口拦截链均为 画像 → 规则，此处验证解析本身互不误吞。
        XCTAssertEqual(AgentPersonaCommandParser.parse("以后你叫小舟"), .setName("小舟"))
        XCTAssertEqual(AgentRuleCommandParser.parse("以后你叫小舟"), .add("你叫小舟"))
    }

    // MARK: - 记忆纠正（忘掉 / 记错了）

    func testMemoryForgetParserVariants() {
        XCTAssertEqual(AgentMemoryCommandParser.parse("忘掉我在上海"), .forget("我在上海"))
        XCTAssertEqual(AgentMemoryCommandParser.parse("记错了我在上海"), .forget("我在上海"))
        XCTAssertEqual(AgentMemoryCommandParser.parse("忘掉那条记忆：我在上海"), .forget("我在上海"))
        XCTAssertEqual(AgentMemoryCommandParser.parse("删除记忆我在上海"), .forget("我在上海"))
        XCTAssertEqual(AgentMemoryCommandParser.parse("那条记错了：我在上海"), .forget("我在上海"))
    }

    func testMemoryForgetParserRejectsEmptyTarget() {
        XCTAssertNil(AgentMemoryCommandParser.parse("忘掉"))
        XCTAssertNil(AgentMemoryCommandParser.parse("记错了"))
        XCTAssertNil(AgentMemoryCommandParser.parse("那条记错了"))
    }

    func testMemoryForgetDoesNotSwallowReminderPhrases() {
        // 裸「忘了 / 忘记」不作为删除前缀，避免误吞「别忘了提醒我」
        XCTAssertNil(AgentMemoryCommandParser.parse("别忘了提醒我喝水"))
        XCTAssertNil(AgentMemoryCommandParser.parse("别忘了"))
    }

    func testMemoryRemoveExactThenContains() {
        _ = AgentMemoryStore.add(text: "我喜欢简洁的回答")
        _ = AgentMemoryStore.add(text: "我在上海工作")

        XCTAssertTrue(AgentMemoryStore.remove(matching: "我喜欢简洁的回答"), "精确匹配应删除")
        XCTAssertEqual(AgentMemoryStore.entries.map(\.text), ["我在上海工作"])

        XCTAssertTrue(AgentMemoryStore.remove(matching: "上海"), "包含匹配应删除")
        XCTAssertTrue(AgentMemoryStore.entries.isEmpty)
    }

    func testMemoryRemoveMatchingMissing() {
        _ = AgentMemoryStore.add(text: "我在上海")
        XCTAssertFalse(AgentMemoryStore.remove(matching: "北京"))
        XCTAssertFalse(AgentMemoryStore.remove(matching: "   "))
        XCTAssertEqual(AgentMemoryStore.entries.count, 1)
    }

    // MARK: - 长任务自动进度播报（qwen-audio-agent v1.8.2 对齐）

    func testCheckInDueOnlyOverdueActiveTasks() {
        let now = Date()
        let old = now.addingTimeInterval(-180)
        let recent = now.addingTimeInterval(-30)
        let tasks = [
            (id: "a", createdAt: old, isActive: true),
            (id: "b", createdAt: recent, isActive: true),
            (id: "c", createdAt: old, isActive: false),
        ]
        XCTAssertEqual(
            AgentTaskProgressCheckIn.dueCheckIns(tasks: tasks, checkedIn: [], now: now),
            ["a"],
            "仅超阈值且活跃的任务进入汇报"
        )
    }

    func testCheckInSkipsAlreadyReported() {
        let old = Date().addingTimeInterval(-180)
        let tasks = [(id: "a", createdAt: old, isActive: true)]
        XCTAssertEqual(
            AgentTaskProgressCheckIn.dueCheckIns(tasks: tasks, checkedIn: ["a"]),
            []
        )
    }

    func testCheckInAnnouncementText() {
        let text = AgentTaskProgressCheckIn.announcementText(
            title: "整理会议纪要",
            elapsed: 150
        )
        XCTAssertTrue(text.contains("整理会议纪要"))
        XCTAssertTrue(text.contains("2"), "150 秒按 2 分钟播报")

        let generic = AgentTaskProgressCheckIn.announcementText(title: nil, elapsed: 40)
        XCTAssertFalse(generic.contains("整理会议纪要"))
        XCTAssertTrue(generic.contains("1"), "不足一分钟按 1 分钟播报")
    }

    // MARK: - 图库直达大脑分发

    func testGalleryRoutePrefersHermes() {
        XCTAssertEqual(
            GalleryAgentRoute.resolve(
                hermesAvailable: true,
                openClawAvailable: true,
                customConfig: CustomAgentConfig(id: UUID(), name: "x", baseURL: "http://x", model: "", toolsJSON: "", transport: .http)
            ),
            .hermes
        )
    }

    func testGalleryRouteFallsBackToOpenClawThenCustom() {
        XCTAssertEqual(
            GalleryAgentRoute.resolve(
                hermesAvailable: false,
                openClawAvailable: true,
                customConfig: nil
            ),
            .openclaw
        )
        let config = CustomAgentConfig(id: UUID(), name: "x", baseURL: "http://x", model: "", toolsJSON: "", transport: .http)
        XCTAssertEqual(
            GalleryAgentRoute.resolve(
                hermesAvailable: false,
                openClawAvailable: false,
                customConfig: config
            ),
            .custom(config)
        )
    }

    func testGalleryRouteFallsBackToHermesWhenNothingAvailable() {
        XCTAssertEqual(
            GalleryAgentRoute.resolve(
                hermesAvailable: false,
                openClawAvailable: false,
                customConfig: nil
            ),
            .hermes,
            "全部不可用时回退 Hermes 入口展示配置引导"
        )
    }

    func testGalleryRouteKindAndConfigMapping() {
        XCTAssertEqual(GalleryAgentRoute.hermes.kind, .hermes)
        XCTAssertNil(GalleryAgentRoute.hermes.customConfig)
        XCTAssertEqual(GalleryAgentRoute.openclaw.kind, .openclaw)
        XCTAssertNil(GalleryAgentRoute.openclaw.customConfig)
        let config = CustomAgentConfig(id: UUID(), name: "x", baseURL: "http://x", model: "", toolsJSON: "", transport: .http)
        XCTAssertEqual(GalleryAgentRoute.custom(config).kind, .hermes)
        XCTAssertEqual(GalleryAgentRoute.custom(config).customConfig, config)
    }

    // MARK: - 回复话术（语音页 / 聊天页共用）

    func testProfileCommandReplyTexts() {
        XCTAssertFalse(AgentProfileCommandReply.personaSet(name: "小舟").isEmpty)
        XCTAssertFalse(AgentProfileCommandReply.memoryForgot(text: "X").isEmpty)
        XCTAssertFalse(AgentProfileCommandReply.memoryForgetMissing().isEmpty)
        XCTAssertEqual(
            AgentProfileCommandReply.memoryQuery(entries: []),
            "agent.memory.query.empty".localized
        )
    }
}
