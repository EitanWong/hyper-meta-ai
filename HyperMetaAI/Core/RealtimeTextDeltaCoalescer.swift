/*
 * Realtime Text Delta Coalescer
 * Keeps provider text callbacks off the main actor and publishes bounded-rate
 * UI snapshots for every active realtime session.
 */

import Foundation
import os
import os.lock

enum RealtimeTextDeltaAppendResult: Equatable, Sendable {
  case accepted
  case inactive
  case pendingBufferFull
}

struct RealtimeTextDeltaSnapshot: Equatable, Sendable {
  let sessionGeneration: Int
  let responseID: UInt64
  let sequence: UInt64
  let text: String
  let isFinal: Bool
  let coalescedDeltaCount: Int
  let coalescedCharacterCount: Int
  let firstDeltaToPublishMilliseconds: Double
}

struct RealtimeTextDeltaPerformanceSnapshot: Equatable, Sendable {
  static let empty = RealtimeTextDeltaPerformanceSnapshot(
    intervalSeconds: 0,
    inputDeltas: 0,
    inputCharacters: 0,
    publishedSnapshots: 0,
    completedResponses: 0,
    inactiveDrops: 0,
    pendingBufferDrops: 0,
    currentPendingDeltas: 0,
    currentPendingCharacters: 0,
    maximumPendingDeltas: 0,
    maximumPendingCharacters: 0,
    averageFirstDeltaToPublishMilliseconds: 0,
    maximumFirstDeltaToPublishMilliseconds: 0
  )

  let intervalSeconds: TimeInterval
  let inputDeltas: Int
  let inputCharacters: Int
  let publishedSnapshots: Int
  let completedResponses: Int
  let inactiveDrops: Int
  let pendingBufferDrops: Int
  let currentPendingDeltas: Int
  let currentPendingCharacters: Int
  let maximumPendingDeltas: Int
  let maximumPendingCharacters: Int
  let averageFirstDeltaToPublishMilliseconds: Double
  let maximumFirstDeltaToPublishMilliseconds: Double

  var droppedDeltas: Int {
    inactiveDrops + pendingBufferDrops
  }

  var isEmpty: Bool {
    inputDeltas == 0 && publishedSnapshots == 0 && completedResponses == 0 && droppedDeltas == 0
  }
}

private struct RealtimeTextDeltaMetricsWindow {
  var startedAt: TimeInterval
  var inputDeltas = 0
  var inputCharacters = 0
  var publishedSnapshots = 0
  var completedResponses = 0
  var inactiveDrops = 0
  var pendingBufferDrops = 0
  var maximumPendingDeltas = 0
  var maximumPendingCharacters = 0
  var latencySamples = 0
  var firstDeltaToPublishTotalMilliseconds = 0.0
  var firstDeltaToPublishMaximumMilliseconds = 0.0
}

private final class RealtimeTextDeltaPerformanceMonitor: @unchecked Sendable {
  private var lock = os_unfair_lock_s()
  private var window: RealtimeTextDeltaMetricsWindow

  init(windowStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    window = RealtimeTextDeltaMetricsWindow(startedAt: windowStartedAt)
  }

  func recordAppend(
    result: RealtimeTextDeltaAppendResult,
    characterCount: Int,
    pendingDeltaCount: Int,
    pendingCharacterCount: Int
  ) {
    withLock {
      switch result {
      case .accepted:
        window.inputDeltas += 1
        window.inputCharacters += characterCount
        window.maximumPendingDeltas = max(window.maximumPendingDeltas, pendingDeltaCount)
        window.maximumPendingCharacters = max(window.maximumPendingCharacters, pendingCharacterCount)
      case .inactive:
        window.inactiveDrops += 1
      case .pendingBufferFull:
        window.pendingBufferDrops += 1
      }
    }
  }

  func recordSnapshot(firstDeltaToPublishMilliseconds: Double) {
    withLock {
      window.publishedSnapshots += 1
      guard firstDeltaToPublishMilliseconds > 0 else { return }
      window.latencySamples += 1
      window.firstDeltaToPublishTotalMilliseconds += firstDeltaToPublishMilliseconds
      window.firstDeltaToPublishMaximumMilliseconds = max(
        window.firstDeltaToPublishMaximumMilliseconds,
        firstDeltaToPublishMilliseconds
      )
    }
  }

  func recordResponseCompleted() {
    withLock { window.completedResponses += 1 }
  }

  func snapshot(
    currentPendingDeltas: Int,
    currentPendingCharacters: Int,
    at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeTextDeltaPerformanceSnapshot {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    let interval = max(0, timestamp - window.startedAt)
    let snapshot = RealtimeTextDeltaPerformanceSnapshot(
      intervalSeconds: interval,
      inputDeltas: window.inputDeltas,
      inputCharacters: window.inputCharacters,
      publishedSnapshots: window.publishedSnapshots,
      completedResponses: window.completedResponses,
      inactiveDrops: window.inactiveDrops,
      pendingBufferDrops: window.pendingBufferDrops,
      currentPendingDeltas: currentPendingDeltas,
      currentPendingCharacters: currentPendingCharacters,
      maximumPendingDeltas: window.maximumPendingDeltas,
      maximumPendingCharacters: window.maximumPendingCharacters,
      averageFirstDeltaToPublishMilliseconds: average(
        total: window.firstDeltaToPublishTotalMilliseconds,
        samples: window.latencySamples
      ),
      maximumFirstDeltaToPublishMilliseconds: window.firstDeltaToPublishMaximumMilliseconds
    )
    window = RealtimeTextDeltaMetricsWindow(startedAt: timestamp)
    return snapshot
  }

  private func withLock(_ body: () -> Void) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    body()
  }

  private func average(total: Double, samples: Int) -> Double {
    guard samples > 0 else { return 0 }
    return total / Double(samples)
  }
}

private enum RealtimeTextDeltaSignposts {
  static let text = OSSignposter(
    subsystem: AppIdentity.loggingSubsystem,
    category: "RealtimeText"
  )
}

private struct RealtimeTextDeltaSnapshotPayload {
  let sessionGeneration: Int
  let responseID: UInt64
  let sequence: UInt64
  let segments: [String]
  let isFinal: Bool
  let coalescedDeltaCount: Int
  let coalescedCharacterCount: Int
  let firstDeltaAt: TimeInterval?
}

/// Aggregates streaming provider output on a serial background queue. Incoming
/// deltas use only a short unfair-lock section and never schedule a MainActor task.
final class RealtimeTextDeltaCoalescer: @unchecked Sendable {
  typealias SnapshotHandler = (RealtimeTextDeltaSnapshot) -> Void

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()
  private let publishingInterval: TimeInterval
  private let maximumPendingDeltaCount: Int
  private let maximumPendingCharacterCount: Int
  private let performanceMonitor = RealtimeTextDeltaPerformanceMonitor()
  private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "RealtimeText")

  private var ingressLock = os_unfair_lock_s()
  private var activeGeneration: Int?
  private var activeResponseID: UInt64 = 0
  private var responseIsComplete = true
  private var pendingSegments: [String] = []
  private var pendingCharacterCount = 0
  private var pendingFirstDeltaAt: TimeInterval?
  private var completedSegments: [String] = []
  private var nextSequence: UInt64 = 0

  private var timer: DispatchSourceTimer?
  private var onSnapshot: SnapshotHandler?
  private var lastMetricsReportAt = ProcessInfo.processInfo.systemUptime

  init(
    label: String,
    publishingInterval: TimeInterval = 0.06,
    maximumPendingDeltaCount: Int = 256,
    maximumPendingCharacterCount: Int = 32 * 1_024
  ) {
    precondition(publishingInterval > 0)
    precondition(maximumPendingDeltaCount > 0)
    precondition(maximumPendingCharacterCount > 0)

    queue = DispatchQueue(label: label, qos: .userInitiated)
    self.publishingInterval = publishingInterval
    self.maximumPendingDeltaCount = maximumPendingDeltaCount
    self.maximumPendingCharacterCount = maximumPendingCharacterCount
    queue.setSpecific(key: queueKey, value: ())
  }

  deinit {
    stop()
  }

  func start(generation: Int, onSnapshot: @escaping SnapshotHandler) {
    synchronouslyOnQueue {
      self.onSnapshot = onSnapshot
      self.lastMetricsReportAt = ProcessInfo.processInfo.systemUptime
      self.startTimerIfNeeded()
    }

    withIngressLock {
      activeGeneration = generation
      activeResponseID = 0
      responseIsComplete = true
      pendingSegments.removeAll(keepingCapacity: true)
      pendingCharacterCount = 0
      pendingFirstDeltaAt = nil
      completedSegments.removeAll(keepingCapacity: true)
      nextSequence = 0
    }
  }

  func stop() {
    withIngressLock {
      activeGeneration = nil
      activeResponseID &+= 1
      responseIsComplete = true
      pendingSegments.removeAll(keepingCapacity: true)
      pendingCharacterCount = 0
      pendingFirstDeltaAt = nil
      completedSegments.removeAll(keepingCapacity: true)
      nextSequence = 0
    }

    synchronouslyOnQueue {
      self.onSnapshot = nil
      self.cancelTimer()
    }
  }

  @discardableResult
  func append(
    _ delta: String,
    receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeTextDeltaAppendResult {
    guard !delta.isEmpty else { return .accepted }

    let characterCount = delta.utf8.count
    let result: RealtimeTextDeltaAppendResult
    let pendingDeltaCount: Int
    let pendingCharacters: Int

    os_unfair_lock_lock(&ingressLock)
    if activeGeneration == nil {
      result = .inactive
      pendingDeltaCount = pendingSegments.count
      pendingCharacters = pendingCharacterCount
    } else {
      beginResponseIfNeededUnsafe()
      if pendingSegments.count >= maximumPendingDeltaCount
        || pendingCharacterCount + characterCount > maximumPendingCharacterCount {
        result = .pendingBufferFull
        pendingDeltaCount = pendingSegments.count
        pendingCharacters = pendingCharacterCount
      } else {
        pendingSegments.append(delta)
        pendingCharacterCount += characterCount
        pendingFirstDeltaAt = pendingFirstDeltaAt ?? receivedAt
        result = .accepted
        pendingDeltaCount = pendingSegments.count
        pendingCharacters = pendingCharacterCount
      }
    }
    os_unfair_lock_unlock(&ingressLock)

    performanceMonitor.recordAppend(
      result: result,
      characterCount: characterCount,
      pendingDeltaCount: pendingDeltaCount,
      pendingCharacterCount: pendingCharacters
    )
    return result
  }

  /// Delivers any buffered text immediately. The method is primarily useful for
  /// deterministic tests and completion boundaries that need no timer delay.
  func flush() {
    queue.async { [weak self] in
      self?.publishPendingSnapshot()
    }
  }

  /// Provider-final text is authoritative when available. An empty final text
  /// preserves the buffered delta aggregation, which supports providers that
  /// signal completion separately from their incremental transcript events.
  func finish(finalText: String? = nil) {
    queue.async { [weak self] in
      self?.finishResponse(finalText: finalText)
    }
  }

  func performanceSnapshot(
    at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeTextDeltaPerformanceSnapshot {
    let pending = withIngressLock { (pendingSegments.count, pendingCharacterCount) }
    return performanceMonitor.snapshot(
      currentPendingDeltas: pending.0,
      currentPendingCharacters: pending.1,
      at: timestamp
    )
  }

  private func publishPendingSnapshot() {
    guard let payload = takePendingSnapshotPayload() else { return }
    emit(payload)
  }

  private func finishResponse(finalText: String?) {
    let payload: RealtimeTextDeltaSnapshotPayload?
    os_unfair_lock_lock(&ingressLock)
    if activeGeneration == nil {
      payload = nil
    } else {
      if responseIsComplete {
        // A final-only first response has no delta from which to establish a
        // boundary. Once a response ID exists, another completion belongs to
        // that completed response and must not create a duplicate UI message.
        guard activeResponseID == 0,
              let finalText,
              !finalText.isEmpty else {
          os_unfair_lock_unlock(&ingressLock)
          return
        }
        beginResponseIfNeededUnsafe()
      }

      let coalescedDeltaCount = pendingSegments.count
      let coalescedCharacterCount = pendingCharacterCount
      let firstDeltaAt = pendingFirstDeltaAt
      if !pendingSegments.isEmpty {
        completedSegments.append(contentsOf: pendingSegments)
      }
      pendingSegments.removeAll(keepingCapacity: true)
      pendingCharacterCount = 0
      pendingFirstDeltaAt = nil

      if let finalText, !finalText.isEmpty {
        completedSegments = [finalText]
      }

      nextSequence &+= 1
      responseIsComplete = true
      payload = RealtimeTextDeltaSnapshotPayload(
        sessionGeneration: activeGeneration!,
        responseID: activeResponseID,
        sequence: nextSequence,
        segments: completedSegments,
        isFinal: true,
        coalescedDeltaCount: coalescedDeltaCount,
        coalescedCharacterCount: coalescedCharacterCount,
        firstDeltaAt: firstDeltaAt
      )
    }
    os_unfair_lock_unlock(&ingressLock)

    guard let payload else { return }
    performanceMonitor.recordResponseCompleted()
    emit(payload)
  }

  private func takePendingSnapshotPayload() -> RealtimeTextDeltaSnapshotPayload? {
    os_unfair_lock_lock(&ingressLock)
    defer { os_unfair_lock_unlock(&ingressLock) }

    guard let activeGeneration, !responseIsComplete, !pendingSegments.isEmpty else {
      return nil
    }

    let coalescedDeltaCount = pendingSegments.count
    let coalescedCharacterCount = pendingCharacterCount
    let firstDeltaAt = pendingFirstDeltaAt
    completedSegments.append(contentsOf: pendingSegments)
    pendingSegments.removeAll(keepingCapacity: true)
    pendingCharacterCount = 0
    pendingFirstDeltaAt = nil
    nextSequence &+= 1
    return RealtimeTextDeltaSnapshotPayload(
      sessionGeneration: activeGeneration,
      responseID: activeResponseID,
      sequence: nextSequence,
      segments: completedSegments,
      isFinal: false,
      coalescedDeltaCount: coalescedDeltaCount,
      coalescedCharacterCount: coalescedCharacterCount,
      firstDeltaAt: firstDeltaAt
    )
  }

  private func emit(_ payload: RealtimeTextDeltaSnapshotPayload) {
    let signpost = RealtimeTextDeltaSignposts.text.beginInterval("TextSnapshot")
    let text = payload.segments.joined()
    RealtimeTextDeltaSignposts.text.endInterval("TextSnapshot", signpost)

    let now = ProcessInfo.processInfo.systemUptime
    let latencyMilliseconds = payload.firstDeltaAt.map { max(0, now - $0) * 1_000 } ?? 0
    performanceMonitor.recordSnapshot(firstDeltaToPublishMilliseconds: latencyMilliseconds)
    onSnapshot?(
      RealtimeTextDeltaSnapshot(
        sessionGeneration: payload.sessionGeneration,
        responseID: payload.responseID,
        sequence: payload.sequence,
        text: text,
        isFinal: payload.isFinal,
        coalescedDeltaCount: payload.coalescedDeltaCount,
        coalescedCharacterCount: payload.coalescedCharacterCount,
        firstDeltaToPublishMilliseconds: latencyMilliseconds
      )
    )
    reportMetricsIfNeeded(at: now)
  }

  private func beginResponseIfNeededUnsafe() {
    guard responseIsComplete else { return }
    activeResponseID &+= 1
    responseIsComplete = false
    pendingSegments.removeAll(keepingCapacity: true)
    pendingCharacterCount = 0
    pendingFirstDeltaAt = nil
    completedSegments.removeAll(keepingCapacity: true)
    nextSequence = 0
  }

  private func startTimerIfNeeded() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + publishingInterval,
      repeating: publishingInterval,
      leeway: .milliseconds(5)
    )
    timer.setEventHandler { [weak self] in
      self?.publishPendingSnapshot()
    }
    self.timer = timer
    timer.resume()
  }

  private func cancelTimer() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private func reportMetricsIfNeeded(at now: TimeInterval) {
    guard now - lastMetricsReportAt >= 1 else { return }
    lastMetricsReportAt = now
    let metrics = performanceSnapshot(at: now)
    guard !metrics.isEmpty else { return }
    logger.debug(
      "Realtime text: deltas=\(metrics.inputDeltas, privacy: .public) snapshots=\(metrics.publishedSnapshots, privacy: .public) pending=\(metrics.currentPendingDeltas, privacy: .public) drops=\(metrics.droppedDeltas, privacy: .public) first_delta_latency_ms=\(metrics.averageFirstDeltaToPublishMilliseconds, privacy: .public)"
    )
  }

  private func synchronouslyOnQueue(_ body: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      body()
    } else {
      queue.sync(execute: body)
    }
  }

  private func withIngressLock<T>(_ body: () -> T) -> T {
    os_unfair_lock_lock(&ingressLock)
    defer { os_unfair_lock_unlock(&ingressLock) }
    return body()
  }
}
