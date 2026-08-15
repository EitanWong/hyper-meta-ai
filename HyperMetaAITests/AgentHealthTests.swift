import XCTest
@testable import HyperMetaAI

// MARK: - 指令解析

final class AgentHealthCommandParserTests: XCTestCase {
  // 2026-08-13 08:00 +0800
  private let now = AgentCalendarTestClock.date(2026, 8, 13, 8)

  private func parse(_ text: String) -> AgentHealthCommand? {
    AgentHealthCommandParser.parse(text, now: now, calendar: AgentCalendarTestClock.calendar)
  }

  func testRecordWeight() {
    XCTAssertEqual(
      parse("记录体重65公斤"),
      .recordWeight(65, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("记一下体重65.5kg"),
      .recordWeight(65.5, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("把体重记为70千克"),
      .recordWeight(70, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("记录体重72"),
      .recordWeight(72, AgentCalendarTestClock.date(2026, 8, 13)),
      "无单位也允许（默认公斤）"
    )
  }

  func testRecordWeightRejectsInvalid() {
    XCTAssertNil(parse("记录体重"), "缺数字")
    XCTAssertNil(parse("记录体重七十公斤"), "中文数字不支持")
    XCTAssertNil(parse("记录体重65斤"), "非公斤单位")
  }

  func testRecordSteps() {
    XCTAssertEqual(
      parse("记录步数8000"),
      .recordSteps(8000, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("记录步数8000步"),
      .recordSteps(8000, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("今天走了8000步"),
      .recordSteps(8000, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("昨天走了6000步"),
      .recordSteps(6000, AgentCalendarTestClock.date(2026, 8, 12))
    )
  }

  func testRecordStepsRejectsInvalid() {
    XCTAssertNil(parse("今天走了八千步"))
    XCTAssertNil(parse("走了很多步"))
  }

  func testRecordRun() {
    XCTAssertEqual(
      parse("记录跑步5公里"),
      .recordRun(5, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("我跑了3.5公里"),
      .recordRun(3.5, AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("跑了10km"),
      .recordRun(10, AgentCalendarTestClock.date(2026, 8, 13))
    )
  }

  func testRecordRunRejectsInvalid() {
    XCTAssertNil(parse("跑了一趟银行"))
    XCTAssertNil(parse("记录跑步"))
  }

  func testQuerySteps() {
    XCTAssertEqual(
      parse("今天走了多少步"),
      .querySteps(AgentCalendarTestClock.date(2026, 8, 13))
    )
    XCTAssertEqual(
      parse("昨天走了多少步"),
      .querySteps(AgentCalendarTestClock.date(2026, 8, 12))
    )
    XCTAssertEqual(
      parse("走了多少步"),
      .querySteps(AgentCalendarTestClock.date(2026, 8, 13)),
      "无日期词默认今天"
    )
  }

  func testQueryWeightAndSleep() {
    XCTAssertEqual(parse("我体重多少"), .queryWeight)
    XCTAssertEqual(parse("查一下体重"), .queryWeight)
    XCTAssertEqual(parse("昨晚睡了多久"), .querySleep)
    XCTAssertEqual(parse("睡眠怎么样"), .querySleep)
  }

  func testNonHealthTextIsNotIntercepted() {
    XCTAssertNil(parse("把牛奶加到购物单"))
    XCTAssertNil(parse("记录一下今天的心情"))
    XCTAssertNil(parse("今天走了多少步明天还要走多少步后天呢"))
    XCTAssertNil(parse(""))
  }

  func testNumberParser() {
    XCTAssertEqual(AgentHealthCommandParser.parseNumber("65")?.value, 65)
    XCTAssertEqual(AgentHealthCommandParser.parseNumber("65")?.consumedCount, 2)
    XCTAssertEqual(AgentHealthCommandParser.parseNumber("65.5公斤")?.value, 65.5)
    XCTAssertEqual(AgentHealthCommandParser.parseNumber("65点5公斤")?.value, 65.5)
    XCTAssertEqual(AgentHealthCommandParser.parseNumber("8000步")?.value, 8000)
    XCTAssertNil(AgentHealthCommandParser.parseNumber("点5"))
    XCTAssertNil(AgentHealthCommandParser.parseNumber(""))
  }
}

// MARK: - 时间窗

final class AgentHealthTimeWindowTests: XCTestCase {

  func testLastNightWindow() {
    let window = AgentHealthTimeWindow.lastNight(
      now: AgentCalendarTestClock.date(2026, 8, 13, 8),
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(window.start, AgentCalendarTestClock.date(2026, 8, 12, 22))
    XCTAssertEqual(window.end, AgentCalendarTestClock.date(2026, 8, 13, 10))
  }
}

// MARK: - 文案格式化

@MainActor
final class AgentHealthFormatterTests: XCTestCase {
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

  func testUnits() {
    XCTAssertEqual(AgentHealthFormatter.weight(65), "65公斤")
    XCTAssertEqual(AgentHealthFormatter.weight(65.5), "65.5公斤")
    XCTAssertEqual(AgentHealthFormatter.steps(8000), "8000步")
    XCTAssertEqual(AgentHealthFormatter.run(5), "5公里")
    XCTAssertEqual(AgentHealthFormatter.sleepHours(7.5), "7.5小时")
    XCTAssertEqual(AgentHealthFormatter.sleepHours(7), "7小时")
  }

  func testDateLabel() {
    let calendar = AgentCalendarTestClock.calendar
    let now = AgentCalendarTestClock.date(2026, 8, 13, 8)
    XCTAssertEqual(AgentHealthFormatter.dateLabel(AgentCalendarTestClock.date(2026, 8, 13, 10), now: now, calendar: calendar), "今天")
    XCTAssertEqual(AgentHealthFormatter.dateLabel(AgentCalendarTestClock.date(2026, 8, 12, 22), now: now, calendar: calendar), "昨天")
  }
}

// MARK: - 执行器（Mock provider）

private final class MockHealthProvider: AgentHealthProviding {
  var authorization: AgentHealthAuthorization = .notDetermined
  var authorizationAfterRequest: AgentHealthAuthorization = .authorized
  var requestAuthorizationCount = 0
  var stepsResult = 0
  var weightResult: (kilograms: Double, date: Date)?
  var sleepResult: Double = 0
  var queryError: Error?
  var writeError: Error?
  var recordedSteps: [Int] = []
  var recordedWeights: [Double] = []
  var recordedRuns: [Double] = []

  func requestAuthorization() async -> AgentHealthAuthorization {
    requestAuthorizationCount += 1
    authorization = authorizationAfterRequest
    return authorization
  }

  func recordSteps(_ count: Int, date: Date) async throws {
    if let writeError { throw writeError }
    recordedSteps.append(count)
  }

  func recordBodyMass(kilograms: Double, date: Date) async throws {
    if let writeError { throw writeError }
    recordedWeights.append(kilograms)
  }

  func recordRun(kilometers: Double, date: Date) async throws {
    if let writeError { throw writeError }
    recordedRuns.append(kilometers)
  }

  func steps(from start: Date, to end: Date) async throws -> Int {
    if let queryError { throw queryError }
    return stepsResult
  }

  func latestBodyMass() async throws -> (kilograms: Double, date: Date)? {
    if let queryError { throw queryError }
    return weightResult
  }

  func sleepHours(from start: Date, to end: Date) async throws -> Double {
    if let queryError { throw queryError }
    return sleepResult
  }
}

private enum MockHealthError: Error {
  case failed
}

@MainActor
final class AgentHealthExecutorTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system
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

  func testRecordWeightAuthorized() async {
    let provider = MockHealthProvider()
    let reply = await AgentHealthExecutor.execute(
      .recordWeight(65, AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "已记录体重：65公斤。")
    XCTAssertEqual(provider.recordedWeights, [65])
    XCTAssertEqual(provider.requestAuthorizationCount, 1)
  }

  func testRecordStepsDenied() async {
    let provider = MockHealthProvider()
    provider.authorizationAfterRequest = .denied
    let reply = await AgentHealthExecutor.execute(
      .recordSteps(8000, AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "健康权限未开启，请在设置中允许访问健康数据。")
    XCTAssertTrue(provider.recordedSteps.isEmpty)
  }

  func testRecordRunFailure() async {
    let provider = MockHealthProvider()
    provider.writeError = MockHealthError.failed
    let reply = await AgentHealthExecutor.execute(
      .recordRun(5, AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "无法保存到健康数据。")
  }

  func testQueryStepsToday() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    provider.stepsResult = 8000
    let reply = await AgentHealthExecutor.execute(
      .querySteps(AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "今天走了8000步。")
  }

  func testQueryStepsYesterday() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    provider.stepsResult = 6000
    let reply = await AgentHealthExecutor.execute(
      .querySteps(AgentCalendarTestClock.date(2026, 8, 12)),
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "昨天走了6000步。")
  }

  func testQueryStepsEmpty() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    let reply = await AgentHealthExecutor.execute(
      .querySteps(AgentCalendarTestClock.date(2026, 8, 13)),
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "今天还没有步数记录。")
  }

  func testQueryWeight() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    provider.weightResult = (kilograms: 65.5, date: AgentCalendarTestClock.date(2026, 8, 12, 20))
    let reply = await AgentHealthExecutor.execute(
      .queryWeight,
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "最近体重：65.5公斤（昨天）。")
  }

  func testQueryWeightEmpty() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    let reply = await AgentHealthExecutor.execute(
      .queryWeight,
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "还没有体重记录。")
  }

  func testQuerySleep() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    provider.sleepResult = 7.5
    let reply = await AgentHealthExecutor.execute(
      .querySleep,
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "昨晚睡了约7.5小时。")
  }

  func testQuerySleepEmpty() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    let reply = await AgentHealthExecutor.execute(
      .querySleep,
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "昨晚没有睡眠记录。")
  }

  func testQueryFailure() async {
    let provider = MockHealthProvider()
    provider.authorization = .authorized
    provider.queryError = MockHealthError.failed
    let reply = await AgentHealthExecutor.execute(
      .querySleep,
      provider: provider,
      now: now,
      calendar: AgentCalendarTestClock.calendar
    )
    XCTAssertEqual(reply, "无法读取健康数据。")
  }
}
