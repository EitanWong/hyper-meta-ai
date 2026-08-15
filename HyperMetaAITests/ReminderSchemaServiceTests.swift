/*
 * Reminder Schema Service Tests
 * 系统提醒 Schema 的业务层：默认触发时间、时间解析、备注 / 标签 / 链接合并、
 * 重复规则透传、失败分支与调度副作用（全部注入，不触碰系统通知）。
 */

import XCTest

@testable import HyperMetaAI

@MainActor
final class ReminderSchemaServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC

    private var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        AgentReminderStore.clear()
        ReminderSchemaService.scheduleOverride = { _ in }
    }

    override func tearDown() {
        ReminderSchemaService.scheduleOverride = nil
        AgentReminderStore.clear()
        super.tearDown()
    }

    func testEmptyTitleFails() {
        let outcome = ReminderSchemaService.createReminder(
            title: "   ",
            now: now,
            calendar: utcCalendar
        )
        XCTAssertEqual(outcome, .failed(.emptyTitle))
    }

    func testStoreRejectionFailsAsLimitReached() {
        let outcome = ReminderSchemaService.createReminder(
            title: "喝水",
            store: { _ in nil }
        )
        XCTAssertEqual(outcome, .failed(.limitReached))
    }

    func testDefaultsToOneHourLeadTime() {
        var stored: AgentReminder?
        var scheduled: AgentReminder?
        let outcome = ReminderSchemaService.createReminder(
            title: "喝水",
            now: now,
            calendar: utcCalendar,
            store: { stored = $0; return $0 },
            schedule: { scheduled = $0 }
        )
        guard case .created(let created) = outcome else {
            return XCTFail("应当创建成功")
        }
        XCTAssertEqual(created.reminder.fireDate, now.addingTimeInterval(3600))
        XCTAssertEqual(stored?.fireDate, now.addingTimeInterval(3600))
        XCTAssertEqual(scheduled?.id, created.reminder.id)
        XCTAssertEqual(created.title, "喝水")
        XCTAssertNil(created.note)
        XCTAssertTrue(created.tags.isEmpty)
        XCTAssertTrue(created.urls.isEmpty)
    }

    func testDueDateResolvesThroughCalendar() {
        let outcome = ReminderSchemaService.createReminder(
            title: "喝水",
            dueDate: DateComponents(year: 2026, month: 8, day: 13, hour: 9, minute: 30),
            now: now,
            calendar: utcCalendar,
            store: { $0 },
            schedule: { _ in }
        )
        guard case .created(let created) = outcome else {
            return XCTFail("应当创建成功")
        }
        let expected = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 9, minute: 30))
        XCTAssertEqual(created.reminder.fireDate, expected)
    }

    func testNoteTagsAndUrlsMergeIntoStoredText() {
        let outcome = ReminderSchemaService.createReminder(
            title: "买牛奶",
            note: "低脂",
            tags: ["购物", "周末"],
            urls: [URL(string: "https://example.com/list")!],
            now: now,
            calendar: utcCalendar,
            store: { $0 },
            schedule: { _ in }
        )
        guard case .created(let created) = outcome else {
            return XCTFail("应当创建成功")
        }
        XCTAssertEqual(created.title, "买牛奶")
        XCTAssertEqual(created.note, "低脂")
        XCTAssertEqual(created.tags, ["购物", "周末"])
        XCTAssertEqual(created.urls.map(\.absoluteString), ["https://example.com/list"])
        XCTAssertEqual(created.reminder.text, "买牛奶\n低脂\n#周末 #购物\nhttps://example.com/list")
    }

    func testBlankNoteIsOmitted() {
        let outcome = ReminderSchemaService.createReminder(
            title: "喝水",
            note: "   ",
            store: { $0 },
            schedule: { _ in }
        )
        guard case .created(let created) = outcome else {
            return XCTFail("应当创建成功")
        }
        XCTAssertNil(created.note)
        XCTAssertEqual(created.reminder.text, "喝水")
    }

    func testRepeatRulePassesThrough() {
        var stored: AgentReminder?
        let outcome = ReminderSchemaService.createReminder(
            title: "喝水",
            repeatRule: .daily,
            now: now,
            calendar: utcCalendar,
            store: { stored = $0; return $0 },
            schedule: { _ in }
        )
        guard case .created = outcome else {
            return XCTFail("应当创建成功")
        }
        XCTAssertEqual(stored?.repeatRule, .daily)
    }

    func testScheduleSkippedOnFailure() {
        var scheduled = false
        let outcome = ReminderSchemaService.createReminder(
            title: "  ",
            store: { _ in nil },
            schedule: { _ in scheduled = true }
        )
        XCTAssertEqual(outcome, .failed(.emptyTitle))
        XCTAssertFalse(scheduled)
    }

    func testScheduleOverrideUsedWhenNoExplicitSchedule() {
        var scheduled: AgentReminder?
        ReminderSchemaService.scheduleOverride = { scheduled = $0 }
        let outcome = ReminderSchemaService.createReminder(
            title: "喝水",
            store: { $0 }
        )
        guard case .created(let created) = outcome else {
            return XCTFail("应当创建成功")
        }
        XCTAssertEqual(scheduled?.id, created.reminder.id)
    }
}

@MainActor
final class ReminderListSchemaServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentListStore.clear()
    }

    override func tearDown() {
        AgentListStore.clear()
        super.tearDown()
    }

    func testEmptyNameFails() {
        XCTAssertEqual(
            ReminderListSchemaService.createList(name: "  "),
            .failed(.emptyName)
        )
    }

    func testDuplicateNameFails() {
        XCTAssertNotNil(AgentListStore.createList(named: "购物单"))
        XCTAssertEqual(
            ReminderListSchemaService.createList(name: "购物单"),
            .failed(.duplicate)
        )
    }

    func testDuplicateNameIsCaseAndSpaceInsensitive() {
        XCTAssertNotNil(AgentListStore.createList(named: "购物单"))
        XCTAssertEqual(
            ReminderListSchemaService.createList(name: " 购物单 "),
            .failed(.duplicate)
        )
    }

    func testStoreRejectionFailsAsLimitReached() {
        let outcome = ReminderListSchemaService.createList(
            name: "新清单",
            store: { _ in nil }
        )
        XCTAssertEqual(outcome, .failed(.limitReached))
    }

    func testCreateListSucceeds() {
        guard case .created(let list) = ReminderListSchemaService.createList(name: "购物单") else {
            return XCTFail("应当创建成功")
        }
        XCTAssertEqual(list.name, "购物单")
        XCTAssertEqual(AgentListStore.list(named: "购物单")?.id, list.id)
    }

    func testNameIsTrimmed() {
        guard case .created(let list) = ReminderListSchemaService.createList(name: " 待办 ") else {
            return XCTFail("应当创建成功")
        }
        XCTAssertEqual(list.name, "待办")
    }
}
