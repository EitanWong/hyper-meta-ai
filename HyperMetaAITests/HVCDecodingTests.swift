import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class HVCBitstreamInspectorTests: XCTestCase {
  func testFindsIDRInLengthPrefixedSample() {
    let sample = makeLengthPrefixedSample(nalUnitTypes: [32, 33, 34, 19])

    XCTAssertEqual(
      HVCBitstreamInspector.containsRandomAccessNALUnit(
        sample,
        nalUnitLengthFieldSize: 4
      ),
      true
    )
  }

  func testRejectsInterPredictedSampleAsRecoveryPoint() {
    let sample = makeLengthPrefixedSample(nalUnitTypes: [1])

    XCTAssertEqual(
      HVCBitstreamInspector.containsRandomAccessNALUnit(
        sample,
        nalUnitLengthFieldSize: 4
      ),
      false
    )
  }

  func testRejectsTruncatedNALUnitLength() {
    let sample: [UInt8] = [0, 0, 0, 8, 0x26, 0x01]

    XCTAssertNil(
      HVCBitstreamInspector.containsRandomAccessNALUnit(
        sample,
        nalUnitLengthFieldSize: 4
      )
    )
  }

  private func makeLengthPrefixedSample(nalUnitTypes: [UInt8]) -> [UInt8] {
    nalUnitTypes.flatMap { nalUnitType in
      let payload: [UInt8] = [nalUnitType << 1, 0x01, 0x00]
      return [0, 0, 0, UInt8(payload.count)] + payload
    }
  }
}

final class HVCDecoderFailurePolicyTests: XCTestCase {
  func testKeepsDecoderSessionForRecoverableBitstreamDamage() {
    XCTAssertFalse(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderBadDataErr)
    )
    XCTAssertFalse(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderReferenceMissingErr)
    )
  }

  func testResetsDecoderSessionForDecoderLifecycleFailures() {
    XCTAssertTrue(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTInvalidSessionErr)
    )
    XCTAssertTrue(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderMalfunctionErr)
    )
    XCTAssertTrue(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderRemovedErr)
    )
  }
}
