import XCTest
@testable import HyperMetaAI

/// 晨报控制请求存储（App Group 标记通道，可注入 defaults）
final class AgentBriefingRequestStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.briefing.request.v1")
        suite.removePersistentDomain(forName: "test.briefing.request.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.briefing.request.v1")
        super.tearDown()
    }

    func testConsumeFalseWhenEmpty() {
        XCTAssertFalse(AgentBriefingRequestStore.consume(defaults: suite))
    }

    func testConsumeRoundTripOnce() {
        suite.set(true, forKey: AgentBriefingRequestStore.requestKey)
        XCTAssertTrue(AgentBriefingRequestStore.consume(defaults: suite))
        XCTAssertFalse(AgentBriefingRequestStore.consume(defaults: suite))
    }
}

/// 协调器：消费标记 → 执行播报（execute 注入验证接线）
@MainActor
final class AgentBriefingControlCoordinatorTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.briefing.request.v1")
        suite.removePersistentDomain(forName: "test.briefing.request.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.briefing.request.v1")
        super.tearDown()
    }

    func testConsumeExecutesOnce() async {
        suite.set(true, forKey: AgentBriefingRequestStore.requestKey)
        var executions = 0
        let handled = await AgentBriefingControlCoordinator.consumeIfNeeded(
            defaults: suite,
            execute: { executions += 1 }
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(executions, 1)
        // 一次性消费：再次调用不再执行
        let second = await AgentBriefingControlCoordinator.consumeIfNeeded(
            defaults: suite,
            execute: { executions += 1 }
        )
        XCTAssertFalse(second)
        XCTAssertEqual(executions, 1)
    }

    func testNoMarkerNoExecute() async {
        var executions = 0
        let handled = await AgentBriefingControlCoordinator.consumeIfNeeded(
            defaults: suite,
            execute: { executions += 1 }
        )
        XCTAssertFalse(handled)
        XCTAssertEqual(executions, 0)
    }
}
