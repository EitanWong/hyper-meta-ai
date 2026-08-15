import XCTest

@testable import HyperMetaAI

final class RTMPQualityLockPolicyTests: XCTestCase {

  private let preset = RTMPQualityPreset(bitrate: 2_000_000, width: 420, height: 420, fps: 24)

  private func decision(_ action: RTMPAdaptiveQualityController.Decision.Action)
    -> RTMPAdaptiveQualityController.Decision {
    RTMPAdaptiveQualityController.Decision(action: action, preset: preset)
  }

  func testLockedBlocksDownshift() {
    XCTAssertFalse(
      RTMPQualityLockPolicy.shouldApply(decision: decision(.downshift), locked: true)
    )
  }

  func testLockedBlocksUpshift() {
    XCTAssertFalse(
      RTMPQualityLockPolicy.shouldApply(decision: decision(.upshift), locked: true)
    )
  }

  func testUnlockedIgnoresHold() {
    XCTAssertFalse(
      RTMPQualityLockPolicy.shouldApply(decision: decision(.hold), locked: false)
    )
  }

  func testUnlockedAppliesShifts() {
    XCTAssertTrue(
      RTMPQualityLockPolicy.shouldApply(decision: decision(.downshift), locked: false)
    )
    XCTAssertTrue(
      RTMPQualityLockPolicy.shouldApply(decision: decision(.upshift), locked: false)
    )
  }
}
