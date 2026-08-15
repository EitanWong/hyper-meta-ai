/*
 * System Schema Intent Tests
 * assistant.activate / reminders.createReminder / reminders.createList 的运行时行为：
 * 意图真实执行 + 业务落库断言（iOS 26.2 / 27.0 运行时代码在低版本模拟器上跳过）。
 */

import XCTest

@testable import HyperMetaAI

@MainActor
final class SystemSchemaIntentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentReminderStore.clear()
        AgentListStore.clear()
        ReminderSchemaService.scheduleOverride = { _ in }
    }

    override func tearDown() {
        ReminderSchemaService.scheduleOverride = nil
        AgentReminderStore.clear()
        AgentListStore.clear()
        VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
        super.tearDown()
    }

    func testActivateIntentRequestsVoiceSession() async throws {
        guard #available(iOS 26.2, *) else {
            throw XCTSkip("assistant.activate 需要 iOS 26.2")
        }
        let router = VoiceAssistantRouter.shared
        router.consumeVoiceSessionRequest()
        var woken = false
        let previous = router.wakeExecutor
        router.wakeExecutor = { woken = true }
        defer {
            router.wakeExecutor = previous
            router.consumeVoiceSessionRequest()
        }

        let intent = ActivateVoiceAssistantSceneIntent()
        _ = try await intent.perform()

        XCTAssertTrue(woken)
        XCTAssertTrue(router.isVoiceSessionRequested)
    }

    func testCreateReminderIntentPersistsReminder() async throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("reminders.createReminder 需要 iOS 27.0")
        }
        var intent = CreateAgentReminderAppIntent()
        intent.title = "买咖啡"
        intent.note = "拿铁"
        intent.tags = Set(["咖啡"])
        intent.urls = []
        intent.images = []

        let result = try await intent.perform()

        let stored = AgentReminderStore.reminders.first
        let value = try XCTUnwrap(result.value)
        XCTAssertEqual(stored?.text, "买咖啡\n拿铁\n#咖啡")
        XCTAssertEqual(value.title, "买咖啡")
        XCTAssertEqual(value.note, "拿铁")
        XCTAssertEqual(value.tags, ["咖啡"])
    }

    func testCreateListIntentPersistsList() async throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("reminders.createList 需要 iOS 27.0")
        }
        var intent = CreateAgentReminderListAppIntent()
        intent.name = "购物单"
        intent.type = .standard

        let result = try await intent.perform()

        let value = try XCTUnwrap(result.value)
        XCTAssertEqual(value.name, "购物单")
        XCTAssertNotNil(AgentListStore.list(named: "购物单"))
    }

    func testRecurrenceMapping() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("Calendar.RecurrenceRule 映射需要 iOS 27.0")
        }
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(
            ReminderRecurrenceMapper.repeatRule(Calendar.RecurrenceRule(calendar: calendar, frequency: .daily)),
            .daily
        )
        XCTAssertEqual(
            ReminderRecurrenceMapper.repeatRule(Calendar.RecurrenceRule(calendar: calendar, frequency: .weekly)),
            .weekly
        )
        XCTAssertEqual(
            ReminderRecurrenceMapper.repeatRule(Calendar.RecurrenceRule(calendar: calendar, frequency: .monthly)),
            .none
        )
        XCTAssertEqual(ReminderRecurrenceMapper.repeatRule(nil), .none)
    }

    func testReminderEntityQueryResolvesStoredReminders() async throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("reminders.reminder 实体需要 iOS 27.0")
        }
        let reminder = AgentReminderStore.add(text: "喝水", fireDate: Date())!
        defer { AgentReminderStore.clear() }

        let query = AgentReminderEntity.DefaultQuery()
        let resolved = try await query.entities(for: [reminder.id])
        XCTAssertEqual(resolved.map(\.id), [reminder.id])
        XCTAssertEqual(resolved.first?.title, "喝水")
    }

    func testReminderListEntityQueryMatchesByName() async throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("reminders.list 实体需要 iOS 27.0")
        }
        let list = AgentListStore.createList(named: "购物单")!
        defer { AgentListStore.clear() }

        let query = AgentReminderListEntity.DefaultQuery()
        let matched = try await query.entities(matching: "购物")
        XCTAssertEqual(matched.map(\.id), [list.id])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), [list.id])
    }
}
