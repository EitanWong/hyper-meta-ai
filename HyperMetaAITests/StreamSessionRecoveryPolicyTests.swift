import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class StreamSessionRecoveryPolicyTests: XCTestCase {
  func testRetriesTransientStreamFailures() {
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.internalError))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.deviceNotFound("test-device")))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.deviceNotConnected("test-device")))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.timeout))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.videoStreamingError))
  }

  func testDoesNotRetryTerminalStreamFailures() {
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.permissionDenied))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.hingesClosed))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.thermalCritical))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.thermalEmergency))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.peakPowerShutdown))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.batteryCritical))
  }

  func testRetriesOnlyRecoverableDeviceSessionFailures() {
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.noEligibleDevice))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.sessionAlreadyStopped))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.unexpectedError(description: "transport reset")))

    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.sessionAlreadyExists))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.sessionIdle))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.capabilityAlreadyActive))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.capabilityNotFound))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.thermalCritical))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.thermalEmergency))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.peakPowerShutdown))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.batteryCritical))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(.datAppOnTheGlassesUpdateRequired))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(.dwaUnavailable))
  }
}
