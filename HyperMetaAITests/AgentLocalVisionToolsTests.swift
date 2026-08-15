import XCTest

@testable import HyperMetaAI

/// 端侧视觉工具（vision.ocr / vision.scene / vision.objects）注册与本地执行
final class AgentLocalVisionToolsTests: XCTestCase {
    func testVisionToolsRegisteredWithoutPermission() {
        let ids = AgentToolRegistry.allTools.map(\.id)
        XCTAssertTrue(ids.contains(AgentToolRegistry.visionOCR.id))
        XCTAssertTrue(ids.contains(AgentToolRegistry.visionScene.id))
        XCTAssertTrue(ids.contains(AgentToolRegistry.visionObjects.id))
        XCTAssertFalse(AgentToolRegistry.visionOCR.requiresPermission)
        XCTAssertFalse(AgentToolRegistry.visionScene.requiresPermission)
        XCTAssertFalse(AgentToolRegistry.visionObjects.requiresPermission)
        XCTAssertEqual(AgentToolRegistry.visionOCR.category, .vision)
        XCTAssertEqual(AgentToolRegistry.visionScene.category, .vision)
        XCTAssertEqual(AgentToolRegistry.visionObjects.category, .vision)
    }

    func testOCRWithoutFrameReturnsGuidance() async {
        let call = CustomToolCall(id: "1", name: AgentToolRegistry.visionOCR.id, arguments: "{}")
        let result = await CustomAgentLocalTools.execute(
            call,
            context: CustomAgentToolContext(latestFrame: { nil })
        )
        XCTAssertEqual(result, "custom.agent.tool.vision.frame.missing".localized)
    }

    func testSceneWithoutFrameReturnsGuidance() async {
        let call = CustomToolCall(id: "2", name: AgentToolRegistry.visionScene.id, arguments: "{}")
        let result = await CustomAgentLocalTools.execute(
            call,
            context: CustomAgentToolContext(latestFrame: { nil })
        )
        XCTAssertEqual(result, "custom.agent.tool.vision.frame.missing".localized)
    }

    func testObjectsWithoutFrameReturnsGuidance() async {
        let call = CustomToolCall(id: "4", name: AgentToolRegistry.visionObjects.id, arguments: "{}")
        let result = await CustomAgentLocalTools.execute(
            call,
            context: CustomAgentToolContext(latestFrame: { nil })
        )
        XCTAssertEqual(result, "custom.agent.tool.vision.frame.missing".localized)
    }

    func testUnknownVisionToolStaysUnavailable() async {
        let call = CustomToolCall(id: "3", name: "vision.unknown", arguments: "{}")
        let result = await CustomAgentLocalTools.execute(call)
        XCTAssertEqual(result, "custom.agent.tool.unavailable".localized("vision.unknown"))
    }

    func testContextDefaultLatestFrameIsNil() {
        let context = CustomAgentToolContext()
        XCTAssertNil(context.latestFrame())
    }
}
