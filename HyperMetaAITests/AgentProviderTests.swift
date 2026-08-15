import Foundation
import XCTest

@testable import HyperMetaAI

final class AgentProviderTests: XCTestCase {
  func testAgentKindsAreStable() {
    XCTAssertEqual(AgentKind.allCases.map(\.rawValue), ["openclaw", "hermes"])
    XCTAssertEqual(AgentKind.allCases.map(\.displayName), ["OpenClaw", "Hermes"])
    XCTAssertEqual(AgentKind.openclaw.id, "openclaw")
    XCTAssertEqual(AgentKind.hermes.id, "hermes")
    XCTAssertFalse(AgentKind.openclaw.iconName.isEmpty)
    XCTAssertFalse(AgentKind.hermes.iconName.isEmpty)
  }

  func testOpenClawStateMapping() {
    XCTAssertEqual(AgentConnectionState.map(.disconnected), .unknown)
    XCTAssertEqual(AgentConnectionState.map(.connecting), .connecting)
    XCTAssertEqual(AgentConnectionState.map(.waitingForPairing), .waitingForPairing)
    XCTAssertEqual(AgentConnectionState.map(.connected), .connected)
    XCTAssertEqual(AgentConnectionState.map(.error("boom")), .failed("boom"))
  }

  func testHermesStateMapping() {
    XCTAssertEqual(AgentConnectionState.map(.unknown), .unknown)
    XCTAssertEqual(AgentConnectionState.map(.checking), .connecting)
    XCTAssertEqual(AgentConnectionState.map(.online), .connected)
    XCTAssertEqual(AgentConnectionState.map(.offline("down")), .failed("down"))
  }

  func testUnifiedStateHelpers() {
    XCTAssertTrue(AgentConnectionState.connected.isOnline)
    XCTAssertFalse(AgentConnectionState.failed("x").isOnline)
    XCTAssertFalse(AgentConnectionState.connected.isBusy)
    XCTAssertTrue(AgentConnectionState.connecting.isBusy)
  }
}
