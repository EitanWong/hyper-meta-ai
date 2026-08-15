/*
 * Agent Display Home Tests
 * 镜片主页 HUD：时间/日期格式、未读文案、HomeKit 状态行、
 * 快捷动作列表与视图构造；数据装载（通知权限 + HomeKit 授权）。
 */

import XCTest
import UserNotifications
@testable import HyperMetaAI

// MARK: - 纯映射

final class AgentDisplayHomeMappingTests: XCTestCase {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let posixLocale = Locale(identifier: "en_US_POSIX")

    private func device(
        _ kind: AgentHomeKitDevice.Kind,
        name: String = "灯",
        isOn: Bool? = nil,
        isLocked: Bool? = nil,
        current: Double? = nil,
        target: Double? = nil
    ) -> AgentHomeKitDevice {
        AgentHomeKitDevice(
            id: name,
            name: name,
            roomName: nil,
            kind: kind,
            isOn: isOn,
            brightness: nil,
            currentTemperature: current,
            targetTemperature: target,
            isLocked: isLocked
        )
    }

    func testTimeTextUsesFixedFormat() {
        let date = Date(timeIntervalSince1970: 3661)
        XCTAssertEqual(
            AgentDisplayHomeMapping.timeText(
                date,
                calendar: utcCalendar,
                locale: posixLocale
            ),
            "01:01"
        )
    }

    func testDateTextUsesShortWeekday() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            AgentDisplayHomeMapping.dateText(
                date,
                calendar: utcCalendar,
                locale: posixLocale
            ),
            "1/1 Thu"
        )
    }

    func testUnreadTextNone() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.unreadText(count: 0),
            "agent.display.home.unread.none".localized
        )
    }

    func testUnreadTextCount() {
        let text = AgentDisplayHomeMapping.unreadText(count: 3)
        XCTAssertEqual(
            text,
            String(format: "agent.display.home.unread.count".localized, 3)
        )
        XCTAssertTrue(text.contains("3"))
    }

    func testShortStatusLightOnOff() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(device(.light, name: "客厅灯", isOn: true)),
            "客厅灯 " + "agent.display.home.status.on".localized
        )
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(device(.light, name: "客厅灯", isOn: false)),
            "客厅灯 " + "agent.display.home.status.off".localized
        )
    }

    func testShortStatusOutletUsesOnOff() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(device(.outlet, name: "插座", isOn: true)),
            "插座 " + "agent.display.home.status.on".localized
        )
    }

    func testShortStatusThermostatUsesTarget() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(
                device(.thermostat, name: "空调", target: 21.4)
            ),
            "空调 21°"
        )
    }

    func testShortStatusLockedState() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(device(.lock, name: "门锁", isLocked: true)),
            "门锁 " + "agent.display.home.status.locked".localized
        )
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(device(.lock, name: "门锁", isLocked: false)),
            "门锁 " + "agent.display.home.status.unlocked".localized
        )
    }

    func testShortStatusUnknownKindUsesNameOnly() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.shortStatus(device(.unknown, name: "未知设备")),
            "未知设备"
        )
    }

    func testStatusLinesTruncatesToLimit() {
        let devices = [
            device(.light, name: "A"),
            device(.light, name: "B"),
            device(.light, name: "C"),
            device(.light, name: "D"),
            device(.light, name: "E")
        ]
        XCTAssertEqual(AgentDisplayHomeMapping.statusLines(from: devices).count, 3)
        XCTAssertEqual(
            AgentDisplayHomeMapping.statusLines(from: devices, limit: 2).count,
            2
        )
    }

    func testHudActionsOrderIsStable() {
        XCTAssertEqual(
            AgentDisplayHomeMapping.hudActions(),
            [.wake, .captureVision, .repeatLastReply, .newChat, .dismiss]
        )
    }

    func testStateAssemblyPreservesInput() {
        let now = Date(timeIntervalSince1970: 1000)
        let devices = [device(.light, name: "台灯", isOn: true)]
        let state = AgentDisplayHomeMapping.state(
            now: now,
            unreadCount: 5,
            devices: devices
        )
        XCTAssertEqual(state.now, now)
        XCTAssertEqual(state.unreadCount, 5)
        XCTAssertTrue(state.calendarLines.isEmpty)
        XCTAssertEqual(state.statusLines, ["台灯 " + "agent.display.home.status.on".localized])
        XCTAssertEqual(state.actions, AgentDisplayHomeMapping.hudActions())
    }

    private func calendarEvent(
        _ title: String,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        isAllDay: Bool = false
    ) -> AgentCalendarEvent {
        let start = AgentCalendarTestClock.date(year, month, day, hour, minute)
        return AgentCalendarEvent(
            title: title,
            start: start,
            end: start.addingTimeInterval(isAllDay ? 86400 : 3600),
            isAllDay: isAllDay
        )
    }

    func testCalendarLinesEmptyWithoutEvents() {
        XCTAssertTrue(
            AgentDisplayHomeMapping.calendarLines(
                from: [],
                now: AgentCalendarTestClock.now,
                calendar: AgentCalendarTestClock.calendar
            ).isEmpty
        )
    }

    func testCalendarLineTimedFormat() {
        let line = AgentDisplayHomeMapping.calendarLine(
            calendarEvent("产品评审", 2026, 8, 12, 15, 30),
            now: AgentCalendarTestClock.now,
            calendar: AgentCalendarTestClock.calendar
        )
        XCTAssertEqual(
            line,
            "agent.calendar.day.today".localized + " 15:30 产品评审"
        )
    }

    func testCalendarLineAllDayFormat() {
        let line = AgentDisplayHomeMapping.calendarLine(
            calendarEvent("出游", 2026, 8, 13, isAllDay: true),
            now: AgentCalendarTestClock.now,
            calendar: AgentCalendarTestClock.calendar
        )
        XCTAssertEqual(
            line,
            "agent.calendar.day.tomorrow".localized + " " + "agent.calendar.allday".localized + " 出游"
        )
    }

    func testCalendarLinesPrioritizeTodayThenTomorrowAndLimit() {
        let events = [
            calendarEvent("出差", 2026, 8, 13, 9),
            calendarEvent("评审", 2026, 8, 12, 15),
            calendarEvent("早会", 2026, 8, 12, 9),
        ]
        let lines = AgentDisplayHomeMapping.calendarLines(
            from: events,
            now: AgentCalendarTestClock.now,
            calendar: AgentCalendarTestClock.calendar
        )
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("早会"))
        XCTAssertTrue(lines[1].contains("评审"))
        XCTAssertTrue(lines[2].contains("出差"))

        let limited = AgentDisplayHomeMapping.calendarLines(
            from: events,
            now: AgentCalendarTestClock.now,
            calendar: AgentCalendarTestClock.calendar,
            limit: 2
        )
        XCTAssertEqual(limited, Array(lines.prefix(2)))
    }

    func testCalendarLinesExcludeOtherDays() {
        let events = [
            calendarEvent("昨天", 2026, 8, 11, 15),
            calendarEvent("后天", 2026, 8, 14, 9),
            calendarEvent("下周", 2026, 8, 19, 9),
        ]
        XCTAssertTrue(
            AgentDisplayHomeMapping.calendarLines(
                from: events,
                now: AgentCalendarTestClock.now,
                calendar: AgentCalendarTestClock.calendar
            ).isEmpty
        )
    }

    func testStateAssemblyIncludesCalendarLines() {
        let state = AgentDisplayHomeMapping.state(
            now: AgentCalendarTestClock.now,
            unreadCount: 2,
            devices: [],
            calendarEvents: [calendarEvent("评审", 2026, 8, 12, 15)],
            calendar: AgentCalendarTestClock.calendar
        )
        XCTAssertEqual(state.calendarLines.count, 1)
        XCTAssertTrue(state.calendarLines[0].contains("评审"))
        XCTAssertTrue(state.statusLines.isEmpty)
    }

    private func persistedTask(_ title: String, status: String) -> PersistedAgentTask {
        PersistedAgentTask(
            taskId: UUID().uuidString,
            title: title,
            status: status,
            updatedAt: AgentCalendarTestClock.now
        )
    }

    func testTaskLineNilWithoutRunningTasks() {
        XCTAssertNil(AgentDisplayHomeMapping.taskLine(from: []))
        let tasks = [
            persistedTask("上传视频", status: QwenAgentTask.Status.completed.notificationRaw),
            persistedTask("整理报告", status: QwenAgentTask.Status.failed.notificationRaw),
        ]
        XCTAssertNil(AgentDisplayHomeMapping.taskLine(from: tasks))
    }

    func testTaskLineSingleShowsTitle() {
        let tasks = [persistedTask("上传视频", status: QwenAgentTask.Status.running.notificationRaw)]
        XCTAssertEqual(
            AgentDisplayHomeMapping.taskLine(from: tasks),
            String(format: "agent.display.home.task.running".localized, "上传视频")
        )
    }

    func testTaskLineMultipleShowsCountAndCountsWaiting() {
        let tasks = [
            persistedTask("上传视频", status: QwenAgentTask.Status.running.notificationRaw),
            persistedTask("生成字幕", status: QwenAgentTask.Status.waiting.notificationRaw),
            persistedTask("已完成的", status: QwenAgentTask.Status.completed.notificationRaw),
        ]
        XCTAssertEqual(
            AgentDisplayHomeMapping.taskLine(from: tasks),
            String(format: "agent.display.home.task.more".localized, "上传视频", 2)
        )
    }

    func testTaskLineIgnoresEmptyTitle() {
        let tasks = [persistedTask("   ", status: QwenAgentTask.Status.running.notificationRaw)]
        XCTAssertNil(AgentDisplayHomeMapping.taskLine(from: tasks))
    }

    func testReminderLineShowsNextUpcoming() {
        let now = AgentCalendarTestClock.now
        let soon = AgentReminder(
            text: "吃药",
            fireDate: now.addingTimeInterval(25 * 60),
            repeatRule: .none
        )
        let later = AgentReminder(
            text: "会议",
            fireDate: now.addingTimeInterval(3600),
            repeatRule: .none
        )
        let line = AgentDisplayHomeMapping.reminderLine(
            from: [later, soon],
            now: now,
            calendar: AgentCalendarTestClock.calendar
        )
        let when = AgentReminderTimeFormatter.relativeDescription(
            from: now.addingTimeInterval(25 * 60),
            now: now,
            calendar: AgentCalendarTestClock.calendar
        )
        XCTAssertEqual(
            line,
            String(format: "agent.display.home.reminder".localized, "\(when) 吃药")
        )
    }

    func testReminderLineNilWithoutUpcoming() {
        let now = AgentCalendarTestClock.now
        let past = AgentReminder(
            text: "吃药",
            fireDate: now.addingTimeInterval(-600),
            repeatRule: .none
        )
        XCTAssertNil(
            AgentDisplayHomeMapping.reminderLine(
                from: [past],
                now: now,
                calendar: AgentCalendarTestClock.calendar
            )
        )
    }

    func testStateAssemblyIncludesTaskAndReminderLines() {
        let now = AgentCalendarTestClock.now
        let state = AgentDisplayHomeMapping.state(
            now: now,
            unreadCount: 0,
            devices: [],
            tasks: [persistedTask("上传视频", status: QwenAgentTask.Status.running.notificationRaw)],
            reminders: [
                AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(600), repeatRule: .none)
            ],
            calendar: AgentCalendarTestClock.calendar
        )
        XCTAssertEqual(state.taskLine, AgentDisplayHomeMapping.taskLine(from: [
            persistedTask("上传视频", status: QwenAgentTask.Status.running.notificationRaw)
        ]))
        XCTAssertNotNil(state.reminderLine)
    }

    func testMakeViewRendersHudWithActions() {
        let now = Date(timeIntervalSince1970: 1000)
        let devices = [device(.light, name: "台灯", isOn: true)]
        let state = AgentDisplayHomeMapping.state(
            now: now,
            unreadCount: 2,
            devices: devices
        )
        let view = AgentDisplayHomeMapping.makeView(state: state) { _ in }
        XCTAssertNotNil(view)
    }
}

// MARK: - 数据装载

private final class MockHomeKitProvider: AgentHomeKitProviding {
    var authorization: AgentHomeKitAuthorization = .authorized
    var storedDevices: [AgentHomeKitDevice] = []

    func devices() async -> [AgentHomeKitDevice] { storedDevices }

    func setPower(deviceID: String, on: Bool) async throws {}

    func setBrightness(deviceID: String, percent: Int) async throws {}

    func setTemperature(deviceID: String, celsius: Double) async throws {}
}

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

private final class MockHomeCalendarProvider: AgentCalendarProviding {
    var authorization: AgentCalendarAuthorization = .authorized
    var events: [AgentCalendarEvent] = []
    var fetchCount = 0

    func requestAuthorization() async -> AgentCalendarAuthorization {
        authorization
    }

    func fetchEvents(from start: Date, to end: Date) async -> [AgentCalendarEvent] {
        fetchCount += 1
        return events
    }

    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws -> AgentCalendarEvent {
        AgentCalendarEvent(title: title, start: start, end: end, isAllDay: isAllDay)
    }

    func deleteEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws {
        events.removeAll {
            $0.title == title && $0.start == start && $0.end == end && $0.isAllDay == isAllDay
        }
    }
}

final class AgentDisplayHomeLoaderTests: XCTestCase {

    private func device(
        _ kind: AgentHomeKitDevice.Kind,
        name: String
    ) -> AgentHomeKitDevice {
        AgentHomeKitDevice(
            id: name,
            name: name,
            roomName: nil,
            kind: kind,
            isOn: true,
            brightness: nil,
            currentTemperature: nil,
            targetTemperature: nil,
            isLocked: nil
        )
    }

    func testDeniedNotificationAccessYieldsZeroUnread() async {
        let notifications = MockNotificationProvider()
        notifications.status = .denied
        notifications.items = [
            AgentNotificationItem(id: "1", title: "A", body: "", date: Date())
        ]
        let homeKit = MockHomeKitProvider()
        homeKit.storedDevices = [device(.light, name: "台灯")]

        let state = await AgentDisplayHomeLoader.state(
            notificationProvider: notifications,
            homeKitProvider: homeKit
        )
        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertEqual(state.statusLines.count, 1)
    }

    func testHomeKitUnavailableYieldsEmptyStatus() async {
        let notifications = MockNotificationProvider()
        let homeKit = MockHomeKitProvider()
        homeKit.authorization = .unavailable
        homeKit.storedDevices = [device(.light, name: "台灯")]

        let state = await AgentDisplayHomeLoader.state(
            notificationProvider: notifications,
            homeKitProvider: homeKit
        )
        XCTAssertTrue(state.statusLines.isEmpty)
    }

    func testLoaderCombinesData() async {
        let notifications = MockNotificationProvider()
        notifications.items = [
            AgentNotificationItem(id: "1", title: "A", body: "", date: Date()),
            AgentNotificationItem(id: "2", title: "B", body: "", date: Date())
        ]
        let homeKit = MockHomeKitProvider()
        homeKit.storedDevices = [
            device(.light, name: "客厅灯"),
            device(.lock, name: "门锁")
        ]

        let state = await AgentDisplayHomeLoader.state(
            notificationProvider: notifications,
            homeKitProvider: homeKit
        )
        XCTAssertEqual(state.unreadCount, 2)
        XCTAssertEqual(state.statusLines.count, 2)
        XCTAssertEqual(state.actions, AgentDisplayHomeMapping.hudActions())
    }

    func testLoaderIncludesCalendarLinesWhenAuthorized() async {
        let provider = MockHomeCalendarProvider()
        provider.authorization = .authorized
        provider.events = [
            AgentCalendarEvent(
                title: "评审",
                start: AgentCalendarTestClock.date(2026, 8, 12, 15),
                end: AgentCalendarTestClock.date(2026, 8, 12, 16)
            )
        ]
        let state = await AgentDisplayHomeLoader.state(
            now: AgentCalendarTestClock.now,
            calendar: AgentCalendarTestClock.calendar,
            notificationProvider: MockNotificationProvider(),
            homeKitProvider: MockHomeKitProvider(),
            calendarProvider: provider
        )
        XCTAssertEqual(state.calendarLines.count, 1)
        XCTAssertTrue(state.calendarLines[0].contains("评审"))
        XCTAssertEqual(provider.fetchCount, 1)
    }

    func testLoaderSkipsCalendarWhenNotAuthorized() async {
        let provider = MockHomeCalendarProvider()
        provider.authorization = .denied
        let state = await AgentDisplayHomeLoader.state(
            notificationProvider: MockNotificationProvider(),
            homeKitProvider: MockHomeKitProvider(),
            calendarProvider: provider
        )
        XCTAssertTrue(state.calendarLines.isEmpty)
        XCTAssertEqual(provider.fetchCount, 0)
    }

    func testLoaderIncludesTaskAndReminderLines() async {
        let now = AgentCalendarTestClock.now
        let tasks = [
            PersistedAgentTask(
                taskId: "t1",
                title: "上传视频",
                status: QwenAgentTask.Status.running.notificationRaw,
                updatedAt: now
            )
        ]
        let reminders = [
            AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(600), repeatRule: .none)
        ]
        let state = await AgentDisplayHomeLoader.state(
            now: now,
            calendar: AgentCalendarTestClock.calendar,
            notificationProvider: MockNotificationProvider(),
            homeKitProvider: MockHomeKitProvider(),
            tasks: tasks,
            reminders: reminders
        )
        XCTAssertEqual(
            state.taskLine,
            AgentDisplayHomeMapping.taskLine(from: tasks)
        )
        XCTAssertEqual(
            state.reminderLine,
            AgentDisplayHomeMapping.reminderLine(
                from: reminders,
                now: now,
                calendar: AgentCalendarTestClock.calendar
            )
        )
    }
}
