/*
 * Agent Ask Intent Tests
 * 「问 JARVIS」App Intent：大脑选项映射、应答文案（截断 / 各结果分支）、
 * 单轮执行器（空输入拦截 / 回复 / 错误 / 超时 / Auto 路由 / Qwen 拒绝）。
 */

import XCTest
@testable import HyperMetaAI

// MARK: - 大脑选项

final class AgentAskBrainOptionTests: XCTestCase {
    func testOptionMapsToAgentBrain() {
        XCTAssertEqual(AgentAskBrainOption.auto.agentBrain, .auto)
        XCTAssertEqual(AgentAskBrainOption.none.agentBrain, .none)
        XCTAssertEqual(AgentAskBrainOption.hermes.agentBrain, .hermes)
        XCTAssertEqual(AgentAskBrainOption.openclaw.agentBrain, .openclaw)
        XCTAssertEqual(AgentAskBrainOption.custom.agentBrain, .custom)
    }
}

// MARK: - 应答文案

final class AgentAskIntentFormatterTests: XCTestCase {
    func testRepliedReturnsTrimmedText() {
        XCTAssertEqual(
            AgentAskIntentFormatter.dialog(for: .replied(text: "  你好  ")),
            "你好"
        )
    }

    func testRepliedTruncatesLongText() {
        let long = String(repeating: "字", count: 800)
        let dialog = AgentAskIntentFormatter.dialog(for: .replied(text: long))
        XCTAssertEqual(
            dialog.count,
            AgentAskIntentFormatter.maxDialogLength + 1
        )
        XCTAssertTrue(dialog.hasSuffix("…"))
    }

    func testEmptyOutcome() {
        XCTAssertEqual(
            AgentAskIntentFormatter.dialog(for: .empty(text: " ")),
            "agent.ask.intent.empty".localized
        )
    }

    func testUnavailableOutcome() {
        XCTAssertEqual(
            AgentAskIntentFormatter.dialog(for: .unavailable(text: "hi")),
            "agent.ask.intent.unavailable".localized
        )
    }

    func testTimedOutOutcome() {
        XCTAssertEqual(
            AgentAskIntentFormatter.dialog(for: .timedOut(text: "hi")),
            "agent.ask.intent.timeout".localized
        )
    }

    func testFailedOutcomeIncludesReason() {
        XCTAssertEqual(
            AgentAskIntentFormatter.dialog(
                for: .failed(text: "hi", reason: "network")
            ),
            String(format: "agent.ask.intent.failed".localized, "network")
        )
    }
}

// MARK: - 单轮执行器

@MainActor
final class AgentAskIntentHandlerTests: XCTestCase {

    private let hermesReady = AgentBackendAvailability(
        openClawReady: false,
        hermesReady: true,
        customReady: false
    )
    private let allReady = AgentBackendAvailability(
        openClawReady: true,
        hermesReady: true,
        customReady: true
    )

    private func captureSend(
        _ capture: @escaping (String, AgentBrain) -> Void
    ) -> @MainActor (String, AgentBrain, @escaping (String) -> Void, @escaping (String) -> Void) -> Void {
        { text, brain, onFinal, onError in
            capture(text, brain)
            _ = onFinal
            _ = onError
        }
    }

    func testEmptyMessageDoesNotCallSend() async {
        var sendCalled = false
        let outcome = await AgentAskIntentHandler.ask(
            message: "   ",
            timeout: 1,
            send: { _, _, _, _ in sendCalled = true }
        )
        XCTAssertEqual(outcome, .empty(text: "   "))
        XCTAssertFalse(sendCalled)
    }

    func testRepliedOutcome() async {
        let outcome = await AgentAskIntentHandler.ask(
            message: "介绍一下你自己",
            timeout: 1,
            availability: hermesReady,
            send: { _, _, onFinal, _ in
                onFinal("我是 Hyper，你的智能管家。")
            }
        )
        XCTAssertEqual(outcome, .replied(text: "我是 Hyper，你的智能管家。"))
    }

    func testErrorOutcome() async {
        let outcome = await AgentAskIntentHandler.ask(
            message: "查一下天气",
            timeout: 1,
            availability: hermesReady,
            send: { _, _, _, onError in
                onError("hermes.error.notconnected".localized)
            }
        )
        XCTAssertEqual(
            outcome,
            .failed(text: "查一下天气", reason: "hermes.error.notconnected".localized)
        )
    }

    func testTimeoutOutcomeWhenSendNeverReplies() async {
        let outcome = await AgentAskIntentHandler.ask(
            message: "慢任务",
            timeout: 0.1,
            availability: hermesReady,
            send: { _, _, _, _ in }
        )
        XCTAssertEqual(outcome, .timedOut(text: "慢任务"))
    }

    func testAutoRoutesTaskKeywordToOpenClaw() async {
        var receivedBrain: AgentBrain?
        let outcome = await AgentAskIntentHandler.ask(
            message: "帮我查一下明天的天气",
            timeout: 1,
            availability: allReady,
            send: { _, brain, onFinal, _ in
                receivedBrain = brain
                onFinal("done")
            }
        )
        XCTAssertEqual(outcome, .replied(text: "done"))
        XCTAssertEqual(receivedBrain, .openclaw)
    }

    func testAutoRoutesGeneralQuestionToHermes() async {
        var receivedBrain: AgentBrain?
        let outcome = await AgentAskIntentHandler.ask(
            message: "介绍一下你自己",
            timeout: 1,
            availability: allReady,
            send: { _, brain, onFinal, _ in
                receivedBrain = brain
                onFinal("ok")
            }
        )
        XCTAssertEqual(outcome, .replied(text: "ok"))
        XCTAssertEqual(receivedBrain, .hermes)
    }

    func testExplicitQwenIsUnavailable() async {
        let outcome = await AgentAskIntentHandler.ask(
            message: "你好",
            brain: .qwen,
            timeout: 1,
            send: { _, _, _, _ in }
        )
        XCTAssertEqual(outcome, .unavailable(text: "你好"))
    }

    func testAutoWithoutConfiguredBackendIsUnavailable() async {
        var sendCalled = false
        let outcome = await AgentAskIntentHandler.ask(
            message: "帮我查天气",
            timeout: 1,
            availability: .none,
            send: { _, _, _, _ in sendCalled = true }
        )
        XCTAssertEqual(outcome, .unavailable(text: "帮我查天气"))
        XCTAssertFalse(sendCalled)
    }

    func testExplicitNoBackendIsUnavailable() async {
        var sendCalled = false
        let outcome = await AgentAskIntentHandler.ask(
            message: "你好",
            brain: .none,
            timeout: 1,
            availability: allReady,
            send: { _, _, _, _ in sendCalled = true }
        )
        XCTAssertEqual(outcome, .unavailable(text: "你好"))
        XCTAssertFalse(sendCalled)
    }

    func testSendOnlyResumesOnce() async {
        var callbacks = 0
        let outcome = await AgentAskIntentHandler.ask(
            message: "先回复再报错",
            timeout: 1,
            availability: hermesReady,
            send: { _, _, onFinal, onError in
                onFinal("第一条回复")
                onError("迟到错误")
                onFinal("第二条回复")
                callbacks += 1
            }
        )
        XCTAssertEqual(outcome, .replied(text: "第一条回复"))
        XCTAssertEqual(callbacks, 1)
    }
}

// MARK: - 结果通知 Action（继续追问 / 查看详情）

final class AgentAskResultNotificationActionParserTests: XCTestCase {
    func testFollowUpIdentifierParsesToFollowUp() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: AgentAskResultNotificationCategory.followUpIdentifier
            ),
            .followUp
        )
    }

    func testDefaultTapParsesToOpenDetail() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ),
            .openDetail
        )
    }

    func testUnknownActionParsesToNone() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(actionIdentifier: "UNKNOWN"),
            .none
        )
    }

    func testReplyIdentifierParsesWithText() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: AgentAskResultNotificationCategory.replyIdentifier,
                text: "帮我把牛奶加到购物单"
            ),
            .reply(text: "帮我把牛奶加到购物单")
        )
    }

    func testReplyIdentifierWithoutTextParsesEmpty() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: AgentAskResultNotificationCategory.replyIdentifier
            ),
            .reply(text: ""),
            "旧调用不传文本时 reply 带空文本（Handler 侧忽略空输入）"
        )
    }

    func testReplyDoesNotAffectOtherActions() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: AgentAskResultNotificationCategory.followUpIdentifier,
                text: "不该生效"
            ),
            .followUp
        )
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                text: "不该生效"
            ),
            .openDetail
        )
    }

    func testRetryIdentifierParsesToRetry() {
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: AgentAskResultNotificationCategory.retryIdentifier
            ),
            .retry
        )
        XCTAssertEqual(
            AgentAskResultNotificationActionParser.parse(
                actionIdentifier: AgentAskResultNotificationCategory.retryIdentifier,
                text: "不该生效"
            ),
            .retry,
            "文本输入只对 reply 标识生效"
        )
    }
}

// MARK: - 结果通知分类（继续追问 / 回复 JARVIS）

final class AgentAskResultNotificationCategoryTests: XCTestCase {
    func testActionsIncludeFollowUpRetryAndReply() {
        let actions = AgentAskResultNotificationCategory.actions
        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(
            actions[0].identifier,
            AgentAskResultNotificationCategory.followUpIdentifier
        )
        XCTAssertEqual(actions[1].identifier, AgentAskResultNotificationCategory.retryIdentifier)
        XCTAssertEqual(actions[2].identifier, AgentAskResultNotificationCategory.replyIdentifier)
        XCTAssertTrue(actions[0].options.contains(.foreground), "追问需带 .foreground 打开 App")
        XCTAssertTrue(actions[1].options.contains(.foreground), "重试需带 .foreground 打开 App")
    }

    func testReplyActionIsTextInputWithForeground() {
        let reply = AgentAskResultNotificationCategory.replyAction
        XCTAssertEqual(reply.identifier, AgentAskResultNotificationCategory.replyIdentifier)
        XCTAssertTrue(reply.options.contains(.foreground), "回复需打开 App 呈现语音页")
    }
}

final class AgentAskFollowUpContextResolverTests: XCTestCase {
    private func record(id: UUID = UUID(), reply: String?) -> ConversationRecord {
        var messages = [ConversationMessage(role: .user, content: "问题")]
        if let reply {
            messages.append(ConversationMessage(role: .assistant, content: reply))
        }
        return ConversationRecord(id: id, messages: messages, aiModel: "agent-ask")
    }

    func testResolvesLastAssistantReply() {
        let id = UUID()
        let context = AgentAskFollowUpContextResolver.resolve(
            recordID: id,
            records: [record(id: id, reply: "这是一株健康的室内观叶植物。")]
        )
        XCTAssertEqual(context, "这是一株健康的室内观叶植物。")
    }

    func testNilWhenRecordIDMissing() {
        XCTAssertNil(
            AgentAskFollowUpContextResolver.resolve(recordID: nil, records: [record(reply: "有回复")])
        )
    }

    func testNilWhenRecordNotFound() {
        XCTAssertNil(
            AgentAskFollowUpContextResolver.resolve(recordID: UUID(), records: [record(reply: "有回复")])
        )
    }

    func testNilWhenNoAssistantReply() {
        let id = UUID()
        XCTAssertNil(
            AgentAskFollowUpContextResolver.resolve(
                recordID: id,
                records: [record(id: id, reply: nil)]
            )
        )
        XCTAssertNil(
            AgentAskFollowUpContextResolver.resolve(recordID: id, records: [record(id: id, reply: "   ")])
        )
    }
}

// MARK: - 结果通知 Action 执行（Mock 路由）

@MainActor
final class AgentAskResultNotificationActionHandlerTests: XCTestCase {

    private final class MockRouter: AgentAskResultNotificationActionRouting {
        var openedDetailIDs: [UUID] = []
        var followUpIDs: [UUID?] = []
        var repliedTexts: [String] = []
        var repliedRecordIDs: [UUID?] = []
        var retriedAsks: [(message: String, brain: AgentBrain)] = []

        func openDetail(recordID: UUID) {
            openedDetailIDs.append(recordID)
        }

        func openFollowUp(recordID: UUID?) {
            followUpIDs.append(recordID)
        }

        func replyToJARVIS(text: String, recordID: UUID?) {
            repliedTexts.append(text)
            repliedRecordIDs.append(recordID)
        }

        func retryAsk(message: String, brain: AgentBrain) async {
            retriedAsks.append((message, brain))
        }
    }

    func testOpenDetailRoutesRecordID() async {
        let router = MockRouter()
        let id = UUID()
        await AgentAskResultNotificationActionHandler.handle(
            action: .openDetail,
            recordID: id,
            router: router
        )
        XCTAssertEqual(router.openedDetailIDs, [id])
        XCTAssertTrue(router.followUpIDs.isEmpty)
    }

    func testOpenDetailWithoutRecordIDIsNoOp() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .openDetail,
            recordID: nil,
            router: router
        )
        XCTAssertTrue(router.openedDetailIDs.isEmpty, "无记录 ID 时不深链")
        XCTAssertTrue(router.followUpIDs.isEmpty)
    }

    func testFollowUpRoutesRecordID() async {
        let router = MockRouter()
        let id = UUID()
        await AgentAskResultNotificationActionHandler.handle(
            action: .followUp,
            recordID: id,
            router: router
        )
        XCTAssertEqual(router.followUpIDs, [id])
        XCTAssertTrue(router.openedDetailIDs.isEmpty)
    }

    func testFollowUpWithoutRecordIDStillOpensVoicePage() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .followUp,
            recordID: nil,
            router: router
        )
        XCTAssertEqual(router.followUpIDs, [nil], "无记录也打开语音页（协调器回退最近任务/会话上下文）")
    }

    func testReplyRoutesTrimmedTextAndRecordIDToJARVIS() async {
        let router = MockRouter()
        let id = UUID()
        await AgentAskResultNotificationActionHandler.handle(
            action: .reply(text: "  那它多久浇一次水？  "),
            recordID: id,
            router: router
        )
        XCTAssertEqual(router.repliedTexts, ["那它多久浇一次水？"])
        XCTAssertEqual(router.repliedRecordIDs, [id], "回复携带记录 ID，供路由恢复结果上下文")
        XCTAssertTrue(router.openedDetailIDs.isEmpty)
        XCTAssertTrue(router.followUpIDs.isEmpty)
    }

    func testReplyWithoutRecordIDStillOpensVoicePage() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .reply(text: "把牛奶加到购物单"),
            recordID: nil,
            router: router
        )
        XCTAssertEqual(router.repliedTexts, ["把牛奶加到购物单"])
        XCTAssertEqual(router.repliedRecordIDs, [nil], "无记录时文本照常作为指令打开语音页")
    }

    func testReplyIgnoresWhitespaceOnlyText() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .reply(text: "   "),
            recordID: UUID(),
            router: router
        )
        XCTAssertTrue(router.repliedTexts.isEmpty, "空白输入忽略")
        XCTAssertTrue(router.repliedRecordIDs.isEmpty)
    }

    func testRetryRoutesMessageAndBrain() async {
        let router = MockRouter()
        let id = UUID()
        await AgentAskResultNotificationActionHandler.handle(
            action: .retry,
            recordID: id,
            message: "  查一下天气  ",
            brain: .openclaw,
            router: router
        )
        XCTAssertEqual(router.retriedAsks.count, 1)
        XCTAssertEqual(router.retriedAsks[0].message, "  查一下天气  ", "原文原样透传（协调器侧去空白）")
        XCTAssertEqual(router.retriedAsks[0].brain, .openclaw, "重试沿用通知携带的大脑")
        XCTAssertTrue(router.openedDetailIDs.isEmpty)
        XCTAssertTrue(router.followUpIDs.isEmpty)
    }

    func testRetryWithoutBrainDefaultsToAuto() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .retry,
            recordID: nil,
            message: "查一下天气",
            brain: nil,
            router: router
        )
        XCTAssertEqual(router.retriedAsks.map(\.brain), [.auto], "旧通知无大脑载荷时回退 Auto")
    }

    func testRetryWithoutMessageIsIgnored() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .retry,
            recordID: UUID(),
            message: nil,
            router: router
        )
        XCTAssertTrue(router.retriedAsks.isEmpty, "旧通知无原文载荷时不重试（防御）")
    }

    func testNoneIsNoOp() async {
        let router = MockRouter()
        await AgentAskResultNotificationActionHandler.handle(
            action: .none,
            recordID: UUID(),
            router: router
        )
        XCTAssertTrue(router.openedDetailIDs.isEmpty)
        XCTAssertTrue(router.followUpIDs.isEmpty)
        XCTAssertTrue(router.repliedTexts.isEmpty)
        XCTAssertTrue(router.repliedRecordIDs.isEmpty)
        XCTAssertTrue(router.retriedAsks.isEmpty)
    }
}

// MARK: - 结果通知「重试」协调器（send / storage / notifier 注入）

@MainActor
final class AgentAskRetryCoordinatorTests: XCTestCase {

    private var suite: UserDefaults!
    private var storage: ConversationStorage!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.ask.retry.v1")
        suite.removePersistentDomain(forName: "test.ask.retry.v1")
        storage = ConversationStorage(userDefaults: suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.ask.retry.v1")
        super.tearDown()
    }

    private final class MockNotifier: AgentAskResultNotifying {
        var sent: [(outcome: AgentAskIntentOutcome, message: String?, brain: AgentBrain?)] = []
        func send(
            title: String,
            body: String,
            recordID: UUID?,
            message: String?,
            brain: AgentBrain?
        ) async {
            sent.append((.replied(text: body), message, brain))
        }
    }

    private func captureSend(
        _ capture: @escaping (String, AgentBrain) -> Void
    ) -> @MainActor (String, AgentBrain, @escaping (String) -> Void, @escaping (String) -> Void) -> Void {
        { text, brain, onFinal, onError in
            capture(text, brain)
            _ = onFinal
            _ = onError
        }
    }

    func testRetryRepliesAndArchives() async {
        var receivedBrain: AgentBrain?
        let outcome = await AgentAskRetryCoordinator.retry(
            message: "  查一下天气  ",
            brain: .auto,
            timeout: 1,
            storage: storage,
            notifier: MockNotifier(),
            send: { text, brain, onFinal, _ in
                receivedBrain = brain
                onFinal("明天多云。")
            }
        )
        XCTAssertEqual(outcome, .replied(text: "明天多云。"))
        let records = storage.loadAllConversations()
        XCTAssertEqual(records.count, 1, "成功回复归档到 Hub 时间线")
        XCTAssertEqual(records[0].aiModel, AgentAskArchiver.aiModel)
        XCTAssertEqual(records[0].messages.first?.content, "查一下天气", "原文去空白后归档")
    }

    func testRetryUsesOriginalBrain() async {
        var receivedBrain: AgentBrain?
        _ = await AgentAskRetryCoordinator.retry(
            message: "查一下天气",
            brain: .hermes,
            timeout: 1,
            storage: storage,
            notifier: MockNotifier(),
            send: { _, brain, onFinal, _ in
                receivedBrain = brain
                onFinal("ok")
            }
        )
        XCTAssertEqual(receivedBrain, .hermes, "重试沿用通知携带的大脑")
    }

    func testRetryFailedOutcomeDoesNotArchive() async {
        let outcome = await AgentAskRetryCoordinator.retry(
            message: "查一下天气",
            brain: .hermes,
            timeout: 1,
            storage: storage,
            notifier: MockNotifier(),
            send: { _, _, _, onError in
                onError("hermes.error.notconnected".localized)
            }
        )
        guard case .failed(let text, _) = outcome else {
            return XCTFail("期望 failed 结果")
        }
        XCTAssertEqual(text, "查一下天气")
        XCTAssertTrue(storage.loadAllConversations().isEmpty, "失败不归档")
    }

    func testRetryEmptyMessageIsRejected() async {
        var sendCalled = false
        let outcome = await AgentAskRetryCoordinator.retry(
            message: "   ",
            brain: .auto,
            timeout: 1,
            storage: storage,
            notifier: MockNotifier(),
            send: captureSend { _, _ in sendCalled = true }
        )
        XCTAssertEqual(outcome, .empty(text: "   "))
        XCTAssertFalse(sendCalled)
        XCTAssertTrue(storage.loadAllConversations().isEmpty)
    }

    func testRetryNotifiesWithMessageAndBrain() async {
        let notifier = MockNotifier()
        _ = await AgentAskRetryCoordinator.retry(
            message: "查一下天气",
            brain: .openclaw,
            timeout: 1,
            appActive: false,
            storage: storage,
            notifier: notifier,
            send: { _, _, onFinal, _ in onFinal("ok") }
        )
        XCTAssertEqual(notifier.sent.count, 1)
        XCTAssertEqual(notifier.sent.first?.message, "查一下天气")
        XCTAssertEqual(notifier.sent.first?.brain, .openclaw)
    }

    func testRetrySkipsNotificationWhenAppActive() async {
        let notifier = MockNotifier()
        _ = await AgentAskRetryCoordinator.retry(
            message: "查一下天气",
            brain: .hermes,
            timeout: 1,
            appActive: true,
            storage: storage,
            notifier: notifier,
            send: { _, _, onFinal, _ in onFinal("ok") }
        )
        XCTAssertTrue(notifier.sent.isEmpty, "App 前台时结果经镜片卡反馈，不重复投递通知")
        XCTAssertEqual(storage.loadAllConversations().count, 1, "前台重试成功仍归档")
    }
}

// MARK: - 今日安排

@MainActor
final class AgentTodayIntentTests: XCTestCase {
    private var previousLanguage: AppLanguage = .system
    private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        previousLanguage = LanguageManager.shared.currentLanguage
        LanguageManager.shared.currentLanguage = .chinese
    }

    override func tearDown() {
        LanguageManager.shared.currentLanguage = previousLanguage
        super.tearDown()
    }

    private func event(_ title: String, hourOffset: TimeInterval) -> AgentCalendarEvent {
        let start = now.addingTimeInterval(hourOffset * 3600)
        return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
    }

    private func task(id: String, title: String, status: QwenAgentTask.Status) -> QwenAgentTask {
        QwenAgentTask(
            taskId: id,
            title: title,
            status: status,
            resultText: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
    }

    func testFullOverviewText() {
        let outcome = AgentTodayIntentBuilder.outcome(
            events: [event("产品评审", hourOffset: 2)],
            reminders: [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))],
            taskTitles: ["上传视频", "  "],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(outcome.text.contains("产品评审"))
        XCTAssertTrue(outcome.text.contains("喝水"))
        XCTAssertTrue(outcome.text.contains("进行中任务 1 项"))
    }

    func testEmptyOverviewFallsBack() {
        let outcome = AgentTodayIntentBuilder.outcome(
            events: [],
            reminders: [],
            taskTitles: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(outcome.text, "一切就绪，暂无安排。")
    }

    func testActiveTaskTitlesOnlyRunningAndWaiting() {
        let titles = AgentTodayIntentBuilder.activeTaskTitles(from: [
            task(id: "t1", title: "上传视频", status: .running),
            task(id: "t2", title: "整理报告", status: .waiting),
            task(id: "t3", title: "已完成任务", status: .completed),
            task(id: "t4", title: "失败任务", status: .failed),
            task(id: "t5", title: "取消任务", status: .cancelled)
        ])
        XCTAssertEqual(titles, ["上传视频", "整理报告"])
    }

    func testBlankTaskTitlesDoNotBreakOverview() {
        let outcome = AgentTodayIntentBuilder.outcome(
            events: [],
            reminders: [],
            taskTitles: ["  ", ""],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(outcome.text, "一切就绪，暂无安排。")
    }
}


// MARK: - 明日安排

@MainActor
final class AgentTomorrowIntentTests: XCTestCase {
    private var previousLanguage: AppLanguage = .system
    private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        previousLanguage = LanguageManager.shared.currentLanguage
        LanguageManager.shared.currentLanguage = .chinese
    }

    override func tearDown() {
        LanguageManager.shared.currentLanguage = previousLanguage
        super.tearDown()
    }

    private func tomorrowEvent(_ title: String, hourOffset: TimeInterval) -> AgentCalendarEvent {
        let start = now.addingTimeInterval(24 * 3600 + hourOffset * 3600)
        return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
    }

    func testOverviewIncludesNextEventAndCount() {
        let outcome = AgentTomorrowIntentBuilder.outcome(
            events: [
                tomorrowEvent("产品评审", hourOffset: 2),
                tomorrowEvent("出游", hourOffset: 5)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(outcome.text.contains("明天"))
        XCTAssertTrue(outcome.text.contains("产品评审"))
        XCTAssertTrue(outcome.text.contains("明天共 2 场日程"))
    }

    func testSingleEventOmitsCount() {
        let outcome = AgentTomorrowIntentBuilder.outcome(
            events: [tomorrowEvent("产品评审", hourOffset: 2)],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(outcome.text.contains("产品评审"))
        XCTAssertFalse(outcome.text.contains("场日程"))
    }

    func testEmptyFallsBack() {
        let outcome = AgentTomorrowIntentBuilder.outcome(
            events: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(outcome.text, "明天暂无安排。")
    }
}
