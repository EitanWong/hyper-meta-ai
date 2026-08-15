import XCTest

@testable import HyperMetaAI

/// 个性化规则：存储 / 注入 prompt / 语音指令解析（纯逻辑）
final class AgentRuleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentRuleStore.clear()
    }

    override func tearDown() {
        AgentRuleStore.clear()
        UserDefaults.standard.removeObject(forKey: AgentMemoryStore.key)
        super.tearDown()
    }

    // MARK: - 存储

    func testAddAndPersistRoundtrip() {
        XCTAssertTrue(AgentRuleStore.add(text: "汇报先说结论"))
        XCTAssertEqual(AgentRuleStore.entries.count, 1)
        XCTAssertEqual(AgentRuleStore.entries[0].text, "汇报先说结论")
    }

    func testAddTrimsAndRejectsEmpty() {
        XCTAssertFalse(AgentRuleStore.add(text: "   "))
        XCTAssertFalse(AgentRuleStore.add(text: ""))
        XCTAssertTrue(AgentRuleStore.add(text: "  回复简洁  "))
        XCTAssertEqual(AgentRuleStore.entries[0].text, "回复简洁")
    }

    func testAddRejectsDuplicate() {
        XCTAssertTrue(AgentRuleStore.add(text: "汇报先说结论"))
        XCTAssertFalse(AgentRuleStore.add(text: "汇报先说结论"))
        XCTAssertEqual(AgentRuleStore.entries.count, 1)
    }

    func testAddRespectsMaxCount() {
        for i in 0..<AgentRuleStore.maxCount {
            XCTAssertTrue(AgentRuleStore.add(text: "规则\(i)"), "第 \(i) 条应可添加")
        }
        XCTAssertFalse(AgentRuleStore.add(text: "超出的规则"))
        XCTAssertEqual(AgentRuleStore.entries.count, AgentRuleStore.maxCount)
    }

    func testRemoveByText() {
        AgentRuleStore.add(text: "汇报先说结论")
        XCTAssertTrue(AgentRuleStore.remove(text: "汇报先说结论"))
        XCTAssertTrue(AgentRuleStore.entries.isEmpty)
        XCTAssertFalse(AgentRuleStore.remove(text: "不存在的规则"))
    }

    func testRemoveByIdAndClear() {
        AgentRuleStore.add(text: "规则A")
        AgentRuleStore.add(text: "规则B")
        let id = AgentRuleStore.entries[0].id
        AgentRuleStore.remove(id: id)
        XCTAssertEqual(AgentRuleStore.entries.map(\.text), ["规则B"])
        AgentRuleStore.clear()
        XCTAssertTrue(AgentRuleStore.entries.isEmpty)
    }

    // MARK: - system prompt 注入

    func testSystemPromptNilWhenNoRules() {
        XCTAssertNil(AgentRulePromptBuilder.systemPromptForCurrentStore())
        XCTAssertNil(AgentRulePromptBuilder.makeSystemPrompt(entries: []))
    }

    func testSystemPromptContainsRules() {
        AgentRuleStore.add(text: "汇报先说结论")
        AgentRuleStore.add(text: "回复简洁")
        let prompt = AgentRulePromptBuilder.systemPromptForCurrentStore()
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt!.contains("汇报先说结论"))
        XCTAssertTrue(prompt!.contains("回复简洁"))
        XCTAssertTrue(prompt!.hasPrefix("agent.rules.system.prefix".localized))
    }

    func testSystemPromptTruncatesByLines() {
        let long = AgentRuleEntry(text: String(repeating: "长", count: 600))
        let short = AgentRuleEntry(text: "短规则")
        let prompt = AgentRulePromptBuilder.makeSystemPrompt(entries: [long, short])
        XCTAssertNotNil(prompt)
        XCTAssertLessThanOrEqual(prompt!.count, AgentRulePromptBuilder.maxPromptLength)
        XCTAssertFalse(prompt!.contains("短规则"), "超长时按行截断，短规则应被丢弃")
    }

    // MARK: - 语音转发前缀

    func testVoicePrefixNilWhenNoRules() {
        XCTAssertNil(AgentRulePromptBuilder.voicePrefix())
    }

    func testVoicePrefixContainsRules() {
        AgentRuleStore.add(text: "汇报先说结论")
        let prefix = AgentRulePromptBuilder.voicePrefix()
        XCTAssertNotNil(prefix)
        XCTAssertTrue(prefix!.contains("汇报先说结论"))
        XCTAssertTrue(prefix!.hasPrefix("agent.rules.voice.prefix".localized))
    }

    func testVoicePrefixCapped() {
        AgentRuleStore.add(text: String(repeating: "长", count: 200))
        let prefix = AgentRulePromptBuilder.voicePrefix()
        XCTAssertNotNil(prefix, "单条规则放不下时应截断携带而非丢弃")
        XCTAssertLessThanOrEqual(prefix!.count, 120)
        XCTAssertTrue(prefix!.contains("长"), "截断后的前缀仍应包含规则内容")
    }

    // MARK: - 统一 system prompt（记忆 + 规则）

    func testSystemPromptBuilderCombinesMemoryAndRules() {
        AgentMemoryStore.add(text: "喜欢简洁")
        AgentRuleStore.add(text: "汇报先说结论")
        AgentMemorySettings.enabled = true
        defer { AgentMemorySettings.enabled = false }
        let prompt = AgentSystemPromptBuilder.build()
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt!.contains("喜欢简洁"))
        XCTAssertTrue(prompt!.contains("汇报先说结论"))
    }

    func testSystemPromptBuilderNilWhenAllLayersEmpty() {
        AgentMemorySettings.enabled = true
        defer { AgentMemorySettings.enabled = false }
        // 直接写入关闭的画像（save 对空角色/风格会回退默认画像）
        AgentPersonaStore.current = AgentPersona(
            name: "",
            role: "",
            style: "",
            enabled: false
        )
        defer { AgentPersonaStore.reset() }
        XCTAssertNil(AgentSystemPromptBuilder.build())
    }

    func testSystemPromptBuilderLayeringRulesBeforeMemoryBeforePersona() {
        AgentMemorySettings.enabled = true
        defer { AgentMemorySettings.enabled = false }
        AgentMemoryStore.add(text: "喜欢简洁")
        AgentRuleStore.add(text: "汇报先说结论")
        AgentPersonaStore.save(
            name: "小舟",
            role: "助手",
            style: "简洁",
            enabled: true
        )
        defer { AgentPersonaStore.reset() }
        let prompt = AgentSystemPromptBuilder.build()
        XCTAssertNotNil(prompt)
        // 优先级顺序：用户偏好（规则）→ 长期记忆 → 助手画像（最弱层）
        let ruleIndex = prompt!.range(of: "汇报先说结论")!.lowerBound
        let memoryIndex = prompt!.range(of: "喜欢简洁")!.lowerBound
        let personaIndex = prompt!.range(of: "小舟")!.lowerBound
        XCTAssertLessThan(ruleIndex, memoryIndex)
        XCTAssertLessThan(memoryIndex, personaIndex)
    }

    // MARK: - 语音指令解析

    func testParseAddVariants() {
        XCTAssertEqual(AgentRuleCommandParser.parse("以后汇报先说结论"), .add("汇报先说结论"))
        XCTAssertEqual(AgentRuleCommandParser.parse("从现在开始回复要简洁"), .add("回复要简洁"))
        XCTAssertEqual(AgentRuleCommandParser.parse("接下来每次先给结论"), .add("先给结论"))
        XCTAssertEqual(AgentRuleCommandParser.parse("记住规则：用中文回答"), .add("用中文回答"))
        XCTAssertEqual(AgentRuleCommandParser.parse("规则：不要说废话"), .add("不要说废话"))
    }

    func testParseRejectsQuestionsAndTooShort() {
        XCTAssertNil(AgentRuleCommandParser.parse("以后怎么办？"))
        XCTAssertNil(AgentRuleCommandParser.parse("以后呢"))
        XCTAssertNil(AgentRuleCommandParser.parse("以后"))
    }

    func testParseQuery() {
        XCTAssertEqual(AgentRuleCommandParser.parse("有什么规则"), .query)
        XCTAssertEqual(AgentRuleCommandParser.parse("我的规则"), .query)
        XCTAssertEqual(AgentRuleCommandParser.parse("当前有哪些规则"), .query)
    }

    func testParseRemoveAndClear() {
        XCTAssertEqual(AgentRuleCommandParser.parse("删掉规则汇报先说结论"), .remove("汇报先说结论"))
        XCTAssertEqual(AgentRuleCommandParser.parse("删除规则回复简洁"), .remove("回复简洁"))
        XCTAssertEqual(AgentRuleCommandParser.parse("清空规则"), .clear)
        XCTAssertEqual(AgentRuleCommandParser.parse("删除全部规则"), .clear)
    }

    func testParseIgnoresUnrelatedSpeech() {
        XCTAssertNil(AgentRuleCommandParser.parse("帮我订个餐厅"))
        XCTAssertNil(AgentRuleCommandParser.parse("今天天气怎么样"))
    }

    func testRuleValidation() {
        XCTAssertTrue(AgentRuleCommandParser.isValidRule("汇报先说结论"))
        XCTAssertFalse(AgentRuleCommandParser.isValidRule("怎么办？"))
        XCTAssertFalse(AgentRuleCommandParser.isValidRule("好"))
    }
}
