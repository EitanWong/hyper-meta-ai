import XCTest

@testable import HyperMetaAI

final class RTMPSceneAnalysisPromptTests: XCTestCase {

  func testMessageContainsSceneContext() {
    let message = RTMPSceneAnalysisPrompt.message(
      sceneLabel: "Restaurant",
      summary: "Restaurant, Food",
      platformName: "抖音"
    )

    XCTAssertTrue(message.contains("直播场景：Restaurant"))
    XCTAssertTrue(message.contains("场景摘要：Restaurant, Food"))
    XCTAssertTrue(message.contains("直播平台：抖音"))
    XCTAssertTrue(message.contains("3 条互动建议"))
  }

  func testEmptyContextLinesOmitted() {
    let message = RTMPSceneAnalysisPrompt.message(
      sceneLabel: nil,
      summary: "",
      platformName: nil
    )

    XCTAssertFalse(message.contains("直播场景："))
    XCTAssertFalse(message.contains("场景摘要："))
    XCTAssertFalse(message.contains("直播平台："))
    XCTAssertTrue(message.contains("请直接给出建议，不要寒暄。"))
  }

  func testMessageDoesNotExposeSecrets() {
    let message = RTMPSceneAnalysisPrompt.message(
      sceneLabel: "Cafe",
      summary: "Coffee",
      platformName: "Twitch"
    )

    XCTAssertFalse(message.contains("rtmp://"))
    XCTAssertFalse(message.contains("streamKey"))
  }
}

final class RTMPSceneAnalysisMemoryTests: XCTestCase {

  func testMemoryTextAddsPrefix() {
    let memory = RTMPSceneAnalysisMemory.memoryText("推荐展示菜品制作过程")

    XCTAssertEqual(memory, "直播互动建议：推荐展示菜品制作过程")
  }

  func testEmptyAnalysisReturnsNil() {
    XCTAssertNil(RTMPSceneAnalysisMemory.memoryText(""))
    XCTAssertNil(RTMPSceneAnalysisMemory.memoryText("   \n "))
  }

  func testLongAnalysisTruncated() {
    let long = String(repeating: "建议", count: 150)
    let memory = RTMPSceneAnalysisMemory.memoryText(long)

    XCTAssertEqual(memory?.count, RTMPSceneAnalysisMemory.maxMemoryLength)
    XCTAssertTrue(memory?.hasPrefix("直播互动建议：") ?? false)
  }
}

final class SceneAssistantBrainTests: XCTestCase {

  func testHermesPreferred() {
    XCTAssertEqual(
      SceneAssistantBrain.resolve(hermesAvailable: true, openClawAvailable: true, customAvailable: true),
      .hermes
    )
    XCTAssertEqual(
      SceneAssistantBrain.resolve(hermesAvailable: true, openClawAvailable: false, customAvailable: false),
      .hermes
    )
  }

  func testOpenClawFallsBackAfterHermes() {
    XCTAssertEqual(
      SceneAssistantBrain.resolve(hermesAvailable: false, openClawAvailable: true, customAvailable: true),
      .openclaw
    )
    XCTAssertEqual(
      SceneAssistantBrain.resolve(hermesAvailable: false, openClawAvailable: true, customAvailable: false),
      .openclaw
    )
  }

  func testCustomIsLastResort() {
    XCTAssertEqual(
      SceneAssistantBrain.resolve(hermesAvailable: false, openClawAvailable: false, customAvailable: true),
      .custom
    )
  }

  func testLocalFallsBackAfterCustom() {
    XCTAssertEqual(
      SceneAssistantBrain.resolve(
        hermesAvailable: false,
        openClawAvailable: false,
        customAvailable: false,
        localAvailable: true
      ),
      .local
    )
  }

  func testLocalIgnoredWhenGatewayAvailable() {
    XCTAssertEqual(
      SceneAssistantBrain.resolve(
        hermesAvailable: false,
        openClawAvailable: false,
        customAvailable: true,
        localAvailable: true
      ),
      .custom
    )
  }

  func testLocalDisabledByDefault() {
    XCTAssertNil(
      SceneAssistantBrain.resolve(
        hermesAvailable: false,
        openClawAvailable: false,
        customAvailable: false
      )
    )
  }

  func testNoneAvailableReturnsNil() {
    XCTAssertNil(
      SceneAssistantBrain.resolve(hermesAvailable: false, openClawAvailable: false, customAvailable: false)
    )
  }
}
