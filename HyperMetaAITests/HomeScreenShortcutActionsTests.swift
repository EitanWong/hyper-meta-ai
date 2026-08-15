import UIKit
import XCTest

@testable import HyperMetaAI

/// 主屏快捷操作：identifier → 路由映射与项构造（纯逻辑）
@MainActor
final class HomeScreenShortcutActionsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  // MARK: - 映射

  func testStaticRouteMapping() {
    XCTAssertEqual(
      HomeScreenShortcutActions.route(for: HomeScreenShortcutActions.voiceIdentifier),
      .startVoiceSession
    )
    XCTAssertEqual(
      HomeScreenShortcutActions.route(for: HomeScreenShortcutActions.stopIdentifier),
      .stopVoiceSession
    )
    XCTAssertEqual(
      HomeScreenShortcutActions.route(for: HomeScreenShortcutActions.visionIdentifier),
      .quickVision
    )
    XCTAssertNil(HomeScreenShortcutActions.route(for: "unknown.identifier"))
    XCTAssertNil(HomeScreenShortcutActions.route(for: ""))
  }

  func testReminderRouteMapping() {
    let id = UUID()
    let identifier = HomeScreenShortcutActions.reminderIdentifierPrefix + id.uuidString
    XCTAssertEqual(HomeScreenShortcutActions.route(for: identifier), .announceReminder(id))
    XCTAssertNil(
      HomeScreenShortcutActions.route(for: HomeScreenShortcutActions.reminderIdentifierPrefix + "not-a-uuid")
    )
    XCTAssertNil(HomeScreenShortcutActions.route(for: HomeScreenShortcutActions.reminderIdentifierPrefix))
  }

  // MARK: - 项构造

  func testStaticItems() {
    let items = HomeScreenShortcutActions.staticItems()
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items[0].type, HomeScreenShortcutActions.voiceIdentifier)
    XCTAssertEqual(items[1].type, HomeScreenShortcutActions.stopIdentifier)
    XCTAssertEqual(items[2].type, HomeScreenShortcutActions.visionIdentifier)
    for item in items {
      XCTAssertFalse(item.localizedTitle.isEmpty)
      XCTAssertNotNil(item.localizedSubtitle)
    }
  }

  func testItemsWithoutRemindersKeepStaticOnly() {
    let items = HomeScreenShortcutActions.items(reminders: [], now: now, calendar: calendar)
    XCTAssertEqual(items.count, 3)
  }

  func testItemsIncludeNextReminder() {
    let reminder = AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))
    let items = HomeScreenShortcutActions.items(reminders: [reminder], now: now, calendar: calendar)
    XCTAssertEqual(items.count, 4)
    XCTAssertEqual(
      items[3].type,
      HomeScreenShortcutActions.reminderIdentifierPrefix + reminder.id.uuidString
    )
    XCTAssertTrue(items[3].localizedTitle.contains("喝水"))
    XCTAssertEqual(items[3].localizedSubtitle, "agent.reminder.time.minutes".localized(10))
    XCTAssertEqual(
      items[3].userInfo?[HomeScreenShortcutActions.reminderIdentifierUserInfoKey] as? String,
      reminder.id.uuidString
    )
  }

  func testExpiredOneShotExcludedFromDynamicItem() {
    let expired = AgentReminder(text: "过期", fireDate: now.addingTimeInterval(-60))
    let items = HomeScreenShortcutActions.items(reminders: [expired], now: now, calendar: calendar)
    XCTAssertEqual(items.count, 3, "过期的单次提醒不进入快捷操作")
  }

  func testRepeatingReminderIncludedAsNext() {
    let repeating = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(-3600), repeatRule: .daily)
    let items = HomeScreenShortcutActions.items(reminders: [repeating], now: now, calendar: calendar)
    XCTAssertEqual(items.count, 4, "周期提醒仍会触发，保留为下次提醒")
    XCTAssertEqual(
      items[3].type,
      HomeScreenShortcutActions.reminderIdentifierPrefix + repeating.id.uuidString
    )
  }

  func testReminderItemSubtitleForRepeating() {
    let repeating = AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(-3600), repeatRule: .daily)
    let item = HomeScreenShortcutActions.reminderItem(for: repeating, now: now, calendar: calendar)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    let expected = String(
      format: "agent.reminder.time.repeating.daily".localized,
      formatter.string(from: repeating.fireDate)
    )
    XCTAssertEqual(item?.localizedSubtitle, expected, "周期提醒显示「每天 HH:mm」")
  }
}
