/*
 * Agent Connect Greeting Tests
 * 眼镜连接问候：策略门控（开关 / 会话中不打扰 / 最小间隔）、文案构建
 * （栏目条数 / 全空回退 / 助手名注入）、数据组装（内容开关 / 通知授权）、
 * 设置持久化往返。
 */

import XCTest
import UserNotifications
@testable import HyperMetaAI

// MARK: - 策略

final class AgentConnectGreetingPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testDisabledNeverGreets() {
        XCTAssertFalse(
            AgentConnectGreetingPolicy.shouldGreet(
                enabled: false,
                isSessionActive: false,
                lastGreetedAt: nil,
                now: now,
                minInterval: 60
            )
        )
    }

    func testActiveSessionSkipsGreeting() {
        XCTAssertFalse(
            AgentConnectGreetingPolicy.shouldGreet(
                enabled: true,
                isSessionActive: true,
                lastGreetedAt: nil,
                now: now,
                minInterval: 60
            )
        )
    }

    func testFirstConnectAlwaysGreets() {
        XCTAssertTrue(
            AgentConnectGreetingPolicy.shouldGreet(
                enabled: true,
                isSessionActive: false,
                lastGreetedAt: nil,
                now: now,
                minInterval: 60
            )
        )
    }

    func testWithinIntervalSkips() {
        XCTAssertFalse(
            AgentConnectGreetingPolicy.shouldGreet(
                enabled: true,
                isSessionActive: false,
                lastGreetedAt: now.addingTimeInterval(-30),
                now: now,
                minInterval: 60
            )
        )
    }

    func testAtIntervalGreets() {
        XCTAssertTrue(
            AgentConnectGreetingPolicy.shouldGreet(
                enabled: true,
                isSessionActive: false,
                lastGreetedAt: now.addingTimeInterval(-60),
                now: now,
                minInterval: 60
            )
        )
    }

    func testNegativeIntervalNeverGreets() {
        XCTAssertFalse(
            AgentConnectGreetingPolicy.shouldGreet(
                enabled: true,
                isSessionActive: false,
                lastGreetedAt: nil,
                now: now,
                minInterval: -1
            )
        )
    }
}

// MARK: - 文案构建

final class AgentConnectGreetingBuilderTests: XCTestCase {

    func testSummaryListsSectionsInOrder() {
        let text = AgentConnectGreetingBuilder.summary(
            scheduleCount: 2,
            reminderCount: 1,
            taskCount: 3,
            unreadCount: 5,
            personaName: "Lucky"
        )
        let head = String(
            format: "agent.connect.greeting.head".localized,
            "Lucky"
        )
        let schedule = String(
            format: "agent.connect.greeting.schedule".localized,
            2
        )
        let reminders = String(
            format: "agent.connect.greeting.reminders".localized,
            1
        )
        let tasks = String(
            format: "agent.connect.greeting.tasks".localized,
            3
        )
        let unread = String(
            format: "agent.connect.greeting.unread".localized,
            5
        )
        XCTAssertEqual(text, "\(head) \(schedule)，\(reminders)，\(tasks)，\(unread)")
    }

    func testZeroCountsFallBackToAllClear() {
        let text = AgentConnectGreetingBuilder.summary(
            scheduleCount: 0,
            reminderCount: 0,
            taskCount: 0,
            unreadCount: 0,
            personaName: "Lucky"
        )
        let head = String(
            format: "agent.connect.greeting.head".localized,
            "Lucky"
        )
        XCTAssertEqual(
            text,
            head + " " + "agent.connect.greeting.allClear".localized
        )
    }

    func testEmptyPersonaUsesFallbackName() {
        let text = AgentConnectGreetingBuilder.summary(
            scheduleCount: 1,
            reminderCount: 0,
            taskCount: 0,
            unreadCount: 0,
            personaName: ""
        )
        XCTAssertTrue(text.hasPrefix(String(
            format: "agent.connect.greeting.head".localized,
            "agent.briefing.greeting.fallback".localized
        )))
    }
}

// MARK: - 数据组装

private final class MockBriefingProvider: AgentBriefingDataProviding {
    var storedEvents: [AgentCalendarEvent] = []
    var storedReminders: [AgentReminder] = []
    var storedTaskTitles: [String] = []

    func todayEvents() async -> [AgentCalendarEvent] { storedEvents }
    var reminders: [AgentReminder] { storedReminders }
    var taskTitles: [String] { storedTaskTitles }
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

@MainActor
final class AgentConnectGreetingAssemblerTests: XCTestCase {

    private func provider(
        events: Int = 0,
        reminders: Int = 0,
        tasks: Int = 0
    ) -> MockBriefingProvider {
        let provider = MockBriefingProvider()
        provider.storedEvents = (0..<events).map {
            AgentCalendarEvent(
                title: "E\($0)",
                start: Date(timeIntervalSince1970: Double($0)),
                end: Date(timeIntervalSince1970: Double($0) + 60)
            )
        }
        provider.storedReminders = (0..<reminders).map {
            AgentReminder(text: "R\($0)", fireDate: Date(timeIntervalSince1970: Double($0)))
        }
        provider.storedTaskTitles = (0..<tasks).map { "T\($0)" }
        return provider
    }

    func testCombinesAllSectionsWhenEnabled() async {
        let notifications = MockNotificationProvider()
        notifications.items = (0..<4).map {
            AgentNotificationItem(
                id: "\($0)",
                title: "N\($0)",
                body: "",
                date: Date(timeIntervalSince1970: Double($0))
            )
        }
        let text = await AgentConnectGreetingAssembler.buildSummary(
            includeSchedule: true,
            includeReminders: true,
            includeTasks: true,
            includeUnread: true,
            briefingProvider: provider(events: 2, reminders: 1, tasks: 3),
            notificationProvider: notifications,
            personaName: "Lucky"
        )
        XCTAssertTrue(text.contains(String(
            format: "agent.connect.greeting.schedule".localized, 2
        )))
        XCTAssertTrue(text.contains(String(
            format: "agent.connect.greeting.reminders".localized, 1
        )))
        XCTAssertTrue(text.contains(String(
            format: "agent.connect.greeting.tasks".localized, 3
        )))
        XCTAssertTrue(text.contains(String(
            format: "agent.connect.greeting.unread".localized, 4
        )))
    }

    func testDisabledSectionsExcluded() async {
        let text = await AgentConnectGreetingAssembler.buildSummary(
            includeSchedule: false,
            includeReminders: false,
            includeTasks: false,
            includeUnread: false,
            briefingProvider: provider(events: 5, reminders: 5, tasks: 5),
            notificationProvider: MockNotificationProvider(),
            personaName: "Lucky"
        )
        XCTAssertEqual(text, String(
            format: "agent.connect.greeting.head".localized, "Lucky"
        ) + " " + "agent.connect.greeting.allClear".localized)
    }

    func testUnreadRequiresNotificationAuthorization() async {
        let notifications = MockNotificationProvider()
        notifications.status = .denied
        notifications.items = [
            AgentNotificationItem(id: "1", title: "A", body: "", date: Date())
        ]
        let text = await AgentConnectGreetingAssembler.buildSummary(
            includeSchedule: false,
            includeReminders: false,
            includeTasks: false,
            includeUnread: true,
            briefingProvider: provider(),
            notificationProvider: notifications,
            personaName: "Lucky"
        )
        XCTAssertEqual(text, String(
            format: "agent.connect.greeting.head".localized, "Lucky"
        ) + " " + "agent.connect.greeting.allClear".localized)
    }
}

// MARK: - 设置持久化

final class AgentConnectGreetingSettingsTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(
            forKey: AgentConnectGreetingSettings.enabledKey
        )
        UserDefaults.standard.removeObject(
            forKey: AgentConnectGreetingSettings.scheduleKey
        )
        UserDefaults.standard.removeObject(
            forKey: AgentConnectGreetingSettings.remindersKey
        )
        UserDefaults.standard.removeObject(
            forKey: AgentConnectGreetingSettings.tasksKey
        )
        UserDefaults.standard.removeObject(
            forKey: AgentConnectGreetingSettings.unreadKey
        )
        UserDefaults.standard.removeObject(
            forKey: AgentConnectGreetingSettings.minIntervalKey
        )
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertTrue(AgentConnectGreetingSettings.enabled)
        XCTAssertTrue(AgentConnectGreetingSettings.includeSchedule)
        XCTAssertTrue(AgentConnectGreetingSettings.includeReminders)
        XCTAssertTrue(AgentConnectGreetingSettings.includeTasks)
        XCTAssertTrue(AgentConnectGreetingSettings.includeUnread)
        XCTAssertEqual(AgentConnectGreetingSettings.minInterval, 60)
    }

    func testRoundTrip() {
        AgentConnectGreetingSettings.enabled = false
        AgentConnectGreetingSettings.includeSchedule = false
        AgentConnectGreetingSettings.includeReminders = false
        AgentConnectGreetingSettings.includeTasks = false
        AgentConnectGreetingSettings.includeUnread = false
        AgentConnectGreetingSettings.minInterval = 30

        XCTAssertFalse(AgentConnectGreetingSettings.enabled)
        XCTAssertFalse(AgentConnectGreetingSettings.includeSchedule)
        XCTAssertFalse(AgentConnectGreetingSettings.includeReminders)
        XCTAssertFalse(AgentConnectGreetingSettings.includeTasks)
        XCTAssertFalse(AgentConnectGreetingSettings.includeUnread)
        XCTAssertEqual(AgentConnectGreetingSettings.minInterval, 30)
    }
}
