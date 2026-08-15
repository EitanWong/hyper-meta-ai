/*
 * Agent Approval Tap Store Tests
 * 任务 Live Activity 审批按钮请求消费：无请求默认 nil、allow / deny 解析、
 * 一次性消费（防重复提交）、未知值忽略、键与扩展侧一致。
 */

import XCTest
@testable import HyperMetaAI

final class AgentApprovalTapStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.approval.tap")
        defaults.removePersistentDomain(forName: "test.agent.approval.tap")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.approval.tap")
        defaults = nil
        super.tearDown()
    }

    func testNoRequestConsumesNil() {
        XCTAssertNil(AgentApprovalTapStore.consume(defaults: defaults))
        XCTAssertNil(AgentApprovalTapStore.consumeDecision(defaults: defaults))
    }

    func testAllowRequestConsumesAllowDecisionOnce() {
        defaults.set("allow", forKey: AgentApprovalTapStore.requestKey)
        XCTAssertEqual(
            AgentApprovalTapStore.consumeDecision(defaults: defaults),
            .allow
        )
        // 一次性消费：第二次不再触发
        XCTAssertNil(AgentApprovalTapStore.consumeDecision(defaults: defaults))
    }

    func testDenyRequestConsumesDenyDecision() {
        defaults.set("deny", forKey: AgentApprovalTapStore.requestKey)
        XCTAssertEqual(
            AgentApprovalTapStore.consumeDecision(defaults: defaults),
            .deny
        )
    }

    func testRawConsumeReturnsValueAndClears() {
        defaults.set("allow", forKey: AgentApprovalTapStore.requestKey)
        XCTAssertEqual(AgentApprovalTapStore.consume(defaults: defaults), "allow")
        XCTAssertNil(defaults.object(forKey: AgentApprovalTapStore.requestKey))
    }

    func testUnknownValueIgnored() {
        defaults.set("maybe", forKey: AgentApprovalTapStore.requestKey)
        XCTAssertNil(AgentApprovalTapStore.consumeDecision(defaults: defaults))
    }

    func testKeyMatchesExtension() {
        XCTAssertEqual(
            AgentApprovalTapStore.requestKey,
            "agent.liveactivity.tap.approval.v1"
        )
        XCTAssertEqual(
            AgentApprovalTapStore.suiteName,
            "group.com.lunflux.hyper-meta-ai"
        )
    }
}
