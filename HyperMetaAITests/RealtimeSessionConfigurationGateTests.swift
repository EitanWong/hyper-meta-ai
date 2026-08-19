import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class RealtimeSessionConfigurationGateTests: XCTestCase {
  func testConfigurationConfirmationIsGenerationScopedAndIdempotent() {
    let gate = RealtimeSessionConfigurationGate()

    gate.activate(generation: 4)
    XCTAssertFalse(gate.confirm(generation: 3))
    XCTAssertTrue(gate.confirm(generation: 4))
    XCTAssertFalse(gate.confirm(generation: 4))

    gate.activate(generation: 5)
    XCTAssertTrue(gate.confirm(generation: 5))
    gate.invalidate()
    XCTAssertFalse(gate.confirm(generation: 5))
  }
}
