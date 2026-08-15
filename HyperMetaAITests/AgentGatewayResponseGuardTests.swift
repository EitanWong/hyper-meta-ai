/*
 * Agent Gateway Response Guard Tests
 * action-promise 守卫（中文承诺短句识别 + 反例）与实时响应生命周期。
 */

import XCTest
@testable import HyperMetaAI

final class AgentGatewayActionPromiseGuardTests: XCTestCase {
    func testRecognizesExplicitPromise() {
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("好的，我来查一下"))
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("我来处理"))
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("马上搜索"))
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("我来查一下杭州今天的天气。"))
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("好的，我马上检查这个仓库。"))
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("马上去看这个文件。"))
        XCTAssertTrue(AgentGatewayActionPromiseGuard.promisesAction("稍等，我来核实一下。"))
    }

    func testRejectsConfirmationRequests() {
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("要我帮你查吗？"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("我帮你查好吗"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("我帮你查可以吗"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("需要我处理吗"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("我来帮你重构这个模块，可以吗？"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("需要我现在就去改吗"))
    }

    func testRejectsDeliveredContent() {
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("查到了：结果如下"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("已经完成修改"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("原因是不兼容"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("答案是 42"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("杭州今天二十六度，多云。"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("我觉得这两个方案差别不大。"))
    }

    func testRejectsEmptyAndOversized() {
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction(""))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("   "))
        let long = "我来处理" + String(repeating: "啊", count: AgentGatewayActionPromiseGuard.maxChars)
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction(long))
    }

    func testRejectsNonPromiseChatter() {
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("今天天气不错"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("你好呀"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("这是一个很长的普通句子，不是承诺执行。"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("让我来"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("我现在就去修改"))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.promisesAction("这就帮你查"))
    }

    func testGuardMatchesOnlyModelOriginWithoutTools() {
        XCTAssertTrue(AgentGatewayActionPromiseGuard.matches(
            origin: "model",
            hasFunctionCall: false,
            failed: false,
            suppressed: false,
            transcript: "好的，我来查一下"
        ))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.matches(
            origin: "model",
            hasFunctionCall: true,
            failed: false,
            suppressed: false,
            transcript: "好的，我来查一下"
        ))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.matches(
            origin: "announcement",
            hasFunctionCall: false,
            failed: false,
            suppressed: false,
            transcript: "好的，我来查一下"
        ))
        XCTAssertFalse(AgentGatewayActionPromiseGuard.matches(
            origin: "model",
            hasFunctionCall: false,
            failed: true,
            suppressed: false,
            transcript: "好的，我来查一下"
        ))
    }

    func testGuardCarriesInstructions() {
        XCTAssertFalse(AgentGatewayActionPromiseGuard.id.isEmpty)
        XCTAssertTrue(AgentGatewayActionPromiseGuard.instructions.contains("没有调用工具"))
    }
}

final class AgentGatewayResponseLifecycleTests: XCTestCase {
    func testResponseIdPriority() {
        XCTAssertEqual(
            AgentGatewayResponseLifecycle.realtimeResponseId(
                responseId: "r1",
                responseObjectId: "r2",
                itemResponseId: "r3"
            ),
            "r1"
        )
        XCTAssertEqual(
            AgentGatewayResponseLifecycle.realtimeResponseId(
                responseId: "",
                responseObjectId: "r2",
                itemResponseId: "r3"
            ),
            "r2"
        )
        XCTAssertEqual(
            AgentGatewayResponseLifecycle.realtimeResponseId(
                responseId: nil,
                responseObjectId: nil,
                itemResponseId: "r3"
            ),
            "r3"
        )
        XCTAssertEqual(
            AgentGatewayResponseLifecycle.realtimeResponseId(
                responseId: nil,
                responseObjectId: nil,
                itemResponseId: nil
            ),
            ""
        )
    }

    func testResponseActivityDetection() {
        XCTAssertTrue(AgentGatewayResponseLifecycle.isResponseActivityEvent(
            type: "response.audio.delta",
            responseId: "r1"
        ))
        XCTAssertTrue(AgentGatewayResponseLifecycle.isResponseActivityEvent(
            type: "response.output_audio_transcript.done",
            responseId: "r1"
        ))
        XCTAssertFalse(AgentGatewayResponseLifecycle.isResponseActivityEvent(
            type: "response.audio.delta",
            responseId: ""
        ))
        XCTAssertFalse(AgentGatewayResponseLifecycle.isResponseActivityEvent(
            type: "turn.started",
            responseId: "r1"
        ))
    }
}
