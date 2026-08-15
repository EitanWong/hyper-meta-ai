/*
 * Agent Task View Request Store Tests
 * 任务 Live Activity「查看任务」按钮请求消费：无请求默认 false、
 * 有请求消费一次即清除（一次性深链），App Group 键与扩展侧一致。
 */

import XCTest
@testable import HyperMetaAI

final class AgentTaskViewRequestStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.taskview.request")
        defaults.removePersistentDomain(forName: "test.agent.taskview.request")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.taskview.request")
        defaults = nil
        super.tearDown()
    }

    func testNoRequestConsumesFalse() {
        XCTAssertFalse(AgentTaskViewRequestStore.consume(defaults: defaults))
    }

    func testRequestConsumedOnce() {
        // 模拟扩展进程写入（与 AgentTaskViewRequestStore.requestViewTask 同一键）
        defaults.set(true, forKey: AgentTaskViewRequestStore.requestKey)
        XCTAssertTrue(AgentTaskViewRequestStore.consume(defaults: defaults))
        // 一次性消费：第二次不再触发
        XCTAssertFalse(AgentTaskViewRequestStore.consume(defaults: defaults))
    }

    func testConsumeClearsFlag() {
        defaults.set(true, forKey: AgentTaskViewRequestStore.requestKey)
        _ = AgentTaskViewRequestStore.consume(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AgentTaskViewRequestStore.requestKey))
    }

    func testRequestKeyMatchesExtension() {
        XCTAssertEqual(
            AgentTaskViewRequestStore.requestKey,
            "agent.liveactivity.tap.viewTask.v1"
        )
        XCTAssertEqual(
            AgentTaskViewRequestStore.suiteName,
            "group.com.lunflux.hyper-meta-ai"
        )
    }
}
