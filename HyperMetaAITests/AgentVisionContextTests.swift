import XCTest
@testable import HyperMetaAI

final class AgentVisionContextPolicyTests: XCTestCase {

  func testExplicitImageAlwaysAttaches() {
    XCTAssertTrue(AgentVisionContextPolicy.shouldAttach(
      sendingImage: true, hasActiveContext: false, followUpEnabled: false
    ))
    XCTAssertTrue(AgentVisionContextPolicy.shouldAttach(
      sendingImage: true, hasActiveContext: true, followUpEnabled: true
    ))
  }

  func testFollowUpAttachesOnlyWhenContextActiveAndEnabled() {
    XCTAssertTrue(AgentVisionContextPolicy.shouldAttach(
      sendingImage: false, hasActiveContext: true, followUpEnabled: true
    ))
    XCTAssertFalse(AgentVisionContextPolicy.shouldAttach(
      sendingImage: false, hasActiveContext: true, followUpEnabled: false
    ))
    XCTAssertFalse(AgentVisionContextPolicy.shouldAttach(
      sendingImage: false, hasActiveContext: false, followUpEnabled: true
    ))
    XCTAssertFalse(AgentVisionContextPolicy.shouldAttach(
      sendingImage: false, hasActiveContext: false, followUpEnabled: false
    ))
  }
}

final class AssistantRuntimePolicyTests: XCTestCase {
  func testPhoneStandaloneKeepsVoiceAvailableWithoutWearableCapabilities() {
    let capabilities = AssistantRuntimePolicy.resolve(hasActiveGlasses: false)

    XCTAssertEqual(capabilities.mode, .phoneStandalone)
    XCTAssertEqual(capabilities.preferredVisualInput, .photoLibrary)
    XCTAssertFalse(capabilities.supportsWearableControls)
    XCTAssertTrue(capabilities.supportsCoreVoice)
  }

  func testConnectedGlassesEnhanceTheSameCoreRuntime() {
    let capabilities = AssistantRuntimePolicy.resolve(hasActiveGlasses: true)

    XCTAssertEqual(capabilities.mode, .glassesEnhanced)
    XCTAssertEqual(capabilities.preferredVisualInput, .glassesCamera)
    XCTAssertTrue(capabilities.supportsWearableControls)
    XCTAssertTrue(capabilities.supportsCoreVoice)
  }
}

final class AgentVisionIntentParserTests: XCTestCase {
  func testSceneRequestsUseOneFrameVision() {
    XCTAssertEqual(AgentVisionIntentParser.parse("我眼前是什么")?.kind, .scene)
    XCTAssertEqual(AgentVisionIntentParser.parse("What am I looking at?")?.kind, .scene)
    XCTAssertEqual(AgentVisionIntentParser.parse("看看这是什么呀")?.kind, .scene)
  }

  func testReadingAndTranslationRequestsUseTextVision() {
    XCTAssertEqual(AgentVisionIntentParser.parse("这上面写了什么？")?.kind, .text)
    XCTAssertEqual(AgentVisionIntentParser.parse("翻译这个菜单")?.kind, .text)
    XCTAssertEqual(AgentVisionIntentParser.parse("Read this sign")?.kind, .text)
  }

  func testOrdinaryConversationDoesNotStartCamera() {
    XCTAssertNil(AgentVisionIntentParser.parse("今天天气怎么样"))
    XCTAssertNil(AgentVisionIntentParser.parse("帮我看看明天的日程"))
    XCTAssertNil(AgentVisionIntentParser.parse("翻译这句话的语法"))
  }
}

final class AgentVisionFollowUpSettingsTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: AgentVisionSettings.followUpEnabledKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: AgentVisionSettings.followUpEnabledKey)
    super.tearDown()
  }

  func testFollowUpDefaultsEnabled() {
    XCTAssertTrue(AgentVisionSettings.followUpEnabled)
  }

  func testFollowUpPersists() {
    AgentVisionSettings.followUpEnabled = false
    XCTAssertFalse(AgentVisionSettings.followUpEnabled)
    AgentVisionSettings.followUpEnabled = true
    XCTAssertTrue(AgentVisionSettings.followUpEnabled)
  }
}
