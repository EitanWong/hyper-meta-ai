import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class FrameUpdateThrottleTests: XCTestCase {
  func testPublishesFirstFrameAndThrottlesFramesWithinInterval() {
    var throttle = FrameUpdateThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldPublish(at: 0))
    XCTAssertFalse(throttle.shouldPublish(at: 0.05))
    XCTAssertTrue(throttle.shouldPublish(at: 1.0 / 15.0))
  }

  func testResetAllowsAnImmediateFrame() {
    var throttle = FrameUpdateThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldPublish(at: 10))
    XCTAssertFalse(throttle.shouldPublish(at: 10.01))

    throttle.reset()

    XCTAssertTrue(throttle.shouldPublish(at: 10.01))
  }
}

final class FrameIngressThrottleTests: XCTestCase {
  func testAcceptsOnlyFramesAtTheConfiguredCadence() {
    let throttle = FrameIngressThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldAccept(at: 10))
    XCTAssertFalse(throttle.shouldAccept(at: 10.05))
    XCTAssertTrue(throttle.shouldAccept(at: 10 + (1.0 / 15.0)))
  }

  func testResetAllowsTheFirstFrameOfANewStreamGeneration() {
    let throttle = FrameIngressThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldAccept(at: 10))
    XCTAssertFalse(throttle.shouldAccept(at: 10.01))

    throttle.reset()

    XCTAssertTrue(throttle.shouldAccept(at: 10.01))
  }

  func testProviderSnapshotCadenceAcceptsOnlyTheLatestTwoFramesPerSecond() {
    let throttle = FrameIngressThrottle(maximumFramesPerSecond: 2)

    XCTAssertTrue(throttle.shouldAccept(at: 500))
    XCTAssertFalse(throttle.shouldAccept(at: 500.499))
    XCTAssertTrue(throttle.shouldAccept(at: 500.5))
    XCTAssertFalse(throttle.shouldAccept(at: 500.999))
    XCTAssertTrue(throttle.shouldAccept(at: 501))
  }
}
