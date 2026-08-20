/*
 * Agent Wearable Trigger Tests
 * 触发路由（含去抖）、URL 触发解析、触发日志存储与文案格式化。
 */

import XCTest
@testable import HyperMetaAI

// MARK: - 路由

final class AgentWearableTriggerRouterTests: XCTestCase {
    func testWakeAlwaysMapsToTurnCommand() {
        // 每个断言用独立 router，避免同源同手势命中去抖
        var idleRouter = AgentWearableTriggerRouter()
        XCTAssertEqual(
            idleRouter.route(source: .backTap, gesture: .wake, isSessionActive: false),
            .turn(.wake)
        )
        var activeRouter = AgentWearableTriggerRouter()
        XCTAssertEqual(
            activeRouter.route(source: .backTap, gesture: .wake, isSessionActive: true),
            .turn(.wake)
        )
    }

    func testSessionGesturesRequireActiveSession() {
        let cases: [(AgentWearableGesture, AgentWearableOutcome)] = [
            (.interrupt, .turn(.interrupt)),
            (.resume, .turn(.resume)),
            (.endTurn, .turn(.endTurn)),
            (.repeatLastReply, .repeatLastReply)
        ]
        for (gesture, activeOutcome) in cases {
            var idleRouter = AgentWearableTriggerRouter()
            XCTAssertEqual(
                idleRouter.route(source: .backTap, gesture: gesture, isSessionActive: false),
                .ignored(.noActiveSession),
                "\(gesture) should be ignored without an active session"
            )
            var activeRouter = AgentWearableTriggerRouter()
            XCTAssertEqual(
                activeRouter.route(source: .backTap, gesture: gesture, isSessionActive: true),
                activeOutcome,
                "\(gesture) should map while session is active"
            )
        }
    }

    func testCaptureVisionAlwaysAllowed() {
        var router = AgentWearableTriggerRouter()
        XCTAssertEqual(
            router.route(source: .backTap, gesture: .captureVision, isSessionActive: false),
            .captureVision
        )
    }

    func testCaptureButtonUsesVisionCapturePath() {
        var router = AgentWearableTriggerRouter()
        XCTAssertEqual(
            router.route(source: .glassesCaptureButton, gesture: .captureButton, isSessionActive: false),
            .captureVision
        )
    }

    func testDoubleTapIsExplicitlyReportedUnsupported() {
        var router = AgentWearableTriggerRouter()
        XCTAssertEqual(
            router.route(source: .glassesSession, gesture: .doubleTap, isSessionActive: false),
            .ignored(.unsupportedGesture)
        )
    }

    func testTouchCatalogSeparatesSupportedAndUnavailableHardwareEvents() {
        let singleTap = AgentWearableTouchCatalog.realGlasses.first { $0.kind == .singleTap }
        let doubleTap = AgentWearableTouchCatalog.realGlasses.first { $0.kind == .doubleTap }
        let captureButton = AgentWearableTouchCatalog.realGlasses.first { $0.kind == .captureButton }
        XCTAssertEqual(singleTap?.isAvailable, true)
        XCTAssertEqual(doubleTap?.isAvailable, false)
        XCTAssertEqual(captureButton?.isAvailable, false)
    }

    func testMockTapMapsToWake() {
        var router = AgentWearableTriggerRouter()
        XCTAssertEqual(
            router.route(source: .mockCaptouch, gesture: .mockTap, isSessionActive: false),
            .turn(.wake)
        )
    }

    func testMockTapAndHoldRequiresActiveSession() {
        var idleRouter = AgentWearableTriggerRouter()
        XCTAssertEqual(
            idleRouter.route(source: .mockCaptouch, gesture: .mockTapAndHold, isSessionActive: false),
            .ignored(.noActiveSession)
        )
        var activeRouter = AgentWearableTriggerRouter()
        XCTAssertEqual(
            activeRouter.route(source: .mockCaptouch, gesture: .mockTapAndHold, isSessionActive: true),
            .turn(.endTurn)
        )
    }

    func testOutcomeCodesAreStable() {
        let cases: [(AgentWearableOutcome, String)] = [
            (.turn(.wake), "wake"),
            (.turn(.interrupt), "interrupt"),
            (.turn(.resume), "resume"),
            (.turn(.endTurn), "endTurn"),
            (.turn(.none), "none"),
            (.captureVision, "captureVision"),
            (.ignored(.unsupportedGesture), "ignored.unsupportedGesture"),
            (.repeatLastReply, "repeatLastReply"),
            (.newChat, "newChat"),
            (.dismissMenu, "dismiss"),
            (.ignored(.cooldown), "ignored.cooldown"),
            (.ignored(.noActiveSession), "ignored.noActiveSession")
        ]
        for (outcome, code) in cases {
            XCTAssertEqual(outcome.code, code)
        }
    }

    // MARK: 去抖

    func testCooldownDeduplicatesSameSourceAndGesture() {
        var router = AgentWearableTriggerRouter()
        let now = Date()
        XCTAssertEqual(
            router.route(source: .backTap, gesture: .wake, isSessionActive: false, now: now),
            .turn(.wake)
        )
        XCTAssertEqual(
            router.route(
                source: .backTap,
                gesture: .wake,
                isSessionActive: false,
                now: now.addingTimeInterval(0.3)
            ),
            .ignored(.cooldown)
        )
    }

    func testCooldownAllowsDifferentGesture() {
        var router = AgentWearableTriggerRouter()
        let now = Date()
        _ = router.route(source: .backTap, gesture: .wake, isSessionActive: false, now: now)
        XCTAssertEqual(
            router.route(
                source: .backTap,
                gesture: .captureVision,
                isSessionActive: false,
                now: now.addingTimeInterval(0.3)
            ),
            .captureVision
        )
    }

    func testCooldownAllowsDifferentSource() {
        var router = AgentWearableTriggerRouter()
        let now = Date()
        _ = router.route(source: .backTap, gesture: .wake, isSessionActive: false, now: now)
        XCTAssertEqual(
            router.route(
                source: .glassesSession,
                gesture: .wake,
                isSessionActive: false,
                now: now.addingTimeInterval(0.3)
            ),
            .turn(.wake)
        )
    }

    func testCooldownExpiresAfterInterval() {
        var router = AgentWearableTriggerRouter()
        let now = Date()
        _ = router.route(source: .backTap, gesture: .wake, isSessionActive: false, now: now)
        XCTAssertEqual(
            router.route(
                source: .backTap,
                gesture: .wake,
                isSessionActive: false,
                now: now.addingTimeInterval(AgentWearableTriggerRouter.cooldownInterval + 0.1)
            ),
            .turn(.wake)
        )
    }

    func testResetClearsCooldown() {
        var router = AgentWearableTriggerRouter()
        let now = Date()
        _ = router.route(source: .backTap, gesture: .wake, isSessionActive: false, now: now)
        router.reset()
        XCTAssertEqual(
            router.route(
                source: .backTap,
                gesture: .wake,
                isSessionActive: false,
                now: now.addingTimeInterval(0.3)
            ),
            .turn(.wake)
        )
    }
}

// MARK: - URL 触发解析

final class AgentWearableURLTriggerTests: XCTestCase {
    func testParsesValidGesture() throws {
        let url = try XCTUnwrap(URL(string: "hypermetaai://trigger?gesture=wake"))
        XCTAssertEqual(AgentWearableURLTrigger.parse(url: url), .wake)
    }

    func testParsesCaptureGesture() throws {
        let url = try XCTUnwrap(URL(string: "hypermetaai://trigger?gesture=captureVision"))
        XCTAssertEqual(AgentWearableURLTrigger.parse(url: url), .captureVision)
    }

    func testIgnoresNonTriggerHost() throws {
        let url = try XCTUnwrap(URL(string: "hypermetaai://register?gesture=wake"))
        XCTAssertNil(AgentWearableURLTrigger.parse(url: url))
    }

    func testIgnoresUnknownGesture() throws {
        let url = try XCTUnwrap(URL(string: "hypermetaai://trigger?gesture=fly"))
        XCTAssertNil(AgentWearableURLTrigger.parse(url: url))
    }

    func testIgnoresMissingGesture() throws {
        let url = try XCTUnwrap(URL(string: "hypermetaai://trigger"))
        XCTAssertNil(AgentWearableURLTrigger.parse(url: url))
    }

    func testIgnoresForeignScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://trigger?gesture=wake"))
        XCTAssertNil(AgentWearableURLTrigger.parse(url: url))
    }
}

// MARK: - 触发日志存储

final class AgentWearableLogStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.wearable.log")
        defaults.removePersistentDomain(forName: "test.agent.wearable.log")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.wearable.log")
        defaults = nil
        super.tearDown()
    }

    private func makeEntry(
        gesture: AgentWearableGesture = .wake,
        at date: Date = Date()
    ) -> AgentWearableLogEntry {
        AgentWearableLogEntry(
            id: UUID(),
            source: .backTap,
            gesture: gesture,
            outcomeCode: "wake",
            timestamp: date
        )
    }

    func testAddInsertsNewestFirst() {
        let first = makeEntry(at: Date(timeIntervalSince1970: 100))
        let second = makeEntry(gesture: .captureVision, at: Date(timeIntervalSince1970: 200))
        AgentWearableLogStore.add(first, defaults: defaults)
        AgentWearableLogStore.add(second, defaults: defaults)

        let entries = AgentWearableLogStore.load(defaults: defaults)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.gesture, .captureVision)
        XCTAssertEqual(entries.last?.gesture, .wake)
    }

    func testAddTrimsToLimit() {
        for index in 0..<(AgentWearableLogStore.maxEntries + 10) {
            AgentWearableLogStore.add(
                makeEntry(gesture: .wake, at: Date(timeIntervalSince1970: TimeInterval(index))),
                defaults: defaults
            )
        }
        let entries = AgentWearableLogStore.load(defaults: defaults)
        XCTAssertEqual(entries.count, AgentWearableLogStore.maxEntries)
        // 最新（时间最大）的保留在前
        XCTAssertEqual(
            entries.first?.timestamp,
            Date(timeIntervalSince1970: TimeInterval(AgentWearableLogStore.maxEntries + 9))
        )
    }

    func testPersistsAcrossLoads() {
        AgentWearableLogStore.add(makeEntry(), defaults: defaults)
        // 新实例读取同一 UserDefaults
        let reloaded = AgentWearableLogStore.load(
            defaults: UserDefaults(suiteName: "test.agent.wearable.log")!
        )
        XCTAssertEqual(reloaded.count, 1)
    }

    func testClearRemovesAll() {
        AgentWearableLogStore.add(makeEntry(), defaults: defaults)
        AgentWearableLogStore.clear(defaults: defaults)
        XCTAssertTrue(AgentWearableLogStore.load(defaults: defaults).isEmpty)
    }

    func testEmptyLoadReturnsEmpty() {
        XCTAssertTrue(AgentWearableLogStore.load(defaults: defaults).isEmpty)
    }
}

// MARK: - 日志文案

final class AgentWearableLogFormatterTests: XCTestCase {
    func testOutcomeTextMapsKnownCodes() {
        XCTAssertFalse(AgentWearableLogFormatter.outcomeText(code: "wake").isEmpty)
        XCTAssertFalse(AgentWearableLogFormatter.outcomeText(code: "ignored.cooldown").isEmpty)
        XCTAssertFalse(AgentWearableLogFormatter.outcomeText(code: "captureVision").isEmpty)
    }

    func testOutcomeTextFallsBackToCode() {
        XCTAssertEqual(AgentWearableLogFormatter.outcomeText(code: "unknown.code"), "unknown.code")
    }

    func testRelativeTimeJustNow() {
        XCTAssertEqual(
            AgentWearableLogFormatter.relativeTime(
                Date(timeIntervalSinceNow: -5),
                now: Date()
            ),
            "agent.wearable.log.relative.justNow".localized
        )
    }

    func testRelativeTimeMinutes() {
        let now = Date()
        let text = AgentWearableLogFormatter.relativeTime(
            now.addingTimeInterval(-120),
            now: now
        )
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(text, "agent.wearable.log.relative.minutes".localized(2))
    }

    func testRelativeTimeHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let text = AgentWearableLogFormatter.relativeTime(
            now.addingTimeInterval(-7200),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(text, "agent.wearable.log.relative.hours".localized(2))
    }

    func testRelativeTimeYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(
            AgentWearableLogFormatter.relativeTime(yesterday, now: now, calendar: calendar),
            "agent.wearable.log.relative.yesterday".localized
        )
    }

    func testRowTitleComposesSourceAndGesture() {
        let entry = AgentWearableLogEntry(
            id: UUID(),
            source: .backTap,
            gesture: .wake,
            outcomeCode: "wake",
            timestamp: Date()
        )
        let title = AgentWearableLogFormatter.rowTitle(entry)
        XCTAssertTrue(title.contains(AgentWearableSource.backTap.displayName))
        XCTAssertTrue(title.contains(AgentWearableGesture.wake.displayName))
    }

    func testRowDetailMapsOutcome() {
        let entry = AgentWearableLogEntry(
            id: UUID(),
            source: .backTap,
            gesture: .wake,
            outcomeCode: "ignored.cooldown",
            timestamp: Date()
        )
        XCTAssertEqual(
            AgentWearableLogFormatter.rowDetail(entry),
            AgentWearableLogFormatter.outcomeText(code: "ignored.cooldown")
        )
    }

    func testSourceIconsExistForAllSources() {
        for source in AgentWearableSource.allCases {
            XCTAssertFalse(source.iconName.isEmpty, "\(source) should have an icon")
        }
    }
}
