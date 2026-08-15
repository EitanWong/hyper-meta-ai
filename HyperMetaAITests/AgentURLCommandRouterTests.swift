/*
 * Agent URL Command Router Tests
 * JARVIS URL 命令协议：解析矩阵（trigger / ask / lens / briefing、参数缺省、
 * 百分号编码、非法输入）与路由分发（Mock 执行器）。
 */

import XCTest
@testable import HyperMetaAI

// MARK: - 解析

final class AgentURLCommandParserTests: XCTestCase {
    private func url(_ string: String) -> URL? {
        URL(string: string)
    }

    func testTriggerGesture() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(url: url("hypermetaai://trigger?gesture=wake")!),
            .trigger(.wake)
        )
    }

    func testAskWithBrain() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(
                url: url("hypermetaai://ask?text=整理报告&brain=hermes")!
            ),
            .ask(text: "整理报告", brain: .hermes)
        )
    }

    func testAskDefaultsToAutoBrain() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(url: url("hypermetaai://ask?text=你好")!),
            .ask(text: "你好", brain: .auto)
        )
    }

    func testAskUnknownBrainFallsBackToAuto() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(url: url("hypermetaai://ask?text=你好&brain=foo")!),
            .ask(text: "你好", brain: .auto)
        )
    }

    func testAskEmptyTextRejected() {
        XCTAssertNil(
            AgentURLCommandParser.parse(url: url("hypermetaai://ask?text=")!)
        )
        XCTAssertNil(
            AgentURLCommandParser.parse(url: url("hypermetaai://ask")!)
        )
    }

    func testAskPercentEncodedTextDecoded() {
        let raw = "帮我看看今天的日程"
        let encodedText = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let encoded = "hypermetaai://ask?text=\(encodedText)"
        XCTAssertEqual(
            AgentURLCommandParser.parse(url: url(encoded)!),
            .ask(text: raw, brain: .auto)
        )
    }

    func testLensWithSpeak() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(
                url: url("hypermetaai://lens?text=任务完成&speak=1")!
            ),
            .lens(text: "任务完成", speak: true)
        )
    }

    func testLensDefaultsToNoSpeak() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(url: url("hypermetaai://lens?text=任务完成")!),
            .lens(text: "任务完成", speak: false)
        )
        XCTAssertEqual(
            AgentURLCommandParser.parse(
                url: url("hypermetaai://lens?text=任务完成&speak=0")!
            ),
            .lens(text: "任务完成", speak: false)
        )
    }

    func testLensEmptyTextRejected() {
        XCTAssertNil(
            AgentURLCommandParser.parse(url: url("hypermetaai://lens?text=")!)
        )
    }

    func testBriefing() {
        XCTAssertEqual(
            AgentURLCommandParser.parse(url: url("hypermetaai://briefing")!),
            .briefing
        )
    }

    func testUnknownHostRejected() {
        XCTAssertNil(
            AgentURLCommandParser.parse(url: url("hypermetaai://unknown")!)
        )
    }

    func testWrongSchemeRejected() {
        XCTAssertNil(
            AgentURLCommandParser.parse(url: url("https://trigger?gesture=wake")!)
        )
    }

    func testInvalidTriggerGestureRejected() {
        XCTAssertNil(
            AgentURLCommandParser.parse(url: url("hypermetaai://trigger?gesture=fly")!)
        )
    }
}

// MARK: - 路由分发

@MainActor
final class AgentURLCommandRouterTests: XCTestCase {
    private final class MockExecutor: AgentURLCommandExecuting {
        var triggers: [AgentWearableGesture] = []
        var asks: [(text: String, brain: AgentAskBrainOption)] = []
        var lenses: [(text: String, speak: Bool)] = []
        var briefings = 0

        func dispatchTrigger(_ gesture: AgentWearableGesture) {
            triggers.append(gesture)
        }

        func dispatchAsk(text: String, brain: AgentAskBrainOption) async -> String {
            asks.append((text, brain))
            return "回复：\(text)"
        }

        func dispatchLens(text: String, speak: Bool) {
            lenses.append((text, speak))
        }

        func dispatchBriefing() async -> String {
            briefings += 1
            return "晨报"
        }
    }

    func testTriggerRouted() async {
        let executor = MockExecutor()
        await AgentURLCommandRouter.dispatch(.trigger(.wake), executor: executor)
        XCTAssertEqual(executor.triggers, [.wake])
        XCTAssertTrue(executor.asks.isEmpty)
        XCTAssertTrue(executor.lenses.isEmpty)
        XCTAssertEqual(executor.briefings, 0)
    }

    func testAskRoutedWithTextAndBrain() async {
        let executor = MockExecutor()
        await AgentURLCommandRouter.dispatch(
            .ask(text: "整理报告", brain: .openclaw),
            executor: executor
        )
        XCTAssertEqual(executor.asks.count, 1)
        XCTAssertEqual(executor.asks[0].text, "整理报告")
        XCTAssertEqual(executor.asks[0].brain, .openclaw)
    }

    func testLensRoutedWithSpeakFlag() async {
        let executor = MockExecutor()
        await AgentURLCommandRouter.dispatch(
            .lens(text: "任务完成", speak: true),
            executor: executor
        )
        XCTAssertEqual(executor.lenses.count, 1)
        XCTAssertEqual(executor.lenses[0].text, "任务完成")
        XCTAssertTrue(executor.lenses[0].speak)
    }

    func testBriefingRouted() async {
        let executor = MockExecutor()
        await AgentURLCommandRouter.dispatch(.briefing, executor: executor)
        XCTAssertEqual(executor.briefings, 1)
    }

    func testDispatchParsesURLAndRoutes() async {
        let executor = MockExecutor()
        let command = await AgentURLCommandRouter.dispatch(
            url: URL(string: "hypermetaai://ask?text=你好&brain=hermes")!,
            executor: executor
        )
        XCTAssertEqual(command, .ask(text: "你好", brain: .hermes))
        XCTAssertEqual(executor.asks.count, 1)
    }

    func testDispatchNonCommandReturnsNilAndDoesNothing() async {
        let executor = MockExecutor()
        let command = await AgentURLCommandRouter.dispatch(
            url: URL(string: "https://example.com")!,
            executor: executor
        )
        XCTAssertNil(command)
        XCTAssertTrue(executor.triggers.isEmpty)
        XCTAssertTrue(executor.asks.isEmpty)
        XCTAssertTrue(executor.lenses.isEmpty)
        XCTAssertEqual(executor.briefings, 0)
    }
}
