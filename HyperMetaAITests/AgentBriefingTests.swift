import XCTest
@testable import HyperMetaAI

// MARK: - 设置存储

final class AgentBriefingStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentBriefingStore.clear()
  }

  override func tearDown() {
    AgentBriefingStore.clear()
    super.tearDown()
  }

  func testDefaults() {
    let settings = AgentBriefingStore.current
    XCTAssertFalse(settings.enabled)
    XCTAssertEqual(settings.hour, 8)
    XCTAssertEqual(settings.minute, 0)
    XCTAssertTrue(settings.includeSchedule)
    XCTAssertTrue(settings.includeReminders)
    XCTAssertTrue(settings.includeTasks)
  }

  func testUpdateClampsTime() {
    AgentBriefingStore.update {
      $0.enabled = true
      $0.hour = 25
      $0.minute = -5
      $0.includeSchedule = false
    }
    let settings = AgentBriefingStore.current
    XCTAssertTrue(settings.enabled)
    XCTAssertEqual(settings.hour, 23)
    XCTAssertEqual(settings.minute, 0)
    XCTAssertFalse(settings.includeSchedule)
  }

  func testSaveLoadRoundTrip() {
    AgentBriefingStore.update {
      $0.enabled = true
      $0.hour = 7
      $0.minute = 30
      $0.includeTasks = false
    }
    let loaded = AgentBriefingStore.current
    XCTAssertEqual(loaded.hour, 7)
    XCTAssertEqual(loaded.minute, 30)
    XCTAssertFalse(loaded.includeTasks)
  }
}

// MARK: - 内容构建

@MainActor
final class AgentBriefingBuilderTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system

  // 2026-08-13 08:00 +0800（星期四）
  private let now = AgentCalendarTestClock.date(2026, 8, 13, 8)

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
  }

  override func tearDown() {
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func settings(
    schedule: Bool = true,
    reminders: Bool = true,
    tasks: Bool = true
  ) -> AgentBriefingSettings {
    AgentBriefingSettings(
      enabled: true,
      hour: 8,
      minute: 0,
      includeSchedule: schedule,
      includeReminders: reminders,
      includeTasks: tasks
    )
  }

  func testFullBriefing() {
    let content = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "产品评审",
          start: AgentCalendarTestClock.date(2026, 8, 13, 9),
          end: AgentCalendarTestClock.date(2026, 8, 13, 10)
        ),
      ],
      reminders: [
        AgentReminder(
          text: "吃药",
          fireDate: AgentCalendarTestClock.date(2026, 8, 13, 10)
        ),
      ],
      taskTitles: ["整理报告", "写周报"],
      settings: settings(),
      personaName: "Lucky"
    )

    XCTAssertEqual(content.greeting, "早上好，Lucky！")
    XCTAssertEqual(content.dateLine, "今天是8月13日 星期四。")
    XCTAssertEqual(content.scheduleLine, "日程：今天 09:00-10:00 产品评审")
    XCTAssertTrue(content.reminderLine?.contains("提醒：") == true)
    XCTAssertTrue(content.reminderLine?.contains("吃药") == true)
    XCTAssertEqual(content.taskLine, "任务：整理报告，写周报")
    XCTAssertFalse(content.isEmpty)
    XCTAssertTrue(content.fullText.contains("早上好，Lucky！"))
    XCTAssertTrue(content.fullText.contains("日程：今天 09:00-10:00 产品评审"))
  }

  func testSectionsCanBeDisabled() {
    let content = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "评审",
          start: AgentCalendarTestClock.date(2026, 8, 13, 9),
          end: AgentCalendarTestClock.date(2026, 8, 13, 10)
        ),
      ],
      reminders: [
        AgentReminder(text: "吃药", fireDate: AgentCalendarTestClock.date(2026, 8, 13, 10)),
      ],
      taskTitles: ["整理报告"],
      settings: settings(schedule: false, reminders: false, tasks: false),
      personaName: "Lucky"
    )
    XCTAssertNil(content.scheduleLine)
    XCTAssertNil(content.reminderLine)
    XCTAssertNil(content.taskLine)
    XCTAssertTrue(content.isEmpty)
  }

  func testEmptyBriefingFallsBack() {
    let content = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "Lucky"
    )
    XCTAssertTrue(content.isEmpty)
    XCTAssertEqual(
      content.fullText,
      "早上好，Lucky！\n今天是8月13日 星期四。\n今天没有日程、提醒和任务，祝你有美好的一天！"
    )
  }

  func testGreetingUsesPersonaNameOrFallback() {
    let withName = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "小舟"
    )
    XCTAssertEqual(withName.greeting, "早上好，小舟！")

    let emptyName = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: ""
    )
    XCTAssertEqual(emptyName.greeting, "早上好，朋友！")
  }

  func testAllDayEventIncluded() {
    let content = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "年会",
          start: AgentCalendarTestClock.date(2026, 8, 13),
          end: AgentCalendarTestClock.date(2026, 8, 14),
          isAllDay: true
        ),
      ],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "Lucky"
    )
    XCTAssertEqual(content.scheduleLine, "日程：全天 年会")
  }

  func testGreetingPeriodBoundaries() {
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 5), .morning)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 11), .morning)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 12), .afternoon)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 17), .afternoon)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 18), .evening)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 22), .evening)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 23), .night)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 0), .night)
    XCTAssertEqual(AgentBriefingGreetingPeriod.period(hour: 4), .night)
  }

  func testGreetingFollowsTimeOfDay() {
    let at = { (hour: Int) in
      AgentBriefingBuilder.greeting(
        personaName: "Lucky",
        date: AgentCalendarTestClock.date(2026, 8, 13, hour),
        calendar: AgentCalendarTestClock.calendar
      )
    }
    XCTAssertEqual(at(8), "早上好，Lucky！")
    XCTAssertEqual(at(14), "下午好，Lucky！")
    XCTAssertEqual(at(20), "晚上好，Lucky！")
    XCTAssertEqual(at(23), "夜深了，Lucky。早点休息！")
    XCTAssertEqual(at(3), "夜深了，Lucky。早点休息！")
  }

  func testNextEventCountdownMinutes() {
    let content = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "评审",
          start: AgentCalendarTestClock.date(2026, 8, 13, 8, 45),
          end: AgentCalendarTestClock.date(2026, 8, 13, 9, 30)
        ),
      ],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "Lucky"
    )
    XCTAssertEqual(content.nextEventLine, "下一场日程 45 分钟后开始。")
    XCTAssertTrue(content.fullText.contains("下一场日程 45 分钟后开始。"))
    XCTAssertTrue(
      content.fullText.range(of: "下一场日程 45 分钟后开始。")!.lowerBound
        < content.fullText.range(of: "日程：今天 08:45-09:30 评审")!.lowerBound,
      "倒计时行应排在日程行之前"
    )
  }

  func testNextEventCountdownHours() {
    let content = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "汇报",
          start: AgentCalendarTestClock.date(2026, 8, 13, 10),
          end: AgentCalendarTestClock.date(2026, 8, 13, 11)
        ),
      ],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "Lucky"
    )
    XCTAssertEqual(content.nextEventLine, "下一场日程 2 小时后开始。")
  }

  func testNextEventHiddenWhenStartedOrBeyondDay() {
    // 已开始的日程：不显示倒计时（避免误导）
    let started = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "晨会",
          start: AgentCalendarTestClock.date(2026, 8, 13, 7, 30),
          end: AgentCalendarTestClock.date(2026, 8, 13, 8, 30)
        ),
      ],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "Lucky"
    )
    XCTAssertNil(started.nextEventLine)

    // 超过 24 小时的日程：不显示倒计时
    let beyond = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "出差",
          start: AgentCalendarTestClock.date(2026, 8, 15, 9),
          end: AgentCalendarTestClock.date(2026, 8, 15, 10)
        ),
      ],
      reminders: [],
      taskTitles: [],
      settings: settings(),
      personaName: "Lucky"
    )
    XCTAssertNil(beyond.nextEventLine)
    XCTAssertNotNil(beyond.scheduleLine, "超 24 小时日程仍保留在日程列表")

    // 关闭日程栏目：不显示倒计时
    let disabled = AgentBriefingBuilder.build(
      date: now,
      calendar: AgentCalendarTestClock.calendar,
      events: [
        AgentCalendarEvent(
          title: "评审",
          start: AgentCalendarTestClock.date(2026, 8, 13, 8, 45),
          end: AgentCalendarTestClock.date(2026, 8, 13, 9, 30)
        ),
      ],
      reminders: [],
      taskTitles: [],
      settings: settings(schedule: false),
      personaName: "Lucky"
    )
    XCTAssertNil(disabled.nextEventLine)
  }
}

// MARK: - 调度器（Mock 通知中心 + Mock 数据源）

@MainActor
private final class FakeBriefingCenter: AgentBriefingNotificationCentering {
  var requests: [UNNotificationRequest] = []
  var removedIdentifiers: [String] = []

  func add(_ request: UNNotificationRequest) {
    requests.append(request)
  }

  func removePending(withIdentifiers identifiers: [String]) {
    removedIdentifiers.append(contentsOf: identifiers)
    requests.removeAll { identifiers.contains($0.identifier) }
  }
}

@MainActor
private final class MockBriefingDataProvider: AgentBriefingDataProviding {
  var events: [AgentCalendarEvent] = []
  var reminders: [AgentReminder] = []
  var taskTitles: [String] = []

  func todayEvents() async -> [AgentCalendarEvent] {
    events
  }
}

@MainActor
final class AgentBriefingSchedulerTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system
  private let fakeCenter = FakeBriefingCenter()
  private let mockProvider = MockBriefingDataProvider()
  private var previousCenter: AgentBriefingNotificationCentering?
  private var previousProvider: AgentBriefingDataProviding?

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
    previousCenter = AgentBriefingScheduler.center
    previousProvider = AgentBriefingScheduler.dataProvider
    AgentBriefingScheduler.center = fakeCenter
    AgentBriefingScheduler.dataProvider = mockProvider
    AgentBriefingStore.clear()
  }

  override func tearDown() {
    AgentBriefingStore.clear()
    AgentBriefingScheduler.center = previousCenter ?? SystemBriefingNotificationCenter()
    AgentBriefingScheduler.dataProvider = previousProvider ?? LiveAgentBriefingDataProvider()
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  func testEnabledSchedulesDailyNotification() async {
    mockProvider.events = [
      AgentCalendarEvent(
        title: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 13, 9),
        end: AgentCalendarTestClock.date(2026, 8, 13, 10)
      ),
    ]
    mockProvider.taskTitles = ["整理报告"]
    let settings = AgentBriefingSettings(enabled: true, hour: 7, minute: 30)

    await AgentBriefingScheduler.sync(settings: settings)

    XCTAssertEqual(fakeCenter.requests.count, 1)
    let request = fakeCenter.requests[0]
    XCTAssertEqual(request.identifier, AgentBriefingScheduler.identifier)
    XCTAssertEqual(request.content.title, "每日晨报")
    XCTAssertTrue(request.content.body.contains("评审"))
    XCTAssertTrue(request.content.body.contains("整理报告"))
    XCTAssertEqual(request.content.userInfo[AgentBriefingScheduler.userInfoKey] as? Bool, true)
    let trigger = try? XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
    XCTAssertEqual(trigger?.dateComponents.hour, 7)
    XCTAssertEqual(trigger?.dateComponents.minute, 30)
    XCTAssertEqual(trigger?.repeats, true)
  }

  func testDisabledRemovesPending() async {
    await AgentBriefingScheduler.sync(settings: AgentBriefingSettings(enabled: false))

    XCTAssertTrue(fakeCenter.requests.isEmpty)
    XCTAssertEqual(fakeCenter.removedIdentifiers, [AgentBriefingScheduler.identifier])
  }

  func testResyncReplacesSingleRequest() async {
    let settings = AgentBriefingSettings(enabled: true, hour: 8, minute: 0)
    await AgentBriefingScheduler.sync(settings: settings)
    await AgentBriefingScheduler.sync(settings: settings)

    XCTAssertEqual(fakeCenter.requests.count, 1, "幂等：先移除再添加，只保留一条")
    XCTAssertEqual(fakeCenter.removedIdentifiers.count, 2)
  }

  func testEmptyDataStillSchedulesGreeting() async {
    let settings = AgentBriefingSettings(enabled: true, hour: 8, minute: 0)
    await AgentBriefingScheduler.sync(settings: settings)

    XCTAssertEqual(fakeCenter.requests.count, 1)
    // 问候语随当前时段变化（早上好 / 下午好 / 晚上好 / 夜深了）：
    // 按构建器同一逻辑断言，避免测试随时段失败
    let expectedGreeting = AgentBriefingBuilder.greeting(
        personaName: AgentPersonaStore.current.name
    )
    XCTAssertTrue(fakeCenter.requests[0].content.body.contains(expectedGreeting))
  }
}
