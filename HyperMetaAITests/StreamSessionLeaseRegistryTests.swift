import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class StreamSessionLeaseRegistryTests: XCTestCase {
  func testAgentTriggerLeaseKeepsControlsWithoutRequestingCamera() {
    var registry = StreamSessionLeaseRegistry()

    _ = registry.acquire(.agentTrigger)
    XCTAssertTrue(registry.keepsAgentTriggerSession)
    XCTAssertFalse(registry.requiresCameraStream)

    _ = registry.acquire(.agentChat)
    XCTAssertTrue(registry.requiresCameraStream)
    _ = registry.release(.agentChat)
    XCTAssertFalse(registry.requiresCameraStream)
    XCTAssertTrue(registry.keepsAgentTriggerSession)
  }

  func testOnlyTheFinalOwnerReleasesTheSharedSession() {
    var registry = StreamSessionLeaseRegistry()

    XCTAssertTrue(registry.acquire(.liveAI))
    XCTAssertTrue(registry.acquire(.quickVision))
    XCTAssertFalse(registry.isEmpty)

    XCTAssertTrue(registry.release(.quickVision))
    XCTAssertFalse(registry.isEmpty)
    XCTAssertTrue(registry.owners.contains(.liveAI))

    XCTAssertTrue(registry.release(.liveAI))
    XCTAssertTrue(registry.isEmpty)
  }

  func testDuplicateOwnerDoesNotCreateAnAdditionalLease() {
    var registry = StreamSessionLeaseRegistry()

    XCTAssertTrue(registry.acquire(.rtmp))
    XCTAssertFalse(registry.acquire(.rtmp))
    XCTAssertTrue(registry.release(.rtmp))
    XCTAssertTrue(registry.isEmpty)
  }

  func testQuickVisionRequestsOwnIndependentLeases() {
    var registry = StreamSessionLeaseRegistry()
    let firstRequest = StreamSessionOwner.quickVisionRequest(UUID())
    let secondRequest = StreamSessionOwner.quickVisionRequest(UUID())

    XCTAssertTrue(registry.acquire(firstRequest))
    XCTAssertTrue(registry.acquire(secondRequest))
    XCTAssertTrue(registry.release(firstRequest))
    XCTAssertFalse(registry.isEmpty)
    XCTAssertTrue(registry.owners.contains(secondRequest))

    XCTAssertTrue(registry.release(secondRequest))
    XCTAssertTrue(registry.isEmpty)
  }

  func testOnlyLiveAIRequestsTheDirectRawPreview() {
    var registry = StreamSessionLeaseRegistry()

    XCTAssertFalse(registry.usesDirectRawPreview)
    _ = registry.acquire(.simpleLiveStream)
    XCTAssertFalse(registry.usesDirectRawPreview)

    _ = registry.acquire(.liveAI)
    XCTAssertTrue(registry.usesDirectRawPreview)

    XCTAssertTrue(registry.release(.liveAI))
    XCTAssertFalse(registry.usesDirectRawPreview)
  }

  func testOnlyLiveAIRequestsTheFullDuplexTransportProfile() {
    var registry = StreamSessionLeaseRegistry()

    _ = registry.acquire(.quickVision)
    XCTAssertFalse(registry.requiresFullDuplexTransportProfile)

    _ = registry.acquire(.liveAI)
    XCTAssertTrue(registry.requiresFullDuplexTransportProfile)

    _ = registry.release(.liveAI)
    XCTAssertFalse(registry.requiresFullDuplexTransportProfile)
  }
}
