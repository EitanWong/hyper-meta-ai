import Foundation
import XCTest

@testable import HyperMetaAI

/// 桌面小组件快照：构造 / 共享存储往返（纯逻辑，不触达 Widget 渲染）
@MainActor
final class AgentWidgetSnapshotTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()
  private var previousLanguage: AppLanguage = .system

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
  }

  override func tearDown() {
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func make(
    reminders: [AgentReminder] = [],
    active: Bool = false,
    task: String = "",
    calendarEvents: [AgentCalendarEvent] = []
  ) -> AgentWidgetSnapshot {
    AgentWidgetSnapshot.make(
      reminders: reminders,
      isVoiceSessionActive: active,
      taskSummary: task,
      calendarEvents: calendarEvents,
      now: now,
      calendar: calendar
    )
  }

  func testEmptyRemindersShowEmptyState() {
    let snapshot = make()
    XCTAssertEqual(snapshot.nextReminderText, "agent.widget.noReminder".localized)
    XCTAssertEqual(snapshot.nextReminderDetail, "")
    XCTAssertFalse(snapshot.hasReminder)
    XCTAssertEqual(snapshot.reminderCount, 0)
    XCTAssertFalse(snapshot.isVoiceSessionActive)
    XCTAssertEqual(snapshot.taskSummary, "")
  }

  func testPicksEarliestReminder() {
    let later = AgentReminder(text: "晚", fireDate: now.addingTimeInterval(3600))
    let sooner = AgentReminder(text: "早", fireDate: now.addingTimeInterval(600))
    let snapshot = make(reminders: [later, sooner])
    XCTAssertEqual(snapshot.nextReminderText, "早")
    XCTAssertEqual(snapshot.nextReminderDetail, "agent.reminder.time.minutes".localized(10))
    XCTAssertTrue(snapshot.hasReminder)
    XCTAssertEqual(snapshot.reminderCount, 2)
  }

  func testRepeatingReminderCountsAsNextEvenIfExpired() {
    let expired = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(-3600), repeatRule: .daily)
    let snapshot = make(reminders: [expired])
    XCTAssertEqual(snapshot.nextReminderText, "吃药")
    XCTAssertTrue(snapshot.hasReminder)
  }

  func testExpiredOneShotShowsEmptyStateButKeepsCount() {
    let expired = AgentReminder(text: "过期", fireDate: now.addingTimeInterval(-60))
    let snapshot = make(reminders: [expired])
    XCTAssertFalse(snapshot.hasReminder)
    XCTAssertEqual(snapshot.nextReminderText, "agent.widget.noReminder".localized)
    XCTAssertEqual(snapshot.reminderCount, 1)
  }

  func testVoiceButtonTitleFollowsActiveState() {
    XCTAssertEqual(
      make(active: true).voiceButtonTitle,
      "agent.widget.voice.stop".localized
    )
    XCTAssertEqual(
      make(active: false).voiceButtonTitle,
      "agent.widget.voice.start".localized
    )
  }

  func testTaskSummaryCarriedThrough() {
    XCTAssertEqual(make(task: "整理报告").taskSummary, "整理报告")
  }

  func testPicksNextCalendarEventWithinWindow() {
    let allDay = AgentCalendarEvent(
      title: "全天",
      start: now.addingTimeInterval(3600),
      end: now.addingTimeInterval(7200),
      isAllDay: true
    )
    let later = AgentCalendarEvent(
      title: "评审",
      start: now.addingTimeInterval(7200),
      end: now.addingTimeInterval(10800)
    )
    let far = AgentCalendarEvent(
      title: "太远",
      start: now.addingTimeInterval(25 * 3600),
      end: now.addingTimeInterval(26 * 3600)
    )
    let snapshot = make(calendarEvents: [allDay, later, far])
    XCTAssertEqual(snapshot.nextCalendarText, "评审")
    XCTAssertEqual(snapshot.nextCalendarDetail, "14:00")
    XCTAssertTrue(snapshot.hasCalendar)
  }

  func testCalendarEmptyWithoutEvents() {
    let snapshot = make()
    XCTAssertEqual(snapshot.nextCalendarText, "")
    XCTAssertEqual(snapshot.nextCalendarDetail, "")
    XCTAssertFalse(snapshot.hasCalendar)
  }

  func testCalendarTitleFallsBackForEmptyTitle() {
    let event = AgentCalendarEvent(
      title: "  ",
      start: now.addingTimeInterval(3600),
      end: now.addingTimeInterval(7200)
    )
    let snapshot = make(calendarEvents: [event])
    XCTAssertEqual(snapshot.nextCalendarText, "agent.widget.calendar.event".localized)
  }

  func testCalendarTomorrowDetail() {
    let event = AgentCalendarEvent(
      title: "晨会",
      start: now.addingTimeInterval(21 * 3600),
      end: now.addingTimeInterval(22 * 3600)
    )
    let snapshot = make(calendarEvents: [event])
    XCTAssertEqual(snapshot.nextCalendarDetail, "agent.widget.calendar.tomorrow".localized("09:00"))
  }

  func testCalendarLaterDateDetail() {
    let later = now.addingTimeInterval(3 * 86_400)
    XCTAssertEqual(
      AgentWidgetCalendarFormatter.detail(for: later, now: now, calendar: calendar),
      "3月10日 12:00"
    )
  }

  func testAccessoryFallsBackToCalendarWhenNoReminderOrTask() {
    let event = AgentCalendarEvent(
      title: "评审",
      start: now.addingTimeInterval(7200),
      end: now.addingTimeInterval(10800)
    )
    let snapshot = make(calendarEvents: [event])
    XCTAssertEqual(snapshot.accessoryTitle, "agent.widget.calendar.next".localized)
    XCTAssertEqual(snapshot.accessoryBody, "14:00 评审")
    XCTAssertEqual(snapshot.accessoryDetail, "")
    XCTAssertEqual(
      snapshot.accessoryInlineText,
      "agent.widget.accessory.inline.next".localized("14:00 评审")
    )
  }

  func testAccessoryReminderTakesPriorityOverCalendar() {
    let event = AgentCalendarEvent(
      title: "评审",
      start: now.addingTimeInterval(7200),
      end: now.addingTimeInterval(10800)
    )
    let snapshot = make(
      reminders: [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))],
      calendarEvents: [event]
    )
    XCTAssertEqual(snapshot.accessoryTitle, "agent.widget.accessory.nextReminder".localized)
    XCTAssertEqual(snapshot.accessoryBody, "喝水")
    XCTAssertEqual(snapshot.accessoryDetail, "agent.reminder.time.minutes".localized(10))
    XCTAssertEqual(snapshot.accessoryInlineText, "agent.widget.accessory.inline.next".localized("喝水"))
  }

  func testAccessoryFieldsPreferTaskWhenRunning() {
    let snapshot = make(
      reminders: [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))],
      task: "整理报告"
    )
    XCTAssertEqual(snapshot.accessoryTitle, "agent.widget.accessory.task".localized)
    XCTAssertEqual(snapshot.accessoryBody, "整理报告")
    XCTAssertEqual(snapshot.accessoryDetail, "")
    XCTAssertEqual(snapshot.accessoryInlineText, "整理报告")
  }

  func testAccessoryFieldsFallBackToNextReminder() {
    let snapshot = make(
      reminders: [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))]
    )
    XCTAssertEqual(snapshot.accessoryTitle, "agent.widget.accessory.nextReminder".localized)
    XCTAssertEqual(snapshot.accessoryBody, "喝水")
    XCTAssertEqual(snapshot.accessoryDetail, "agent.reminder.time.minutes".localized(10))
    XCTAssertEqual(
      snapshot.accessoryInlineText,
      "agent.widget.accessory.inline.next".localized("喝水")
    )
  }

  func testAccessoryFieldsShowEmptyStateWithoutTaskOrReminder() {
    let snapshot = make()
    XCTAssertEqual(snapshot.accessoryTitle, "agent.widget.accessory.empty".localized)
    XCTAssertEqual(snapshot.accessoryBody, "agent.widget.noReminder".localized)
    XCTAssertEqual(snapshot.accessoryDetail, "")
    XCTAssertEqual(snapshot.accessoryInlineText, "agent.widget.accessory.empty".localized)
  }

  func testAccessoryFieldsCoverTaskWithoutReminders() {
    let snapshot = make(task: "写周报")
    XCTAssertEqual(snapshot.accessoryTitle, "agent.widget.accessory.task".localized)
    XCTAssertEqual(snapshot.accessoryBody, "写周报")
    XCTAssertEqual(snapshot.accessoryInlineText, "写周报")
    XCTAssertEqual(snapshot.accessoryDetail, "")
  }

  func testSnapshotRoundTripThroughAppGroupDefaults() {
    AgentWidgetSnapshotStore.clear()
    defer { AgentWidgetSnapshotStore.clear() }

    let snapshot = make(
      reminders: [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))],
      active: true,
      task: "写周报",
      calendarEvents: [AgentCalendarEvent(
        title: "评审",
        start: now.addingTimeInterval(7200),
        end: now.addingTimeInterval(10800)
      )]
    )
    XCTAssertNil(AgentWidgetSnapshotStore.read(), "写入前应为空")

    AgentWidgetSnapshotStore.write(snapshot)
    XCTAssertEqual(AgentWidgetSnapshotStore.read(), snapshot)

    AgentWidgetSnapshotStore.clear()
    XCTAssertNil(AgentWidgetSnapshotStore.read())
  }
}
