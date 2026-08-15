/*
 * Agent Notification Butler Tests
 * 汇总文案（截断 / 隐私分级）、播报策略、指令解析、收件箱去重、
 * 执行器（权限流转 + Mock 通知中心）。
 */

import XCTest
import UserNotifications
@testable import HyperMetaAI

// MARK: - 汇总

final class AgentNotificationSummarizerTests: XCTestCase {
    private func item(
        _ title: String,
        _ body: String = "",
        id: String = UUID().uuidString,
        date: Date = Date()
    ) -> AgentNotificationItem {
        AgentNotificationItem(id: id, title: title, body: body, date: date)
    }

    func testTruncateKeepsShortText() {
        XCTAssertEqual(AgentNotificationSummarizer.truncate("你好", to: 10), "你好")
    }

    func testTruncateLongTextAppendsEllipsis() {
        XCTAssertEqual(
            AgentNotificationSummarizer.truncate("一二三四五六七八九十", to: 5),
            "一二三四五…"
        )
    }

    func testTruncateZeroLengthReturnsEmpty() {
        XCTAssertEqual(AgentNotificationSummarizer.truncate("你好", to: 0), "")
    }

    func testAnnouncementTitlesOnly() {
        let text = AgentNotificationSummarizer.announcementText(
            for: item("张三", "晚上好"),
            privacy: .titlesOnly,
            maxLength: 60
        )
        XCTAssertEqual(text, "agent.notify.live.titlesOnly".localized)
    }

    func testAnnouncementTitlesUsesTitle() {
        let text = AgentNotificationSummarizer.announcementText(
            for: item("张三", "晚上好"),
            privacy: .titles,
            maxLength: 60
        )
        XCTAssertEqual(text, "agent.notify.live.prefix".localized + "张三")
    }

    func testAnnouncementTitlesFallsBackToBodyWhenTitleEmpty() {
        let text = AgentNotificationSummarizer.announcementText(
            for: item("", "晚上好"),
            privacy: .titles,
            maxLength: 60
        )
        XCTAssertEqual(text, "agent.notify.live.prefix".localized + "晚上好")
    }

    func testAnnouncementFullCombinesTitleAndBody() {
        let text = AgentNotificationSummarizer.announcementText(
            for: item("张三", "晚上好"),
            privacy: .full,
            maxLength: 60
        )
        XCTAssertEqual(text, "agent.notify.live.prefix".localized + "张三：晚上好")
    }

    func testAnnouncementFullRespectsMaxLength() {
        let text = AgentNotificationSummarizer.announcementText(
            for: item("一二三四五六七八九十", "abcdefghijklmnopqrstuvwxyz"),
            privacy: .full,
            maxLength: 12
        )
        XCTAssertTrue(text.hasSuffix("…"))
        // 前缀（随 locale 变化）+ 截断后文本 + 省略号
        let prefix = "agent.notify.live.prefix".localized
        XCTAssertLessThanOrEqual(text.count, prefix.count + 13)
    }

    func testCatchUpEmpty() {
        let text = AgentNotificationSummarizer.catchUpText(
            items: [],
            privacy: .full,
            maxItems: 5,
            maxLength: 60
        )
        XCTAssertEqual(text, "agent.notify.summary.empty".localized)
    }

    func testCatchUpTitlesOnlyShowsCount() {
        let text = AgentNotificationSummarizer.catchUpText(
            items: [item("A"), item("B")],
            privacy: .titlesOnly,
            maxItems: 5,
            maxLength: 60
        )
        XCTAssertEqual(text, String(format: "agent.notify.summary.prefix".localized, 2))
    }

    func testCatchUpTitlesListsTitles() {
        let text = AgentNotificationSummarizer.catchUpText(
            items: [item("张三"), item("李四")],
            privacy: .titles,
            maxItems: 5,
            maxLength: 60
        )
        XCTAssertTrue(text.contains("张三"))
        XCTAssertTrue(text.contains("李四"))
    }

    func testCatchUpFullListsTitleAndBody() {
        let text = AgentNotificationSummarizer.catchUpText(
            items: [item("张三", "晚上好")],
            privacy: .full,
            maxItems: 5,
            maxLength: 60
        )
        XCTAssertTrue(text.contains("张三：晚上好"))
    }

    func testCatchUpRespectsMaxItems() {
        // 乱序输入 + 不同时间戳：内部排序后最新在前，只呈现最近 maxItems 条
        let items = (0..<10).map {
            item("标题\($0)", date: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let text = AgentNotificationSummarizer.catchUpText(
            items: items.shuffled(),
            privacy: .titles,
            maxItems: 3,
            maxLength: 60
        )
        XCTAssertTrue(text.contains("标题9"))
        XCTAssertTrue(text.contains("标题7"))
        XCTAssertFalse(text.contains("标题6"))
        XCTAssertTrue(text.hasPrefix(String(format: "agent.notify.summary.prefix".localized, 10)))
    }

    func testSortedNewestFirst() {
        let older = item("旧", date: Date(timeIntervalSince1970: 100))
        let newer = item("新", date: Date(timeIntervalSince1970: 200))
        let sorted = AgentNotificationSummarizer.sortedNewestFirst([older, newer])
        XCTAssertEqual(sorted.first?.title, "新")
    }
}

// MARK: - 策略

final class AgentNotificationPolicyTests: XCTestCase {
    func testOffNeverAnnounces() {
        XCTAssertFalse(
            AgentNotificationPolicy.shouldAnnounce(mode: .off, isSessionActive: false)
        )
        XCTAssertFalse(
            AgentNotificationPolicy.shouldAnnounce(mode: .off, isSessionActive: true)
        )
    }

    func testActiveSessionRequiresSession() {
        XCTAssertFalse(
            AgentNotificationPolicy.shouldAnnounce(mode: .activeSession, isSessionActive: false)
        )
        XCTAssertTrue(
            AgentNotificationPolicy.shouldAnnounce(mode: .activeSession, isSessionActive: true)
        )
    }

    func testForegroundAlwaysAnnounces() {
        XCTAssertTrue(
            AgentNotificationPolicy.shouldAnnounce(mode: .foreground, isSessionActive: false)
        )
        XCTAssertTrue(
            AgentNotificationPolicy.shouldAnnounce(mode: .foreground, isSessionActive: true)
        )
    }
}

// MARK: - 指令解析

final class AgentNotificationCommandParserTests: XCTestCase {
    func testParsesCatchUpKeywords() {
        for keyword in ["有什么通知", "未读消息", "未读通知", "播报通知", "看看通知", "读通知"] {
            XCTAssertEqual(
                AgentNotificationCommandParser.parse(keyword),
                .catchUp,
                "\(keyword) should parse as catchUp"
            )
        }
    }

    func testParsesClearKeywords() {
        for keyword in ["清空通知", "清除通知", "清空所有通知", "把通知清掉"] {
            XCTAssertEqual(
                AgentNotificationCommandParser.parse(keyword),
                .clear,
                "\(keyword) should parse as clear"
            )
        }
    }

    func testIgnoresPlainConversation() {
        XCTAssertNil(AgentNotificationCommandParser.parse("今天天气怎么样"))
        XCTAssertNil(AgentNotificationCommandParser.parse("通知中心在哪"))
        XCTAssertNil(AgentNotificationCommandParser.parse(""))
    }

    func testIgnoresOverlongText() {
        let long = "有什么通知" + String(repeating: "啊", count: 30)
        XCTAssertNil(AgentNotificationCommandParser.parse(long))
    }

    func testClearTakesPriorityOverCatchUp() {
        // 「清空通知」同时含「通知」但 clear 关键词优先
        XCTAssertEqual(
            AgentNotificationCommandParser.parse("请清空通知"),
            .clear
        )
    }
}

// MARK: - 收件箱

final class AgentNotificationInboxTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.notify.inbox")
        defaults.removePersistentDomain(forName: "test.agent.notify.inbox")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.notify.inbox")
        defaults = nil
        super.tearDown()
    }

    func testRecordInsertsNewestFirstAndDeduplicates() {
        AgentNotificationInbox.record("a", defaults: defaults)
        AgentNotificationInbox.record("b", defaults: defaults)
        AgentNotificationInbox.record("a", defaults: defaults)

        let ids = AgentNotificationInbox.load(defaults: defaults)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testContains() {
        AgentNotificationInbox.record("a", defaults: defaults)
        XCTAssertTrue(AgentNotificationInbox.contains("a", defaults: defaults))
        XCTAssertFalse(AgentNotificationInbox.contains("z", defaults: defaults))
    }

    func testCapsAtLimit() {
        for index in 0..<(AgentNotificationInbox.maxEntries + 10) {
            AgentNotificationInbox.record("id-\(index)", defaults: defaults)
        }
        let ids = AgentNotificationInbox.load(defaults: defaults)
        XCTAssertEqual(ids.count, AgentNotificationInbox.maxEntries)
        XCTAssertEqual(ids.first, "id-\(AgentNotificationInbox.maxEntries + 9)")
    }

    func testPersistsAcrossLoads() {
        AgentNotificationInbox.record("a", defaults: defaults)
        let reloaded = AgentNotificationInbox.load(
            defaults: UserDefaults(suiteName: "test.agent.notify.inbox")!
        )
        XCTAssertEqual(reloaded, ["a"])
    }

    func testClearRemovesAll() {
        AgentNotificationInbox.record("a", defaults: defaults)
        AgentNotificationInbox.clear(defaults: defaults)
        XCTAssertTrue(AgentNotificationInbox.load(defaults: defaults).isEmpty)
    }
}

// MARK: - 执行器

private final class MockNotificationProvider: AgentNotificationProviding {
    var status: UNAuthorizationStatus = .authorized
    var items: [AgentNotificationItem] = []
    var removed = false
    var requested = false

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        requested = true
        if status == .notDetermined {
            status = .authorized
        }
        return status == .authorized
    }

    func deliveredNotifications() async -> [AgentNotificationItem] { items }

    func removeAllDeliveredNotifications() async {
        removed = true
    }
}

final class AgentNotificationExecutorTests: XCTestCase {
    func testCatchUpSummarizesDelivered() async {
        let provider = MockNotificationProvider()
        provider.items = [
            AgentNotificationItem(id: "1", title: "张三", body: "晚上好", date: Date(timeIntervalSince1970: 200)),
            AgentNotificationItem(id: "2", title: "李四", body: "", date: Date(timeIntervalSince1970: 100))
        ]
        let reply = await AgentNotificationExecutor.execute(
            .catchUp,
            provider: provider,
            privacy: .titles,
            maxItems: 5,
            maxLength: 60
        )
        XCTAssertTrue(reply.contains("张三"))
        XCTAssertTrue(reply.contains("李四"))
        XCTAssertTrue(reply.hasPrefix(String(format: "agent.notify.summary.prefix".localized, 2)))
    }

    func testCatchUpEmpty() async {
        let provider = MockNotificationProvider()
        let reply = await AgentNotificationExecutor.execute(.catchUp, provider: provider)
        XCTAssertEqual(reply, "agent.notify.summary.empty".localized)
    }

    func testCatchUpDenied() async {
        let provider = MockNotificationProvider()
        provider.status = .denied
        let reply = await AgentNotificationExecutor.execute(.catchUp, provider: provider)
        XCTAssertEqual(reply, "agent.notify.denied".localized)
        XCTAssertFalse(provider.requested)
    }

    func testNotDeterminedRequestsAuthorization() async {
        let provider = MockNotificationProvider()
        provider.status = .notDetermined
        let reply = await AgentNotificationExecutor.execute(.catchUp, provider: provider)
        XCTAssertTrue(provider.requested)
        XCTAssertEqual(reply, "agent.notify.summary.empty".localized)
    }

    func testClearRemovesAllDelivered() async {
        let provider = MockNotificationProvider()
        provider.items = [
            AgentNotificationItem(id: "1", title: "A", body: "", date: Date()),
            AgentNotificationItem(id: "2", title: "B", body: "", date: Date()),
            AgentNotificationItem(id: "3", title: "C", body: "", date: Date())
        ]
        let reply = await AgentNotificationExecutor.execute(.clear, provider: provider)
        XCTAssertTrue(provider.removed)
        XCTAssertEqual(reply, String(format: "agent.notify.cleared".localized, 3))
    }
}
