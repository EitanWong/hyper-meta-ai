import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class CameraStreamTransportProfileTests: XCTestCase {
  func testFullDuplexProfileUsesProviderIndependentCompressedVideo() {
    let profile = CameraStreamTransportProfile.make(
      savedQuality: "high",
      requiresFullDuplexTransport: true
    )

    XCTAssertEqual(profile.videoCodec, .hvc1)
    XCTAssertEqual(profile.resolution, .low)
    XCTAssertEqual(profile.frameRate, 24)
  }

  func testNonFullDuplexProfilePreservesTheSavedCameraQuality() {
    let profile = CameraStreamTransportProfile.make(
      savedQuality: "high",
      requiresFullDuplexTransport: false
    )

    XCTAssertEqual(profile.videoCodec, .raw)
    XCTAssertEqual(profile.resolution, .high)
    XCTAssertEqual(profile.frameRate, 24)
  }
}

final class CameraCaptureStateTests: XCTestCase {
  func testStateSemanticsAreStableForFeatureGuards() {
    XCTAssertFalse(CameraCaptureState.unavailable.isStreaming)
    XCTAssertTrue(CameraCaptureState.unavailable.isUnavailable)
    XCTAssertTrue(CameraCaptureState.starting.isBusy)
    XCTAssertTrue(CameraCaptureState.stopping.isBusy)
    XCTAssertTrue(CameraCaptureState.streaming.isStreaming)
    XCTAssertFalse(CameraCaptureState.streaming.isUnavailable)
    XCTAssertTrue(CameraCaptureState.failed("test").isFailed)
  }
}
