import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class VideoFramePerformanceMonitorTests: XCTestCase {
  func testCapturesQueueDepthLatencyDropsAndConversionTiming() {
    let monitor = VideoFramePerformanceMonitor(windowStartedAt: 10)

    monitor.recordFrameReceived()
    monitor.recordMailboxOffer(replacedExistingFrame: false)
    monitor.recordFrameReceived()
    monitor.recordMailboxOffer(replacedExistingFrame: true)
    monitor.recordMainActorEntry(at: 10.010, receivedAt: 10)
    monitor.recordDrop(.throttle)
    monitor.recordMainActorEntry(at: 10.030, receivedAt: 10)
    monitor.recordImageConversion(duration: 0.004, published: true)
    monitor.recordDrop(.staleGeneration)
    monitor.recordDrop(.decoderBackpressure)
    monitor.recordQueueDepth(4)

    let snapshot = monitor.snapshot(at: 11)

    XCTAssertEqual(snapshot.inputFrames, 2)
    XCTAssertEqual(snapshot.mainActorDeliveries, 2)
    XCTAssertEqual(snapshot.publishedFrames, 1)
    XCTAssertEqual(snapshot.mailboxReplacements, 1)
    XCTAssertEqual(snapshot.throttleDrops, 1)
    XCTAssertEqual(snapshot.staleGenerationDrops, 1)
    XCTAssertEqual(snapshot.decoderBackpressureDrops, 1)
    XCTAssertEqual(snapshot.droppedFrames, 4)
    XCTAssertEqual(snapshot.currentQueueDepth, 0)
    XCTAssertEqual(snapshot.maximumQueueDepth, 4)
    XCTAssertEqual(snapshot.inputFramesPerSecond, 2)
    XCTAssertEqual(snapshot.publishedFramesPerSecond, 1)
    XCTAssertEqual(snapshot.averageMainActorDispatchLatencyMilliseconds, 20, accuracy: 0.001)
    XCTAssertEqual(snapshot.maximumMainActorDispatchLatencyMilliseconds, 30, accuracy: 0.001)
    XCTAssertEqual(snapshot.averageImageConversionMilliseconds, 4, accuracy: 0.001)
    XCTAssertEqual(snapshot.maximumImageConversionMilliseconds, 4, accuracy: 0.001)
  }

  func testSnapshotStartsANewMetricsWindow() {
    let monitor = VideoFramePerformanceMonitor(windowStartedAt: 0)

    monitor.recordFrameReceived()
    monitor.recordMailboxOffer(replacedExistingFrame: false)
    _ = monitor.snapshot(at: 1)

    let secondWindow = monitor.snapshot(at: 2)

    XCTAssertTrue(secondWindow.isEmpty)
    XCTAssertEqual(secondWindow.intervalSeconds, 1)
    XCTAssertEqual(secondWindow.currentQueueDepth, 0)
  }

  func testCountsRenderedFramesOnlyWhenTheMainActorPublishesThem() {
    let monitor = VideoFramePerformanceMonitor(windowStartedAt: 0)

    monitor.recordImageConversion(duration: 0.004, published: false)
    monitor.recordPublishedFrame()

    let snapshot = monitor.snapshot(at: 1)
    XCTAssertEqual(snapshot.publishedFrames, 1)
    XCTAssertEqual(snapshot.averageImageConversionMilliseconds, 4, accuracy: 0.001)
  }
}
