import XCTest
@testable import HyperMetaAI

final class AgentMemoryStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentMemoryStore.clear()
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.enabledKey)
  }

  override func tearDown() {
    AgentMemoryStore.clear()
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.enabledKey)
    super.tearDown()
  }

  func testStoreDefaultsEmpty() {
    XCTAssertTrue(AgentMemoryStore.entries.isEmpty)
  }

  func testAddTrimsAndRejectsEmpty() {
    XCTAssertTrue(AgentMemoryStore.add(text: "  我喜欢简洁的回答  "))
    XCTAssertEqual(AgentMemoryStore.entries.count, 1)
    XCTAssertEqual(AgentMemoryStore.entries[0].text, "我喜欢简洁的回答")

    XCTAssertFalse(AgentMemoryStore.add(text: "   "))
    XCTAssertEqual(AgentMemoryStore.entries.count, 1)
  }

  func testAddRejectsDuplicate() {
    XCTAssertTrue(AgentMemoryStore.add(text: "我在上海"))
    XCTAssertFalse(AgentMemoryStore.add(text: "我在上海"), "重复内容应被拒绝")
    XCTAssertEqual(AgentMemoryStore.entries.count, 1)
  }

  func testAddRespectsMaxCount() {
    for index in 0..<AgentMemoryStore.maxCount {
      XCTAssertTrue(AgentMemoryStore.add(text: "记忆\(index)"))
    }
    XCTAssertEqual(AgentMemoryStore.entries.count, AgentMemoryStore.maxCount)
    XCTAssertFalse(AgentMemoryStore.add(text: "超限"))
  }

  func testRemoveAndClear() {
    _ = AgentMemoryStore.add(text: "甲")
    _ = AgentMemoryStore.add(text: "乙")
    let target = AgentMemoryStore.entries[0]
    AgentMemoryStore.remove(id: target.id)
    XCTAssertEqual(AgentMemoryStore.entries.map(\.text), ["乙"])
    AgentMemoryStore.clear()
    XCTAssertTrue(AgentMemoryStore.entries.isEmpty)
  }

  func testMemorySettingDefaultsDisabled() {
    XCTAssertFalse(AgentMemorySettings.enabled)
    AgentMemorySettings.enabled = true
    XCTAssertTrue(AgentMemorySettings.enabled)
  }
}

final class AgentMemoryPromptBuilderTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentMemoryStore.clear()
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.enabledKey)
  }

  override func tearDown() {
    AgentMemoryStore.clear()
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.enabledKey)
    super.tearDown()
  }

  func testEmptyEntriesYieldNil() {
    XCTAssertNil(AgentMemoryPromptBuilder.makeSystemPrompt(entries: []))
  }

  func testPromptContainsPrefixAndEntries() {
    let entries = [
      AgentMemoryEntry(text: "我喜欢简洁的回答"),
      AgentMemoryEntry(text: "我在上海"),
    ]
    let prompt = AgentMemoryPromptBuilder.makeSystemPrompt(entries: entries)
    XCTAssertNotNil(prompt)
    XCTAssertTrue(prompt!.hasPrefix("agent.memory.system.prefix".localized))
    XCTAssertTrue(prompt!.contains("我喜欢简洁的回答"))
    XCTAssertTrue(prompt!.contains("我在上海"))
  }

  func testPromptTruncatesByLines() {
    let entries = [
      AgentMemoryEntry(text: "第一条"),
      AgentMemoryEntry(text: "第二条"),
      AgentMemoryEntry(text: "第三条"),
    ]
    let prefix = "agent.memory.system.prefix".localized
    let limit = prefix.count + 1 + "第一条".count + 1 + "第二条".count
    let prompt = AgentMemoryPromptBuilder.makeSystemPrompt(entries: entries, maxLength: limit)
    XCTAssertNotNil(prompt)
    XCTAssertTrue(prompt!.contains("第一条"))
    XCTAssertTrue(prompt!.contains("第二条"))
    XCTAssertFalse(prompt!.contains("第三条"), "超出上限的条目应被截掉")
    XCTAssertLessThanOrEqual(prompt!.count, limit)
  }

  func testSystemPromptForCurrentStoreRespectsToggle() {
    _ = AgentMemoryStore.add(text: "记住我")
    XCTAssertNil(AgentMemoryPromptBuilder.systemPromptForCurrentStore(), "未开启时不应注入")

    AgentMemorySettings.enabled = true
    let prompt = AgentMemoryPromptBuilder.systemPromptForCurrentStore()
    XCTAssertNotNil(prompt)
    XCTAssertTrue(prompt!.contains("记住我"))
  }

  func testHermesRequestCarriesInstructions() throws {
    let request = HermesResponsesRequest.plainText(
      "你好",
      model: "hermes",
      conversation: "conv",
      instructions: "长期记忆"
    )
    let data = try JSONEncoder().encode(request)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["instructions"] as? String, "长期记忆")
    XCTAssertEqual(json["model"] as? String, "hermes")
  }
}

/// 镜片 Prefs 子菜单映射（记忆 + 规则混合）
final class AgentPrefsDisplayMappingTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentMemoryStore.clear()
    AgentRuleStore.clear()
  }

  override func tearDown() {
    AgentMemoryStore.clear()
    AgentRuleStore.clear()
    super.tearDown()
  }

  private func memoryEntry(text: String, date: Date) -> AgentMemoryEntry {
    AgentMemoryEntry(text: text, date: date)
  }

  private func ruleEntry(text: String, date: Date) -> AgentRuleEntry {
    AgentRuleEntry(text: text, date: date)
  }

  func testHasPrefs() {
    XCTAssertFalse(AgentPrefsDisplayMapping.hasPrefs())
    AgentMemoryStore.entries = [memoryEntry(text: "我在上海", date: Date())]
    XCTAssertTrue(AgentPrefsDisplayMapping.hasPrefs(), "有记忆即显示入口")

    AgentMemoryStore.clear()
    AgentRuleStore.entries = [ruleEntry(text: "汇报先说结论", date: Date())]
    XCTAssertTrue(AgentPrefsDisplayMapping.hasPrefs(), "有规则即显示入口")
  }

  func testRecentItemsMergesMemoryAndRulesSortedByDate() {
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = older.addingTimeInterval(3600)
    let newest = older.addingTimeInterval(7200)

    AgentMemoryStore.entries = [
      memoryEntry(text: "旧记忆", date: older),
      memoryEntry(text: "新记忆", date: newest),
    ]
    AgentRuleStore.entries = [ruleEntry(text: "中规则", date: newer)]

    let items = AgentPrefsDisplayMapping.recentItems(limit: 10)
    XCTAssertEqual(items.map(\.text), ["新记忆", "中规则", "旧记忆"], "按更新时间降序混合")

    let limited = AgentPrefsDisplayMapping.recentItems(limit: 2)
    XCTAssertEqual(limited.map(\.text), ["新记忆", "中规则"], "limit 生效")
  }

  func testMenuLabelTruncates() {
    let item = AgentPrefsDisplayMapping.Item(
      kind: .memory,
      text: "去楼下拿快递并拍照",
      date: Date()
    )
    XCTAssertEqual(
      AgentPrefsDisplayMapping.menuLabel(for: item),
      "去楼下拿快递并拍…"
    )
    let short = AgentPrefsDisplayMapping.Item(kind: .rule, text: "先结论", date: Date())
    XCTAssertEqual(AgentPrefsDisplayMapping.menuLabel(for: short), "先结论")
  }

  func testResultTextAndIconDistinguishKind() {
    let memory = AgentPrefsDisplayMapping.Item(kind: .memory, text: "我在上海", date: Date())
    XCTAssertEqual(
      AgentPrefsDisplayMapping.resultText(for: memory),
      String(format: "agent.prefs.memory.prefix".localized, "我在上海")
    )
    XCTAssertEqual(AgentPrefsDisplayMapping.iconName(for: memory), "heart")

    let rule = AgentPrefsDisplayMapping.Item(kind: .rule, text: "汇报先说结论", date: Date())
    XCTAssertEqual(
      AgentPrefsDisplayMapping.resultText(for: rule),
      String(format: "agent.prefs.rule.prefix".localized, "汇报先说结论")
    )
    XCTAssertEqual(AgentPrefsDisplayMapping.iconName(for: rule), "sliders_horizontal")
  }
}
