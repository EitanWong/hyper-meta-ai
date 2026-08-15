import XCTest
@testable import HyperMetaAI

/// 任务 Live Activity「取消 / 加速」请求标记（App Group 通道）
final class AgentTaskControlTapStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.task.control.tap.v1")
        suite.removePersistentDomain(forName: "test.task.control.tap.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.task.control.tap.v1")
        super.tearDown()
    }

    func testConsumeRoundTrip() {
        suite.set("cancel", forKey: AgentTaskControlTapStore.requestKey)
        XCTAssertEqual(AgentTaskControlTapStore.consume(defaults: suite), "cancel")
        XCTAssertNil(AgentTaskControlTapStore.consume(defaults: suite), "一次性消费，读到即清除")
    }

    func testConsumeAccelerate() {
        suite.set("accelerate", forKey: AgentTaskControlTapStore.requestKey)
        XCTAssertEqual(AgentTaskControlTapStore.consume(defaults: suite), "accelerate")
    }

    func testConsumeEmptyReturnsNil() {
        XCTAssertNil(AgentTaskControlTapStore.consume(defaults: suite))
        XCTAssertNil(AgentTaskControlTapStore.consume(defaults: suite))
    }
}

/// 原始标记 → 动作（纯解析）
final class AgentTaskControlActionParserTests: XCTestCase {

    func testParseKnownActions() {
        XCTAssertEqual(AgentTaskControlActionParser.parse("cancel"), .cancel)
        XCTAssertEqual(AgentTaskControlActionParser.parse("accelerate"), .accelerate)
    }

    func testParseUnknownOrEmptyReturnsNil() {
        XCTAssertNil(AgentTaskControlActionParser.parse("snooze"))
        XCTAssertNil(AgentTaskControlActionParser.parse(""))
        XCTAssertNil(AgentTaskControlActionParser.parse(nil))
    }
}

/// 协调器：消费 + 应用接线（apply 注入）
@MainActor
final class AgentTaskControlCoordinatorTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.task.control.coordinator.v1")
        suite.removePersistentDomain(forName: "test.task.control.coordinator.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.task.control.coordinator.v1")
        super.tearDown()
    }

    private func setMarker(_ raw: String) {
        suite.set(raw, forKey: AgentTaskControlTapStore.requestKey)
    }

    func testConsumesAndAppliesCancel() {
        setMarker("cancel")
        var applied: [AgentTaskControlAction] = []
        let handled = AgentTaskControlCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { action in
                applied.append(action)
                return "订餐厅"
            }
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(applied, [.cancel])
        XCTAssertNil(AgentTaskControlTapStore.consume(defaults: suite), "标记已清除")
    }

    func testConsumesAndAppliesAccelerate() {
        setMarker("accelerate")
        var applied: [AgentTaskControlAction] = []
        _ = AgentTaskControlCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { action in
                applied.append(action)
                return "整理报告"
            }
        )
        XCTAssertEqual(applied, [.accelerate])
    }

    func testNoMarkerIsNoOp() {
        var applied: [AgentTaskControlAction] = []
        let handled = AgentTaskControlCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { action in
                applied.append(action)
                return "x"
            }
        )
        XCTAssertFalse(handled)
        XCTAssertTrue(applied.isEmpty)
    }

    func testUnknownMarkerConsumedButNotApplied() {
        setMarker("not-a-real-action")
        var applied: [AgentTaskControlAction] = []
        let handled = AgentTaskControlCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { action in
                applied.append(action)
                return "x"
            }
        )
        XCTAssertTrue(handled, "未知标记仍消费，避免卡住后续请求")
        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(AgentTaskControlTapStore.consume(defaults: suite))
    }

    func testNoRunningTaskStillConsumes() {
        setMarker("cancel")
        var applied: [AgentTaskControlAction] = []
        let handled = AgentTaskControlCoordinator.consumeIfNeeded(
            defaults: suite,
            apply: { action in
                applied.append(action)
                return nil // 无可作用任务
            }
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(applied, [.cancel])
        XCTAssertNil(AgentTaskControlTapStore.consume(defaults: suite), "无任务也消费，避免重复触发")
    }
}
