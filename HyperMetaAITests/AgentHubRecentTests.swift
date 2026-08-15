import XCTest
@testable import HyperMetaAI

final class AgentHubRecentTests: XCTestCase {

    private func record(agent: String) -> ConversationRecord {
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "测试")],
            aiModel: agent
        )
    }

    func testKindForKnownAgents() {
        XCTAssertEqual(AgentHubRecentKind.kind(for: "OpenClaw"), .openclaw)
        XCTAssertEqual(AgentHubRecentKind.kind(for: "Hermes"), .hermes)
        XCTAssertEqual(AgentHubRecentKind.kind(for: "qwen-audio-agent"), .qwen)
        XCTAssertEqual(AgentHubRecentKind.kind(for: AgentAskArchiver.aiModel), .ask)
    }

    func testKindForUnknownAgentIsNil() {
        XCTAssertNil(AgentHubRecentKind.kind(for: "some-other-agent"))
        XCTAssertNil(AgentHubRecentKind.kind(for: ""))
    }

    func testIconsMatchAgentUnifiedIcons() {
        XCTAssertEqual(AgentHubRecentKind.openclaw.iconName, "link.circle.fill")
        XCTAssertEqual(AgentHubRecentKind.hermes.iconName, "wand.and.stars")
        XCTAssertEqual(AgentHubRecentKind.qwen.iconName, "waveform")
        XCTAssertEqual(AgentHubRecentKind.ask.iconName, "sparkles")
        XCTAssertEqual(AgentHubRecentKind.ask.tintColor, .orange)
    }

    func testAgentKindRouting() {
        XCTAssertEqual(AgentHubRecentKind.openclaw.agentKind, .openclaw)
        XCTAssertEqual(AgentHubRecentKind.hermes.agentKind, .hermes)
        XCTAssertNil(AgentHubRecentKind.qwen.agentKind)
        XCTAssertNil(AgentHubRecentKind.ask.agentKind, "问 JARVIS 结果走详情页而非聊天")
    }

    func testSelectionIsIdentifiableByRecordID() {
        let record = record(agent: "Hermes")
        let selection = AgentHubRecentSelection(record: record, kind: .hermes)
        XCTAssertEqual(selection.id, record.id)
    }

    func testKindForCustomAgentPrefix() {
        let id = UUID()
        XCTAssertEqual(
            AgentHubRecentKind.kind(for: "custom." + id.uuidString),
            .custom(id)
        )
        XCTAssertNil(AgentHubRecentKind.kind(for: "custom.not-a-uuid"))
        XCTAssertNil(AgentHubRecentKind.kind(for: "custom."))
        XCTAssertNil(AgentHubRecentKind.kind(for: "Custom." + id.uuidString), "前缀区分大小写")
        XCTAssertNil(AgentHubRecentKind.kind(for: "custom"), "缺少 ID 不归类")
    }

    func testCustomKindIconAndRouting() {
        let id = UUID()
        XCTAssertEqual(AgentHubRecentKind.custom(id).iconName, "globe")
        XCTAssertEqual(AgentHubRecentKind.custom(id).agentKind, .hermes)
    }
}

final class AgentHubRecentFilterTests: XCTestCase {

    private func record(agent: String, title: String = "测试", summary: String = "摘要") -> ConversationRecord {
        ConversationRecord(
            messages: [
                ConversationMessage(role: .user, content: title),
                ConversationMessage(role: .assistant, content: summary),
            ],
            aiModel: agent
        )
    }

    private func selection(_ record: ConversationRecord) -> AgentHubRecentSelection {
        let kind = AgentHubRecentKind.kind(for: record.aiModel)!
        return AgentHubRecentSelection(record: record, kind: kind)
    }

    private func makeItems() -> [AgentHubRecentSelection] {
        [
            selection(record(agent: "OpenClaw", title: "整理会议纪要", summary: "三页要点")),
            selection(record(agent: "Hermes", title: "查航班", summary: "明天 10 点起飞")),
            selection(record(agent: "qwen-audio-agent", title: "语音备忘", summary: "买牛奶")),
            selection(record(agent: AgentAskArchiver.aiModel, title: "问 JARVIS", summary: "明天多云")),
            selection(record(agent: "custom." + UUID().uuidString, title: "自定义小助手", summary: "自定义摘要")),
        ]
    }

    func testFilterAllKeepsAll() {
        XCTAssertEqual(AgentHubRecentFilter.filter(makeItems(), choice: .all).count, 5)
    }

    func testFilterByEachKind() {
        let items = makeItems()
        XCTAssertEqual(AgentHubRecentFilter.filter(items, choice: .openclaw).count, 1)
        XCTAssertEqual(AgentHubRecentFilter.filter(items, choice: .hermes).count, 1)
        XCTAssertEqual(AgentHubRecentFilter.filter(items, choice: .qwen).count, 1)
        XCTAssertEqual(AgentHubRecentFilter.filter(items, choice: .ask).count, 1)
        XCTAssertEqual(AgentHubRecentFilter.filter(items, choice: .custom).count, 1)
    }

    func testAskMatchesOnlyAskRecords() {
        let items = makeItems()
        XCTAssertTrue(AgentHubRecentFilter.matches(items[3], choice: .ask))
        XCTAssertFalse(AgentHubRecentFilter.matches(items[0], choice: .ask))
    }

    func testCustomMatchesAnyCustomConfig() {
        let a = selection(record(agent: "custom." + UUID().uuidString, title: "A", summary: "a"))
        let b = selection(record(agent: "custom." + UUID().uuidString, title: "B", summary: "b"))
        XCTAssertEqual(AgentHubRecentFilter.filter([a, b], choice: .custom).count, 2)
    }

    func testMatches() {
        let items = makeItems()
        XCTAssertTrue(AgentHubRecentFilter.matches(items[0], choice: .all))
        XCTAssertTrue(AgentHubRecentFilter.matches(items[0], choice: .openclaw))
        XCTAssertFalse(AgentHubRecentFilter.matches(items[0], choice: .hermes))
    }

    func testSearchByTitleAndSummaryCaseInsensitive() {
        let items = makeItems()
        XCTAssertEqual(AgentHubRecentFilter.search(items, query: "会议").map(\.record.title), ["整理会议纪要"])
        XCTAssertEqual(AgentHubRecentFilter.search(items, query: "三页").count, 1, "摘要可命中")
        XCTAssertEqual(AgentHubRecentFilter.search(items, query: "QIANWU").count, 0, "无匹配返回空")

        let english = selection(record(agent: "Hermes", title: "Meeting Notes", summary: "Action items"))
        XCTAssertEqual(AgentHubRecentFilter.search([english], query: "meeting").count, 1, "标题大小写不敏感命中")
        XCTAssertEqual(AgentHubRecentFilter.search([english], query: "ACTION").count, 1, "摘要大小写不敏感命中")
    }

    func testSearchEmptyOrWhitespaceQueryReturnsAll() {
        let items = makeItems()
        XCTAssertEqual(AgentHubRecentFilter.search(items, query: "").count, 5)
        XCTAssertEqual(AgentHubRecentFilter.search(items, query: "   ").count, 5)
    }

  func testSearchCombinedWithFilter() {
    let items = makeItems()
    let hermesOnly = AgentHubRecentFilter.filter(items, choice: .hermes)
    XCTAssertEqual(AgentHubRecentFilter.search(hermesOnly, query: "会议").count, 0, "过滤后再搜索不跨类别命中")
    XCTAssertEqual(AgentHubRecentFilter.search(hermesOnly, query: "航班").count, 1)
  }

  func testSearchMatchesCustomConfigName() {
    let id = UUID()
    let item = selection(record(agent: "custom." + id.uuidString, title: "对话记录", summary: "摘要"))
    XCTAssertEqual(
      AgentHubRecentFilter.search([item], query: "助手", configNames: [id: "我的助手"]).count,
      1,
      "按配置名命中"
    )
    XCTAssertEqual(
      AgentHubRecentFilter.search([item], query: "HELPER", configNames: [id: "My Helper"]).count,
      1,
      "配置名大小写不敏感"
    )
    XCTAssertEqual(
      AgentHubRecentFilter.search([item], query: "助手", configNames: [:]).count,
      0,
      "无配置名索引时不因配置名命中"
    )
    XCTAssertEqual(
      AgentHubRecentFilter.search([item], query: "对话", configNames: [id: "我的助手"]).count,
      1,
      "标题命中不受配置名影响"
    )
  }

  func testSearchConfigNameOnlyMatchesItsOwnCustomRecord() {
    let idA = UUID()
    let idB = UUID()
    let a = selection(record(agent: "custom." + idA.uuidString, title: "A 记录", summary: "a"))
    let b = selection(record(agent: "custom." + idB.uuidString, title: "B 记录", summary: "b"))
    XCTAssertEqual(
      AgentHubRecentFilter.search([a, b], query: "助手", configNames: [idA: "我的助手", idB: "另一个"]).count,
      1,
      "只命中配置名对应的记录"
    )
  }

    func testAvailableChoicesFixedOrderAndDedupe() {
        let items = makeItems()
        XCTAssertEqual(
            AgentHubRecentFilter.availableChoices(items),
            [.openclaw, .hermes, .qwen, .ask, .custom],
            "固定顺序：OpenClaw → Hermes → Qwen → 问 JARVIS → 自定义"
        )
        let onlyQwen = [selection(record(agent: "qwen-audio-agent", title: "x", summary: "y"))]
        XCTAssertEqual(AgentHubRecentFilter.availableChoices(onlyQwen), [.qwen])
        let onlyAsk = [selection(record(agent: AgentAskArchiver.aiModel, title: "x", summary: "y"))]
        XCTAssertEqual(AgentHubRecentFilter.availableChoices(onlyAsk), [.ask])
        XCTAssertTrue(AgentHubRecentFilter.availableChoices([]).isEmpty)
    }

    func testFilterLabels() {
        XCTAssertEqual(AgentHubRecentFilter.filterLabel(for: .all), "agents.hub.recent.filter.all".localized)
        XCTAssertEqual(AgentHubRecentFilter.filterLabel(for: .openclaw), "OpenClaw")
        XCTAssertEqual(AgentHubRecentFilter.filterLabel(for: .hermes), "Hermes")
        XCTAssertEqual(AgentHubRecentFilter.filterLabel(for: .qwen), "Qwen")
        XCTAssertEqual(AgentHubRecentFilter.filterLabel(for: .ask), "agents.hub.recent.filter.ask".localized)
        XCTAssertEqual(AgentHubRecentFilter.filterLabel(for: .custom), "agents.hub.recent.filter.custom".localized)
    }
}

final class AgentHubRecentDisplayTests: XCTestCase {

    private func record(agent: String, title: String = "首条消息") -> ConversationRecord {
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: title)],
            aiModel: agent
        )
    }

    private func selection(_ record: ConversationRecord) -> AgentHubRecentSelection {
        AgentHubRecentSelection(record: record, kind: AgentHubRecentKind.kind(for: record.aiModel)!)
    }

    func testTitleUsesConfigNameForCustomAgent() {
        let id = UUID()
        let item = selection(record(agent: "custom." + id.uuidString))
        XCTAssertEqual(
            AgentHubRecentDisplay.title(for: item, configNames: [id: "我的助手"]),
            "我的助手"
        )
    }

    func testTitleFallsBackToRecordTitleWhenConfigMissingOrEmpty() {
        let id = UUID()
        let item = selection(record(agent: "custom." + id.uuidString, title: "历史会话"))
        XCTAssertEqual(
            AgentHubRecentDisplay.title(for: item, configNames: [:]),
            "历史会话",
            "配置已删除时回退记录标题"
        )
        XCTAssertEqual(
            AgentHubRecentDisplay.title(for: item, configNames: [id: "   "]),
            "历史会话",
            "空配置名回退记录标题"
        )
    }

    func testTitleUsesRecordTitleForBuiltInAgents() {
        let item = selection(record(agent: "Hermes", title: "查航班"))
        XCTAssertEqual(
            AgentHubRecentDisplay.title(for: item, configNames: [:]),
            "查航班"
        )
    }

    func testSubtitleForCustomAgentPrefixesRecordTitle() {
        let item = selection(record(agent: "custom." + UUID().uuidString, title: "整理纪要"))
        XCTAssertEqual(
            AgentHubRecentDisplay.subtitle(for: item, configNames: [:], dateText: "今天 10:00"),
            "整理纪要 · 今天 10:00"
        )
    }

    func testSubtitleForBuiltInAgentsIsDateOnly() {
        let item = selection(record(agent: "OpenClaw", title: "整理纪要"))
        XCTAssertEqual(
            AgentHubRecentDisplay.subtitle(for: item, configNames: [:], dateText: "昨天 09:30"),
            "昨天 09:30"
        )
    }
}
