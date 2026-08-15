import Foundation
import XCTest

@testable import HyperMetaAI

/// 固定 UTC 日历，让绝对时间断言不依赖运行环境时区
private let utcCalendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}()

final class AgentReminderTimeParserTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC

  func testRelativeMinutes() {
    let match = AgentReminderTimeParser.parse(from: "十分钟后喝水", now: now, calendar: utcCalendar)
    XCTAssertEqual(match?.date.timeIntervalSince(now), 600)
    XCTAssertEqual(match?.consumedCount, 4)
  }

  func testRelativeArabicMinutes() {
    let match = AgentReminderTimeParser.parse(from: "10分钟后喝水", now: now, calendar: utcCalendar)
    XCTAssertEqual(match?.date.timeIntervalSince(now), 600)
  }

  func testRelativeHalfHourAndHours() {
    XCTAssertEqual(AgentReminderTimeParser.parse(from: "半小时后", now: now, calendar: utcCalendar)?.date.timeIntervalSince(now), 1800)
    XCTAssertEqual(AgentReminderTimeParser.parse(from: "半个小时", now: now, calendar: utcCalendar)?.date.timeIntervalSince(now), 1800)
    XCTAssertEqual(AgentReminderTimeParser.parse(from: "两小时后", now: now, calendar: utcCalendar)?.date.timeIntervalSince(now), 7200)
    XCTAssertEqual(AgentReminderTimeParser.parse(from: "三天后", now: now, calendar: utcCalendar)?.date.timeIntervalSince(now), 259_200)
  }

  func testAbsoluteClockTodayWhenInFuture() {
    let match = AgentReminderTimeParser.parse(from: "下午三点半喝水", now: now, calendar: utcCalendar)
    XCTAssertEqual(match?.date, now.addingTimeInterval(3.5 * 3600))
  }

  func testAbsoluteClockRollsToTomorrowWhenPassed() {
    let match = AgentReminderTimeParser.parse(from: "八点喝水", now: now, calendar: utcCalendar)
    XCTAssertEqual(match?.date, now.addingTimeInterval(20 * 3600), "今天 8 点已过应顺延到明天 8 点")
  }

  func testAbsoluteTomorrowMorning() {
    let match = AgentReminderTimeParser.parse(from: "明天早上八点开会", now: now, calendar: utcCalendar)
    XCTAssertEqual(match?.date, now.addingTimeInterval(20 * 3600))
  }

  func testAbsoluteTonightAndMinutes() {
    XCTAssertEqual(
      AgentReminderTimeParser.parse(from: "今晚九点", now: now, calendar: utcCalendar)?.date,
      now.addingTimeInterval(9 * 3600)
    )
    XCTAssertEqual(
      AgentReminderTimeParser.parse(from: "明天下午三点十五分", now: now, calendar: utcCalendar)?.date,
      now.addingTimeInterval(27.25 * 3600)
    )
  }

  func testUnsupportedTimeIsNil() {
    XCTAssertNil(AgentReminderTimeParser.parse(from: "喝水", now: now, calendar: utcCalendar))
    XCTAssertNil(AgentReminderTimeParser.parse(from: "明天", now: now, calendar: utcCalendar))
    XCTAssertNil(AgentReminderTimeParser.parse(from: "尽快", now: now, calendar: utcCalendar))
  }
}

final class AgentReminderCommandParserTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800)

  func testSetReminderWithPrefixFirst() {
    let command = AgentReminderCommandParser.parse("提醒我十分钟后喝水", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "喝水")
    XCTAssertEqual(fireDate.timeIntervalSince(now), 600)
    XCTAssertEqual(repeatRule, .none)
  }

  func testSetReminderWithTimeFirst() {
    let command = AgentReminderCommandParser.parse("明天早上八点提醒我开会", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "开会")
    XCTAssertEqual(fireDate.timeIntervalSince(now), 20 * 3600)
    XCTAssertEqual(repeatRule, .none)
  }

  func testSetReminderAbsoluteClock() {
    let command = AgentReminderCommandParser.parse("提醒我下午三点半吃药", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "吃药")
    XCTAssertEqual(fireDate.timeIntervalSince(now), 3.5 * 3600)
    XCTAssertEqual(repeatRule, .none)
  }

  func testDailyReminderWithTimeFirst() {
    let command = AgentReminderCommandParser.parse("每天八点提醒我吃药", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "吃药")
    // 12:00 UTC 已过今天 8 点 → 顺延到明天 8 点
    XCTAssertEqual(fireDate.timeIntervalSince(now), 20 * 3600)
    XCTAssertEqual(repeatRule, .daily)
  }

  func testDailyReminderWithPrefixFirst() {
    let command = AgentReminderCommandParser.parse("提醒我每天早上八点起床", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "起床")
    XCTAssertEqual(fireDate.timeIntervalSince(now), 20 * 3600)
    XCTAssertEqual(repeatRule, .daily)
  }

  func testWeeklyReminderWithWeekday() {
    // 2026-03-07 是周六，下一个周三 = +4 天，下午三点 = 15:00
    let command = AgentReminderCommandParser.parse("每周三下午三点提醒我汇报", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "汇报")
    XCTAssertEqual(fireDate.timeIntervalSince(now), 99 * 3600)
    XCTAssertEqual(repeatRule, .weekly)
  }

  func testWeeklyReminderPlainRollsSevenDays() {
    // 「每周八点」以今天（周六）为准，8 点已过 → 顺延 7 天
    let command = AgentReminderCommandParser.parse("每周八点提醒我吃药", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = command else {
      return XCTFail("应解析为 set: \(String(describing: command))")
    }
    XCTAssertEqual(text, "吃药")
    XCTAssertEqual(fireDate.timeIntervalSince(now), 164 * 3600)
    XCTAssertEqual(repeatRule, .weekly)
  }

  func testWeekdayAliases() {
    let sunday = AgentReminderCommandParser.parse("周日上午九点提醒我做礼拜", now: now, calendar: utcCalendar)
    guard case .set(let text, let fireDate, let repeatRule) = sunday else {
      return XCTFail("应解析为 set: \(String(describing: sunday))")
    }
    XCTAssertEqual(text, "做礼拜")
    XCTAssertEqual(repeatRule, .weekly)
    // 周六 → 周日 = +1 天，上午 9 点
    XCTAssertEqual(fireDate.timeIntervalSince(now), 21 * 3600)

    let wednesday = AgentReminderCommandParser.parse("星期三早上八点提醒我开会", now: now, calendar: utcCalendar)
    guard case .set(_, let wednesdayDate, _) = wednesday else {
      return XCTFail("应解析为 set: \(String(describing: wednesday))")
    }
    XCTAssertEqual(wednesdayDate.timeIntervalSince(now), 92 * 3600)
  }

  func testCancelReminders() {
    XCTAssertEqual(
      AgentReminderCommandParser.parse("取消提醒", now: now, calendar: utcCalendar),
      .cancel(text: nil)
    )
    XCTAssertEqual(
      AgentReminderCommandParser.parse("取消提醒喝水", now: now, calendar: utcCalendar),
      .cancel(text: "喝水")
    )
  }

  func testCompleteReminders() {
    XCTAssertEqual(
      AgentReminderCommandParser.parse("完成提醒", now: now, calendar: utcCalendar),
      .complete(text: nil)
    )
    XCTAssertEqual(
      AgentReminderCommandParser.parse("完成提醒喝水", now: now, calendar: utcCalendar),
      .complete(text: "喝水")
    )
    XCTAssertEqual(
      AgentReminderCommandParser.parse("提醒完成吃药", now: now, calendar: utcCalendar),
      .complete(text: "吃药")
    )
    XCTAssertEqual(
      AgentReminderCommandParser.parse("标记完成开会", now: now, calendar: utcCalendar),
      .complete(text: "开会")
    )
    // 「已完成」口语变体：目标可能带「提醒」字样，执行器按包含匹配
    XCTAssertEqual(
      AgentReminderCommandParser.parse("已完成提醒喝水", now: now, calendar: utcCalendar),
      .complete(text: "提醒喝水")
    )
    XCTAssertEqual(
      AgentReminderCommandParser.parse("标为完成", now: now, calendar: utcCalendar),
      .complete(text: nil)
    )
  }

  func testQueryReminders() {
    XCTAssertEqual(AgentReminderCommandParser.parse("有什么提醒", now: now, calendar: utcCalendar), .query)
    XCTAssertEqual(AgentReminderCommandParser.parse("提醒我什么", now: now, calendar: utcCalendar), .query)
  }

  func testPlainChatIsNotIntercepted() {
    XCTAssertNil(AgentReminderCommandParser.parse("今天天气怎么样", now: now, calendar: utcCalendar))
    XCTAssertNil(AgentReminderCommandParser.parse("提醒我", now: now, calendar: utcCalendar))
    XCTAssertNil(AgentReminderCommandParser.parse("定个提醒", now: now, calendar: utcCalendar))
    XCTAssertNil(AgentReminderCommandParser.parse("", now: now, calendar: utcCalendar))
  }
}

final class AgentReminderStoreTests: XCTestCase {
  override func setUp() {
    super.setUp()
    AgentReminderStore.clear()
  }

  override func tearDown() {
    AgentReminderStore.clear()
    super.tearDown()
  }

  func testAddAndRemove() {
    let reminder = AgentReminderStore.add(text: "喝水", fireDate: Date())
    XCTAssertNotNil(reminder)
    XCTAssertEqual(AgentReminderStore.reminders.count, 1)

    AgentReminderStore.remove(id: reminder!.id)
    XCTAssertTrue(AgentReminderStore.reminders.isEmpty)
  }

  func testRemoveMatchingText() {
    _ = AgentReminderStore.add(text: "喝水", fireDate: Date())
    _ = AgentReminderStore.add(text: "吃水果", fireDate: Date())
    XCTAssertEqual(AgentReminderStore.remove(matching: "喝水"), 1)
    XCTAssertEqual(AgentReminderStore.reminders.count, 1)
  }

  func testSortsByFireDate() {
    let later = AgentReminderStore.add(text: "晚", fireDate: Date().addingTimeInterval(3600))
    let earlier = AgentReminderStore.add(text: "早", fireDate: Date())
    XCTAssertEqual(AgentReminderStore.reminders.first?.id, earlier?.id)
    XCTAssertEqual(AgentReminderStore.reminders.last?.id, later?.id)
  }

  func testMaxLimit() {
    for index in 0..<AgentReminderStore.maxCount {
      XCTAssertNotNil(AgentReminderStore.add(text: "提醒\(index)", fireDate: Date()))
    }
    XCTAssertNil(AgentReminderStore.add(text: "超限", fireDate: Date()))
  }

  func testRepeatingReminderPersists() {
    let reminder = AgentReminderStore.add(
      text: "吃药",
      fireDate: Date().addingTimeInterval(3600),
      repeatRule: .daily
    )
    XCTAssertEqual(AgentReminderStore.reminders.first?.repeatRule, .daily)
    AgentReminderStore.remove(id: reminder!.id)
  }

  func testDecodesLegacyDataWithoutRepeatRule() throws {
    let legacy = """
    {"id":"\(UUID().uuidString)","text":"喝水","fireDate":\(Date().timeIntervalSince1970),"createdAt":\(Date().timeIntervalSince1970)}
    """
    let decoded = try JSONDecoder().decode(AgentReminder.self, from: Data(legacy.utf8))
    XCTAssertEqual(decoded.repeatRule, .none)
  }

  func testRoundTripsRepeatRule() throws {
    let reminder = AgentReminder(text: "吃药", fireDate: Date(), repeatRule: .weekly)
    let data = try JSONEncoder().encode(reminder)
    let decoded = try JSONDecoder().decode(AgentReminder.self, from: data)
    XCTAssertEqual(decoded.repeatRule, .weekly)
  }
}

final class AgentReminderScheduleBuilderTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800)

  func testOneShotUsesFullDateWithoutRepeat() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))
    let spec = AgentReminderScheduleBuilder.spec(for: reminder, calendar: utcCalendar)
    XCTAssertFalse(spec.repeats)
    XCTAssertNotNil(spec.components.year)
    XCTAssertNotNil(spec.components.month)
    XCTAssertNotNil(spec.components.day)
    XCTAssertEqual(spec.components.hour, 12)
    XCTAssertEqual(spec.components.minute, 10)
  }

  func testDailyRepeatsWithHourMinuteOnly() {
    let reminder = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(600), repeatRule: .daily)
    let spec = AgentReminderScheduleBuilder.spec(for: reminder, calendar: utcCalendar)
    XCTAssertTrue(spec.repeats)
    XCTAssertNil(spec.components.year)
    XCTAssertNil(spec.components.day)
    XCTAssertEqual(spec.components.hour, 12)
    XCTAssertEqual(spec.components.minute, 10)
  }

  func testWeeklyRepeatsWithWeekdayHourMinute() {
    let reminder = AgentReminder(text: "汇报", fireDate: now.addingTimeInterval(99 * 3600), repeatRule: .weekly)
    let spec = AgentReminderScheduleBuilder.spec(for: reminder, calendar: utcCalendar)
    XCTAssertTrue(spec.repeats)
    XCTAssertEqual(spec.components.weekday, 4) // 2026-03-11 是周三
    XCTAssertEqual(spec.components.hour, 15)
    XCTAssertEqual(spec.components.minute, 0)
  }
}

final class AgentReminderTimeFormatterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800)

  func testRelativeDescriptions() {
    XCTAssertEqual(
      AgentReminderTimeFormatter.relativeDescription(from: now.addingTimeInterval(30), now: now, calendar: utcCalendar),
      "agent.reminder.time.moment".localized
    )
    XCTAssertEqual(
      AgentReminderTimeFormatter.relativeDescription(from: now.addingTimeInterval(600), now: now, calendar: utcCalendar),
      String(format: "agent.reminder.time.minutes".localized, 10)
    )
    XCTAssertEqual(
      AgentReminderTimeFormatter.relativeDescription(from: now.addingTimeInterval(7200), now: now, calendar: utcCalendar),
      String(format: "agent.reminder.time.hours".localized, 2)
    )
  }

  func testTomorrowDescription() {
    let tomorrow = now.addingTimeInterval(20 * 3600)
    let description = AgentReminderTimeFormatter.relativeDescription(from: tomorrow, now: now, calendar: utcCalendar)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    XCTAssertEqual(description, "agent.reminder.time.tomorrow".localized(formatter.string(from: tomorrow)))
  }

  func testAnnouncementDescriptionForRepeating() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"

    let daily = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(20 * 3600), repeatRule: .daily)
    XCTAssertEqual(
      AgentReminderTimeFormatter.announcementDescription(for: daily, now: now, calendar: utcCalendar),
      String(format: "agent.reminder.time.repeating.daily".localized, formatter.string(from: daily.fireDate))
    )

    let weekly = AgentReminder(text: "汇报", fireDate: now.addingTimeInterval(99 * 3600), repeatRule: .weekly)
    XCTAssertEqual(
      AgentReminderTimeFormatter.announcementDescription(for: weekly, now: now, calendar: utcCalendar),
      String(format: "agent.reminder.time.repeating.weekly".localized, formatter.string(from: weekly.fireDate))
    )
  }

  func testRepeatBadge() {
    XCTAssertEqual(AgentReminderTimeFormatter.repeatBadge(.none), "")
    XCTAssertEqual(AgentReminderTimeFormatter.repeatBadge(.daily), "agent.reminder.repeat.daily".localized)
    XCTAssertEqual(AgentReminderTimeFormatter.repeatBadge(.weekly), "agent.reminder.repeat.weekly".localized)
  }
}

final class AgentHomeReminderCardMappingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800)

  private func clockText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }

  func testEmptyShowsPlaceholder() {
    let content = AgentHomeReminderCardMapping.content(
      reminders: [],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertTrue(content.isPlaceholder)
    XCTAssertEqual(content.line, "home.reminder.empty".localized)
  }

  func testSingleReminderUsesRelativeTime() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))
    let content = AgentHomeReminderCardMapping.content(
      reminders: [reminder],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertFalse(content.isPlaceholder)
    XCTAssertEqual(content.line, String(format: "agent.reminder.time.minutes".localized, 10))
  }

  func testMomentUsesMomentText() {
    let reminder = AgentReminder(text: "马上", fireDate: now.addingTimeInterval(30))
    let content = AgentHomeReminderCardMapping.content(
      reminders: [reminder],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(content.line, "agent.reminder.time.moment".localized)
  }

  func testDailyShowsClock() {
    let reminder = AgentReminder(
      text: "吃药",
      fireDate: now.addingTimeInterval(20 * 3600),
      repeatRule: .daily
    )
    let content = AgentHomeReminderCardMapping.content(
      reminders: [reminder],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(
      content.line,
      String(format: "agent.reminder.time.repeating.daily".localized, clockText(reminder.fireDate))
    )
  }

  func testWeeklyShowsClock() {
    let reminder = AgentReminder(
      text: "汇报",
      fireDate: now.addingTimeInterval(99 * 3600),
      repeatRule: .weekly
    )
    let content = AgentHomeReminderCardMapping.content(
      reminders: [reminder],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(
      content.line,
      String(format: "agent.reminder.time.repeating.weekly".localized, clockText(reminder.fireDate))
    )
  }

  func testPicksEarliestFireDate() {
    let later = AgentReminder(text: "晚", fireDate: now.addingTimeInterval(7200))
    let earlier = AgentReminder(text: "早", fireDate: now.addingTimeInterval(600))
    let content = AgentHomeReminderCardMapping.content(
      reminders: [later, earlier],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(content.line, String(format: "agent.reminder.time.minutes".localized, 10))
  }

  func testCountIncludesActiveRemindersOnly() {
    // 未来单次 + 周期 + 已过单次（不计）
    let content = AgentHomeReminderCardMapping.content(
      reminders: [
        AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600)),
        AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(3600), repeatRule: .daily),
        AgentReminder(text: "过期", fireDate: now.addingTimeInterval(-600)),
      ],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(content.count, 2)
  }

  func testCountEmptyIsZero() {
    let content = AgentHomeReminderCardMapping.content(
      reminders: [],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(content.count, 0)
  }
}

final class AgentReminderDisplayMappingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC

  private func reminder(
    text: String = "喝水",
    offset: TimeInterval,
    repeatRule: AgentReminderRepeat = .none
  ) -> AgentReminder {
    AgentReminder(text: text, fireDate: now.addingTimeInterval(offset), repeatRule: repeatRule)
  }

  func testHasActiveReminders() {
    XCTAssertFalse(AgentReminderDisplayMapping.hasActiveReminders([], now: now))
    XCTAssertFalse(
      AgentReminderDisplayMapping.hasActiveReminders([reminder(text: "过期", offset: -60)], now: now),
      "过期的单次提醒不算活动"
    )
    XCTAssertTrue(
      AgentReminderDisplayMapping.hasActiveReminders([reminder(text: "喝水", offset: 600)], now: now)
    )
    XCTAssertTrue(
      AgentReminderDisplayMapping.hasActiveReminders([reminder(text: "边界", offset: 0)], now: now),
      "恰好到点的提醒仍算活动"
    )
    XCTAssertTrue(
      AgentReminderDisplayMapping.hasActiveReminders(
        [reminder(text: "周期", offset: -3600, repeatRule: .daily)],
        now: now
      ),
      "周期提醒下次仍会触发，永远有效"
    )
  }

  func testUpcomingFiltersSortsAndLimits() {
    let expired = reminder(text: "过期", offset: -60)
    let later = reminder(text: "晚", offset: 3600)
    let sooner = reminder(text: "早", offset: 300)
    let repeating = reminder(text: "周期", offset: -3600, repeatRule: .weekly)

    let all = AgentReminderDisplayMapping.upcoming(
      [expired, later, sooner, repeating],
      now: now,
      limit: 10
    )
    XCTAssertEqual(
      all.map(\.text),
      ["周期", "早", "晚"],
      "过滤过期的单次提醒；周期提醒（fireDate 为最近一次触发，可能已过）保留，按 fireDate 升序"
    )

    let limited = AgentReminderDisplayMapping.upcoming(
      [sooner, later, repeating],
      now: now,
      limit: 2
    )
    XCTAssertEqual(limited.map(\.text), ["周期", "早"], "limit 生效")
  }

  func testMenuLabel() {
    XCTAssertEqual(
      AgentReminderDisplayMapping.menuLabel(for: AgentReminder(text: "  ", fireDate: now)),
      "Reminder",
      "空内容回退固定标签"
    )
    XCTAssertEqual(
      AgentReminderDisplayMapping.menuLabel(for: AgentReminder(text: "喝水", fireDate: now)),
      "喝水"
    )
    let long = AgentReminder(text: "去楼下拿快递并拍照", fireDate: now)
    XCTAssertEqual(
      AgentReminderDisplayMapping.menuLabel(for: long),
      "去楼下拿快递并拍…",
      "超长内容截断加省略号"
    )
  }

  func testResultTextContainsTimeAndContent() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))
    let text = AgentReminderDisplayMapping.resultText(for: reminder, now: now)
    XCTAssertTrue(text.contains("喝水"))
    XCTAssertTrue(text.contains(String(format: "agent.reminder.time.minutes".localized, 10)))
  }
}

final class ReminderNotificationPresenterTests: XCTestCase {

  func testIsReminder() {
    XCTAssertTrue(ReminderNotificationPresenter.isReminder([ReminderNotificationPresenter.userInfoKey: true]))
    XCTAssertFalse(ReminderNotificationPresenter.isReminder([ReminderNotificationPresenter.userInfoKey: false]))
    XCTAssertFalse(ReminderNotificationPresenter.isReminder(["other": true]))
    XCTAssertFalse(ReminderNotificationPresenter.isReminder([:]))
    XCTAssertFalse(ReminderNotificationPresenter.isReminder(nil))
  }

  func testAnnouncementText() {
    XCTAssertEqual(
      ReminderNotificationPresenter.announcementText(for: "吃药"),
      String(format: "agent.reminder.notification.body".localized, "吃药")
    )
  }
}

final class AgentReminderNotificationActionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC（周六）

  func testIdentifiersStable() {
    XCTAssertEqual(AgentReminderNotificationAction.categoryIdentifier, "agent.reminder.category")
    XCTAssertEqual(AgentReminderNotificationAction.snoozeIdentifier, "agent.reminder.action.snooze")
    XCTAssertEqual(AgentReminderNotificationAction.tomorrowIdentifier, "agent.reminder.action.tomorrow")
    XCTAssertEqual(AgentReminderNotificationAction.completeIdentifier, "agent.reminder.action.complete")
    XCTAssertEqual(AgentReminderNotificationAction.replyIdentifier, "agent.reminder.action.reply")
    XCTAssertEqual(AgentReminderNotificationAction.snoozeMinutes, 10)
  }

  func testActionsIncludeTomorrowAndReplyTextInput() {
    let ids = AgentReminderNotificationAction.actions.map(\.identifier)
    XCTAssertEqual(ids.count, 4)
    XCTAssertEqual(ids[0], AgentReminderNotificationAction.snoozeIdentifier)
    XCTAssertEqual(ids[1], AgentReminderNotificationAction.tomorrowIdentifier)
    XCTAssertEqual(ids[2], AgentReminderNotificationAction.completeIdentifier)
    XCTAssertEqual(ids[3], AgentReminderNotificationAction.replyIdentifier)
    let tomorrow = AgentReminderNotificationAction.actions[1]
    XCTAssertTrue(tomorrow.options.isEmpty, "明天提醒为后台静默重排，无需打开 App")
    let reply = AgentReminderNotificationAction.replyAction
    XCTAssertTrue(reply.options.contains(.foreground), "回复需打开 App 呈现语音页")
  }

  func testReplyTextTrimsAndRejectsBlank() {
    XCTAssertEqual(AgentReminderNotificationAction.replyText(from: "  帮我把牛奶加到购物单  "), "帮我把牛奶加到购物单")
    XCTAssertNil(AgentReminderNotificationAction.replyText(from: nil))
    XCTAssertNil(AgentReminderNotificationAction.replyText(from: ""))
    XCTAssertNil(AgentReminderNotificationAction.replyText(from: "   "))
  }

  func testFindReminderByNotificationIdentifier() {
    let a = AgentReminder(text: "喝水", fireDate: now)
    let b = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(600))
    XCTAssertEqual(
      AgentReminderNotificationAction.reminder(in: [a, b], notificationIdentifier: b.id.uuidString),
      b
    )
    XCTAssertNil(
      AgentReminderNotificationAction.reminder(in: [a], notificationIdentifier: UUID().uuidString)
    )
  }

  func testSnoozeOneShotAddsTenMinutes() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(60))
    let snoozed = AgentReminderNotificationAction.snoozed(reminder, minutes: 10, now: now, calendar: utcCalendar)
    XCTAssertEqual(snoozed.fireDate, now.addingTimeInterval(660))
    XCTAssertEqual(snoozed.id, reminder.id)
    XCTAssertEqual(snoozed.text, reminder.text)
    XCTAssertEqual(snoozed.repeatRule, .none)
  }

  func testSnoozeOneShotWhenResponseLateUsesNow() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(-3600))
    let snoozed = AgentReminderNotificationAction.snoozed(reminder, minutes: 10, now: now, calendar: utcCalendar)
    XCTAssertEqual(snoozed.fireDate, now.addingTimeInterval(600), "响应晚于触发时间时从当前时间起算")
  }

  func testSnoozeDailySkipsToNextOccurrence() {
    // 每天 09:00，今天 09:00 已触发，稍后提醒应跳过今天落到明天 09:00
    let fireDate = now.addingTimeInterval(-3 * 3600)
    let reminder = AgentReminder(text: "晨会", fireDate: fireDate, repeatRule: .daily)
    let snoozed = AgentReminderNotificationAction.snoozed(reminder, minutes: 10, now: now, calendar: utcCalendar)
    XCTAssertEqual(snoozed.fireDate, now.addingTimeInterval(21 * 3600), "明天 09:00 UTC")
    XCTAssertEqual(snoozed.repeatRule, .daily, "周期提醒保留重复规则")
  }

  func testSnoozeWeeklySkipsToNextWeekdayOccurrence() {
    // 每周六 11:00，今天 11:00 已触发，稍后提醒应落到下周六 11:00
    let fireDate = now.addingTimeInterval(-3600)
    let reminder = AgentReminder(text: "例会", fireDate: fireDate, repeatRule: .weekly)
    let snoozed = AgentReminderNotificationAction.snoozed(reminder, minutes: 10, now: now, calendar: utcCalendar)
    XCTAssertEqual(snoozed.fireDate, now.addingTimeInterval((7 * 24 - 1) * 3600), "下周六 11:00 UTC")
    XCTAssertEqual(snoozed.repeatRule, .weekly)
  }

  func testTomorrowOneShotMovesToSameTimeNextDay() {
    // 2026-03-07 15:30 UTC → 2026-03-08 15:30 UTC（保持原时刻）
    let fireDate = utcCalendar.date(
      from: DateComponents(year: 2026, month: 3, day: 7, hour: 15, minute: 30)
    )!
    let reminder = AgentReminder(text: "喝水", fireDate: fireDate)
    let rescheduled = AgentReminderNotificationAction.tomorrow(reminder, calendar: utcCalendar)
    let components = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: rescheduled.fireDate
    )
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 3)
    XCTAssertEqual(components.day, 8, "明天同一时刻")
    XCTAssertEqual(components.hour, 15)
    XCTAssertEqual(components.minute, 30)
    XCTAssertEqual(rescheduled.id, reminder.id)
    XCTAssertEqual(rescheduled.text, reminder.text)
    XCTAssertEqual(rescheduled.repeatRule, .none)
  }

  func testTomorrowAcrossMonthBoundary() {
    // 2026-08-31 23:00 UTC → 2026-09-01 23:00 UTC（日历日加法跨月正确）
    let fireDate = utcCalendar.date(
      from: DateComponents(year: 2026, month: 8, day: 31, hour: 23, minute: 0)
    )!
    let reminder = AgentReminder(text: "月末", fireDate: fireDate)
    let rescheduled = AgentReminderNotificationAction.tomorrow(reminder, calendar: utcCalendar)
    let components = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: rescheduled.fireDate
    )
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 9)
    XCTAssertEqual(components.day, 1)
    XCTAssertEqual(components.hour, 23)
    XCTAssertEqual(components.minute, 0)
  }

  func testTomorrowPreservesDailyRepeatRule() {
    let fireDate = now.addingTimeInterval(3 * 3600) // 今天 15:00 UTC
    let reminder = AgentReminder(text: "晨会", fireDate: fireDate, repeatRule: .daily)
    let rescheduled = AgentReminderNotificationAction.tomorrow(reminder, calendar: utcCalendar)
    XCTAssertEqual(rescheduled.fireDate, fireDate.addingTimeInterval(24 * 3600), "明天同一时刻")
    XCTAssertEqual(rescheduled.repeatRule, .daily, "周期提醒保留重复规则")
  }

  func testOutcomeTomorrowCarriesUpdatedReminder() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(60))
    let result = AgentReminderNotificationAction.outcome(
      actionIdentifier: AgentReminderNotificationAction.tomorrowIdentifier,
      notificationIdentifier: reminder.id.uuidString,
      reminders: [reminder],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(
      result,
      .tomorrow(AgentReminderNotificationAction.tomorrow(reminder, calendar: utcCalendar))
    )
  }

  func testOutcomeSnoozeCarriesUpdatedReminder() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(60))
    let result = AgentReminderNotificationAction.outcome(
      actionIdentifier: AgentReminderNotificationAction.snoozeIdentifier,
      notificationIdentifier: reminder.id.uuidString,
      reminders: [reminder],
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(
      result,
      .snoozed(AgentReminderNotificationAction.snoozed(reminder, minutes: 10, now: now, calendar: utcCalendar))
    )
  }

  func testOutcomeCompleteCarriesReminder() {
    let reminder = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(600))
    XCTAssertEqual(
      AgentReminderNotificationAction.outcome(
        actionIdentifier: AgentReminderNotificationAction.completeIdentifier,
        notificationIdentifier: reminder.id.uuidString,
        reminders: [reminder],
        now: now,
        calendar: utcCalendar
      ),
      .completed(reminder)
    )
  }

  func testOutcomeIgnoresUnknownActionOrUnknownReminder() {
    let reminder = AgentReminder(text: "喝水", fireDate: now)
    XCTAssertEqual(
      AgentReminderNotificationAction.outcome(
        actionIdentifier: "unknown.action",
        notificationIdentifier: reminder.id.uuidString,
        reminders: [reminder],
        now: now,
        calendar: utcCalendar
      ),
      .ignored
    )
    XCTAssertEqual(
      AgentReminderNotificationAction.outcome(
        actionIdentifier: AgentReminderNotificationAction.completeIdentifier,
        notificationIdentifier: UUID().uuidString,
        reminders: [reminder],
        now: now,
        calendar: utcCalendar
      ),
      .ignored
    )
  }
}


// MARK: - 主页双卡刷新信号（提醒数据变更广播）

final class AgentHomeCardRefreshCenterTests: XCTestCase {
  override func setUp() {
    super.setUp()
    AgentReminderStore.clear()
  }

  override func tearDown() {
    AgentReminderStore.clear()
    super.tearDown()
  }

  func testPostDeliversRefreshSignal() {
    let expectation = expectation(
      forNotification: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      handler: nil
    )
    AgentHomeCardRefreshCenter.post()
    wait(for: [expectation], timeout: 1)
  }

  func testReminderAddPostsRefreshSignal() {
    let expectation = expectation(
      forNotification: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      handler: nil
    )
    AgentReminderStore.add(text: "喝水", fireDate: Date())
    wait(for: [expectation], timeout: 1)
  }

  func testReminderRemovePostsRefreshSignal() throws {
    let reminder = try XCTUnwrap(AgentReminderStore.add(text: "喝水", fireDate: Date()))
    let expectation = expectation(
      forNotification: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      handler: nil
    )
    AgentReminderStore.remove(id: reminder.id)
    wait(for: [expectation], timeout: 1)
  }

  func testReminderClearPostsRefreshSignal() {
    _ = AgentReminderStore.add(text: "喝水", fireDate: Date())
    let expectation = expectation(
      forNotification: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      handler: nil
    )
    AgentReminderStore.clear()
    wait(for: [expectation], timeout: 1)
  }
}


// MARK: - 设置页「稍后提醒」滑动动作策略

final class AgentReminderSnoozePolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC

  private func reminder(
    text: String = "喝水",
    fireDate: Date,
    repeatRule: AgentReminderRepeat = .none
  ) -> AgentReminder {
    AgentReminder(text: text, fireDate: fireDate, repeatRule: repeatRule)
  }

  func testCanSnoozeOnlyForExpiredOneTimeReminder() {
    XCTAssertTrue(AgentReminderSnoozePolicy.canSnooze(
      reminder(fireDate: now.addingTimeInterval(-300)),
      now: now
    ))
    XCTAssertFalse(AgentReminderSnoozePolicy.canSnooze(
      reminder(fireDate: now.addingTimeInterval(3600)),
      now: now
    ))
    XCTAssertFalse(AgentReminderSnoozePolicy.canSnooze(
      reminder(fireDate: now.addingTimeInterval(-300), repeatRule: .daily),
      now: now
    ))
    XCTAssertFalse(AgentReminderSnoozePolicy.canSnooze(
      reminder(fireDate: now.addingTimeInterval(-300), repeatRule: .weekly),
      now: now
    ))
  }

  func testSnoozedOneTimeFromNowWhenLate() {
    let updated = AgentReminderSnoozePolicy.snoozed(
      reminder(fireDate: now.addingTimeInterval(-300)),
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(updated.fireDate.timeIntervalSince(now), 600)
    XCTAssertEqual(updated.repeatRule, .none)
  }

  func testSnoozedDailySkipsToNextOccurrence() {
    // fireDate 11:00 已过，now 12:00 → 稍后 10 分钟后的下一次 11:00（次日）
    let fire = Date(timeIntervalSince1970: 1_772_881_200) // 2026-03-07 11:00 UTC
    let updated = AgentReminderSnoozePolicy.snoozed(
      reminder(fireDate: fire, repeatRule: .daily),
      now: now,
      calendar: utcCalendar
    )
    let expected = Date(timeIntervalSince1970: 1_772_967_600) // 2026-03-08 11:00 UTC
    XCTAssertEqual(updated.fireDate, expected)
    XCTAssertEqual(updated.repeatRule, .daily)
  }

  func testSnoozedOneTimeInFutureStillDefers() {
    // 未到点提醒理论上不出现该动作；策略仍按通知 Action 语义从触发时间延后
    let updated = AgentReminderSnoozePolicy.snoozed(
      reminder(fireDate: now.addingTimeInterval(1200)),
      now: now,
      calendar: utcCalendar
    )
    XCTAssertEqual(updated.fireDate.timeIntervalSince(now), 1800)
  }
}

/// 提醒「完成」反馈文案（中文断言：固定语言 + @MainActor）
@MainActor
final class AgentReminderCompletionTextTests: XCTestCase {
  private var previousLanguage: AppLanguage!
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
  }

  override func tearDown() {
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  func testCompletedText() {
    XCTAssertEqual(AgentReminderCompletion.completedText(for: "喝水"), "已完成：喝水")
  }

  func testCompletedAllText() {
    XCTAssertEqual(AgentReminderCompletion.completedAllText(count: 1), "已完成 1 条提醒。")
    XCTAssertEqual(AgentReminderCompletion.completedAllText(count: 3), "已完成 3 条提醒。")
  }

  func testNoneTexts() {
    XCTAssertEqual(
      AgentReminderCompletion.noneText(for: "喝水"),
      "没有找到可完成的提醒：喝水"
    )
    XCTAssertEqual(AgentReminderCompletion.noneAnyText(), "没有可完成的提醒。")
  }
}

/// 镜片提醒操作执行器（@MainActor：中文断言固定语言）
@MainActor
final class AgentReminderLensActionTests: XCTestCase {
  private var previousLanguage: AppLanguage!
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
    AgentReminderStore.clear()
  }

  override func tearDown() {
    AgentReminderStore.clear()
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func addReminder(_ text: String, minutes: Int = 10) -> AgentReminder {
    AgentReminderStore.add(text: text, fireDate: now.addingTimeInterval(TimeInterval(minutes * 60)))!
  }

  func testCompleteRemovesAndAnnounces() {
    let reminder = addReminder("喝水")
    let announcement = AgentReminderLensAction.complete(reminder)
    XCTAssertEqual(announcement, "已完成：喝水")
    XCTAssertTrue(AgentReminderStore.reminders.isEmpty)
  }

  func testDeleteRemovesAndAnnounces() {
    let reminder = addReminder("吃药")
    let announcement = AgentReminderLensAction.delete(reminder)
    XCTAssertEqual(announcement, "已删除提醒：吃药")
    XCTAssertTrue(AgentReminderStore.reminders.isEmpty)
  }

  func testActionsKeepOtherReminders() {
    _ = addReminder("喝水", minutes: 10)
    let other = addReminder("吃药", minutes: 20)
    _ = AgentReminderLensAction.complete(other)
    XCTAssertEqual(AgentReminderStore.reminders.count, 1)
    XCTAssertEqual(AgentReminderStore.reminders.first?.text, "喝水")
  }

  func testActionOnMissingReminderReturnsNil() {
    let reminder = addReminder("喝水")
    _ = AgentReminderLensAction.complete(reminder)
    XCTAssertNil(AgentReminderLensAction.complete(reminder), "重复完成应返回 nil")
    XCTAssertNil(AgentReminderLensAction.delete(reminder), "已移除提醒删除应返回 nil")
  }
}
