/*
 * Frame Update Throttle
 * Limits UI frame publication while preserving the latest accepted video frame.
 */

import Foundation
import os

struct FrameUpdateThrottle {
  private let minimumInterval: TimeInterval
  private var lastPublishedAt: TimeInterval?

  init(maximumFramesPerSecond: Double) {
    precondition(maximumFramesPerSecond > 0)
    minimumInterval = 1 / maximumFramesPerSecond
  }

  mutating func shouldPublish(at timestamp: TimeInterval) -> Bool {
    guard let lastPublishedAt else {
      self.lastPublishedAt = timestamp
      return true
    }

    guard timestamp - lastPublishedAt >= minimumInterval else {
      return false
    }

    self.lastPublishedAt = timestamp
    return true
  }

  mutating func reset() {
    lastPublishedAt = nil
  }
}

/// Thread-safe ingress cadence gate for raw DAT frames. It decides whether a
/// frame is worth rendering while its SDK-owned sample buffer is still valid.
final class FrameIngressThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private let minimumInterval: TimeInterval
  private var lastAcceptedAt: TimeInterval?

  init(maximumFramesPerSecond: Double) {
    precondition(maximumFramesPerSecond > 0)
    minimumInterval = 1 / maximumFramesPerSecond
  }

  func shouldAccept(at timestamp: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard let lastAcceptedAt else {
      self.lastAcceptedAt = timestamp
      return true
    }

    // Comparing against the next deadline avoids subtracting large uptime
    // values, which can turn an exactly-on-cadence frame into a false drop.
    guard timestamp >= lastAcceptedAt + minimumInterval else {
      return false
    }

    self.lastAcceptedAt = timestamp
    return true
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    lastAcceptedAt = nil
  }
}

enum VideoFrameDropReason: Sendable {
  case inactiveStream
  case throttle
  case staleGeneration
  case imageConversionFailure
  case decoderBackpressure
}

struct VideoFramePerformanceSnapshot: Equatable, Sendable {
  static let empty = VideoFramePerformanceSnapshot(
    intervalSeconds: 0,
    inputFrames: 0,
    mainActorDeliveries: 0,
    publishedFrames: 0,
    inactiveStreamDrops: 0,
    mailboxReplacements: 0,
    throttleDrops: 0,
    staleGenerationDrops: 0,
    imageConversionFailures: 0,
    decoderBackpressureDrops: 0,
    currentQueueDepth: 0,
    maximumQueueDepth: 0,
    averageMainActorDispatchLatencyMilliseconds: 0,
    maximumMainActorDispatchLatencyMilliseconds: 0,
    averageImageConversionMilliseconds: 0,
    maximumImageConversionMilliseconds: 0
  )

  let intervalSeconds: TimeInterval
  let inputFrames: Int
  let mainActorDeliveries: Int
  let publishedFrames: Int
  let inactiveStreamDrops: Int
  let mailboxReplacements: Int
  let throttleDrops: Int
  let staleGenerationDrops: Int
  let imageConversionFailures: Int
  let decoderBackpressureDrops: Int
  let currentQueueDepth: Int
  let maximumQueueDepth: Int
  let averageMainActorDispatchLatencyMilliseconds: Double
  let maximumMainActorDispatchLatencyMilliseconds: Double
  let averageImageConversionMilliseconds: Double
  let maximumImageConversionMilliseconds: Double

  var inputFramesPerSecond: Double {
    guard intervalSeconds > 0 else { return 0 }
    return Double(inputFrames) / intervalSeconds
  }

  var publishedFramesPerSecond: Double {
    guard intervalSeconds > 0 else { return 0 }
    return Double(publishedFrames) / intervalSeconds
  }

  var droppedFrames: Int {
    inactiveStreamDrops + mailboxReplacements + throttleDrops + staleGenerationDrops
      + imageConversionFailures + decoderBackpressureDrops
  }

  var isEmpty: Bool {
    inputFrames == 0 && mainActorDeliveries == 0 && droppedFrames == 0
  }
}

/// Thread-safe, one-second-window telemetry for the current DAT-to-SwiftUI
/// frame path. It records bounded mailbox pressure and image conversion work.
final class VideoFramePerformanceMonitor: @unchecked Sendable {
  private struct Window {
    var startedAt: TimeInterval
    var inputFrames = 0
    var mainActorDeliveries = 0
    var publishedFrames = 0
    var inactiveStreamDrops = 0
    var mailboxReplacements = 0
    var throttleDrops = 0
    var staleGenerationDrops = 0
    var imageConversionFailures = 0
    var decoderBackpressureDrops = 0
    var maximumQueueDepth = 0
    var mainActorDispatchLatencyTotalMilliseconds = 0.0
    var mainActorDispatchLatencyMaximumMilliseconds = 0.0
    var mainActorDispatchLatencySamples = 0
    var imageConversionTotalMilliseconds = 0.0
    var imageConversionMaximumMilliseconds = 0.0
    var imageConversionSamples = 0
  }

  private let lock = NSLock()
  private var window: Window

  init(windowStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    window = Window(startedAt: windowStartedAt)
  }

  func recordFrameReceived() {
    lock.lock()
    defer { lock.unlock() }

    window.inputFrames += 1
  }

  func recordMailboxOffer(replacedExistingFrame: Bool) {
    lock.lock()
    defer { lock.unlock() }

    window.maximumQueueDepth = max(window.maximumQueueDepth, 1)
    if replacedExistingFrame {
      window.mailboxReplacements += 1
    }
  }

  func recordQueueDepth(_ depth: Int) {
    lock.lock()
    defer { lock.unlock() }

    window.maximumQueueDepth = max(window.maximumQueueDepth, max(0, depth))
  }

  func recordMainActorEntry(at timestamp: TimeInterval, receivedAt: TimeInterval) {
    let latencyMilliseconds = max(0, timestamp - receivedAt) * 1_000

    lock.lock()
    defer { lock.unlock() }

    window.mainActorDeliveries += 1
    window.mainActorDispatchLatencySamples += 1
    window.mainActorDispatchLatencyTotalMilliseconds += latencyMilliseconds
    window.mainActorDispatchLatencyMaximumMilliseconds = max(
      window.mainActorDispatchLatencyMaximumMilliseconds,
      latencyMilliseconds
    )
  }

  func recordDrop(_ reason: VideoFrameDropReason) {
    lock.lock()
    defer { lock.unlock() }

    switch reason {
    case .inactiveStream:
      window.inactiveStreamDrops += 1
    case .throttle:
      window.throttleDrops += 1
    case .staleGeneration:
      window.staleGenerationDrops += 1
    case .imageConversionFailure:
      window.imageConversionFailures += 1
    case .decoderBackpressure:
      window.decoderBackpressureDrops += 1
    }
  }

  func recordImageConversion(duration: TimeInterval, published: Bool) {
    let milliseconds = max(0, duration) * 1_000

    lock.lock()
    defer { lock.unlock() }

    window.imageConversionSamples += 1
    window.imageConversionTotalMilliseconds += milliseconds
    window.imageConversionMaximumMilliseconds = max(
      window.imageConversionMaximumMilliseconds,
      milliseconds
    )
    if published {
      window.publishedFrames += 1
    }
  }

  func recordPublishedFrame() {
    lock.lock()
    defer { lock.unlock() }

    window.publishedFrames += 1
  }

  func snapshot(
    at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
    currentMailboxDepth: Int = 0
  ) -> VideoFramePerformanceSnapshot {
    lock.lock()
    defer { lock.unlock() }

    let interval = max(0, timestamp - window.startedAt)
    let snapshot = VideoFramePerformanceSnapshot(
      intervalSeconds: interval,
      inputFrames: window.inputFrames,
      mainActorDeliveries: window.mainActorDeliveries,
      publishedFrames: window.publishedFrames,
      inactiveStreamDrops: window.inactiveStreamDrops,
      mailboxReplacements: window.mailboxReplacements,
      throttleDrops: window.throttleDrops,
      staleGenerationDrops: window.staleGenerationDrops,
      imageConversionFailures: window.imageConversionFailures,
      decoderBackpressureDrops: window.decoderBackpressureDrops,
      currentQueueDepth: currentMailboxDepth,
      maximumQueueDepth: window.maximumQueueDepth,
      averageMainActorDispatchLatencyMilliseconds: average(
        total: window.mainActorDispatchLatencyTotalMilliseconds,
        samples: window.mainActorDispatchLatencySamples
      ),
      maximumMainActorDispatchLatencyMilliseconds: window.mainActorDispatchLatencyMaximumMilliseconds,
      averageImageConversionMilliseconds: average(
        total: window.imageConversionTotalMilliseconds,
        samples: window.imageConversionSamples
      ),
      maximumImageConversionMilliseconds: window.imageConversionMaximumMilliseconds
    )

    window = Window(startedAt: timestamp)
    return snapshot
  }

  private func average(total: Double, samples: Int) -> Double {
    guard samples > 0 else { return 0 }
    return total / Double(samples)
  }
}

struct LatestFrameMailboxItem<Value: Sendable>: Sendable {
  let value: Value
  let generation: Int
  let receivedAt: TimeInterval
}

enum LatestFrameMailboxOfferResult: Equatable, Sendable {
  case accepted(replacedExistingFrame: Bool)
  case staleGeneration
}

/// A one-slot mailbox. Producers overwrite stale work, so downstream UI work
/// remains bounded even when DAT delivers frames faster than its target rate.
final class LatestFrameMailbox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var activeGeneration: Int?
  private var latest: LatestFrameMailboxItem<Value>?

  /// Begins accepting frames for one stream generation and discards any item
  /// left by a previous stream before its listener finished unwinding.
  @discardableResult
  func activate(generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    let containedFrame = latest != nil
    activeGeneration = generation
    latest = nil
    return containedFrame
  }

  @discardableResult
  func offer(_ item: LatestFrameMailboxItem<Value>) -> LatestFrameMailboxOfferResult {
    lock.lock()
    defer { lock.unlock() }

    guard activeGeneration == item.generation else {
      return .staleGeneration
    }

    let replacedExistingFrame = latest != nil
    latest = item
    return .accepted(replacedExistingFrame: replacedExistingFrame)
  }

  func takeLatest() -> LatestFrameMailboxItem<Value>? {
    lock.lock()
    defer { lock.unlock() }

    let item = latest
    latest = nil
    return item
  }

  @discardableResult
  func deactivateAndClear() -> Bool {
    lock.lock()
    defer { lock.unlock() }

    let containedFrame = latest != nil
    activeGeneration = nil
    latest = nil
    return containedFrame
  }

  var depth: Int {
    lock.lock()
    defer { lock.unlock() }
    return latest == nil ? 0 : 1
  }
}

enum RealtimePerformanceSignposts {
  static let videoPipeline = OSSignposter(
    subsystem: AppIdentity.loggingSubsystem,
    category: "PointsOfInterest"
  )
}
