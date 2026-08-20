import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class DATGlassesAppUpdateRetryGateTests: XCTestCase {
  func testDetectsOnlyTheDATGlassesAppUpdateRequirement() {
    XCTAssertTrue(
      DATGlassesAppUpdateGuidance.isRequired(for: .datAppOnTheGlassesUpdateRequired)
    )
    XCTAssertTrue(
      DATGlassesAppUpdateGuidance.isRequired(
        for: .unexpectedError(description: "请将直播软件更新至最新版本后重试")
      )
    )
    XCTAssertTrue(
      DATGlassesAppUpdateGuidance.isRequired(message: "请将直播软件更新至最新版本后重试")
    )
    XCTAssertFalse(DATGlassesAppUpdateGuidance.isRequired(for: .dwaUnavailable))
    XCTAssertFalse(
      DATGlassesAppUpdateGuidance.isRequired(
        for: .unexpectedError(description: "Temporary connection failure")
      )
    )
    XCTAssertFalse(DATGlassesAppUpdateGuidance.isRequired(for: .sessionAlreadyStopped))
  }

  func testRequiresTheUpdateRouteBeforePermittingOneManualRetry() {
    var gate = DATGlassesAppUpdateRetryGate()

    gate.requireUpdate()
    XCTAssertTrue(gate.isUpdateRequired)
    XCTAssertFalse(gate.consumeRetry())

    gate.markUpdateDestinationOpened()
    XCTAssertTrue(gate.isRetryArmed)
    XCTAssertTrue(gate.consumeRetry())
    XCTAssertFalse(gate.isUpdateRequired)
    XCTAssertFalse(gate.isRetryArmed)
  }

  func testRequiringAnotherUpdateInvalidatesAStaleRetry() {
    var gate = DATGlassesAppUpdateRetryGate()

    gate.requireUpdate()
    gate.markUpdateDestinationOpened()
    gate.requireUpdate()

    XCTAssertFalse(gate.consumeRetry())
  }
}
