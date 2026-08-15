import XCTest
@testable import HyperMetaAI

/// 提醒倒计时选择策略（纯逻辑）
final class AgentReminderCountdownPolicyTests: XCTestCase {

    private func reminder(
        text: String = "喝水",
        fireDate: Date,
        repeatRule: AgentReminderRepeat = .none
    ) -> AgentReminder {
        AgentReminder(text: text, fireDate: fireDate, repeatRule: repeatRule)
    }

    func testSelectsNearestUpcomingOneTimeReminder() {
        let now = Date()
        let far = reminder(text: "开会", fireDate: now.addingTimeInterval(3600))
        let near = reminder(text: "喝水", fireDate: now.addingTimeInterval(600))
        let selected = AgentReminderCountdownPolicy.nextReminder(
            in: [far, near],
            now: now,
            maxAhead: 6 * 3600
        )
        XCTAssertEqual(selected?.id, near.id)
    }

    func testIgnoresRepeatingReminders() {
        let now = Date()
        let daily = reminder(
            text: "吃药",
            fireDate: now.addingTimeInterval(600),
            repeatRule: .daily
        )
        XCTAssertNil(AgentReminderCountdownPolicy.nextReminder(
            in: [daily],
            now: now,
            maxAhead: 6 * 3600
        ))
    }

    func testIgnoresPastAndNowReminders() {
        let now = Date()
        let past = reminder(text: "过期", fireDate: now.addingTimeInterval(-60))
        let atNow = reminder(text: "现在", fireDate: now)
        XCTAssertNil(AgentReminderCountdownPolicy.nextReminder(
            in: [past, atNow],
            now: now,
            maxAhead: 6 * 3600
        ))
    }

    func testIgnoresBeyondHorizonAndHonorsBoundary() {
        let now = Date()
        let beyond = reminder(text: "太远", fireDate: now.addingTimeInterval(7 * 3600))
        XCTAssertNil(AgentReminderCountdownPolicy.nextReminder(
            in: [beyond],
            now: now,
            maxAhead: 6 * 3600
        ))
        let boundary = reminder(text: "边界", fireDate: now.addingTimeInterval(6 * 3600))
        XCTAssertEqual(
            AgentReminderCountdownPolicy.nextReminder(
                in: [boundary],
                now: now,
                maxAhead: 6 * 3600
            )?.id,
            boundary.id
        )
    }

    func testNilWhenEmpty() {
        XCTAssertNil(AgentReminderCountdownPolicy.nextReminder(
            in: [],
            now: Date(),
            maxAhead: 6 * 3600
        ))
    }
}

/// Live Activity 管理器优先级（审批 > 提醒倒计时 > 任务进度）与回落
@MainActor
final class AgentLiveActivityManagerPriorityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentLiveActivityManager.resetStateForTesting()
    }

    override func tearDown() {
        AgentLiveActivityManager.resetStateForTesting()
        super.tearDown()
    }

    func testReminderCountdownShowsAndFallsBackToTask() {
        AgentLiveActivityManager.updateTaskProgress(count: 2, step: "正在整理")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)

        let fireDate = Date(timeIntervalSinceNow: 600)
        AgentLiveActivityManager.updateReminderCountdown(text: "喝水", fireDate: fireDate)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)

        // 提醒清除（到点 / 取消）：回落任务进度
        AgentLiveActivityManager.updateReminderCountdown(text: nil, fireDate: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)
    }

    func testApprovalOverridesReminderAndResolvesBack() {
        let fireDate = Date(timeIntervalSinceNow: 600)
        AgentLiveActivityManager.updateReminderCountdown(text: "喝水", fireDate: fireDate)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)

        AgentLiveActivityManager.showApproval(text: "允许拍照吗", expiresAt: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .approval)

        AgentLiveActivityManager.resolveApproval(runningTaskCount: 0, step: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)
    }

    func testAllClearedEnds() {
        AgentLiveActivityManager.updateReminderCountdown(text: "喝水", fireDate: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)
        AgentLiveActivityManager.updateReminderCountdown(text: nil, fireDate: nil)
        AgentLiveActivityManager.updateTaskProgress(count: 0, step: nil)
        XCTAssertNil(AgentLiveActivityManager.currentMode)
    }

    func testPastReminderNeverShows() {
        AgentLiveActivityManager.updateReminderCountdown(
            text: "过期",
            fireDate: Date(timeIntervalSinceNow: -10)
        )
        XCTAssertNil(AgentLiveActivityManager.currentMode)
    }

    func testVoiceOverridesTaskAndFallsBack() {
        AgentLiveActivityManager.updateTaskProgress(count: 2, step: "正在整理")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)

        AgentLiveActivityManager.updateVoiceStatus(text: "正在聆听…")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .voiceSession)

        // 会话结束：回落任务进度
        AgentLiveActivityManager.updateVoiceStatus(text: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)
    }

    func testVoiceOverridesCountdown() {
        AgentLiveActivityManager.updateReminderCountdown(
            text: "喝水",
            fireDate: Date(timeIntervalSinceNow: 600)
        )
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)

        AgentLiveActivityManager.updateVoiceStatus(text: "思考中…")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .voiceSession)

        AgentLiveActivityManager.updateVoiceStatus(text: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)
    }

    func testApprovalOverridesVoiceAndResolvesBack() {
        AgentLiveActivityManager.updateVoiceStatus(text: "正在聆听…")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .voiceSession)

        AgentLiveActivityManager.showApproval(text: "允许拍照吗", expiresAt: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .approval)

        AgentLiveActivityManager.resolveApproval(runningTaskCount: 0, step: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .voiceSession)
    }

    func testVoiceClearedEndsWhenNothingElse() {
        AgentLiveActivityManager.updateVoiceStatus(text: "正在回复…")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .voiceSession)
        AgentLiveActivityManager.updateVoiceStatus(text: nil)
        XCTAssertNil(AgentLiveActivityManager.currentMode)
    }
}

/// 协调器：提醒列表 → 倒计时 Live Activity 的同步（幂等）
@MainActor
final class AgentReminderCountdownCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentLiveActivityManager.resetStateForTesting()
    }

    override func tearDown() {
        AgentLiveActivityManager.resetStateForTesting()
        super.tearDown()
    }

    func testSyncShowsNearestReminder() {
        let now = Date()
        let reminders = [
            AgentReminder(text: "开会", fireDate: now.addingTimeInterval(3600)),
            AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600)),
        ]
        AgentReminderCountdownCoordinator.sync(reminders: reminders, now: now)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)
    }

    func testSyncWithNoEligibleReminderEndsCountdown() {
        let now = Date()
        AgentReminderCountdownCoordinator.sync(reminders: [], now: now)
        XCTAssertNil(AgentLiveActivityManager.currentMode)

        let past = AgentReminder(text: "过期", fireDate: now.addingTimeInterval(-60))
        AgentReminderCountdownCoordinator.sync(reminders: [past], now: now)
        XCTAssertNil(AgentLiveActivityManager.currentMode)
    }

    func testSyncKeepsTaskProgressWhenNoReminder() {
        AgentLiveActivityManager.updateTaskProgress(count: 1, step: "进行中")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)
        AgentReminderCountdownCoordinator.sync(reminders: [], now: Date())
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)
    }
}

/// 锁屏提醒按钮请求存储（App Group 标记通道，可注入 defaults）
final class AgentReminderTapStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.reminder.tap.v1")
        suite.removePersistentDomain(forName: "test.reminder.tap.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.reminder.tap.v1")
        super.tearDown()
    }

    func testConsumeNilWhenEmpty() {
        XCTAssertNil(AgentReminderTapStore.consume(defaults: suite))
    }

    func testConsumeRoundTripOnce() {
        suite.set("snooze", forKey: AgentReminderTapStore.requestKey)
        XCTAssertEqual(AgentReminderTapStore.consume(defaults: suite), "snooze")
        XCTAssertNil(AgentReminderTapStore.consume(defaults: suite))
    }
}

/// 锁屏按钮请求 → 提醒操作结果（纯逻辑）
final class AgentReminderTapHandlerTests: XCTestCase {

    private func reminder(text: String, fireDate: Date) -> AgentReminder {
        AgentReminder(text: text, fireDate: fireDate)
    }

    func testSnoozePushesNearestReminderByTenMinutes() {
        let now = Date()
        let reminders = [
            reminder(text: "开会", fireDate: now.addingTimeInterval(3600)),
            reminder(text: "喝水", fireDate: now.addingTimeInterval(600)),
        ]
        let outcome = AgentReminderTapHandler.handle(
            raw: "snooze",
            reminders: reminders,
            now: now
        )
        guard case .snoozed(let updated)? = outcome else {
            return XCTFail("expected snoozed")
        }
        XCTAssertEqual(updated.text, "喝水")
        // 延后语义：在原触发时间基础上 +10 分钟（= now + 20 分钟）
        XCTAssertEqual(
            updated.fireDate.timeIntervalSince(now),
            1200,
            accuracy: 1
        )
    }

    func testCompleteRemovesTarget() {
        let now = Date()
        let target = reminder(text: "喝水", fireDate: now.addingTimeInterval(600))
        let outcome = AgentReminderTapHandler.handle(
            raw: "complete",
            reminders: [target],
            now: now
        )
        guard case .completed(let reminder)? = outcome else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(reminder.id, target.id)
    }

    func testUnknownRawIgnored() {
        let now = Date()
        let reminders = [reminder(text: "喝水", fireDate: now.addingTimeInterval(600))]
        XCTAssertNil(AgentReminderTapHandler.handle(
            raw: "delete",
            reminders: reminders,
            now: now
        ))
    }

    func testNoEligibleReminderIgnored() {
        let now = Date()
        let past = reminder(text: "过期", fireDate: now.addingTimeInterval(-60))
        XCTAssertNil(AgentReminderTapHandler.handle(
            raw: "complete",
            reminders: [past],
            now: now
        ))
        XCTAssertNil(AgentReminderTapHandler.handle(
            raw: "snooze",
            reminders: [],
            now: now
        ))
    }

    func testRepeatingReminderNotAffected() {
        let now = Date()
        let daily = AgentReminder(
            text: "吃药",
            fireDate: now.addingTimeInterval(600),
            repeatRule: .daily
        )
        XCTAssertNil(AgentReminderTapHandler.handle(
            raw: "complete",
            reminders: [daily],
            now: now
        ))
    }
}

/// 协调器：消费标记 → 处理 → 应用（apply 注入验证接线）
@MainActor
final class AgentReminderTapCoordinatorTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.reminder.tap.v1")
        suite.removePersistentDomain(forName: "test.reminder.tap.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.reminder.tap.v1")
        super.tearDown()
    }

    private func write(_ raw: String) {
        suite.set(raw, forKey: AgentReminderTapStore.requestKey)
    }

    func testConsumeAppliesSnoozedOutcome() {
        write("snooze")
        let now = Date()
        let reminders = [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))]
        var applied: AgentReminderNotificationAction.Outcome?
        let handled = AgentReminderTapCoordinator.consumeIfNeeded(
            reminders: reminders,
            defaults: suite,
            apply: { applied = $0 }
        )
        XCTAssertTrue(handled)
        guard case .snoozed(let updated)? = applied else {
            return XCTFail("expected snoozed")
        }
        XCTAssertEqual(updated.text, "喝水")
    }

    func testConsumeAppliesCompletedOutcome() {
        write("complete")
        let now = Date()
        let target = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))
        var applied: AgentReminderNotificationAction.Outcome?
        let handled = AgentReminderTapCoordinator.consumeIfNeeded(
            reminders: [target],
            defaults: suite,
            apply: { applied = $0 }
        )
        XCTAssertTrue(handled)
        guard case .completed(let reminder)? = applied else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(reminder.id, target.id)
    }

    func testNoMarkerNoApply() {
        var applied = false
        let handled = AgentReminderTapCoordinator.consumeIfNeeded(
            reminders: [],
            defaults: suite,
            apply: { _ in applied = true }
        )
        XCTAssertFalse(handled)
        XCTAssertFalse(applied)
    }

    func testUnknownMarkerConsumedButNotApplied() {
        write("bogus")
        var applied = false
        let handled = AgentReminderTapCoordinator.consumeIfNeeded(
            reminders: [AgentReminder(text: "喝水", fireDate: Date().addingTimeInterval(600))],
            defaults: suite,
            apply: { _ in applied = true }
        )
        XCTAssertTrue(handled)
        XCTAssertFalse(applied)
    }
}
