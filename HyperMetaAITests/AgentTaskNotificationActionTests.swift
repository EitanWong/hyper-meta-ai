/*
 * Agent Task Notification Action Tests
 * 任务通知交互 Action：分类动作注册、动作解析（查看 / 稍后提醒 / 未知）、
 * 稍后提醒重发构造、执行闭环（Mock 路由与 Mock 通知调度）。
 */

import XCTest
import UserNotifications
@testable import HyperMetaAI

// MARK: - 动作解析

final class AgentTaskNotificationActionParserTests: XCTestCase {
    func testViewIdentifierParsesToView() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.viewIdentifier
            ),
            .view
        )
    }

    func testSnoozeIdentifierParsesToSnooze() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.snoozeIdentifier
            ),
            .snooze(after: AgentTaskNotificationCategory.snoozeInterval)
        )
    }

    func testFollowUpIdentifierParsesToFollowUp() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.followUpIdentifier
            ),
            .followUp
        )
    }

    func testRetryIdentifierParsesToRetry() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.retryIdentifier
            ),
            .retry
        )
    }

    func testReplyIdentifierParsesWithText() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.replyIdentifier,
                text: "帮我把牛奶加到购物单"
            ),
            .reply(text: "帮我把牛奶加到购物单")
        )
    }

    func testReplyIdentifierWithoutTextParsesEmpty() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.replyIdentifier
            ),
            .reply(text: ""),
            "旧调用不传文本时 reply 带空文本（Handler 侧忽略空输入）"
        )
    }

    func testReplyDoesNotAffectOtherActions() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: AgentTaskNotificationCategory.retryIdentifier,
                text: "任意文本"
            ),
            .retry,
            "文本输入只对 reply 标识生效"
        )
    }

    func testDefaultTapParsesToView() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ),
            .view
        )
    }

    func testUnknownIdentifierParsesToNone() {
        XCTAssertEqual(
            AgentTaskNotificationActionParser.parse(actionIdentifier: "UNKNOWN_ACTION"),
            .none
        )
    }
}

// MARK: - 稍后提醒重发构造

final class AgentTaskSnoozeBuilderTests: XCTestCase {
    private func makeRequest(
        identifier: String = "agent.task.notify.abc",
        title: String = "任务完成",
        body: String = "任务「整理报告」已完成。",
        userInfo: [AnyHashable: Any] = ["taskId": "t1"]
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.categoryIdentifier = AgentTaskNotificationCategory.identifier
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    func testBuildsSnoozePayloadReusingContent() {
        let now = Date(timeIntervalSince1970: 5_000)
        let payload = AgentTaskSnoozeBuilder.payload(
            from: makeRequest(),
            after: 600,
            now: now
        )
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.title, "任务完成")
        XCTAssertEqual(payload?.body, "任务「整理报告」已完成。")
        XCTAssertEqual(
            payload?.userInfo?["taskId"] as? String,
            "t1"
        )
        XCTAssertEqual(payload?.triggerDate, now.addingTimeInterval(600))
        XCTAssertEqual(payload?.categoryIdentifier, AgentTaskNotificationCategory.identifier)
        XCTAssertTrue(payload?.identifier.hasPrefix("agent.task.notify.abc.snoozed.") ?? false)
    }

    func testSnoozePayloadKeepsFailedCategory() {
        let content = UNMutableNotificationContent()
        content.title = "任务失败"
        content.categoryIdentifier = AgentTaskNotificationCategory.failedIdentifier
        let request = UNNotificationRequest(
            identifier: "agent.task.notify.f1",
            content: content,
            trigger: nil
        )
        let payload = AgentTaskSnoozeBuilder.payload(from: request, after: 600)
        XCTAssertEqual(payload?.categoryIdentifier, AgentTaskNotificationCategory.failedIdentifier)
    }

    func testZeroOrNegativeIntervalReturnsNil() {
        let request = makeRequest()
        XCTAssertNil(
            AgentTaskSnoozeBuilder.payload(from: request, after: 0)
        )
        XCTAssertNil(
            AgentTaskSnoozeBuilder.payload(from: request, after: -5)
        )
    }
}

// MARK: - 分类注册参数

final class AgentTaskNotificationCategoryTests: XCTestCase {
    func testDoneActionsWithExpectedIdentifiers() {
        let actions = AgentTaskNotificationCategory.doneActions
        XCTAssertEqual(actions.count, 4)
        XCTAssertEqual(actions[0].identifier, AgentTaskNotificationCategory.viewIdentifier)
        XCTAssertEqual(actions[1].identifier, AgentTaskNotificationCategory.followUpIdentifier)
        XCTAssertEqual(actions[2].identifier, AgentTaskNotificationCategory.snoozeIdentifier)
        XCTAssertEqual(actions[3].identifier, AgentTaskNotificationCategory.replyIdentifier)
        XCTAssertTrue(actions[1].options.contains(.foreground), "追问需带 .foreground 打开 App")
    }

    func testDoneAndFailedActionsIncludeReply() {
        let doneIDs = AgentTaskNotificationCategory.doneActions.map(\.identifier)
        let failedIDs = AgentTaskNotificationCategory.failedActions.map(\.identifier)
        XCTAssertTrue(doneIDs.contains(AgentTaskNotificationCategory.replyIdentifier))
        XCTAssertTrue(failedIDs.contains(AgentTaskNotificationCategory.replyIdentifier))
        let reply = AgentTaskNotificationCategory.replyAction
        XCTAssertEqual(reply.identifier, AgentTaskNotificationCategory.replyIdentifier)
        XCTAssertTrue(reply.options.contains(.foreground), "回复需打开 App 呈现语音页")
    }

    func testFailedActionsIncludeRetry() {
        let actions = AgentTaskNotificationCategory.failedActions
        XCTAssertEqual(actions.count, 4)
        XCTAssertEqual(actions[0].identifier, AgentTaskNotificationCategory.viewIdentifier)
        XCTAssertEqual(actions[1].identifier, AgentTaskNotificationCategory.retryIdentifier)
        XCTAssertEqual(actions[2].identifier, AgentTaskNotificationCategory.snoozeIdentifier)
        XCTAssertEqual(actions[3].identifier, AgentTaskNotificationCategory.replyIdentifier)
        XCTAssertTrue(actions[1].options.contains(.foreground), "重试需带 .foreground 打开 App")
    }

    func testCategorySelectionByStatus() {
        XCTAssertEqual(
            AgentTaskNotificationCategory.categoryIdentifier(
                for: QwenAgentTask.Status.failed.notificationRaw
            ),
            AgentTaskNotificationCategory.failedIdentifier
        )
        XCTAssertEqual(
            AgentTaskNotificationCategory.categoryIdentifier(
                for: QwenAgentTask.Status.completed.notificationRaw
            ),
            AgentTaskNotificationCategory.doneIdentifier
        )
        let failedActions = AgentTaskNotificationCategory.actions(
            for: QwenAgentTask.Status.failed.notificationRaw
        )
        XCTAssertEqual(failedActions.count, 4)
        XCTAssertTrue(failedActions.contains { $0.identifier == AgentTaskNotificationCategory.retryIdentifier })
        XCTAssertTrue(failedActions.contains { $0.identifier == AgentTaskNotificationCategory.replyIdentifier })
        XCTAssertFalse(
            AgentTaskNotificationCategory.actions(for: QwenAgentTask.Status.completed.notificationRaw)
                .contains { $0.identifier == AgentTaskNotificationCategory.retryIdentifier }
        )
    }

    func testIsTaskCategoryCoversAllIdentifiers() {
        XCTAssertTrue(AgentTaskNotificationCategory.isTaskCategory(AgentTaskNotificationCategory.doneIdentifier))
        XCTAssertTrue(AgentTaskNotificationCategory.isTaskCategory(AgentTaskNotificationCategory.failedIdentifier))
        XCTAssertTrue(AgentTaskNotificationCategory.isTaskCategory(AgentTaskNotificationCategory.identifier))
        XCTAssertFalse(AgentTaskNotificationCategory.isTaskCategory("agent.reminder.category"))
    }

    func testSnoozeIntervalIsTenMinutes() {
        XCTAssertEqual(AgentTaskNotificationCategory.snoozeInterval, 600)
    }
}

// MARK: - 执行闭环

final class AgentTaskNotificationActionHandlerTests: XCTestCase {
    private final class MockRouter: AgentTaskNotificationActionRouting {
        var openedAgentHub = false
        var openedFollowUp = false
        var retriedTaskID: String?
        var retriedSourceText: String?
        var repliedText: String?
        func openAgentHub() {
            openedAgentHub = true
        }
        func openFollowUp() {
            openedFollowUp = true
        }
        func retryTask(taskId: String?, sourceText: String?) {
            retriedTaskID = taskId
            retriedSourceText = sourceText
        }
        func replyToJARVIS(text: String) {
            repliedText = text
        }
    }

    private final class MockScheduler: AgentTaskNotificationScheduling {
        var added: [UNNotificationRequest] = []
        func add(_ request: UNNotificationRequest) async {
            added.append(request)
        }
    }

    private func makeRequest(
        identifier: String = "agent.task.notify.abc",
        title: String = "任务完成",
        body: String = "任务「整理报告」已完成。",
        categoryIdentifier: String = AgentTaskNotificationCategory.identifier,
        userInfo: [AnyHashable: Any]? = nil
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        if let userInfo {
            content.userInfo = userInfo
        }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    func testViewActionOpensAgentHubAndDoesNotSchedule() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        await AgentTaskNotificationActionHandler.handle(
            action: .view,
            request: makeRequest(),
            router: router,
            scheduler: scheduler
        )
        XCTAssertTrue(router.openedAgentHub)
        XCTAssertTrue(scheduler.added.isEmpty)
    }

    func testFollowUpActionOpensFollowUpAndDoesNotSchedule() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        await AgentTaskNotificationActionHandler.handle(
            action: .followUp,
            request: makeRequest(),
            router: router,
            scheduler: scheduler
        )
        XCTAssertTrue(router.openedFollowUp)
        XCTAssertFalse(router.openedAgentHub)
        XCTAssertTrue(scheduler.added.isEmpty)
    }

    func testRetryActionRoutesTaskContext() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        let userInfo = AgentTaskNotificationUserInfo.make(
            task: PersistedAgentTask(
                taskId: "t9",
                title: "上传视频",
                status: QwenAgentTask.Status.failed.notificationRaw,
                updatedAt: Date(),
                sourceText: "帮我上传视频"
            )
        )
        await AgentTaskNotificationActionHandler.handle(
            action: .retry,
            request: makeRequest(userInfo: userInfo),
            router: router,
            scheduler: scheduler
        )
        XCTAssertEqual(router.retriedTaskID, "t9")
        XCTAssertEqual(router.retriedSourceText, "帮我上传视频")
        XCTAssertTrue(scheduler.added.isEmpty)
    }

    func testReplyActionRoutesTextToJARVIS() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        await AgentTaskNotificationActionHandler.handle(
            action: .reply(text: "把会议改到下午三点"),
            request: makeRequest(),
            router: router,
            scheduler: scheduler
        )
        XCTAssertEqual(router.repliedText, "把会议改到下午三点")
        XCTAssertTrue(scheduler.added.isEmpty)
    }

    func testReplyActionIgnoresWhitespaceOnlyText() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        await AgentTaskNotificationActionHandler.handle(
            action: .reply(text: "   "),
            request: makeRequest(),
            router: router,
            scheduler: scheduler
        )
        XCTAssertNil(router.repliedText, "空白输入忽略")
    }

    func testSnoozeActionSchedulesResend() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        let now = Date(timeIntervalSince1970: 5_000)
        await AgentTaskNotificationActionHandler.handle(
            action: .snooze(after: 600),
            request: makeRequest(),
            router: router,
            scheduler: scheduler,
            now: now
        )
        XCTAssertFalse(router.openedAgentHub)
        XCTAssertEqual(scheduler.added.count, 1)
        let resent = scheduler.added[0]
        XCTAssertEqual(resent.content.title, "任务完成")
        XCTAssertEqual(resent.content.body, "任务「整理报告」已完成。")
        XCTAssertEqual(resent.content.categoryIdentifier, AgentTaskNotificationCategory.identifier)
        XCTAssertTrue(resent.identifier.hasPrefix("agent.task.notify.abc.snoozed."))
        if let trigger = resent.trigger as? UNTimeIntervalNotificationTrigger {
            XCTAssertEqual(trigger.timeInterval, 600, accuracy: 0.001)
        } else {
            XCTFail("重发通知应带时间触发器")
        }
    }

    func testSnoozeWithInvalidIntervalDoesNothing() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        await AgentTaskNotificationActionHandler.handle(
            action: .snooze(after: 0),
            request: makeRequest(),
            router: router,
            scheduler: scheduler
        )
        XCTAssertFalse(router.openedAgentHub)
        XCTAssertTrue(scheduler.added.isEmpty)
    }

    func testNoneActionDoesNothing() async {
        let router = MockRouter()
        let scheduler = MockScheduler()
        await AgentTaskNotificationActionHandler.handle(
            action: .none,
            request: makeRequest(),
            router: router,
            scheduler: scheduler
        )
        XCTAssertFalse(router.openedAgentHub)
        XCTAssertTrue(scheduler.added.isEmpty)
    }
}

// MARK: - 通知载荷（任务上下文）

final class AgentTaskNotificationUserInfoTests: XCTestCase {
    private func storedTask(
        taskId: String = "t1",
        status: String = QwenAgentTask.Status.failed.notificationRaw,
        sourceText: String? = nil
    ) -> PersistedAgentTask {
        PersistedAgentTask(
            taskId: taskId,
            title: "上传视频",
            status: status,
            updatedAt: Date(timeIntervalSince1970: 5_000),
            resultText: nil,
            sourceText: sourceText
        )
    }

    func testMakeCarriesTaskIDAndSourceText() {
        let info = AgentTaskNotificationUserInfo.make(
            task: storedTask(sourceText: "帮我上传视频")
        )
        XCTAssertEqual(info[AgentTaskNotificationUserInfo.taskIdKey], "t1")
        XCTAssertEqual(info[AgentTaskNotificationUserInfo.sourceTextKey], "帮我上传视频")
    }

    func testMakeOmitsEmptySourceText() {
        let info = AgentTaskNotificationUserInfo.make(task: storedTask(sourceText: "  "))
        XCTAssertEqual(info[AgentTaskNotificationUserInfo.taskIdKey], "t1")
        XCTAssertNil(info[AgentTaskNotificationUserInfo.sourceTextKey])
    }

    func testExtractRoundTrip() {
        let info = AgentTaskNotificationUserInfo.make(
            task: storedTask(taskId: "t7", sourceText: "重新整理")
        )
        XCTAssertEqual(AgentTaskNotificationUserInfo.taskId(from: info), "t7")
        XCTAssertEqual(AgentTaskNotificationUserInfo.sourceText(from: info), "重新整理")
        XCTAssertNil(AgentTaskNotificationUserInfo.taskId(from: nil))
        XCTAssertNil(AgentTaskNotificationUserInfo.sourceText(from: nil))
    }
}

// MARK: - 重试规划（通知「重试」决策）

final class AgentTaskRetryPlannerTests: XCTestCase {
    private func failedTask(taskId: String, title: String = "上传视频", updatedAt: Double = 5_000) -> PersistedAgentTask {
        PersistedAgentTask(
            taskId: taskId,
            title: title,
            status: QwenAgentTask.Status.failed.notificationRaw,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            sourceText: "帮我上传视频"
        )
    }

    func testSessionHoldsTaskRetriesInSession() {
        XCTAssertEqual(
            AgentTaskRetryPlanner.plan(
                taskId: "a",
                sourceText: nil,
                sessionFailedTaskIDs: ["a", "b"],
                storedTasks: []
            ),
            .retryInSession(taskId: "a")
        )
    }

    func testNoTaskIDFallsBackToLatestSessionTask() {
        XCTAssertEqual(
            AgentTaskRetryPlanner.plan(
                taskId: nil,
                sourceText: nil,
                sessionFailedTaskIDs: ["a", "b"],
                storedTasks: []
            ),
            .retryInSession(taskId: nil)
        )
    }

    func testSessionMissingTaskOpensVoiceWithStoredSourceText() {
        let stored = [failedTask(taskId: "a", updatedAt: 5_000)]
        XCTAssertEqual(
            AgentTaskRetryPlanner.plan(
                taskId: "a",
                sourceText: nil,
                sessionFailedTaskIDs: [],
                storedTasks: stored
            ),
            .openVoiceSession(instruction: "帮我上传视频")
        )
    }

    func testNotificationSourceTextWinsOverStored() {
        let stored = [failedTask(taskId: "a", updatedAt: 5_000)]
        XCTAssertEqual(
            AgentTaskRetryPlanner.plan(
                taskId: "a",
                sourceText: "通知携带的原始口述",
                sessionFailedTaskIDs: [],
                storedTasks: stored
            ),
            .openVoiceSession(instruction: "通知携带的原始口述")
        )
    }

    func testMissingSourceFallsBackToNaturalLanguageInstruction() {
        let stored = [
            PersistedAgentTask(
                taskId: "a",
                title: "订餐厅",
                status: QwenAgentTask.Status.failed.notificationRaw,
                updatedAt: Date(timeIntervalSince1970: 5_000)
            )
        ]
        let plan = AgentTaskRetryPlanner.plan(
            taskId: "a",
            sourceText: nil,
            sessionFailedTaskIDs: [],
            storedTasks: stored
        )
        guard case .openVoiceSession(let instruction) = plan else {
            return XCTFail("应带指令打开语音页：\(plan)")
        }
        XCTAssertEqual(instruction, "agent.task.command.retry.instruction".localized("订餐厅"))
    }

    func testStoredTaskByIDFallsBackToLatestFailed() {
        let stored = [
            failedTask(taskId: "a", updatedAt: 5_000),
            failedTask(taskId: "b", title: "整理报告", updatedAt: 6_000)
        ]
        XCTAssertEqual(
            AgentTaskRetryPlanner.plan(
                taskId: "missing",
                sourceText: nil,
                sessionFailedTaskIDs: [],
                storedTasks: stored
            ),
            .openVoiceSession(instruction: "帮我上传视频")
        )
        XCTAssertEqual(
            AgentTaskRetryPlanner.storedTask(taskId: "missing", storedTasks: stored)?.taskId,
            "b",
            "按 ID 找不到时取最近失败任务"
        )
    }

    func testNoSessionAndNoStoredTaskReturnsNone() {
        XCTAssertEqual(
            AgentTaskRetryPlanner.plan(
                taskId: "a",
                sourceText: nil,
                sessionFailedTaskIDs: [],
                storedTasks: []
            ),
            .none
        )
    }
}

// MARK: - Live Activity「重试」按钮通道

/// Live Activity 结果卡「重试」按钮：App Group 标记消费 + 协调器前台消费
@MainActor
final class AgentTaskRetryTapTests: XCTestCase {
    private let suiteName = "test.task.retry.tap.v1"
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTapStoreConsumeRoundTrip() {
        XCTAssertFalse(AgentTaskRetryTapStore.consume(defaults: suite), "未标记不消费")
        suite.set(true, forKey: AgentTaskRetryTapStore.requestKey)
        XCTAssertTrue(AgentTaskRetryTapStore.consume(defaults: suite), "有标记消费成功")
        XCTAssertFalse(AgentTaskRetryTapStore.consume(defaults: suite), "一次性：消费后标记已清除")
    }

    func testConsumeIfNeededAppliesAndClearsMarker() {
        var applied = false
        suite.set(true, forKey: AgentTaskRetryTapStore.requestKey)
        let handled = AgentTaskRetryCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { applied = true; return true }
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(applied, "标记存在时执行重试闭包")
        XCTAssertFalse(AgentTaskRetryTapStore.consume(defaults: suite), "标记已清除")
    }

    func testConsumeIfNeededWithoutMarkerIsNoOp() {
        var applied = false
        let handled = AgentTaskRetryCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { applied = true; return true }
        )
        XCTAssertFalse(handled)
        XCTAssertFalse(applied, "无标记不执行")
    }
}
