import XCTest
@testable import HyperMetaAI

/// 日程倒计时选择策略（纯逻辑）
final class AgentCalendarCountdownPolicyTests: XCTestCase {

    private func event(
        title: String = "评审",
        start: Date,
        isAllDay: Bool = false
    ) -> AgentCalendarEvent {
        AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: isAllDay)
    }

    func testSelectsNearestUpcomingEvent() {
        let now = Date()
        let far = event(title: "开会", start: now.addingTimeInterval(3600))
        let near = event(title: "评审", start: now.addingTimeInterval(600))
        let selected = AgentCalendarCountdownPolicy.nextEvent(
            in: [far, near],
            now: now,
            maxAhead: 6 * 3600
        )
        XCTAssertEqual(selected?.title, "评审")
    }

    func testIgnoresAllDayEvents() {
        let now = Date()
        let allDay = event(title: "全天旅行", start: now.addingTimeInterval(600), isAllDay: true)
        XCTAssertNil(AgentCalendarCountdownPolicy.nextEvent(
            in: [allDay],
            now: now,
            maxAhead: 6 * 3600
        ))
    }

    func testIgnoresPastAndNowEvents() {
        let now = Date()
        let past = event(title: "已开始", start: now.addingTimeInterval(-60))
        let atNow = event(title: "现在", start: now)
        XCTAssertNil(AgentCalendarCountdownPolicy.nextEvent(
            in: [past, atNow],
            now: now,
            maxAhead: 6 * 3600
        ))
    }

    func testIgnoresBeyondHorizonAndHonorsBoundary() {
        let now = Date()
        let beyond = event(title: "太远", start: now.addingTimeInterval(7 * 3600))
        XCTAssertNil(AgentCalendarCountdownPolicy.nextEvent(
            in: [beyond],
            now: now,
            maxAhead: 6 * 3600
        ))
        let boundary = event(title: "边界", start: now.addingTimeInterval(6 * 3600))
        XCTAssertEqual(
            AgentCalendarCountdownPolicy.nextEvent(
                in: [boundary],
                now: now,
                maxAhead: 6 * 3600
            )?.title,
            "边界"
        )
    }

    func testNilWhenEmpty() {
        XCTAssertNil(AgentCalendarCountdownPolicy.nextEvent(in: [], now: Date()))
    }
}

/// 日程倒计时映射（纯逻辑）
final class AgentCalendarCountdownMapperTests: XCTestCase {

    func testCalendarContentCarriesTitleAndStart() {
        let start = Date(timeIntervalSinceNow: 900)
        let event = AgentCalendarEvent(title: "产品评审", start: start, end: start.addingTimeInterval(1800))
        let content = AgentLiveActivityStateMapper.calendarContent(event: event, now: Date())
        XCTAssertEqual(content?.mode, .calendarCountdown)
        XCTAssertEqual(content?.title, "agent.liveactivity.calendar.title".localized)
        XCTAssertEqual(content?.detail, "产品评审")
        XCTAssertEqual(content?.countdownFireDate, start)
    }

    func testCalendarContentNilWhenEmptyTitleOrStarted() {
        let start = Date(timeIntervalSinceNow: 900)
        XCTAssertNil(AgentLiveActivityStateMapper.calendarContent(
            event: AgentCalendarEvent(title: "  ", start: start, end: start.addingTimeInterval(600)),
            now: Date()
        ))
        let started = Date(timeIntervalSinceNow: -60)
        XCTAssertNil(AgentLiveActivityStateMapper.calendarContent(
            event: AgentCalendarEvent(title: "已开始", start: started, end: started.addingTimeInterval(600)),
            now: Date()
        ))
    }
}

/// 管理器优先级：审批 > 提醒/日程倒计时（更早者）> 任务进度
@MainActor
final class AgentCalendarLiveActivityPriorityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentLiveActivityManager.resetStateForTesting()
    }

    override func tearDown() {
        AgentLiveActivityManager.resetStateForTesting()
        super.tearDown()
    }

    private func event(start: Date) -> AgentCalendarEvent {
        AgentCalendarEvent(title: "评审", start: start, end: start.addingTimeInterval(3600))
    }

    func testCalendarCountdownShowsAndFallsBackToTask() {
        AgentLiveActivityManager.updateTaskProgress(count: 1, step: "进行中")
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)

        AgentLiveActivityManager.updateCalendarCountdown(
            event: event(start: Date(timeIntervalSinceNow: 1200))
        )
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .calendarCountdown)

        AgentLiveActivityManager.updateCalendarCountdown(event: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)
    }

    func testSoonerCountdownWinsBetweenReminderAndCalendar() {
        let now = Date()
        // 日程更早 → 日程优先
        AgentLiveActivityManager.updateReminderCountdown(
            text: "喝水",
            fireDate: now.addingTimeInterval(3600)
        )
        AgentLiveActivityManager.updateCalendarCountdown(
            event: event(start: now.addingTimeInterval(600))
        )
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .calendarCountdown)

        // 提醒更早 → 提醒优先（不加刷新也会在下次更新时生效）
        AgentLiveActivityManager.updateReminderCountdown(
            text: "喝水",
            fireDate: now.addingTimeInterval(300)
        )
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .reminderCountdown)

        // 提醒清除 → 回落日程
        AgentLiveActivityManager.updateReminderCountdown(text: nil, fireDate: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .calendarCountdown)
    }

    func testApprovalOverridesCalendarAndResolvesBack() {
        AgentLiveActivityManager.updateCalendarCountdown(
            event: event(start: Date(timeIntervalSinceNow: 600))
        )
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .calendarCountdown)

        AgentLiveActivityManager.showApproval(text: "允许拍照吗", expiresAt: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .approval)

        AgentLiveActivityManager.resolveApproval(runningTaskCount: 0, step: nil)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .calendarCountdown)
    }
}

/// 协调器：日程列表 → 倒计时 Live Activity 的同步（幂等，events 注入）
@MainActor
final class AgentCalendarCountdownCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentLiveActivityManager.resetStateForTesting()
    }

    override func tearDown() {
        AgentLiveActivityManager.resetStateForTesting()
        super.tearDown()
    }

    func testSyncShowsNearestEvent() async {
        let now = Date()
        let events = [
            AgentCalendarEvent(title: "开会", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200)),
            AgentCalendarEvent(title: "评审", start: now.addingTimeInterval(600), end: now.addingTimeInterval(3600)),
        ]
        await AgentCalendarCountdownCoordinator.sync(events: events, now: now)
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .calendarCountdown)
    }

    func testSyncWithNoEligibleEventEndsCountdown() async {
        let now = Date()
        await AgentCalendarCountdownCoordinator.sync(events: [], now: now)
        XCTAssertNil(AgentLiveActivityManager.currentMode)

        let allDay = AgentCalendarEvent(
            title: "旅行",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(86_400),
            isAllDay: true
        )
        await AgentCalendarCountdownCoordinator.sync(events: [allDay], now: now)
        XCTAssertNil(AgentLiveActivityManager.currentMode)
    }

    func testSyncKeepsTaskProgressWhenNoEvent() async {
        AgentLiveActivityManager.updateTaskProgress(count: 2, step: "处理中")
        await AgentCalendarCountdownCoordinator.sync(events: [], now: Date())
        XCTAssertEqual(AgentLiveActivityManager.currentMode, .taskProgress)
    }
}
