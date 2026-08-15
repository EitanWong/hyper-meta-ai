import XCTest
@testable import HyperMetaAI

// MARK: - 固定时间基准（2026-08-12 是星期三）

enum AgentCalendarTestClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2 // 周一为一周起点（中文习惯）
        return calendar
    }

    static let now = Date(timeIntervalSince1970: 1_786_500_000) // 2026-08-12 10:00 +0800

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: components)!
    }
}

// MARK: - 指令解析

final class AgentCalendarCommandParserTests: XCTestCase {

  func testCreateSuffixDrivenWithTimeAtStart() throws {
    let command = AgentCalendarCommandParser.parse(
      "把明天下午3点产品评审加入日历",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    let expected = AgentCalendarCommand.create(
      title: "产品评审",
      start: AgentCalendarTestClock.date(2026, 8, 13, 15),
      end: AgentCalendarTestClock.date(2026, 8, 13, 16)
    )
    XCTAssertEqual(command, expected)
  }

  func testCreateTimeFirstWithFillerAfterTime() throws {
    let command = AgentCalendarCommandParser.parse(
      "明天下午3点把会议加入日历",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .create(
        title: "会议",
        start: AgentCalendarTestClock.date(2026, 8, 13, 15),
        end: AgentCalendarTestClock.date(2026, 8, 13, 16)
      )
    )
  }

  func testCreateWithHelpFillerAndDayAfterTomorrow() throws {
    let command = AgentCalendarCommandParser.parse(
      "帮我把后天上午10点的健身课加进日程",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .create(
        title: "健身课",
        start: AgentCalendarTestClock.date(2026, 8, 14, 10),
        end: AgentCalendarTestClock.date(2026, 8, 14, 11)
      )
    )
  }

  func testCreateRelativeTime() throws {
    let command = AgentCalendarCommandParser.parse(
      "把半小时后的健身加入日历",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    guard case .create(let title, let start, let end) = command else {
      return XCTFail("应为 create，实际 \(String(describing: command))")
    }
    XCTAssertEqual(title, "健身")
    XCTAssertEqual(start, AgentCalendarTestClock.now.addingTimeInterval(1800))
    XCTAssertEqual(end, AgentCalendarTestClock.now.addingTimeInterval(1800 + 3600))
  }

  func testCreateWithTrailingPunctuationAndPossessive() throws {
    let command = AgentCalendarCommandParser.parse(
      "把明天早上8点的产品评审加入日历。",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .create(
        title: "产品评审",
        start: AgentCalendarTestClock.date(2026, 8, 13, 8),
        end: AgentCalendarTestClock.date(2026, 8, 13, 9)
      )
    )
  }

  func testCreateWithoutTimeIsNotIntercepted() {
    let command = AgentCalendarCommandParser.parse(
      "把产品评审加入日历",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertNil(command, "无时间短语不应拦截，交给大脑")
  }

  func testNonCalendarTextIsNotIntercepted() {
    XCTAssertNil(AgentCalendarCommandParser.parse(
      "把牛奶加到购物单",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ))
    XCTAssertNil(AgentCalendarCommandParser.parse(
      "明天下午3点开会怎么样",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ))
  }

  func testQueryToday() {
    XCTAssertEqual(
      AgentCalendarCommandParser.parse(
        "今天有什么日程",
        now: AgentCalendarTestClock.now,
        calendar: AgentCalendarTestClock.calendar
      ),
      .query(
        start: AgentCalendarTestClock.date(2026, 8, 12),
        end: AgentCalendarTestClock.date(2026, 8, 13)
      )
    )
  }

  func testQueryTomorrow() {
    XCTAssertEqual(
      AgentCalendarCommandParser.parse(
        "明天有什么安排",
        now: AgentCalendarTestClock.now,
        calendar: AgentCalendarTestClock.calendar
      ),
      .query(
        start: AgentCalendarTestClock.date(2026, 8, 13),
        end: AgentCalendarTestClock.date(2026, 8, 14)
      )
    )
  }

  func testQueryThisWeek() {
    guard case .query(let start, let end) = AgentCalendarCommandParser.parse(
      "这周有什么日程",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ) else {
      return XCTFail("应为 query")
    }
    XCTAssertEqual(start, AgentCalendarTestClock.date(2026, 8, 10), "本周一")
    XCTAssertEqual(end, AgentCalendarTestClock.date(2026, 8, 17), "下周一（半开区间）")
  }

  func testQueryNextWeek() {
    guard case .query(let start, let end) = AgentCalendarCommandParser.parse(
      "下周有什么安排",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ) else {
      return XCTFail("应为 query")
    }
    XCTAssertEqual(start, AgentCalendarTestClock.date(2026, 8, 17))
    XCTAssertEqual(end, AgentCalendarTestClock.date(2026, 8, 24))
  }

  func testQueryWeekday() {
    let command = AgentCalendarCommandParser.parse(
      "周三有什么安排",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .query(
        start: AgentCalendarTestClock.date(2026, 8, 12),
        end: AgentCalendarTestClock.date(2026, 8, 13)
      ),
      "今天是星期三，应命中今天"
    )
  }

  func testQueryRecent() {
    guard case .query(let start, let end) = AgentCalendarCommandParser.parse(
      "最近有什么安排",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ) else {
      return XCTFail("应为 query")
    }
    XCTAssertEqual(start, AgentCalendarTestClock.now)
    XCTAssertEqual(end, AgentCalendarTestClock.now.addingTimeInterval(7 * 86400))
  }

  func testQueryWithHelperLead() {
    XCTAssertNotNil(AgentCalendarCommandParser.parse(
      "帮我看看今天有什么日程",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ))
  }

  func testQueryTooLongIsNotIntercepted() {
    XCTAssertNil(AgentCalendarCommandParser.parse(
      "你觉得这个方案有什么安排吗我觉得不太行要不我们换个思路再想想",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    ), "超长文本不应被日历查询拦截")
  }

  func testDeleteSuffixWithRangeWord() throws {
    let command = AgentCalendarCommandParser.parse(
      "把明天的评审删掉",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 13, 0),
        end: AgentCalendarTestClock.date(2026, 8, 14, 0)
      )
    )
  }

  func testDeletePrefixWithTimePhrase() throws {
    let command = AgentCalendarCommandParser.parse(
      "删除下午3点的会",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .delete(
        keyword: "会",
        start: AgentCalendarTestClock.date(2026, 8, 12, 15),
        end: AgentCalendarTestClock.date(2026, 8, 13, 15)
      )
    )
  }

  func testDeleteWithExplicitTimeKeepsTitle() throws {
    let command = AgentCalendarCommandParser.parse(
      "把明天下午3点产品评审删掉",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .delete(
        keyword: "产品评审",
        start: AgentCalendarTestClock.date(2026, 8, 13, 15),
        end: AgentCalendarTestClock.date(2026, 8, 14, 15)
      )
    )
  }

  func testDeleteWeekdayRangeKeepsContextWordTitle() throws {
    let command = AgentCalendarCommandParser.parse(
      "移除周三的周会",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      command,
      .delete(
        keyword: "周会",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      )
    )
  }

  func testDeleteWithoutCalendarContextNotIntercepted() throws {
    XCTAssertNil(
      AgentCalendarCommandParser.parse(
        "删掉照片",
        now: AgentCalendarTestClock.now,
        calendar: AgentCalendarTestClock.calendar
      ),
      "无时间 / 范围 / 语境词的删除不拦截，交给大脑"
    )
  }

  func testDeleteWithoutTitleNotIntercepted() throws {
    XCTAssertNil(
      AgentCalendarCommandParser.parse(
        "删掉",
        now: AgentCalendarTestClock.now,
        calendar: AgentCalendarTestClock.calendar
      )
    )
  }

  func testCancelVerbNotIntercepted() throws {
    XCTAssertNil(
      AgentCalendarCommandParser.parse(
        "取消今天的评审",
        now: AgentCalendarTestClock.now,
        calendar: AgentCalendarTestClock.calendar
      ),
      "「取消」留给提醒指令，不误吞"
    )
  }
}

// MARK: - 日期范围

final class AgentCalendarDayRangeTests: XCTestCase {

  func testDefaultIsToday() {
    let range = AgentCalendarDayRange.resolve(
      in: "查一下日程",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(range.start, AgentCalendarTestClock.date(2026, 8, 12))
    XCTAssertEqual(range.end, AgentCalendarTestClock.date(2026, 8, 13))
  }

  func testDayAfterTomorrow() {
    let range = AgentCalendarDayRange.resolve(
      in: "后天",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(range.start, AgentCalendarTestClock.date(2026, 8, 14))
  }

  func testWeekdayUsesTodayWhenMatching() {
    let range = AgentCalendarDayRange.resolve(
      in: "星期三",
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(range.start, AgentCalendarTestClock.date(2026, 8, 12))
  }
}

// MARK: - 删除匹配

final class AgentCalendarDeleteMatcherTests: XCTestCase {
  private func event(_ title: String, _ hour: Int, _ minute: Int = 0) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour, minute)
    return AgentCalendarEvent(
      title: title,
      start: start,
      end: start.addingTimeInterval(3600)
    )
  }

  func testUniqueMatchReturnsDelete() {
    let events = [event("产品评审", 15), event("健身", 18)]
    XCTAssertEqual(
      AgentCalendarDeleteMatcher.match(events: events, keyword: "评审"),
      .delete(event("产品评审", 15))
    )
  }

  func testNoMatchReturnsNotFound() {
    XCTAssertEqual(
      AgentCalendarDeleteMatcher.match(events: [event("健身", 18)], keyword: "评审"),
      .notFound
    )
  }

  func testEmptyKeywordReturnsNotFound() {
    XCTAssertEqual(
      AgentCalendarDeleteMatcher.match(events: [event("健身", 18)], keyword: "   "),
      .notFound
    )
  }

  func testMultipleMatchesReturnAmbiguousSorted() {
    let events = [event("技术评审", 16), event("产品评审", 15)]
    XCTAssertEqual(
      AgentCalendarDeleteMatcher.match(events: events, keyword: "评审"),
      .ambiguous(events: [event("产品评审", 15), event("技术评审", 16)]),
      "多个匹配按开始时间升序返回"
    )
  }

  func testNormalizationIgnoresCaseAndWhitespace() {
    let events = [event("Review  Meeting", 15)]
    XCTAssertEqual(
      AgentCalendarDeleteMatcher.match(events: events, keyword: "review meeting"),
      .delete(event("Review  Meeting", 15))
    )
    XCTAssertEqual(
      AgentCalendarDeleteMatcher.match(events: events, keyword: " Review "),
      .delete(event("Review  Meeting", 15)),
      "关键词含标题（双向包含）也能匹配"
    )
  }
}

// MARK: - 文案格式化

@MainActor
final class AgentCalendarFormatterTests: XCTestCase {
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

  func testTimeRangeLabelToday() {
    let label = AgentCalendarFormatter.timeRangeLabel(
      start: AgentCalendarTestClock.date(2026, 8, 12, 15),
      end: AgentCalendarTestClock.date(2026, 8, 12, 16),
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(label, "今天 15:00-16:00")
  }

  func testTimeRangeLabelTomorrow() {
    let label = AgentCalendarFormatter.timeRangeLabel(
      start: AgentCalendarTestClock.date(2026, 8, 13, 9),
      end: AgentCalendarTestClock.date(2026, 8, 13, 10),
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(label, "明天 09:00-10:00")
  }

  func testTimeRangeLabelCrossDay() {
    let label = AgentCalendarFormatter.timeRangeLabel(
      start: AgentCalendarTestClock.date(2026, 8, 12, 23),
      end: AgentCalendarTestClock.date(2026, 8, 13, 1),
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(label, "今天 23:00-明天 01:00")
  }

  func testEventLineAllDay() {
    let line = AgentCalendarFormatter.eventLine(
      AgentCalendarEvent(title: "生日", start: AgentCalendarTestClock.date(2026, 8, 12), end: AgentCalendarTestClock.date(2026, 8, 13), isAllDay: true),
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(line, "全天 生日")
  }

  func testQuerySummarySortsAndJoins() {
    let events = [
      AgentCalendarEvent(title: "健身", start: AgentCalendarTestClock.date(2026, 8, 12, 18), end: AgentCalendarTestClock.date(2026, 8, 12, 19)),
      AgentCalendarEvent(title: "评审", start: AgentCalendarTestClock.date(2026, 8, 12, 15), end: AgentCalendarTestClock.date(2026, 8, 12, 16)),
    ]
    let summary = AgentCalendarFormatter.querySummary(
      events: events,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(summary, "今天 15:00-16:00 评审，今天 18:00-19:00 健身")
    XCTAssertNil(AgentCalendarFormatter.querySummary(events: [], now: AgentCalendarTestClock.now, calendar: AgentCalendarTestClock.calendar))
  }

  func testRangeTitles() {
    let calendar = AgentCalendarTestClock.calendar
    XCTAssertEqual(
      AgentCalendarFormatter.rangeTitle(
        start: AgentCalendarTestClock.date(2026, 8, 12),
        end: AgentCalendarTestClock.date(2026, 8, 13),
        now: AgentCalendarTestClock.now,
        calendar: calendar
      ),
      "今天"
    )
    XCTAssertEqual(
      AgentCalendarFormatter.rangeTitle(
        start: AgentCalendarTestClock.date(2026, 8, 13),
        end: AgentCalendarTestClock.date(2026, 8, 14),
        now: AgentCalendarTestClock.now,
        calendar: calendar
      ),
      "明天"
    )
    XCTAssertEqual(
      AgentCalendarFormatter.rangeTitle(
        start: AgentCalendarTestClock.date(2026, 8, 10),
        end: AgentCalendarTestClock.date(2026, 8, 17),
        now: AgentCalendarTestClock.now,
        calendar: calendar
      ),
      "本周"
    )
    XCTAssertEqual(
      AgentCalendarFormatter.rangeTitle(
        start: AgentCalendarTestClock.date(2026, 8, 17),
        end: AgentCalendarTestClock.date(2026, 8, 24),
        now: AgentCalendarTestClock.now,
        calendar: calendar
      ),
      "下周"
    )
    XCTAssertEqual(
      AgentCalendarFormatter.rangeTitle(
        start: AgentCalendarTestClock.now,
        end: AgentCalendarTestClock.now.addingTimeInterval(7 * 86400),
        now: AgentCalendarTestClock.now,
        calendar: calendar
      ),
      "未来7天"
    )
  }

  func testCreatedConfirmation() {
    let text = AgentCalendarFormatter.createdConfirmation(
      for: AgentCalendarEvent(
        title: "产品评审",
        start: AgentCalendarTestClock.date(2026, 8, 13, 15),
        end: AgentCalendarTestClock.date(2026, 8, 13, 16)
      ),
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(text, "已加入日历：明天 15:00-16:00 产品评审。")
  }
}

// MARK: - 执行器（授权 + 副作用，Mock provider）

private final class MockCalendarProvider: AgentCalendarProviding {
  var authorization: AgentCalendarAuthorization = .notDetermined
  /// requestAuthorization 后的授权结果（默认变为 authorized；denied 场景可配置为 .denied）
  var authorizationAfterRequest: AgentCalendarAuthorization = .authorized
  var events: [AgentCalendarEvent] = []
  var createError: Error?
  var created: [AgentCalendarEvent] = []
  var deleteError: Error?
  var deleted: [AgentCalendarEvent] = []
  var requestAuthorizationCount = 0
  var fetchCount = 0

  func requestAuthorization() async -> AgentCalendarAuthorization {
    requestAuthorizationCount += 1
    authorization = authorizationAfterRequest
    return authorization
  }

  func fetchEvents(from start: Date, to end: Date) async -> [AgentCalendarEvent] {
    fetchCount += 1
    return events
  }

  func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws -> AgentCalendarEvent {
    if let createError {
      throw createError
    }
    let event = AgentCalendarEvent(title: title, start: start, end: end, isAllDay: isAllDay)
    created.append(event)
    return event
  }

  func deleteEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws {
    if let deleteError {
      throw deleteError
    }
    deleted.append(AgentCalendarEvent(title: title, start: start, end: end, isAllDay: isAllDay))
  }
}

private enum MockError: Error {
  case saveFailed
}

@MainActor
final class AgentCalendarExecutorTests: XCTestCase {
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

  private func event(_ title: String, _ hour: Int, _ minute: Int = 0) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour, minute)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testCreateRequestsAuthorizationAndPersists() async {
    let provider = MockCalendarProvider()
    let command = AgentCalendarCommand.create(
      title: "会议",
      start: AgentCalendarTestClock.date(2026, 8, 13, 15),
      end: AgentCalendarTestClock.date(2026, 8, 13, 16)
    )
    let reply = await AgentCalendarExecutor.execute(
      command,
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(provider.requestAuthorizationCount, 1)
    XCTAssertEqual(provider.created.count, 1)
    XCTAssertEqual(provider.created[0].title, "会议")
    XCTAssertEqual(reply, "已加入日历：明天 15:00-16:00 会议。")
  }

  func testCreateDenied() async {
    let provider = MockCalendarProvider()
    provider.authorization = .denied
    provider.authorizationAfterRequest = .denied
    let reply = await AgentCalendarExecutor.execute(
      .create(title: "会议", start: AgentCalendarTestClock.now, end: AgentCalendarTestClock.now.addingTimeInterval(3600)),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "日历权限未开启，请在设置中允许访问日历。")
    XCTAssertTrue(provider.created.isEmpty)
  }

  func testCreateFailure() async {
    let provider = MockCalendarProvider()
    provider.createError = MockError.saveFailed
    let reply = await AgentCalendarExecutor.execute(
      .create(title: "会议", start: AgentCalendarTestClock.now, end: AgentCalendarTestClock.now.addingTimeInterval(3600)),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "无法添加日程到日历。")
  }

  func testQueryReturnsSummary() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [
      AgentCalendarEvent(title: "评审", start: AgentCalendarTestClock.date(2026, 8, 12, 15), end: AgentCalendarTestClock.date(2026, 8, 12, 16)),
    ]
    let reply = await AgentCalendarExecutor.execute(
      .query(start: AgentCalendarTestClock.date(2026, 8, 12), end: AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "今天 15:00-16:00 评审")
    XCTAssertEqual(provider.fetchCount, 1)
  }

  func testQueryEmpty() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    let reply = await AgentCalendarExecutor.execute(
      .query(start: AgentCalendarTestClock.date(2026, 8, 12), end: AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "今天没有日程安排。")
  }

  func testQueryDeniedDoesNotFetch() async {
    let provider = MockCalendarProvider()
    provider.authorization = .denied
    let reply = await AgentCalendarExecutor.execute(
      .query(start: AgentCalendarTestClock.now, end: AgentCalendarTestClock.now.addingTimeInterval(86400)),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "日历权限未开启，请在设置中允许访问日历。")
    XCTAssertEqual(provider.fetchCount, 0)
  }

  func testDeleteUniqueMatchRemovesAndConfirms() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15)]
    let reply = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(provider.deleted.count, 1)
    XCTAssertEqual(provider.deleted[0].title, "产品评审")
    XCTAssertEqual(reply, "已删除：今天 15:00-16:00 产品评审。")
  }

  func testDeleteNotFound() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("健身", 18)]
    let reply = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertEqual(reply, "没有找到匹配的日程")
  }

  func testDeleteAmbiguousListsMatches() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15), event("技术评审", 16)]
    let reply = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertEqual(
      reply,
      "找到 2 个匹配日程：\n1. 今天 15:00-16:00 产品评审\n2. 今天 16:00-17:00 技术评审\n请回复序号或更具体的名称。"
    )
    // 歧义进入追问闭环：候选暂存，供后续「1 / 产品评审 / 取消」消费
    XCTAssertEqual(AgentCalendarDeletePendingStore.candidates.count, 2)
  }

  func testDeleteDenied() async {
    let provider = MockCalendarProvider()
    provider.authorization = .denied
    let reply = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertEqual(reply, "agent.calendar.denied".localized)
  }

  func testDeleteFailureFeedback() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15)]
    provider.deleteError = MockError.saveFailed
    let reply = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "删除失败，请稍后再试")
  }
}

// MARK: - 眼镜端展示映射

final class AgentCalendarDisplayMappingTests: XCTestCase {
    private var calendar: Calendar { AgentCalendarTestClock.calendar }
    private var now: Date { AgentCalendarTestClock.now }

    private func event(
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

    func testHasUpcomingEventsFalseWhenEmpty() {
        XCTAssertFalse(AgentCalendarDisplayMapping.hasUpcomingEvents([], now: now, calendar: calendar))
    }

    func testHasUpcomingEventsIgnoresPastEventsAndOtherDays() {
        let pastToday = event("已结束", 2026, 8, 12, 9) // 09:00-10:00，now 10:00 已结束
        let yesterday = event("昨天", 2026, 8, 11, 15)
        let tomorrow = event("明天", 2026, 8, 13, 9)
        XCTAssertFalse(
            AgentCalendarDisplayMapping.hasUpcomingEvents(
                [pastToday, yesterday, tomorrow],
                now: now,
                calendar: calendar
            )
        )
    }

    func testHasUpcomingEventsIncludesTodayFutureAndAllDay() {
        let future = event("评审", 2026, 8, 12, 15)
        let allDay = event("全天事项", 2026, 8, 12, isAllDay: true)
        XCTAssertTrue(
            AgentCalendarDisplayMapping.hasUpcomingEvents([future, allDay], now: now, calendar: calendar)
        )
    }

    func testUpcomingSortsByStartAndLimits() {
        let events = [
            event("晚", 2026, 8, 12, 18),
            event("早", 2026, 8, 12, 11),
            event("中", 2026, 8, 12, 14),
            event("更晚", 2026, 8, 12, 20),
            event("最早", 2026, 8, 12, 10, 30),
            event("最晚", 2026, 8, 12, 22),
        ]
        let upcoming = AgentCalendarDisplayMapping.upcoming(events, now: now, calendar: calendar)
        XCTAssertEqual(upcoming.map(\.title), ["最早", "早", "中", "晚", "更晚"])
        let limited = AgentCalendarDisplayMapping.upcoming(
            events,
            now: now,
            calendar: calendar,
            limit: 2
        )
        XCTAssertEqual(limited.map(\.title), ["最早", "早"])
    }

    func testMenuLabelTimedAndTruncated() {
        let event = AgentCalendarEvent(
            title: "产品评审会讨论需求细节",
            start: AgentCalendarTestClock.date(2026, 8, 12, 10, 30),
            end: AgentCalendarTestClock.date(2026, 8, 12, 11, 30)
        )
        let label = AgentCalendarDisplayMapping.menuLabel(for: event)
        XCTAssertTrue(label.hasPrefix("10:30 "))
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertEqual(label, "10:30 产品评审会讨论需…")
    }

    func testMenuLabelAllDayUsesAllDayPrefix() {
        let event = event("出游", 2026, 8, 12, isAllDay: true)
        let label = AgentCalendarDisplayMapping.menuLabel(for: event)
        let expected = "agent.calendar.allday".localized + " 出游"
        XCTAssertEqual(label, expected)
    }

    func testMenuLabelEmptyTitleFallsBack() {
        let event = AgentCalendarEvent(
            title: "   ",
            start: AgentCalendarTestClock.date(2026, 8, 12, 9),
            end: AgentCalendarTestClock.date(2026, 8, 12, 10)
        )
        let label = AgentCalendarDisplayMapping.menuLabel(for: event)
        XCTAssertEqual(label, "09:00 Event")
    }

    func testResultTextUsesEventLine() {
        let event = event("评审", 2026, 8, 12, 15)
        XCTAssertEqual(
            AgentCalendarDisplayMapping.resultText(for: event, now: now, calendar: calendar),
            AgentCalendarFormatter.eventLine(event, now: now, calendar: calendar)
        )
    }

    func testUpcomingEventsForMenuRequiresAuthorization() async {
        let provider = MockCalendarProvider()
        provider.authorization = .notDetermined
        let events = await AgentCalendarDisplayMapping.upcomingEventsForMenu(
            provider: provider,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(provider.fetchCount, 0)
        XCTAssertEqual(provider.requestAuthorizationCount, 0)
    }

    func testUpcomingEventsForMenuFiltersTodayWhenAuthorized() async {
        let provider = MockCalendarProvider()
        provider.authorization = .authorized
        provider.events = [
            event("已结束", 2026, 8, 12, 9),
            event("评审", 2026, 8, 12, 15),
            event("明天", 2026, 8, 13, 9),
        ]
        let events = await AgentCalendarDisplayMapping.upcomingEventsForMenu(
            provider: provider,
            now: now,
            calendar: calendar
        )
    func testUpcomingTomorrowFiltersTomorrowDay() {
        let today = event("今天评审", 2026, 8, 12, 15)
        let tomorrowEarly = event("明天评审", 2026, 8, 13, 9)
        let tomorrowAllDay = event("全天出游", 2026, 8, 13, isAllDay: true)
        let dayAfter = event("后天", 2026, 8, 14, 9)
        let events = AgentCalendarDisplayMapping.upcomingTomorrow(
            [today, tomorrowEarly, tomorrowAllDay, dayAfter],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(events.map(\.title), ["全天出游", "明天评审"], "全天日程按 00:00 起排在最前")
        let limited = AgentCalendarDisplayMapping.upcomingTomorrow(
            [today, tomorrowEarly, tomorrowAllDay, dayAfter],
            now: now,
            calendar: calendar,
            limit: 1
        )
        XCTAssertEqual(limited.map(\.title), ["全天出游"])
    }

    func testTomorrowEventsForMenuRequiresAuthorization() async {
        let provider = MockCalendarProvider()
        provider.authorization = .notDetermined
        let events = await AgentCalendarDisplayMapping.tomorrowEventsForMenu(
            provider: provider,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(provider.fetchCount, 0)
        XCTAssertEqual(provider.requestAuthorizationCount, 0)
    }

    func testTomorrowEventsForMenuFiltersTomorrowWhenAuthorized() async {
        let provider = MockCalendarProvider()
        provider.authorization = .authorized
        provider.events = [
            event("今天评审", 2026, 8, 12, 15),
            event("明天评审", 2026, 8, 13, 15),
            event("后天", 2026, 8, 14, 9),
        ]
        let events = await AgentCalendarDisplayMapping.tomorrowEventsForMenu(
            provider: provider,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(events.map(\.title), ["明天评审"])
        XCTAssertEqual(provider.fetchCount, 1)
    }

        XCTAssertEqual(events.map(\.title), ["评审"])
        XCTAssertEqual(provider.fetchCount, 1)
    }

    func testTodayEventsRequestsAuthorizationWhenNeeded() async {
        let provider = MockCalendarProvider()
        provider.authorization = .notDetermined
        provider.events = [event("评审", 2026, 8, 12, 15)]
        let events = await AgentCalendarDisplayMapping.todayEvents(
            provider: provider,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(events?.map(\.title), ["评审"])
        XCTAssertEqual(provider.requestAuthorizationCount, 1)
    }

    func testTodayEventsReturnsNilWhenDenied() async {
        let provider = MockCalendarProvider()
        provider.authorization = .denied
        let events = await AgentCalendarDisplayMapping.todayEvents(
            provider: provider,
            now: now,
            calendar: calendar
        )
        XCTAssertNil(events)
        XCTAssertEqual(provider.fetchCount, 0)
    }
}

// MARK: - 设置页日历分区

final class AgentCalendarSettingsTests: XCTestCase {
  func testStatusTextMapsAllStates() {
    XCTAssertEqual(
      AgentCalendarSettings.statusText(for: .authorized),
      "agent.settings.calendar.status.authorized".localized
    )
    XCTAssertEqual(
      AgentCalendarSettings.statusText(for: .denied),
      "agent.settings.calendar.status.denied".localized
    )
    XCTAssertEqual(
      AgentCalendarSettings.statusText(for: .restricted),
      "agent.settings.calendar.status.restricted".localized
    )
    XCTAssertEqual(
      AgentCalendarSettings.statusText(for: .notDetermined),
      "agent.settings.calendar.status.notDetermined".localized
    )
  }

  func testActionDecision() {
    XCTAssertEqual(AgentCalendarSettings.action(for: .authorized), .none)
    XCTAssertEqual(AgentCalendarSettings.action(for: .notDetermined), .request)
    XCTAssertEqual(AgentCalendarSettings.action(for: .denied), .openSettings)
    XCTAssertEqual(AgentCalendarSettings.action(for: .restricted), .openSettings)
  }
}

// MARK: - 设置页「近期日程」列表

@MainActor
final class AgentCalendarOverviewMappingTests: XCTestCase {
  private let now = AgentCalendarTestClock.now
  private let calendar = AgentCalendarTestClock.calendar
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

  private func event(
    _ title: String,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0,
    isAllDay: Bool = false
  ) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, day, hour, minute)
    return AgentCalendarEvent(
      title: title,
      start: start,
      end: start.addingTimeInterval(isAllDay ? 0 : 3600),
      isAllDay: isAllDay
    )
  }

  func testGroupAssignment() {
    XCTAssertEqual(
      AgentCalendarOverviewMapping.group(for: event("今天", 12, 10), now: now, calendar: calendar),
      .today
    )
    XCTAssertEqual(
      AgentCalendarOverviewMapping.group(for: event("明天", 13, 10), now: now, calendar: calendar),
      .tomorrow
    )
    XCTAssertEqual(
      AgentCalendarOverviewMapping.group(for: event("后天", 14, 10), now: now, calendar: calendar),
      .later
    )
    XCTAssertNil(
      AgentCalendarOverviewMapping.group(for: event("昨天", 11, 10), now: now, calendar: calendar),
      "今天之前的日程不进入列表"
    )
  }

  func testRowFormatsTimeAndAllDay() {
    XCTAssertEqual(
      AgentCalendarOverviewMapping.row(for: event("评审", 12, 15)),
      AgentCalendarOverviewMapping.Row(timeText: "15:00", title: "评审")
    )
    XCTAssertEqual(
      AgentCalendarOverviewMapping.row(for: event("出游", 12, 0, isAllDay: true)),
      AgentCalendarOverviewMapping.Row(timeText: "全天", title: "出游")
    )
    XCTAssertEqual(
      AgentCalendarOverviewMapping.row(
        for: AgentCalendarEvent(
          title: "  标题带空格  ",
          start: AgentCalendarTestClock.date(2026, 8, 12, 9, 0),
          end: AgentCalendarTestClock.date(2026, 8, 12, 10, 0)
        )
      ).title,
      "标题带空格"
    )
  }

  func testGroupedOrderTodayThenTomorrowThenLater() {
    let events = [
      event("后天", 14, 9),
      event("明天", 13, 8),
      event("今天", 12, 15),
      event("今天早", 12, 9),
    ]
    let grouped = AgentCalendarOverviewMapping.groupedEvents(
      events,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(grouped.map(\.group), [.today, .tomorrow, .later])
    XCTAssertEqual(grouped[0].events.map(\.title), ["今天早", "今天"])
    XCTAssertEqual(grouped[1].events.map(\.title), ["明天"])
    XCTAssertEqual(grouped[2].events.map(\.title), ["后天"])
  }

  func testExcludesPastAndBeyondLookahead() {
    let past = event("昨天", 11, 10)
    let far = event("下周", 20, 9)
    let grouped = AgentCalendarOverviewMapping.groupedEvents(
      [past, far],
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(grouped.isEmpty, "过去的日程与超出 7 天窗口的日程都不展示")
  }

  func testCapsPerGroupAndTotal() {
    let today = (0..<7).map { event("今天\($0)", 12, 10 + $0) }
    let tomorrow = (0..<7).map { event("明天\($0)", 13, 10 + $0) }
    let grouped = AgentCalendarOverviewMapping.groupedEvents(
      today + tomorrow,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(grouped[0].events.count, 5, "单组最多 5 行")
    XCTAssertEqual(grouped[1].events.count, 5, "总量封顶 10 行，第二组仍按单组上限")
    XCTAssertEqual(
      grouped.flatMap(\.events).count,
      AgentCalendarOverviewMapping.maxRows
    )
  }

  func testEmptyEvents() {
    XCTAssertTrue(
      AgentCalendarOverviewMapping.groupedEvents([], now: now, calendar: calendar).isEmpty
    )
  }
}

// MARK: - 日程详情卡

@MainActor
final class AgentCalendarDetailMappingTests: XCTestCase {
  private let now = AgentCalendarTestClock.now
  private let calendar = AgentCalendarTestClock.calendar
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

  private func event(
    _ title: String,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0,
    duration: TimeInterval = 3600,
    isAllDay: Bool = false,
    calendarName: String? = nil
  ) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, day, hour, minute)
    return AgentCalendarEvent(
      title: title,
      start: start,
      end: start.addingTimeInterval(isAllDay ? 0 : duration),
      isAllDay: isAllDay,
      calendarName: calendarName
    )
  }

  func testUpcomingStatusText() {
    XCTAssertEqual(
      AgentCalendarDetailMapping.statusText(for: .upcoming(25 * 60)),
      "还有 25 分钟开始"
    )
    XCTAssertEqual(
      AgentCalendarDetailMapping.statusText(for: .upcoming(3 * 3600)),
      "还有 3 小时开始"
    )
    XCTAssertEqual(
      AgentCalendarDetailMapping.statusText(for: .upcoming(30)),
      "即将开始"
    )
  }

  func testInProgressStatusText() {
    XCTAssertEqual(
      AgentCalendarDetailMapping.statusText(for: .inProgress(10 * 60)),
      "还有 10 分钟结束"
    )
    XCTAssertEqual(
      AgentCalendarDetailMapping.statusText(for: .inProgress(2 * 3600)),
      "还有 2 小时结束"
    )
    XCTAssertEqual(
      AgentCalendarDetailMapping.statusText(for: .inProgress(45)),
      "即将结束"
    )
  }

  func testEndedStatusText() {
    XCTAssertEqual(AgentCalendarDetailMapping.statusText(for: .ended), "已结束")
  }

  func testStatusSymbols() {
    XCTAssertEqual(AgentCalendarDetailMapping.statusSymbol(for: .upcoming(60)), "clock")
    XCTAssertEqual(AgentCalendarDetailMapping.statusSymbol(for: .inProgress(60)), "hourglass")
    XCTAssertEqual(AgentCalendarDetailMapping.statusSymbol(for: .ended), "checkmark.circle")
  }

  func testStatusDecision() {
    XCTAssertEqual(
      AgentCalendarDetailMapping.status(
        for: event("即将", 12, 15, 5),
        now: now
      ),
      .upcoming(18_300)
    )
    XCTAssertEqual(
      AgentCalendarDetailMapping.status(
        for: event("进行中", 12, 9, 50, duration: 3600),
        now: now
      ),
      .inProgress(3_000)
    )
    XCTAssertEqual(
      AgentCalendarDetailMapping.status(
        for: event("已结束", 12, 9),
        now: now
      ),
      .ended
    )
  }

  func testDetailTimeTextAndSource() {
    let detail = AgentCalendarDetailMapping.detail(
      for: event("评审", 12, 15, 0, duration: 3600, calendarName: "工作"),
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(detail.title, "评审")
    XCTAssertEqual(detail.timeText, "今天 15:00-16:00")
    XCTAssertEqual(detail.calendarName, "工作")
    XCTAssertEqual(detail.status, .upcoming(5 * 3600))
  }

  func testAllDayDetailHasNoStatus() {
    let detail = AgentCalendarDetailMapping.detail(
      for: event("出游", 13, 0, isAllDay: true),
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(detail.timeText, "全天")
    XCTAssertNil(detail.status)
  }

  func testDetailTrimsTitle() {
    let detail = AgentCalendarDetailMapping.detail(
      for: event("  带空格  ", 12, 15),
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(detail.title, "带空格")
  }
}

// MARK: - 主页「今日日程」卡片

@MainActor
final class AgentHomeCalendarCardMappingTests: XCTestCase {
  private let now = AgentCalendarTestClock.now
  private let calendar = AgentCalendarTestClock.calendar
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

  private func event(
    _ title: String,
    _ hour: Int,
    _ minute: Int = 0,
    duration: TimeInterval = 3600,
    isAllDay: Bool = false
  ) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour, minute)
    return AgentCalendarEvent(
      title: title,
      start: start,
      end: start.addingTimeInterval(duration),
      isAllDay: isAllDay
    )
  }

  func testUnauthorizedShowsGuidance() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [event("评审", 15)],
      authorized: false,
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(content.isPlaceholder)
    XCTAssertEqual(content.line, "授权日历后显示今日日程")
  }

  func testAuthorizedEmptyShowsPlaceholder() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(content.isPlaceholder)
    XCTAssertEqual(content.line, "今天暂无日程")
  }

  func testAuthorizedWithEventShowsLine() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [event("评审", 15)],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertFalse(content.isPlaceholder)
    XCTAssertEqual(content.line, "今天 15:00-16:00 评审")
  }

  func testPicksNearestEvent() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [event("评审", 15), event("晨会", 9, 30)],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(content.line, "今天 09:30-10:30 晨会")
  }

  func testCountIncludesUpcomingOnly() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [event("晨会", 9, 30), event("评审", 15), event("已结束", 7)],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(content.count, 2)
  }

  func testCountUnauthorizedOrEmptyIsZero() {
    let unauthorized = AgentHomeCalendarCardMapping.content(
      events: [event("评审", 15)],
      authorized: false,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(unauthorized.count, 0)

    let empty = AgentHomeCalendarCardMapping.content(
      events: [],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(empty.count, 0)
  }

  func testEndedEventExcluded() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [event("早会", 9, duration: 3600)],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(content.isPlaceholder, "已结束（end 不晚于当前）的日程不显示")
  }

  func testAllDayEventShown() {
    let content = AgentHomeCalendarCardMapping.content(
      events: [event("出游", 0, isAllDay: true)],
      authorized: true,
      now: now,
      calendar: calendar
    )
    XCTAssertFalse(content.isPlaceholder)
    XCTAssertEqual(content.line, "全天 出游")
  }
}

// MARK: - 日程 → 提醒桥接

final class AgentCalendarReminderBridgeTests: XCTestCase {
  private let now = AgentCalendarTestClock.now

  private func event(
    _ title: String = "评审",
    _ hour: Int = 15,
    _ minute: Int = 0
  ) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour, minute)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testBuildsReminderWithLeadTime() {
    let reminder = AgentCalendarReminderBridge.reminder(
      for: event(),
      leadMinutes: 10,
      now: now
    )
    XCTAssertEqual(reminder?.text, "评审")
    XCTAssertEqual(reminder?.fireDate, AgentCalendarTestClock.date(2026, 8, 12, 14, 50))
    XCTAssertEqual(reminder?.repeatRule, AgentReminderRepeat.none)
  }

  func testInvalidLeadReturnsNil() {
    XCTAssertNil(
      AgentCalendarReminderBridge.reminder(for: event(), leadMinutes: 7, now: now),
      "非选项提前量不设置"
    )
  }

  func testTooLateReturnsNil() {
    XCTAssertNil(
      AgentCalendarReminderBridge.reminder(
        for: event("马上", 10, 5),
        leadMinutes: 10,
        now: now
      ),
      "触发时间已过不设置"
    )
  }

  func testHasReminderSameSource() {
    let reminder = AgentReminder(
      text: "评审",
      fireDate: AgentCalendarTestClock.date(2026, 8, 12, 15)
    )
    XCTAssertTrue(AgentCalendarReminderBridge.hasReminder(for: event(), in: [reminder]))
  }

  func testHasReminderDifferentTimeOrTitle() {
    let reminder = AgentReminder(
      text: "评审",
      fireDate: AgentCalendarTestClock.date(2026, 8, 12, 16)
    )
    XCTAssertFalse(
      AgentCalendarReminderBridge.hasReminder(for: event(), in: [reminder]),
      "开始时间不同视为不同日程"
    )
    let other = AgentReminder(
      text: "健身",
      fireDate: AgentCalendarTestClock.date(2026, 8, 12, 15)
    )
    XCTAssertFalse(AgentCalendarReminderBridge.hasReminder(for: event(), in: [other]))
  }

  func testHasReminderTrimsTitle() {
    let reminder = AgentReminder(
      text: "评审",
      fireDate: AgentCalendarTestClock.date(2026, 8, 12, 15)
    )
    let padded = AgentCalendarEvent(
      title: "  评审  ",
      start: AgentCalendarTestClock.date(2026, 8, 12, 15),
      end: AgentCalendarTestClock.date(2026, 8, 12, 16)
    )
    XCTAssertTrue(AgentCalendarReminderBridge.hasReminder(for: padded, in: [reminder]))
  }
}

// MARK: - 日程提醒通知策略

@MainActor
final class AgentCalendarEventNotifierTests: XCTestCase {
  private let now = AgentCalendarTestClock.now
  private let calendar = AgentCalendarTestClock.calendar
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

  private func event(
    _ title: String,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0,
    duration: TimeInterval = 3600
  ) -> AgentCalendarEvent {
    AgentCalendarEvent(
      title: title,
      start: AgentCalendarTestClock.date(2026, 8, day, hour, minute),
      end: AgentCalendarTestClock.date(2026, 8, day, hour, minute).addingTimeInterval(duration)
    )
  }

  func testSchedulesEventBeforeLeadTime() {
    let specs = AgentCalendarEventNotifier.specs(
      for: [event("评审", 12, 15)],
      now: now,
      calendar: calendar,
      leadTime: 600
    )
    XCTAssertEqual(specs.count, 1)
    XCTAssertEqual(specs[0].body, "今天 15:00-16:00 评审")
    XCTAssertEqual(specs[0].fireDate, AgentCalendarTestClock.date(2026, 8, 12, 14, 50))
  }

  func testExcludesAllDayAndFarEvents() {
    let allDay = AgentCalendarEvent(
      title: "旅行",
      start: AgentCalendarTestClock.date(2026, 8, 13),
      end: AgentCalendarTestClock.date(2026, 8, 14),
      isAllDay: true
    )
    let far = event("下周", 20, 9)
    let specs = AgentCalendarEventNotifier.specs(
      for: [allDay, far],
      now: now,
      calendar: calendar,
      leadTime: 600
    )
    XCTAssertTrue(specs.isEmpty)
  }

  func testExcludesEventAlreadyWithinLeadTime() {
    let specs = AgentCalendarEventNotifier.specs(
      for: [event("马上", 12, 10, 5)],
      now: now,
      calendar: calendar,
      leadTime: 600
    )
    XCTAssertTrue(specs.isEmpty, "触发时间早于当前的不再补通知")
  }

  func testPicksNearestFirstAndCapsCount() {
    let events = (0..<25).map { event("日程\($0)", 12, 10 + $0) }
    let specs = AgentCalendarEventNotifier.specs(
      for: events,
      now: now,
      calendar: calendar,
      leadTime: 600
    )
    XCTAssertEqual(specs.count, AgentCalendarEventNotifier.maxSpecs)
    XCTAssertEqual(specs.first?.body, "今天 11:00-12:00 日程1")
  }

  func testIDStableAndUnique() {
    let a = event("评审", 12, 15)
    let b = event("健身", 12, 16)
    XCTAssertEqual(AgentCalendarEventNotifier.id(for: a), AgentCalendarEventNotifier.id(for: a))
    XCTAssertNotEqual(AgentCalendarEventNotifier.id(for: a), AgentCalendarEventNotifier.id(for: b))
    XCTAssertFalse(AgentCalendarEventNotifier.id(for: a).contains(" "))
  }

  func testEmptyEvents() {
    XCTAssertTrue(
      AgentCalendarEventNotifier.specs(for: [], now: now, calendar: calendar, leadTime: 600).isEmpty
    )
  }
}

// MARK: - 日程提醒通知交互（点按深链）

final class AgentCalendarNotificationActionTests: XCTestCase {
  func testCategoryIdentifierStable() {
    XCTAssertEqual(
      AgentCalendarNotificationAction.categoryIdentifier,
      "agent.calendar.event.notify"
    )
  }

  func testMarkerRecognizesCalendarNotification() {
    let info = AgentCalendarNotificationAction.userInfo(eventID: "abc")
    XCTAssertTrue(AgentCalendarNotificationAction.isCalendarEvent(info))
    XCTAssertFalse(AgentCalendarNotificationAction.isCalendarEvent(nil))
    XCTAssertFalse(AgentCalendarNotificationAction.isCalendarEvent(["other": true]))
  }

  func testEventIDRoundTrip() {
    let info = AgentCalendarNotificationAction.userInfo(eventID: "123-评审")
    XCTAssertEqual(AgentCalendarNotificationAction.eventID(from: info), "123-评审")
    XCTAssertNil(AgentCalendarNotificationAction.eventID(from: [:]))
  }

  func testDefaultTapDeepLinksToCalendarSettings() {
    XCTAssertEqual(
      AgentCalendarNotificationAction.destination(for: UNNotificationDefaultActionIdentifier),
      .agentSettings(.calendar)
    )
  }

  func testUnknownActionHasNoDestination() {
    XCTAssertNil(AgentCalendarNotificationAction.destination(for: "UNKNOWN_ACTION"))
  }
}

// MARK: - 日程提醒设置

final class AgentCalendarNotificationSettingsTests: XCTestCase {
  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: AgentCalendarNotificationSettings.enabledKey)
    UserDefaults.standard.removeObject(forKey: AgentCalendarNotificationSettings.leadMinutesKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: AgentCalendarNotificationSettings.enabledKey)
    UserDefaults.standard.removeObject(forKey: AgentCalendarNotificationSettings.leadMinutesKey)
    super.tearDown()
  }

  func testDefaults() {
    XCTAssertFalse(AgentCalendarNotificationSettings.enabled)
    XCTAssertEqual(AgentCalendarNotificationSettings.leadTimeMinutes, 10)
  }

  func testRoundTripAndInvalidFallback() {
    AgentCalendarNotificationSettings.enabled = true
    AgentCalendarNotificationSettings.leadTimeMinutes = 30
    XCTAssertTrue(AgentCalendarNotificationSettings.enabled)
    XCTAssertEqual(AgentCalendarNotificationSettings.leadTimeMinutes, 30)

    AgentCalendarNotificationSettings.leadTimeMinutes = 7
    XCTAssertEqual(
      AgentCalendarNotificationSettings.leadTimeMinutes,
      AgentCalendarNotificationSettings.defaultLeadMinutes,
      "非选项值回退默认"
    )
  }
}


// MARK: - 主页双卡刷新信号（日历数据变更广播）

final class AgentCalendarRefreshSignalTests: XCTestCase {
  private var observer: NSObjectProtocol?
  private var receivedSignal = false

  override func setUp() {
    super.setUp()
    receivedSignal = false
    observer = NotificationCenter.default.addObserver(
      forName: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.receivedSignal = true
    }
  }

  override func tearDown() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    super.tearDown()
  }

  private func event(_ title: String, _ hour: Int) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testCreateSuccessPostsRefreshSignal() async {
    let provider = MockCalendarProvider()
    _ = await AgentCalendarExecutor.execute(
      .create(
        title: "会议",
        start: AgentCalendarTestClock.date(2026, 8, 13, 15),
        end: AgentCalendarTestClock.date(2026, 8, 13, 16)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(receivedSignal)
    XCTAssertEqual(provider.created.count, 1)
  }

  func testCreateDeniedDoesNotPostRefreshSignal() async {
    let provider = MockCalendarProvider()
    provider.authorization = .denied
    provider.authorizationAfterRequest = .denied
    _ = await AgentCalendarExecutor.execute(
      .create(
        title: "会议",
        start: AgentCalendarTestClock.now,
        end: AgentCalendarTestClock.now.addingTimeInterval(3600)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertFalse(receivedSignal)
    XCTAssertTrue(provider.created.isEmpty)
  }

  func testCreateFailureDoesNotPostRefreshSignal() async {
    let provider = MockCalendarProvider()
    provider.createError = MockError.saveFailed
    _ = await AgentCalendarExecutor.execute(
      .create(
        title: "会议",
        start: AgentCalendarTestClock.now,
        end: AgentCalendarTestClock.now.addingTimeInterval(3600)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertFalse(receivedSignal)
  }

  func testDeleteSuccessPostsRefreshSignal() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15)]
    _ = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(receivedSignal)
    XCTAssertEqual(provider.deleted.count, 1)
  }

  func testDeleteFailureDoesNotPostRefreshSignal() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15)]
    provider.deleteError = MockError.saveFailed
    _ = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertFalse(receivedSignal)
    XCTAssertTrue(provider.deleted.isEmpty)
  }
}


// MARK: - 详情卡「删除此日程」动作

@MainActor
final class AgentCalendarDetailDeleteActionTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system
  private var observer: NSObjectProtocol?
  private var receivedSignal = false

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
    receivedSignal = false
    observer = NotificationCenter.default.addObserver(
      forName: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.receivedSignal = true
    }
  }

  override func tearDown() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func event(_ title: String) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, 15)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testButtonAndConfirmCopy() {
    XCTAssertEqual(AgentCalendarDetailDeleteAction.buttonTitle(), "删除此日程")
    XCTAssertEqual(AgentCalendarDetailDeleteAction.confirmTitle(), "删除此日程？")
    XCTAssertEqual(
      AgentCalendarDetailDeleteAction.confirmMessage(for: event("产品评审")),
      "将从日历中删除「产品评审」，此操作无法撤销。"
    )
    XCTAssertEqual(AgentCalendarDetailDeleteAction.confirmActionTitle(), "删除")
    XCTAssertEqual(AgentCalendarDetailDeleteAction.cancelTitle(), "取消")
    XCTAssertEqual(AgentCalendarDetailDeleteAction.errorTitle(), "无法删除日程")
    XCTAssertEqual(AgentCalendarDetailDeleteAction.failureMessage(), "删除失败，请稍后再试")
  }

  func testPerformDeleteSuccessPostsRefreshSignal() async {
    let provider = MockCalendarProvider()
    let target = event("产品评审")
    let deleted = await AgentCalendarDetailDeleteAction.performDelete(
      event: target,
      provider: provider
    )
    XCTAssertTrue(deleted)
    XCTAssertEqual(provider.deleted.count, 1)
    XCTAssertEqual(provider.deleted[0].title, "产品评审")
    XCTAssertTrue(receivedSignal)
  }

  func testPerformDeleteFailureDoesNotPostRefreshSignal() async {
    let provider = MockCalendarProvider()
    provider.deleteError = MockError.saveFailed
    let deleted = await AgentCalendarDetailDeleteAction.performDelete(
      event: event("产品评审"),
      provider: provider
    )
    XCTAssertFalse(deleted)
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertFalse(receivedSignal)
  }

  func testDeletedTextUsesEventLine() {
    let start = AgentCalendarTestClock.date(2026, 8, 12, 15)
    let event = AgentCalendarEvent(
      title: "产品评审",
      start: start,
      end: start.addingTimeInterval(3600)
    )
    XCTAssertEqual(
      AgentCalendarDetailDeleteAction.deletedText(
        for: event,
        now: AgentCalendarTestClock.now,
        calendar: AgentCalendarTestClock.calendar
      ),
      "已删除：今天 15:00-16:00 产品评审。"
    )
  }
}


// MARK: - 删除歧义追问（提示 / 解析 / 协调闭环）

@MainActor
final class AgentCalendarDeletePromptBuilderTests: XCTestCase {
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

  private func event(_ title: String, _ hour: Int) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testPromptListsCandidatesWithNumbersAndHint() {
    let prompt = AgentCalendarDeletePromptBuilder.prompt(
      for: [event("产品评审", 15), event("技术评审", 16)],
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(
      prompt,
      "找到 2 个匹配日程：\n1. 今天 15:00-16:00 产品评审\n2. 今天 16:00-17:00 技术评审\n请回复序号或更具体的名称。"
    )
  }

  func testPromptSingleCandidate() {
    let prompt = AgentCalendarDeletePromptBuilder.prompt(
      for: [event("评审", 9)],
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(prompt.hasPrefix("找到 1 个匹配日程："))
    XCTAssertTrue(prompt.contains("1. 今天 09:00-10:00 评审"))
    XCTAssertTrue(prompt.hasSuffix("请回复序号或更具体的名称。"))
  }

  func testInvalidReplyShowsRange() {
    XCTAssertEqual(
      AgentCalendarDeletePromptBuilder.invalidReply(number: 3, count: 2),
      "没有序号 3 的日程，请回复 1-2 或更具体的名称。"
    )
  }
}

final class AgentCalendarDeleteSelectionParserTests: XCTestCase {
  private func event(_ title: String) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, 15)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testNumberIndexArabicAndChinese() {
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("1"), 0)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("2"), 1)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("一"), 0)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("十"), 9)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("第2个"), 1)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("第3号"), 2)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("4号"), 3)
    XCTAssertEqual(AgentCalendarDeleteSelectionParser.numberIndex("5个"), 4)
    XCTAssertNil(AgentCalendarDeleteSelectionParser.numberIndex("下午1点"))
    XCTAssertNil(AgentCalendarDeleteSelectionParser.numberIndex("0"))
    XCTAssertNil(AgentCalendarDeleteSelectionParser.numberIndex("谢谢"))
    XCTAssertNil(AgentCalendarDeleteSelectionParser.numberIndex(""))
  }

  func testIsCancelExactMatchOnly() {
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isCancel("取消"))
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isCancel("算了"))
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isCancel("不删了"))
    XCTAssertFalse(AgentCalendarDeleteSelectionParser.isCancel("取消今天的会议"))
    XCTAssertFalse(AgentCalendarDeleteSelectionParser.isCancel("谢谢"))
  }

  func testIsPotentialSelection() {
    let candidates = [event("产品评审"), event("技术评审")]
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isPotentialSelection("1", candidates: candidates))
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isPotentialSelection("取消", candidates: candidates))
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isPotentialSelection("产品评审", candidates: candidates))
    XCTAssertTrue(AgentCalendarDeleteSelectionParser.isPotentialSelection("评审", candidates: candidates))
    XCTAssertFalse(AgentCalendarDeleteSelectionParser.isPotentialSelection("今天天气怎么样", candidates: candidates))
    XCTAssertFalse(AgentCalendarDeleteSelectionParser.isPotentialSelection("", candidates: candidates))
  }
}

@MainActor
final class AgentCalendarDeleteSelectionCoordinatorTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system
  private var observer: NSObjectProtocol?
  private var receivedSignal = false

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
    AgentCalendarDeletePendingStore.clear()
    receivedSignal = false
    observer = NotificationCenter.default.addObserver(
      forName: AgentHomeCardRefreshCenter.didChangeName,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.receivedSignal = true
    }
  }

  override func tearDown() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    AgentCalendarDeletePendingStore.clear()
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func event(_ title: String, _ hour: Int) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  private func storeTwoCandidates() -> MockCalendarProvider {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    AgentCalendarDeletePendingStore.store([
      event("产品评审", 15),
      event("技术评审", 16),
    ])
    return provider
  }

  func testNoPendingReturnsNil() async {
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "1",
      provider: MockCalendarProvider()
    )
    XCTAssertNil(reply)
  }

  func testNumberSelectsAndDeletes() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "1",
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "已删除：今天 15:00-16:00 产品评审。")
    XCTAssertEqual(provider.deleted.count, 1)
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
    XCTAssertTrue(receivedSignal)
  }

  func testChineseNumberSelectsSecond() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "第二个",
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "已删除：今天 16:00-17:00 技术评审。")
    XCTAssertEqual(provider.deleted[0].title, "技术评审")
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
  }

  func testNumberOutOfRangeKeepsPending() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "3",
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "没有序号 3 的日程，请回复 1-2 或更具体的名称。")
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertEqual(AgentCalendarDeletePendingStore.candidates.count, 2)
    XCTAssertFalse(receivedSignal)
  }

  func testCancelClearsPending() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "取消",
      provider: provider
    )
    XCTAssertEqual(reply, "已取消删除。")
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
    XCTAssertFalse(receivedSignal)
  }

  func testUniqueNameSelects() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "技术评审",
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "已删除：今天 16:00-17:00 技术评审。")
    XCTAssertEqual(provider.deleted.count, 1)
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
    XCTAssertTrue(receivedSignal)
  }

  func testMultiNameNarrowsCandidates() async {
    AgentCalendarDeletePendingStore.store([
      event("产品评审", 15),
      event("产品评审", 17),
    ])
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "产品评审",
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(reply?.hasPrefix("找到 2 个匹配日程：") == true)
    XCTAssertTrue(reply?.contains("1. 今天 15:00-16:00 产品评审") == true)
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertEqual(AgentCalendarDeletePendingStore.candidates.count, 2)
    // 收窄后仍可继续用序号选择
    let second = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "2",
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(second, "已删除：今天 17:00-18:00 产品评审。")
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
  }

  func testUnrelatedMessageKeepsPending() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "今天天气怎么样",
      provider: provider
    )
    XCTAssertNil(reply)
    XCTAssertEqual(AgentCalendarDeletePendingStore.candidates.count, 2)
    XCTAssertTrue(provider.deleted.isEmpty)
  }

  func testDeleteFailureReturnsFailedAndClearsPending() async {
    let provider = storeTwoCandidates()
    provider.deleteError = MockError.saveFailed
    let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
      text: "1",
      provider: provider
    )
    XCTAssertEqual(reply, "删除失败，请稍后再试")
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
    XCTAssertFalse(receivedSignal)
  }

  func testButtonSelectMatchesByTitleAndStart() async {
    let provider = storeTwoCandidates()
    let reply = await AgentCalendarDeleteSelectionCoordinator.select(
      matching: event("技术评审", 16),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "已删除：今天 16:00-17:00 技术评审。")
    XCTAssertEqual(provider.deleted.count, 1)
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
    XCTAssertTrue(receivedSignal)
  }

  func testButtonSelectStaleReturnsNil() async {
    let provider = storeTwoCandidates()
    // 语音通道已消费待选
    AgentCalendarDeletePendingStore.clear()
    let reply = await AgentCalendarDeleteSelectionCoordinator.select(
      matching: event("技术评审", 16),
      provider: provider
    )
    XCTAssertNil(reply)
    XCTAssertTrue(provider.deleted.isEmpty)
  }

  func testButtonCancelClearsPending() async {
    let provider = storeTwoCandidates()
    let reply = AgentCalendarDeleteSelectionCoordinator.cancel()
    XCTAssertEqual(reply, "已取消删除。")
    XCTAssertTrue(provider.deleted.isEmpty)
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
    XCTAssertFalse(receivedSignal)
  }
}

@MainActor
final class AgentCalendarDeletePendingExecutorTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
    AgentCalendarDeletePendingStore.clear()
  }

  override func tearDown() {
    AgentCalendarDeletePendingStore.clear()
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func event(_ title: String, _ hour: Int) -> AgentCalendarEvent {
    let start = AgentCalendarTestClock.date(2026, 8, 12, hour)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testAmbiguousStoresCandidatesAndReturnsPrompt() async {
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15), event("技术评审", 16)]
    let reply = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(reply.hasPrefix("找到 2 个匹配日程："))
    XCTAssertTrue(reply.contains("1. 今天 15:00-16:00 产品评审"))
    XCTAssertEqual(AgentCalendarDeletePendingStore.candidates.count, 2)
  }

  func testUniqueDeleteClearsPending() async {
    AgentCalendarDeletePendingStore.store([event("旧日程", 9)])
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = [event("产品评审", 15)]
    _ = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
  }

  func testNotFoundClearsPending() async {
    AgentCalendarDeletePendingStore.store([event("旧日程", 9)])
    let provider = MockCalendarProvider()
    provider.authorization = .authorized
    provider.events = []
    _ = await AgentCalendarExecutor.execute(
      .delete(
        keyword: "评审",
        start: AgentCalendarTestClock.date(2026, 8, 12, 0),
        end: AgentCalendarTestClock.date(2026, 8, 13, 0)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
  }

  func testCreateAndQueryClearPending() async {
    AgentCalendarDeletePendingStore.store([event("旧日程", 9)])
    let provider = MockCalendarProvider()
    _ = await AgentCalendarExecutor.execute(
      .create(
        title: "会议",
        start: AgentCalendarTestClock.now,
        end: AgentCalendarTestClock.now.addingTimeInterval(3600)
      ),
      provider: provider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)

    AgentCalendarDeletePendingStore.store([event("旧日程", 9)])
    let queryProvider = MockCalendarProvider()
    queryProvider.authorization = .authorized
    _ = await AgentCalendarExecutor.execute(
      .query(
        start: AgentCalendarTestClock.date(2026, 8, 12),
        end: AgentCalendarTestClock.date(2026, 8, 13)
      ),
      provider: queryProvider,
      now: AgentCalendarTestClock.now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertTrue(AgentCalendarDeletePendingStore.candidates.isEmpty)
  }
}
