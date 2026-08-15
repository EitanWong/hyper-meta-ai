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
