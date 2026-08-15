import XCTest
@testable import HyperMetaAI

/// 后台问答结果通知策略（纯逻辑）
final class AgentAskResultPolicyTests: XCTestCase {

    func testNotifyOnlyWhenBackgroundAndEnabled() {
        XCTAssertFalse(AgentAskResultPolicy.shouldNotify(appActive: true, enabled: true))
        XCTAssertTrue(AgentAskResultPolicy.shouldNotify(appActive: false, enabled: true))
        XCTAssertFalse(AgentAskResultPolicy.shouldNotify(appActive: false, enabled: false))
        XCTAssertFalse(AgentAskResultPolicy.shouldNotify(appActive: true, enabled: false))
    }
}

/// 结果通知设置（可注入 defaults）
final class AgentAskResultSettingsTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.ask.notify.result.v1")
        suite.removePersistentDomain(forName: "test.ask.notify.result.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.ask.notify.result.v1")
        super.tearDown()
    }

    func testDefaultEnabled() {
        XCTAssertTrue(AgentAskResultSettings.enabled(defaults: suite))
    }

    func testRoundTrip() {
        AgentAskResultSettings.setEnabled(false, defaults: suite)
        XCTAssertFalse(AgentAskResultSettings.enabled(defaults: suite))
        AgentAskResultSettings.setEnabled(true, defaults: suite)
        XCTAssertTrue(AgentAskResultSettings.enabled(defaults: suite))
    }
}

/// 结果通知内容构建（纯逻辑）
final class AgentAskResultContentTests: XCTestCase {

    func testRepliedTitleAndBody() {
        let payload = AgentAskResultContent.content(
            for: .replied(text: "明天多云，适合出行。")
        )
        XCTAssertEqual(payload?.title, "agent.ask.notify.result.title".localized)
        XCTAssertEqual(payload?.body, "明天多云，适合出行。")
    }

    func testRepliedLongTextTruncated() {
        let long = String(repeating: "字", count: 300)
        let payload = AgentAskResultContent.content(for: .replied(text: long))
        XCTAssertEqual(payload?.body.count, AgentAskResultContent.maxBodyLength + 1) // 截断 + …
        XCTAssertTrue(payload?.body.hasSuffix("…") == true)
    }

    func testRepliedEmptyTextNoPayload() {
        XCTAssertNil(AgentAskResultContent.content(for: .replied(text: "   ")))
        XCTAssertNil(AgentAskResultContent.content(for: .empty(text: "")))
    }

    func testFailureOutcomesUseFailedTitle() {
        let unavailable = AgentAskResultContent.content(for: .unavailable(text: "x"))
        XCTAssertEqual(unavailable?.title, "agent.ask.notify.result.failed".localized)
        XCTAssertEqual(unavailable?.body, "agent.ask.intent.unavailable".localized)

        let timedOut = AgentAskResultContent.content(for: .timedOut(text: "x"))
        XCTAssertEqual(timedOut?.body, "agent.ask.intent.timeout".localized)

        let failed = AgentAskResultContent.content(
            for: .failed(text: "x", reason: "网关不可达")
        )
        XCTAssertEqual(failed?.title, "agent.ask.notify.result.failed".localized)
        XCTAssertTrue(failed?.body.contains("网关不可达") == true)
    }
}

/// 协调器：策略 + 内容 + 投递接线（notifier 注入）
@MainActor
final class AgentAskResultCoordinatorTests: XCTestCase {

    private final class MockNotifier: AgentAskResultNotifying {
        var sent: [(title: String, body: String, recordID: UUID?, message: String?, brain: AgentBrain?)] = []
        func send(
            title: String,
            body: String,
            recordID: UUID?,
            message: String?,
            brain: AgentBrain?
        ) async {
            sent.append((title, body, recordID, message, brain))
        }
    }

    func testNotifiesWhenBackgroundAndEnabled() async {
        let notifier = MockNotifier()
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: .replied(text: "明天多云"),
            appActive: false,
            enabled: true,
            notifier: notifier
        )
        XCTAssertEqual(notifier.sent.count, 1)
        XCTAssertEqual(notifier.sent.first?.body, "明天多云")
        XCTAssertNil(notifier.sent.first?.recordID, "未归档时不携带记录 ID")
    }

    func testCarriesRecordIDForDeepLink() async {
        let notifier = MockNotifier()
        let recordID = UUID()
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: .replied(text: "明天多云"),
            appActive: false,
            enabled: true,
            recordID: recordID,
            notifier: notifier
        )
        XCTAssertEqual(notifier.sent.first?.recordID, recordID)
        XCTAssertNil(notifier.sent.first?.message, "未传原文时不携带")
        XCTAssertNil(notifier.sent.first?.brain, "未传大脑时不携带")
    }

    func testCarriesMessageAndBrainForRetry() async {
        let notifier = MockNotifier()
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: .timedOut(text: "查一下天气"),
            appActive: false,
            enabled: true,
            message: "查一下天气",
            brain: .hermes,
            notifier: notifier
        )
        XCTAssertEqual(notifier.sent.first?.message, "查一下天气", "锁屏「重试」需要原文")
        XCTAssertEqual(notifier.sent.first?.brain, .hermes, "重试沿用原大脑")
    }

    func testSkipsWhenForegroundOrDisabled() async {
        let notifier = MockNotifier()
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: .replied(text: "明天多云"),
            appActive: true,
            enabled: true,
            notifier: notifier
        )
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: .replied(text: "明天多云"),
            appActive: false,
            enabled: false,
            notifier: notifier
        )
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testSkipsWhenNoPayload() async {
        let notifier = MockNotifier()
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: .empty(text: ""),
            appActive: false,
            enabled: true,
            notifier: notifier
        )
        XCTAssertTrue(notifier.sent.isEmpty)
    }
}

/// 结果通知深链载荷（userInfo 构建 / 解析）
final class AgentAskResultDeepLinkTests: XCTestCase {

    func testIsAskResult() {
        XCTAssertTrue(AgentAskResultDeepLink.isAskResult(["agent.ask.result": true]))
        XCTAssertFalse(AgentAskResultDeepLink.isAskResult(nil))
        XCTAssertFalse(AgentAskResultDeepLink.isAskResult(["agent.ask.result": false]))
        XCTAssertFalse(AgentAskResultDeepLink.isAskResult(["other": true]))
    }

    func testUserInfoRoundTripWithRecordID() {
        let recordID = UUID()
        let info = AgentAskResultDeepLink.userInfo(recordID: recordID)
        XCTAssertTrue(AgentAskResultDeepLink.isAskResult(info))
        XCTAssertEqual(AgentAskResultDeepLink.recordID(from: info), recordID)
    }

    func testUserInfoWithoutRecordID() {
        let info = AgentAskResultDeepLink.userInfo(recordID: nil)
        XCTAssertTrue(AgentAskResultDeepLink.isAskResult(info))
        XCTAssertNil(AgentAskResultDeepLink.recordID(from: info))
    }

    func testUserInfoRoundTripWithMessageAndBrain() {
        let recordID = UUID()
        let info = AgentAskResultDeepLink.userInfo(
            recordID: recordID,
            message: "  查一下天气  ",
            brain: .openclaw
        )
        XCTAssertEqual(AgentAskResultDeepLink.recordID(from: info), recordID)
        XCTAssertEqual(AgentAskResultDeepLink.message(from: info), "  查一下天气  ", "原文原样保留（Handler 侧去空白）")
        XCTAssertEqual(AgentAskResultDeepLink.brain(from: info), .openclaw)
    }

    func testMessageAndBrainWithoutPayload() {
        let info = AgentAskResultDeepLink.userInfo(recordID: nil)
        XCTAssertNil(AgentAskResultDeepLink.message(from: info))
        XCTAssertNil(AgentAskResultDeepLink.message(from: nil))
        XCTAssertNil(AgentAskResultDeepLink.brain(from: info))
        XCTAssertNil(AgentAskResultDeepLink.brain(from: nil))
        XCTAssertNil(AgentAskResultDeepLink.brain(from: ["agent.ask.result.brain": "not-a-brain"]))
    }

    func testRecordIDFromInvalidValue() {
        XCTAssertNil(AgentAskResultDeepLink.recordID(from: nil))
        XCTAssertNil(AgentAskResultDeepLink.recordID(from: ["agent.ask.result.record": "not-a-uuid"]))
        XCTAssertNil(AgentAskResultDeepLink.recordID(from: ["agent.ask.result.record": 42]))
    }
}

/// 「问 JARVIS」结果归档（记录构建 / 归档策略 / 存储往返）
final class AgentAskArchiverTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.ask.archiver.v1")
        suite.removePersistentDomain(forName: "test.ask.archiver.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.ask.archiver.v1")
        super.tearDown()
    }

    func testMakeRecordBuildsUserAndAssistantMessages() {
        let record = AgentAskArchiver.makeRecord(
            message: "  明天天气怎么样？  ",
            reply: "  明天多云转晴。  ",
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(record.aiModel, AgentAskArchiver.aiModel)
        XCTAssertEqual(record.messages.count, 2)
        XCTAssertEqual(record.messages[0].role, .user)
        XCTAssertEqual(record.messages[0].content, "明天天气怎么样？")
        XCTAssertEqual(record.messages[1].role, .assistant)
        XCTAssertEqual(record.messages[1].content, "明天多云转晴。")
        XCTAssertEqual(record.language, "zh-CN")
        XCTAssertEqual(record.title, "明天天气怎么样？", "标题取首条用户消息")
    }

    func testMakeRecordRespectsInjectedIDTimestampAndLanguage() {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        let record = AgentAskArchiver.makeRecord(
            message: "hi",
            reply: "hello",
            id: id,
            timestamp: timestamp,
            language: "en"
        )
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.timestamp, timestamp)
        XCTAssertEqual(record.language, "en")
    }

    func testShouldArchiveOnlyReplied() {
        XCTAssertTrue(AgentAskArchiver.shouldArchive(.replied(text: "ok")))
        XCTAssertFalse(AgentAskArchiver.shouldArchive(.empty(text: "")))
        XCTAssertFalse(AgentAskArchiver.shouldArchive(.unavailable(text: "x")))
        XCTAssertFalse(AgentAskArchiver.shouldArchive(.timedOut(text: "x")))
        XCTAssertFalse(AgentAskArchiver.shouldArchive(.failed(text: "x", reason: "r")))
    }

    func testSaveAndLoadRoundTrip() {
        let storage = ConversationStorage(userDefaults: suite)
        let record = AgentAskArchiver.makeRecord(message: "查一下航班", reply: "明天 10 点起飞。")
        AgentAskArchiver.save(record, storage: storage)

        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, record.id)
        XCTAssertEqual(loaded.first?.aiModel, AgentAskArchiver.aiModel)
        XCTAssertEqual(loaded.first?.summary, "明天 10 点起飞。")
        XCTAssertEqual(storage.getConversation(by: record.id)?.messageCount, 2)
    }

    func testSaveKeepsMostRecentAskRecordDistinctFromChatHistory() {
        let storage = ConversationStorage(userDefaults: suite)
        let chat = ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "聊天")],
            aiModel: "Hermes"
        )
        storage.saveConversation(chat)
        let ask = AgentAskArchiver.makeRecord(message: "问 JARVIS", reply: "回答")
        AgentAskArchiver.save(ask, storage: storage)

        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.id, ask.id, "新记录插头部")
        XCTAssertEqual(storage.deleteConversations(for: "Hermes"), 1)
        XCTAssertEqual(storage.loadAllConversations().count, 1, "只删 Hermes，不误删 ask 记录")
    }
}
