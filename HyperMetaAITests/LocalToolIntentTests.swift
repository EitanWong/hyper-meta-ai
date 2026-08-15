import Foundation
import XCTest

@testable import HyperMetaAI

/// 日历 Mock（Siri 本地工具日历用例）
private final class MockCalendarProvider: AgentCalendarProviding {
  var authorization: AgentCalendarAuthorization = .authorized
  var events: [AgentCalendarEvent] = []
  var createdEvent: AgentCalendarEvent?

  func requestAuthorization() async -> AgentCalendarAuthorization { authorization }

  func fetchEvents(from start: Date, to end: Date) async -> [AgentCalendarEvent] { events }

  func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws -> AgentCalendarEvent {
    let event = AgentCalendarEvent(title: title, start: start, end: end, isAllDay: isAllDay)
    createdEvent = event
    return event
  }

  func deleteEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws {
    events.removeAll {
      $0.title == title && $0.start == start && $0.end == end && $0.isAllDay == isAllDay
    }
  }
}

/// Siri 本地工具直达：副作用与文案的单元测试
@MainActor
final class LocalToolIntentHandlerTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()
  private var originalAuthorizationProvider: (() async -> Bool)!
  private var originalCalendarProvider: AgentCalendarProviding!
  private var calendarProvider: MockCalendarProvider!
  private var previousLanguage: AppLanguage = .system

  private func shDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
    AgentMemoryStore.clear()
    AgentRuleStore.clear()
    AgentListStore.clear()
    AgentReminderStore.clear()
    originalAuthorizationProvider = LocalToolIntentHandler.authorizationProvider
    LocalToolIntentHandler.authorizationProvider = { true }
    originalCalendarProvider = AgentCalendar.provider
    calendarProvider = MockCalendarProvider()
    AgentCalendar.provider = calendarProvider
  }

  override func tearDown() {
    LocalToolIntentHandler.authorizationProvider = originalAuthorizationProvider
    AgentCalendar.provider = originalCalendarProvider
    LanguageManager.shared.currentLanguage = previousLanguage
    AgentMemoryStore.clear()
    AgentRuleStore.clear()
    AgentListStore.clear()
    AgentReminderStore.clear()
    super.tearDown()
  }

  // MARK: - Memory

  func testMemoryAdd() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .memory, text: "用户喜欢简洁回答", now: now
    )
    XCTAssertEqual(outcome, .memoryAdded(text: "用户喜欢简洁回答"))
    XCTAssertEqual(AgentMemoryStore.entries.count, 1)
  }

  func testMemoryDuplicateAndFull() async {
    _ = await LocalToolIntentHandler.handle(tool: .memory, text: "重复内容", now: now)
    let duplicate = await LocalToolIntentHandler.handle(tool: .memory, text: "重复内容", now: now)
    XCTAssertEqual(duplicate, .memoryDuplicate(text: "重复内容"))

    for index in 0..<AgentMemoryStore.maxCount {
      AgentMemoryStore.add(text: "记忆\(index)")
    }
    let full = await LocalToolIntentHandler.handle(tool: .memory, text: "新记忆", now: now)
    XCTAssertEqual(full, .memoryFull(text: "新记忆"))
  }

  // MARK: - Rule

  func testRuleAddDuplicateAndFull() async {
    let added = await LocalToolIntentHandler.handle(tool: .rule, text: "先讲结论", now: now)
    XCTAssertEqual(added, .ruleAdded(text: "先讲结论"))

    let duplicate = await LocalToolIntentHandler.handle(tool: .rule, text: "先讲结论", now: now)
    XCTAssertEqual(duplicate, .ruleDuplicate(text: "先讲结论"))

    for index in 0..<AgentRuleStore.maxCount {
      AgentRuleStore.add(text: "规则\(index)")
    }
    let full = await LocalToolIntentHandler.handle(tool: .rule, text: "新规则", now: now)
    XCTAssertEqual(full, .ruleFull(text: "新规则"))
  }

  // MARK: - List

  func testListAddAutoCreatesList() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .list, text: "牛奶", listName: "购物单", now: now
    )
    XCTAssertEqual(outcome, .listItemAdded(item: "牛奶", list: "购物单"))
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["牛奶"])
  }

  func testListAddUsesDefaultNameWhenMissing() async {
    let outcome = await LocalToolIntentHandler.handle(tool: .list, text: "吃药", now: now)
    guard case .listItemAdded(let item, let list) = outcome else {
      return XCTFail("预期 listItemAdded，实际 \(outcome)")
    }
    XCTAssertEqual(item, "吃药")
    XCTAssertFalse(list.isEmpty)
  }

  func testListDuplicate() async {
    _ = await LocalToolIntentHandler.handle(tool: .list, text: "牛奶", listName: "购物单", now: now)
    let outcome = await LocalToolIntentHandler.handle(tool: .list, text: "牛奶", listName: "购物单", now: now)
    XCTAssertEqual(outcome, .listItemDuplicate(item: "牛奶", list: "购物单"))
  }

  // MARK: - Reminder

  func testReminderSetWithMinutes() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "喝水", minutes: 10, now: now
    )
    XCTAssertEqual(
      outcome,
      .reminderSet(text: "喝水", fireDate: now.addingTimeInterval(600), repeatRule: .none)
    )
    XCTAssertEqual(AgentReminderStore.reminders.first?.fireDate, now.addingTimeInterval(600))
  }

  func testReminderSetWithChineseCommand() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "十分钟后提醒我喝水", now: now
    )
    XCTAssertEqual(
      outcome,
      .reminderSet(text: "喝水", fireDate: now.addingTimeInterval(600), repeatRule: .none)
    )
  }

  func testReminderDeniedWhenNoAuthorization() async {
    LocalToolIntentHandler.authorizationProvider = { false }
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "喝水", minutes: 10, now: now
    )
    XCTAssertEqual(outcome, .notificationsDenied)
    XCTAssertTrue(AgentReminderStore.reminders.isEmpty)
  }

  func testReminderCancelByText() async {
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "喝水", minutes: 10, now: now)
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "吃药", minutes: 20, now: now)
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "取消提醒喝水", now: now
    )
    XCTAssertEqual(outcome, .reminderCancelled(count: 1))
    XCTAssertEqual(AgentReminderStore.reminders.count, 1)
    XCTAssertEqual(AgentReminderStore.reminders.first?.text, "吃药")
  }

  func testReminderCompleteByText() async {
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "喝水", minutes: 10, now: now)
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "吃药", minutes: 20, now: now)
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "完成提醒喝水", now: now
    )
    XCTAssertEqual(outcome, .reminderCompleted(count: 1, target: "喝水"))
    XCTAssertEqual(AgentReminderStore.reminders.count, 1)
    XCTAssertEqual(AgentReminderStore.reminders.first?.text, "吃药")
  }

  func testReminderCompleteAll() async {
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "喝水", minutes: 10, now: now)
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "吃药", minutes: 20, now: now)
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "完成提醒", now: now
    )
    XCTAssertEqual(outcome, .reminderCompleted(count: 2, target: "喝水"))
    XCTAssertTrue(AgentReminderStore.reminders.isEmpty)
  }

  func testReminderCompleteNoMatch() async {
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "喝水", minutes: 10, now: now)
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "完成提醒开会", now: now
    )
    XCTAssertEqual(outcome, .reminderCompleted(count: 0, target: "开会"))
    XCTAssertEqual(AgentReminderStore.reminders.count, 1)
  }

  func testReminderQuery() async {
    _ = await LocalToolIntentHandler.handle(tool: .reminder, text: "喝水", minutes: 10, now: now)
    let outcome = await LocalToolIntentHandler.handle(tool: .reminder, text: "查看提醒", now: now)
    guard case .reminderQuery(let text) = outcome else {
      return XCTFail("预期 reminderQuery，实际 \(outcome)")
    }
    XCTAssertTrue(text.contains("喝水"))
  }

  func testReminderUnparseable() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .reminder, text: "hello world", now: now
    )
    XCTAssertEqual(outcome, .reminderUnparseable(text: "hello world"))
  }

  // MARK: - Calendar

  func testCalendarCreateViaSiri() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .calendar,
      text: "把明天下午3点产品评审加入日历",
      now: now,
      calendar: calendar
    )
    guard case .calendarReply(let text) = outcome else {
      return XCTFail("预期 calendarReply，实际 \(outcome)")
    }
    XCTAssertEqual(text, "已加入日历：明天 15:00-16:00 产品评审。")
    XCTAssertEqual(calendarProvider.createdEvent?.title, "产品评审")
    XCTAssertEqual(calendarProvider.createdEvent?.start, shDate(2026, 3, 8, 15))
    XCTAssertEqual(calendarProvider.createdEvent?.end, shDate(2026, 3, 8, 16))
  }

  func testCalendarQueryViaSiri() async {
    calendarProvider.events = [
      AgentCalendarEvent(
        title: "评审",
        start: shDate(2026, 3, 7, 14),
        end: shDate(2026, 3, 7, 15)
      ),
      AgentCalendarEvent(
        title: "健身",
        start: shDate(2026, 3, 7, 13),
        end: shDate(2026, 3, 7, 14)
      ),
    ]
    let outcome = await LocalToolIntentHandler.handle(
      tool: .calendar,
      text: "今天有什么安排",
      now: now,
      calendar: calendar
    )
    guard case .calendarReply(let text) = outcome else {
      return XCTFail("预期 calendarReply，实际 \(outcome)")
    }
    XCTAssertEqual(text, "今天 13:00-14:00 健身，今天 14:00-15:00 评审")
  }

  func testCalendarQueryEmptyViaSiri() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .calendar,
      text: "今天有什么安排",
      now: now,
      calendar: calendar
    )
    guard case .calendarReply(let text) = outcome else {
      return XCTFail("预期 calendarReply，实际 \(outcome)")
    }
    XCTAssertEqual(
      text,
      String(format: "agent.calendar.query.empty".localized, "agent.calendar.range.today".localized)
    )
  }

  func testCalendarDeniedViaSiri() async {
    calendarProvider.authorization = .denied
    let outcome = await LocalToolIntentHandler.handle(
      tool: .calendar,
      text: "今天有什么安排",
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(outcome, .calendarReply(text: "agent.calendar.denied".localized))
  }

  func testCalendarUnparseableViaSiri() async {
    let outcome = await LocalToolIntentHandler.handle(
      tool: .calendar,
      text: "随便说点什么",
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(outcome, .calendarUnparseable(text: "随便说点什么"))
  }

  // MARK: - Invalid

  func testInvalidEmptyContent() async {
    let outcome = await LocalToolIntentHandler.handle(tool: .memory, text: "   ", now: now)
    XCTAssertEqual(outcome, .invalid(text: "   "))
  }
}

/// 应答文案构造（不触碰存储）
final class LocalToolIntentFormatterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800)

  func testMemoryDialogs() {
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .memoryAdded(text: "喜欢简洁")),
      String(format: "agent.memory.remembered".localized, "喜欢简洁")
    )
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .memoryDuplicate(text: "x")),
      "agent.memory.remember.dup".localized
    )
  }

  func testListDialog() {
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .listItemAdded(item: "牛奶", list: "购物单")),
      AgentListResponseText.added(item: "牛奶", to: "购物单")
    )
  }

  func testReminderSetDialog() {
    let fireDate = now.addingTimeInterval(600)
    let dialog = LocalToolIntentFormatter.dialog(
      for: .reminderSet(text: "喝水", fireDate: fireDate, repeatRule: .none),
      now: now
    )
    XCTAssertTrue(dialog.contains("喝水"))
    XCTAssertTrue(dialog.contains("agent.reminder.time.minutes".localized(10)))
  }

  func testReminderQueryDialog() {
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .reminderQuery(text: "内容")),
      "内容"
    )
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .reminderUnparseable(text: "x")),
      "tools.intent.reminder.unparseable".localized
    )
  }

  func testCalendarDialogs() {
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .calendarReply(text: "今天 15:00 评审")),
      "今天 15:00 评审"
    )
    XCTAssertEqual(
      LocalToolIntentFormatter.dialog(for: .calendarUnparseable(text: "x")),
      "tools.intent.calendar.unparseable".localized
    )
  }
}

/// 本地化回归：本轮新增键在两种语言都存在，且两语言键集合一致
final class LocalizationKeysTests: XCTestCase {
  private let newKeys = [
    "tools.intent.title",
    "tools.intent.memory.full",
    "tools.intent.rule.dup",
    "tools.intent.reminder.unparseable",
    "tools.intent.calendar.unparseable",
    "tools.intent.list.default",
    "tools.intent.invalid",
    "gallery.brain.title",
    "gallery.brain.auto",
    "gallery.brain.cancel",
    "agent.reminder.action.snooze",
    "agent.reminder.action.complete",
    "agent.reminder.action.snoozed.text",
    "agent.settings.calendar.title",
    "agent.settings.calendar.status.authorized",
    "agent.settings.calendar.status.denied",
    "agent.settings.calendar.status.restricted",
    "agent.settings.calendar.status.notDetermined",
    "agent.settings.calendar.action.request",
    "agent.settings.calendar.action.settings",
    "agent.settings.calendar.footer",
    "agent.settings.calendar.footer.alertsOn",
    "agent.calendar.notify.toggle",
    "agent.calendar.notify.lead",
    "agent.calendar.notify.lead.minutes",
    "agent.calendar.notify.title",
  ]

  private func stringsDictionary(_ language: String) throws -> [String: String] {
    let path = try XCTUnwrap(
      Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
      "找不到 \(language) 的 Localizable.strings"
    )
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try XCTUnwrap(
      plist as? [String: String],
      "无法解析 \(language) 的 Localizable.strings"
    )
  }

  func testNewKeysPresentInBothLanguages() throws {
    for language in ["en", "zh-Hans"] {
      let dict = try stringsDictionary(language)
      for key in newKeys {
        XCTAssertNotNil(dict[key], "\(language) 缺少键 \(key)")
      }
    }
  }

  func testKeySetsIdenticalAcrossLanguages() throws {
    let en = Set(try stringsDictionary("en").keys)
    let zh = Set(try stringsDictionary("zh-Hans").keys)
    XCTAssertEqual(en, zh, "中英本地化键集合必须一致")
  }
}
