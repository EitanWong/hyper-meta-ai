/*
 * Realtime Audio Playback Pipeline
 * Keeps provider audio off the main actor, bounds jitter, and reuses one
 * AVAudioEngine plus AVAudioPlayerNode for each realtime service instance.
 */

import Accelerate
import AVFoundation
import Foundation
import os
import os.lock

enum RealtimeAudioSampleEncoding: Equatable, Sendable {
  case signedInteger16LittleEndian

  var bytesPerSample: Int {
    switch self {
    case .signedInteger16LittleEndian:
      return MemoryLayout<Int16>.size
    }
  }
}

struct RealtimePCMOutputFormat: Equatable, Sendable {
  let sampleRate: Double
  let channelCount: Int
  let encoding: RealtimeAudioSampleEncoding

  static let realtimePCM16Mono24kHz = RealtimePCMOutputFormat(
    sampleRate: 24_000,
    channelCount: 1,
    encoding: .signedInteger16LittleEndian
  )

  init(sampleRate: Double, channelCount: Int, encoding: RealtimeAudioSampleEncoding) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.encoding = encoding
  }

  var bytesPerFrame: Int {
    encoding.bytesPerSample * channelCount
  }

  static func pcm16LittleEndian(
    mimeType: String,
    defaultSampleRate: Double,
    defaultChannelCount: Int
  ) -> RealtimePCMOutputFormat? {
    let components = mimeType.split(separator: ";", omittingEmptySubsequences: true)
    guard let mediaType = components.first?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(), mediaType == "audio/pcm" else {
      return nil
    }

    var sampleRate = defaultSampleRate
    var channelCount = defaultChannelCount

    for component in components.dropFirst() {
      let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }

      let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
      switch name {
      case "rate":
        guard let parsedRate = Double(value) else { return nil }
        sampleRate = parsedRate
      case "channels":
        guard let parsedChannelCount = Int(value) else { return nil }
        channelCount = parsedChannelCount
      default:
        break
      }
    }

    guard sampleRate > 0, channelCount > 0 else {
      return nil
    }
    return RealtimePCMOutputFormat(
      sampleRate: sampleRate,
      channelCount: channelCount,
      encoding: .signedInteger16LittleEndian
    )
  }
}

struct RealtimeAudioPlaybackChunk: Sendable {
  let data: Data
  let frameCount: Int
  let generation: Int
  let responseID: UInt64
  let receivedAt: TimeInterval
}

enum RealtimeAudioJitterOverflowPolicy: Equatable, Sendable {
  /// Favor low latency by skipping already queued audio.
  case replaceOldest
  /// Preserve the audible response prefix and reject only a new tail packet.
  case rejectIncoming
}

enum RealtimeAudioJitterOfferResult: Equatable, Sendable {
  case accepted
  case replacedOldestQueuedChunks(chunkCount: Int, frameCount: Int)
  case inactive
  case staleGeneration
  case invalidFrameAlignment
  case oversizedChunk
  case queueFull

  var isAccepted: Bool {
    switch self {
    case .accepted, .replacedOldestQueuedChunks:
      return true
    case .inactive, .staleGeneration, .invalidFrameAlignment, .oversizedChunk, .queueFull:
      return false
    }
  }
}

struct RealtimeAudioJitterBufferSnapshot: Equatable, Sendable {
  let activeGeneration: Int?
  let responseID: UInt64
  let responseIsComplete: Bool
  let queuedChunks: Int
  let queuedFrames: Int
  let maximumQueuedChunks: Int
  let maximumQueuedFrames: Int
}

struct RealtimeAudioJitterResponseStart: Equatable, Sendable {
  let responseID: UInt64
  let discardedChunks: Int
  let discardedFrames: Int
}

final class RealtimeAudioJitterBuffer: @unchecked Sendable {
  private var lock = os_unfair_lock_s()
  private let maximumQueuedFrames: Int
  private let overflowPolicy: RealtimeAudioJitterOverflowPolicy
  private var storage: [RealtimeAudioPlaybackChunk?]
  private var head = 0
  private var tail = 0
  private var count = 0
  private var queuedFrames = 0
  private var activeGeneration: Int?
  private var responseID: UInt64 = 0
  private var responseIsComplete = true

  init(
    maximumQueuedFrames: Int = 4_800,
    maximumQueuedChunks: Int = 24,
    overflowPolicy: RealtimeAudioJitterOverflowPolicy = .replaceOldest
  ) {
    self.maximumQueuedFrames = max(1, maximumQueuedFrames)
    self.overflowPolicy = overflowPolicy
    storage = Array(repeating: nil, count: max(1, maximumQueuedChunks))
  }

  func activate(generation: Int) -> RealtimeAudioJitterResponseStart? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    let discarded = clearUnsafe()
    activeGeneration = generation
    responseID = 0
    responseIsComplete = true
    guard discarded.chunkCount > 0 else { return nil }
    return RealtimeAudioJitterResponseStart(
      responseID: responseID,
      discardedChunks: discarded.chunkCount,
      discardedFrames: discarded.frameCount
    )
  }

  func deactivateAndClear() -> RealtimeAudioJitterResponseStart? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    let discarded = clearUnsafe()
    activeGeneration = nil
    responseID &+= 1
    responseIsComplete = true
    guard discarded.chunkCount > 0 else { return nil }
    return RealtimeAudioJitterResponseStart(
      responseID: responseID,
      discardedChunks: discarded.chunkCount,
      discardedFrames: discarded.frameCount
    )
  }

  func beginResponse(generation: Int) -> RealtimeAudioJitterResponseStart? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard activeGeneration == generation else { return nil }
    let discarded = clearUnsafe()
    responseID &+= 1
    responseIsComplete = false
    return RealtimeAudioJitterResponseStart(
      responseID: responseID,
      discardedChunks: discarded.chunkCount,
      discardedFrames: discarded.frameCount
    )
  }

  func finishResponse(generation: Int) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard activeGeneration == generation else { return }
    responseIsComplete = true
  }

  func interruptResponse(generation: Int) -> RealtimeAudioJitterResponseStart? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard activeGeneration == generation else { return nil }
    let discarded = clearUnsafe()
    responseID &+= 1
    responseIsComplete = true
    return RealtimeAudioJitterResponseStart(
      responseID: responseID,
      discardedChunks: discarded.chunkCount,
      discardedFrames: discarded.frameCount
    )
  }

  func offer(
    _ data: Data,
    format: RealtimePCMOutputFormat,
    generation: Int,
    responseID: UInt64,
    receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeAudioJitterOfferResult {
    guard !data.isEmpty, data.count.isMultiple(of: format.bytesPerFrame) else {
      return .invalidFrameAlignment
    }
    let frameCount = data.count / format.bytesPerFrame
    guard frameCount <= maximumQueuedFrames else { return .oversizedChunk }

    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard activeGeneration != nil else { return .inactive }
    guard activeGeneration == generation, self.responseID == responseID else {
      return .staleGeneration
    }

    let mustMakeRoom = queuedFrames + frameCount > maximumQueuedFrames || count == storage.count
    var replacedChunkCount = 0
    var replacedFrameCount = 0
    if mustMakeRoom {
      switch overflowPolicy {
      case .replaceOldest:
        while count > 0 && (
          queuedFrames + frameCount > maximumQueuedFrames || count == storage.count
        ) {
          let discarded = removeFirstUnsafe()
          replacedChunkCount += 1
          replacedFrameCount += discarded.frameCount
        }
      case .rejectIncoming:
        return .queueFull
      }
    }

    storage[tail] = RealtimeAudioPlaybackChunk(
      data: data,
      frameCount: frameCount,
      generation: generation,
      responseID: responseID,
      receivedAt: receivedAt
    )
    tail = (tail + 1) % storage.count
    count += 1
    queuedFrames += frameCount

    if replacedChunkCount > 0 {
      return .replacedOldestQueuedChunks(
        chunkCount: replacedChunkCount,
        frameCount: replacedFrameCount
      )
    }
    return .accepted
  }

  func takeNext(generation: Int, responseID: UInt64) -> RealtimeAudioPlaybackChunk? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard activeGeneration == generation,
      self.responseID == responseID,
      let chunk = storage[head],
      chunk.generation == generation,
      chunk.responseID == responseID else {
      return nil
    }
    return removeFirstUnsafe()
  }

  func snapshot() -> RealtimeAudioJitterBufferSnapshot {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    return RealtimeAudioJitterBufferSnapshot(
      activeGeneration: activeGeneration,
      responseID: responseID,
      responseIsComplete: responseIsComplete,
      queuedChunks: count,
      queuedFrames: queuedFrames,
      maximumQueuedChunks: storage.count,
      maximumQueuedFrames: maximumQueuedFrames
    )
  }

  private func removeFirstUnsafe() -> RealtimeAudioPlaybackChunk {
    guard let chunk = storage[head] else {
      preconditionFailure("The jitter buffer head must contain a queued chunk")
    }
    storage[head] = nil
    head = (head + 1) % storage.count
    count -= 1
    queuedFrames -= chunk.frameCount
    return chunk
  }

  private func clearUnsafe() -> (chunkCount: Int, frameCount: Int) {
    let discardedChunkCount = count
    let discardedFrameCount = queuedFrames
    storage = Array(repeating: nil, count: storage.count)
    head = 0
    tail = 0
    count = 0
    queuedFrames = 0
    return (discardedChunkCount, discardedFrameCount)
  }
}

struct RealtimeAudioPlaybackPerformanceSnapshot: Equatable, Sendable {
  static let empty = RealtimeAudioPlaybackPerformanceSnapshot(
    intervalSeconds: 0,
    receivedChunks: 0,
    receivedFrames: 0,
    scheduledChunks: 0,
    playedChunks: 0,
    replacedQueuedChunks: 0,
    replacedQueuedFrames: 0,
    staleGenerationDrops: 0,
    inactiveDrops: 0,
    invalidFormatDrops: 0,
    invalidFrameAlignmentDrops: 0,
    oversizedChunkDrops: 0,
    queueFullDrops: 0,
    discardedOnResponseStart: 0,
    discardedOnInterrupt: 0,
    engineStartFailures: 0,
    underruns: 0,
    currentQueuedChunks: 0,
    currentQueuedFrames: 0,
    queueCapacityChunks: 0,
    queueCapacityFrames: 0,
    maximumQueuedChunks: 0,
    maximumQueuedFrames: 0,
    scheduledFrames: 0,
    maximumScheduledFrames: 0,
    averageDecodeMilliseconds: 0,
    maximumDecodeMilliseconds: 0,
    averageReceiveToScheduleMilliseconds: 0,
    maximumReceiveToScheduleMilliseconds: 0,
    averageScheduleToPlaybackMilliseconds: 0,
    maximumScheduleToPlaybackMilliseconds: 0
  )

  let intervalSeconds: TimeInterval
  let receivedChunks: Int
  let receivedFrames: Int
  let scheduledChunks: Int
  let playedChunks: Int
  let replacedQueuedChunks: Int
  let replacedQueuedFrames: Int
  let staleGenerationDrops: Int
  let inactiveDrops: Int
  let invalidFormatDrops: Int
  let invalidFrameAlignmentDrops: Int
  let oversizedChunkDrops: Int
  let queueFullDrops: Int
  let discardedOnResponseStart: Int
  let discardedOnInterrupt: Int
  let engineStartFailures: Int
  let underruns: Int
  let currentQueuedChunks: Int
  let currentQueuedFrames: Int
  let queueCapacityChunks: Int
  let queueCapacityFrames: Int
  let maximumQueuedChunks: Int
  let maximumQueuedFrames: Int
  let scheduledFrames: Int
  let maximumScheduledFrames: Int
  let averageDecodeMilliseconds: Double
  let maximumDecodeMilliseconds: Double
  let averageReceiveToScheduleMilliseconds: Double
  let maximumReceiveToScheduleMilliseconds: Double
  let averageScheduleToPlaybackMilliseconds: Double
  let maximumScheduleToPlaybackMilliseconds: Double

  var droppedChunks: Int {
    replacedQueuedChunks + staleGenerationDrops + inactiveDrops + invalidFormatDrops
      + invalidFrameAlignmentDrops + oversizedChunkDrops + queueFullDrops + discardedOnResponseStart
      + discardedOnInterrupt
  }

  var isEmpty: Bool {
    receivedChunks == 0 && scheduledChunks == 0 && playedChunks == 0 && droppedChunks == 0
      && engineStartFailures == 0 && underruns == 0
  }
}

private struct RealtimeAudioPlaybackMetricsWindow {
  var startedAt: TimeInterval
  var receivedChunks = 0
  var receivedFrames = 0
  var scheduledChunks = 0
  var playedChunks = 0
  var replacedQueuedChunks = 0
  var replacedQueuedFrames = 0
  var staleGenerationDrops = 0
  var inactiveDrops = 0
  var invalidFormatDrops = 0
  var invalidFrameAlignmentDrops = 0
  var oversizedChunkDrops = 0
  var queueFullDrops = 0
  var discardedOnResponseStart = 0
  var discardedOnInterrupt = 0
  var engineStartFailures = 0
  var underruns = 0
  var maximumQueuedChunks = 0
  var maximumQueuedFrames = 0
  var maximumScheduledFrames = 0
  var decodeSamples = 0
  var decodeTotalMilliseconds = 0.0
  var decodeMaximumMilliseconds = 0.0
  var receiveToScheduleSamples = 0
  var receiveToScheduleTotalMilliseconds = 0.0
  var receiveToScheduleMaximumMilliseconds = 0.0
  var playbackSamples = 0
  var scheduleToPlaybackTotalMilliseconds = 0.0
  var scheduleToPlaybackMaximumMilliseconds = 0.0
}

private final class RealtimeAudioPlaybackPerformanceMonitor: @unchecked Sendable {
  private var lock = os_unfair_lock_s()
  private var window: RealtimeAudioPlaybackMetricsWindow

  init(windowStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    window = RealtimeAudioPlaybackMetricsWindow(startedAt: windowStartedAt)
  }

  func recordOffer(_ result: RealtimeAudioJitterOfferResult, frameCount: Int) {
    withLock {
      switch result {
      case .accepted:
        window.receivedChunks += 1
        window.receivedFrames += frameCount
      case .replacedOldestQueuedChunks(let chunkCount, let replacedFrameCount):
        window.receivedChunks += 1
        window.receivedFrames += frameCount
        window.replacedQueuedChunks += chunkCount
        window.replacedQueuedFrames += replacedFrameCount
      case .inactive:
        window.inactiveDrops += 1
      case .staleGeneration:
        window.staleGenerationDrops += 1
      case .invalidFrameAlignment:
        window.invalidFrameAlignmentDrops += 1
      case .oversizedChunk:
        window.oversizedChunkDrops += 1
      case .queueFull:
        window.queueFullDrops += 1
      }
    }
  }

  func recordInvalidFormat() {
    withLock { window.invalidFormatDrops += 1 }
  }

  func recordResponseStart(discardedChunks: Int) {
    withLock { window.discardedOnResponseStart += discardedChunks }
  }

  func recordInterrupt(discardedChunks: Int) {
    withLock { window.discardedOnInterrupt += discardedChunks }
  }

  func recordScheduled(
    queued: RealtimeAudioJitterBufferSnapshot,
    scheduledFrames: Int,
    decodeDuration: TimeInterval,
    receiveToScheduleDuration: TimeInterval
  ) {
    withLock {
      let decodeMilliseconds = max(0, decodeDuration) * 1_000
      let receiveToScheduleMilliseconds = max(0, receiveToScheduleDuration) * 1_000
      window.scheduledChunks += 1
      window.decodeSamples += 1
      window.decodeTotalMilliseconds += decodeMilliseconds
      window.decodeMaximumMilliseconds = max(
        window.decodeMaximumMilliseconds,
        decodeMilliseconds
      )
      window.receiveToScheduleSamples += 1
      window.receiveToScheduleTotalMilliseconds += receiveToScheduleMilliseconds
      window.receiveToScheduleMaximumMilliseconds = max(
        window.receiveToScheduleMaximumMilliseconds,
        receiveToScheduleMilliseconds
      )
      window.maximumQueuedChunks = max(window.maximumQueuedChunks, queued.queuedChunks)
      window.maximumQueuedFrames = max(window.maximumQueuedFrames, queued.queuedFrames)
      window.maximumScheduledFrames = max(window.maximumScheduledFrames, scheduledFrames)
    }
  }

  func recordPlayed(scheduledAt: TimeInterval) {
    withLock {
      let milliseconds = max(0, ProcessInfo.processInfo.systemUptime - scheduledAt) * 1_000
      window.playedChunks += 1
      window.playbackSamples += 1
      window.scheduleToPlaybackTotalMilliseconds += milliseconds
      window.scheduleToPlaybackMaximumMilliseconds = max(
        window.scheduleToPlaybackMaximumMilliseconds,
        milliseconds
      )
    }
  }

  func recordEngineStartFailure() {
    withLock { window.engineStartFailures += 1 }
  }

  func recordUnderrun() {
    withLock { window.underruns += 1 }
  }

  func snapshot(
    queued: RealtimeAudioJitterBufferSnapshot,
    scheduledFrames: Int,
    at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeAudioPlaybackPerformanceSnapshot {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    let interval = max(0, timestamp - window.startedAt)
    let snapshot = RealtimeAudioPlaybackPerformanceSnapshot(
      intervalSeconds: interval,
      receivedChunks: window.receivedChunks,
      receivedFrames: window.receivedFrames,
      scheduledChunks: window.scheduledChunks,
      playedChunks: window.playedChunks,
      replacedQueuedChunks: window.replacedQueuedChunks,
      replacedQueuedFrames: window.replacedQueuedFrames,
      staleGenerationDrops: window.staleGenerationDrops,
      inactiveDrops: window.inactiveDrops,
      invalidFormatDrops: window.invalidFormatDrops,
      invalidFrameAlignmentDrops: window.invalidFrameAlignmentDrops,
      oversizedChunkDrops: window.oversizedChunkDrops,
      queueFullDrops: window.queueFullDrops,
      discardedOnResponseStart: window.discardedOnResponseStart,
      discardedOnInterrupt: window.discardedOnInterrupt,
      engineStartFailures: window.engineStartFailures,
      underruns: window.underruns,
      currentQueuedChunks: queued.queuedChunks,
      currentQueuedFrames: queued.queuedFrames,
      queueCapacityChunks: queued.maximumQueuedChunks,
      queueCapacityFrames: queued.maximumQueuedFrames,
      maximumQueuedChunks: window.maximumQueuedChunks,
      maximumQueuedFrames: window.maximumQueuedFrames,
      scheduledFrames: scheduledFrames,
      maximumScheduledFrames: window.maximumScheduledFrames,
      averageDecodeMilliseconds: average(
        total: window.decodeTotalMilliseconds,
        samples: window.decodeSamples
      ),
      maximumDecodeMilliseconds: window.decodeMaximumMilliseconds,
      averageReceiveToScheduleMilliseconds: average(
        total: window.receiveToScheduleTotalMilliseconds,
        samples: window.receiveToScheduleSamples
      ),
      maximumReceiveToScheduleMilliseconds: window.receiveToScheduleMaximumMilliseconds,
      averageScheduleToPlaybackMilliseconds: average(
        total: window.scheduleToPlaybackTotalMilliseconds,
        samples: window.playbackSamples
      ),
      maximumScheduleToPlaybackMilliseconds: window.scheduleToPlaybackMaximumMilliseconds
    )
    window = RealtimeAudioPlaybackMetricsWindow(startedAt: timestamp)
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

private enum RealtimeAudioPlaybackSignposts {
  static let playback = OSSignposter(
    subsystem: AppIdentity.loggingSubsystem,
    category: "RealtimeAudioPlayback"
  )
}

final class RealtimeAudioPlaybackPipeline: @unchecked Sendable {
  typealias FailureHandler = @MainActor (String) -> Void
  typealias PlaybackCompletionHandler = @MainActor (Int) -> Void
  typealias AudioLevelHandler = @MainActor (Float) -> Void

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()
  private let outputFormat: RealtimePCMOutputFormat
  private let jitterBuffer: RealtimeAudioJitterBuffer
  private let performanceMonitor = RealtimeAudioPlaybackPerformanceMonitor()
  private let minimumStartupFrames: Int
  private let targetScheduledFrames: Int
  private let schedulingSafetyIntervalMilliseconds: Int
  private let logger: Logger
  private let engineStartOverride: (@Sendable () -> Bool)?

  private var ingressLock = os_unfair_lock_s()
  private var ingressGeneration: Int?
  private var responseIsActive = false
  private var schedulingWakePending = false

  private var playbackEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var playbackAudioFormat: AVAudioFormat?
  private var didStartEngineWithOverride = false
  private var timer: DispatchSourceTimer?
  private var activeGeneration: Int?
  private var activeResponseID: UInt64 = 0
  private var hasStartedScheduling = false
  private var wasStarved = false
  private var scheduledFrames = 0
  private var scheduledBuffers: [UInt64: Int] = [:]
  private var nextScheduleToken: UInt64 = 0
  private var onFailure: FailureHandler?
  private var onResponsePlaybackComplete: PlaybackCompletionHandler?
  private var onAudioLevel: AudioLevelHandler?
  private var lastEmittedAudioLevel: Float = 0
  private var lastAudioLevelEmissionAt: TimeInterval = 0
  private var hasNotifiedResponsePlaybackCompletion = false
  private var lastMetricsReportAt = ProcessInfo.processInfo.systemUptime

  /// Frames confirmed played by `.dataPlayedBack` for the active response.
  /// Guarded by its own lock rather than the playback queue so the barge-in
  /// path can read it without a `queue.sync` barrier.
  private var playedFramesLock = os_unfair_lock_s()
  private var playedFramesForActiveResponse = 0
  private var playedFramesSampleRate: Double = 0
  #if DEBUG
  private var hasLoggedFirstScheduledBuffer = false
  private var hasLoggedFirstPlayedBuffer = false
  #endif

  init(
    label: String,
    outputFormat: RealtimePCMOutputFormat = .realtimePCM16Mono24kHz,
    startupBufferMilliseconds: Double = 40,
    maximumJitterMilliseconds: Double = 200,
    maximumBufferedResponseMilliseconds: Double? = nil,
    maximumBufferedResponseChunks: Int? = nil,
    responseBufferOverflowPolicy: RealtimeAudioJitterOverflowPolicy = .replaceOldest,
    targetScheduledMilliseconds: Double = 80,
    schedulingSafetyIntervalMilliseconds: Int = 20,
    engineStartOverride: (@Sendable () -> Bool)? = nil
  ) {
    self.outputFormat = outputFormat
    minimumStartupFrames = max(1, Int(outputFormat.sampleRate * startupBufferMilliseconds / 1_000))
    targetScheduledFrames = max(1, Int(outputFormat.sampleRate * targetScheduledMilliseconds / 1_000))
    self.schedulingSafetyIntervalMilliseconds = max(1, schedulingSafetyIntervalMilliseconds)
    let maximumBufferedMilliseconds = max(
      maximumJitterMilliseconds,
      maximumBufferedResponseMilliseconds ?? maximumJitterMilliseconds
    )
    jitterBuffer = RealtimeAudioJitterBuffer(
      maximumQueuedFrames: max(1, Int(outputFormat.sampleRate * maximumBufferedMilliseconds / 1_000)),
      maximumQueuedChunks: max(1, maximumBufferedResponseChunks ?? 24),
      overflowPolicy: responseBufferOverflowPolicy
    )
    queue = DispatchQueue(label: label, qos: .userInitiated)
    logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "RealtimeAudioPlayback")
    self.engineStartOverride = engineStartOverride
    queue.setSpecific(key: queueKey, value: ())
  }

  deinit {
    stop()
  }

  func start(
    generation: Int,
    onFailure: @escaping FailureHandler,
    onResponsePlaybackComplete: @escaping PlaybackCompletionHandler = { _ in },
    onAudioLevel: @escaping AudioLevelHandler = { _ in }
  ) {
    withIngressLock {
      ingressGeneration = generation
      responseIsActive = false
      schedulingWakePending = false
      _ = jitterBuffer.activate(generation: generation)
    }

    synchronouslyOnQueue {
      resetPlayer(stopEngine: true)
      activeGeneration = generation
      activeResponseID = 0
      hasStartedScheduling = false
      wasStarved = false
      scheduledFrames = 0
      scheduledBuffers.removeAll(keepingCapacity: true)
      self.onFailure = onFailure
      self.onResponsePlaybackComplete = onResponsePlaybackComplete
      self.onAudioLevel = onAudioLevel
      lastEmittedAudioLevel = 0
      lastAudioLevelEmissionAt = 0
      hasNotifiedResponsePlaybackCompletion = false
      lastMetricsReportAt = ProcessInfo.processInfo.systemUptime
      resetPlayedFrames()
      #if DEBUG
      hasLoggedFirstScheduledBuffer = false
      hasLoggedFirstPlayedBuffer = false
      #endif
    }
  }

  func stop() {
    withIngressLock {
      ingressGeneration = nil
      responseIsActive = false
      schedulingWakePending = false
      _ = jitterBuffer.deactivateAndClear()
    }

    var levelHandler: AudioLevelHandler?
    synchronouslyOnQueue {
      activeGeneration = nil
      activeResponseID = 0
      hasStartedScheduling = false
      wasStarved = false
      scheduledFrames = 0
      scheduledBuffers.removeAll(keepingCapacity: true)
      onFailure = nil
      onResponsePlaybackComplete = nil
      levelHandler = onAudioLevel
      onAudioLevel = nil
      lastEmittedAudioLevel = 0
      lastAudioLevelEmissionAt = 0
      hasNotifiedResponsePlaybackCompletion = false
      resetPlayedFrames()
      #if DEBUG
      hasLoggedFirstScheduledBuffer = false
      hasLoggedFirstPlayedBuffer = false
      #endif
      resetPlayer(stopEngine: true)
      cancelTimer()
    }
    Task { @MainActor in
      levelHandler?(0)
    }
  }

  @discardableResult
  func enqueue(
    _ data: Data,
    generation: Int,
    receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeAudioJitterOfferResult {
    let responseStart: RealtimeAudioJitterResponseStart?
    let responseID: UInt64
    os_unfair_lock_lock(&ingressLock)
    guard ingressGeneration == generation else {
      let isInactive = ingressGeneration == nil
      os_unfair_lock_unlock(&ingressLock)
      let result: RealtimeAudioJitterOfferResult = isInactive ? .inactive : .staleGeneration
      performanceMonitor.recordOffer(result, frameCount: 0)
      return result
    }
    if !responseIsActive {
      guard let started = jitterBuffer.beginResponse(generation: generation) else {
        os_unfair_lock_unlock(&ingressLock)
        performanceMonitor.recordOffer(.staleGeneration, frameCount: 0)
        return .staleGeneration
      }
      responseIsActive = true
      responseStart = started
      responseID = started.responseID
      queue.async { [weak self] in
        guard let self else { return }
        self.prepareForResponse(generation: generation, responseID: started.responseID)
        self.startTimerIfNeeded()
      }
    } else {
      responseStart = nil
      responseID = jitterBuffer.snapshot().responseID
    }
    os_unfair_lock_unlock(&ingressLock)

    if let responseStart {
      performanceMonitor.recordResponseStart(discardedChunks: responseStart.discardedChunks)
    }
    let result = jitterBuffer.offer(
      data,
      format: outputFormat,
      generation: generation,
      responseID: responseID,
      receivedAt: receivedAt
    )
    performanceMonitor.recordOffer(result, frameCount: data.count / outputFormat.bytesPerFrame)
    if result.isAccepted {
      requestScheduling()
    }
    return result
  }

  func prepare(generation: Int) {
    prepare(generation: generation) { _ in }
  }

  func prepare(
    generation: Int,
    completion: @escaping @Sendable (Bool) -> Void
  ) {
    queue.async { [weak self] in
      guard let self, self.activeGeneration == generation else {
        completion(false)
        return
      }
      completion(self.ensurePlayerGraphAndStart())
    }
  }

  func recordUnsupportedFormat() {
    performanceMonitor.recordInvalidFormat()
  }

  func finishResponse(generation: Int) {
    withIngressLock {
      guard ingressGeneration == generation else { return }
      responseIsActive = false
      jitterBuffer.finishResponse(generation: generation)
      queue.async { [weak self] in
        guard let self, self.activeGeneration == generation else { return }
        self.scheduleAvailableAudio()
      }
    }
  }

  /// Milliseconds of assistant audio that actually reached the speaker for the
  /// current response. Read with an atomic load so the barge-in path never
  /// blocks on the playback queue; the value is updated from
  /// `handlePlaybackCompletion` as `.dataPlayedBack` callbacks land.
  var playedMillisecondsForActiveResponse: Int {
    os_unfair_lock_lock(&playedFramesLock)
    let frames = playedFramesForActiveResponse
    let rate = playedFramesSampleRate
    os_unfair_lock_unlock(&playedFramesLock)
    guard rate > 0, frames > 0 else { return 0 }
    return Int((Double(frames) / rate * 1_000).rounded())
  }

  private func resetPlayedFrames() {
    os_unfair_lock_lock(&playedFramesLock)
    playedFramesForActiveResponse = 0
    os_unfair_lock_unlock(&playedFramesLock)
  }

  private func recordPlayedFrames(_ frameCount: Int) {
    guard frameCount > 0 else { return }
    os_unfair_lock_lock(&playedFramesLock)
    playedFramesForActiveResponse += frameCount
    playedFramesSampleRate = outputFormat.sampleRate
    os_unfair_lock_unlock(&playedFramesLock)
  }

  /// Interrupts playback and reports how much of the response was truly heard.
  /// The returned value is captured *before* the reset clears the counter, so
  /// callers can forward it to the provider as `audio_end_ms`.
  @discardableResult
  func interrupt(generation: Int) -> Int {
    let runsOnPlaybackQueue = DispatchQueue.getSpecific(key: queueKey) != nil
    let playedMilliseconds = playedMillisecondsForActiveResponse
    let interrupted = withIngressLock { () -> RealtimeAudioJitterResponseStart? in
      guard ingressGeneration == generation else { return nil }
      responseIsActive = false
      guard let interrupted = jitterBuffer.interruptResponse(generation: generation) else {
        return nil
      }
      if runsOnPlaybackQueue {
        resetAfterInterruption(
          generation: generation,
          responseID: interrupted.responseID,
          discardAudioGraph: false
        )
      } else {
        queue.async { [weak self] in
          self?.resetAfterInterruption(
            generation: generation,
            responseID: interrupted.responseID,
            discardAudioGraph: false
          )
        }
      }
      return interrupted
    }
    // A no-op interrupt (stale generation, or no response to interrupt) must not
    // report progress: the caller would forward it as `audio_end_ms` for a
    // response this call never actually stopped.
    guard let interrupted else { return 0 }
    performanceMonitor.recordInterrupt(discardedChunks: interrupted.discardedChunks)
    // The barrier is load-bearing and covered by
    // `testInterruptWaitsForPlayerResetBarrierWithinBudget`: callers rely on the
    // queued `resetPlayer` having run by the time this returns. Note it does
    // block the caller (@MainActor on the barge-in path) for as long as the
    // playback queue is busy — normally microseconds, but up to the engine-start
    // timeout in the worst case. Moving the reset off the blocking path is a
    // separate change that needs the test updated alongside it.
    if !runsOnPlaybackQueue {
      synchronouslyOnQueue {}
    }
    return playedMilliseconds
  }

  /// Drops the active response and discards the AVAudioEngine graph after an
  /// audio-system interruption or media-services reset. Ingress stays active,
  /// so the next response can rebuild lazily without reconnecting the session.
  @discardableResult
  func invalidateAudioSystem(generation: Int) -> Int {
    let runsOnPlaybackQueue = DispatchQueue.getSpecific(key: queueKey) != nil
    let playedMilliseconds = playedMillisecondsForActiveResponse
    let interrupted = withIngressLock { () -> RealtimeAudioJitterResponseStart? in
      guard ingressGeneration == generation else { return nil }
      responseIsActive = false
      guard let interrupted = jitterBuffer.interruptResponse(generation: generation) else {
        return nil
      }
      if runsOnPlaybackQueue {
        resetAfterInterruption(
          generation: generation,
          responseID: interrupted.responseID,
          discardAudioGraph: true
        )
      } else {
        queue.async { [weak self] in
          self?.resetAfterInterruption(
            generation: generation,
            responseID: interrupted.responseID,
            discardAudioGraph: true
          )
        }
      }
      return interrupted
    }
    // Same rule as `interrupt`: nothing was stopped, so report no progress.
    guard let interrupted else { return 0 }
    performanceMonitor.recordInterrupt(discardedChunks: interrupted.discardedChunks)
    if !runsOnPlaybackQueue {
      synchronouslyOnQueue {}
    }
    return playedMilliseconds
  }

  func snapshot() -> RealtimeAudioPlaybackPerformanceSnapshot {
    let queued = jitterBuffer.snapshot()
    var currentScheduledFrames = 0
    synchronouslyOnQueue {
      currentScheduledFrames = scheduledFrames
    }
    return performanceMonitor.snapshot(queued: queued, scheduledFrames: currentScheduledFrames)
  }

  private func startTimerIfNeeded() {
    guard timer == nil else { return }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now(),
      repeating: .milliseconds(schedulingSafetyIntervalMilliseconds),
      leeway: .milliseconds(1)
    )
    timer.setEventHandler { [weak self] in
      self?.scheduleAvailableAudio()
      self?.reportMetricsIfNeeded()
    }
    self.timer = timer
    timer.resume()
  }

  private func requestScheduling() {
    let shouldWake = withIngressLock { () -> Bool in
      guard !schedulingWakePending else { return false }
      schedulingWakePending = true
      return true
    }
    guard shouldWake else { return }

    queue.async { [weak self] in
      guard let self else { return }
      // Clear before reading the jitter buffer so an offer racing with this
      // scheduling pass can enqueue one follow-up wake instead of being lost.
      self.withIngressLock {
        self.schedulingWakePending = false
      }
      self.scheduleAvailableAudio()
    }
  }

  private func cancelTimer() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private func prepareForResponse(generation: Int, responseID: UInt64) {
    guard activeGeneration == generation else { return }
    let queued = jitterBuffer.snapshot()
    guard queued.activeGeneration == generation, queued.responseID == responseID else { return }
    // Shared with the interruption path so the played-frame counter can never be
    // reset in one place and forgotten in the other — a stale count here would
    // truncate the *next* response at the previous response's position.
    resetResponseScheduling(responseID: responseID)
    resetPlayer(stopEngine: false)
  }

  private func scheduleAvailableAudio() {
    guard let generation = activeGeneration, activeResponseID > 0 else { return }
    let queued = jitterBuffer.snapshot()
    guard queued.activeGeneration == generation, queued.responseID == activeResponseID else {
      return
    }

    if queued.responseIsComplete,
      queued.queuedFrames == 0,
      scheduledFrames == 0 {
      cancelTimer()
      return
    }

    if !hasStartedScheduling {
      guard queued.queuedFrames >= minimumStartupFrames || (
        queued.responseIsComplete && queued.queuedFrames > 0
      ) else {
        return
      }
      hasStartedScheduling = true
    }

    while scheduledFrames < targetScheduledFrames,
      let chunk = jitterBuffer.takeNext(generation: generation, responseID: activeResponseID) {
      guard schedule(chunk) else { return }
    }

    let remaining = jitterBuffer.snapshot()
    if hasStartedScheduling,
      !remaining.responseIsComplete,
      remaining.queuedFrames == 0,
      scheduledFrames == 0,
      !wasStarved {
      wasStarved = true
      performanceMonitor.recordUnderrun()
    }
    notifyResponsePlaybackCompletionIfNeeded(queued: remaining)
    if remaining.responseIsComplete,
      remaining.queuedFrames == 0,
      scheduledFrames == 0 {
      cancelTimer()
    }
  }

  private func schedule(_ chunk: RealtimeAudioPlaybackChunk) -> Bool {
    guard ensurePlayerGraphAndStart() else {
      failPlayback(generation: chunk.generation, message: "Audio playback engine failed to start")
      return false
    }

    let decodingStartedAt = ProcessInfo.processInfo.systemUptime
    let signpost = RealtimeAudioPlaybackSignposts.playback.beginInterval("PCM16Decode")
    defer { RealtimeAudioPlaybackSignposts.playback.endInterval("PCM16Decode", signpost) }
    guard let playerNode, let playbackAudioFormat,
      let buffer = makePCMBuffer(from: chunk.data, format: playbackAudioFormat) else {
      failPlayback(generation: chunk.generation, message: "Audio playback buffer could not be decoded")
      return false
    }

    nextScheduleToken &+= 1
    let token = nextScheduleToken
    let scheduledAt = ProcessInfo.processInfo.systemUptime
    scheduledFrames += chunk.frameCount
    scheduledBuffers[token] = chunk.frameCount
    wasStarved = false
    performanceMonitor.recordScheduled(
      queued: jitterBuffer.snapshot(),
      scheduledFrames: scheduledFrames,
      decodeDuration: scheduledAt - decodingStartedAt,
      receiveToScheduleDuration: scheduledAt - chunk.receivedAt
    )

    let pipeline = self
    playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak pipeline] _ in
      guard let pipeline else { return }
      pipeline.queue.async {
        pipeline.handlePlaybackCompletion(token: token, scheduledAt: scheduledAt)
      }
    }
    if !playerNode.isPlaying {
      playerNode.play()
    }
    #if DEBUG
    if !hasLoggedFirstScheduledBuffer {
      hasLoggedFirstScheduledBuffer = true
      let audioSession = AVAudioSession.sharedInstance()
      let input = audioSession.currentRoute.inputs.map(\.portName).joined(separator: ",")
      let output = audioSession.currentRoute.outputs.map(\.portName).joined(separator: ",")
      print(
        "▶️ [RealtimePlayback] 首个 PCM 缓冲已调度: frames=\(chunk.frameCount), "
          + "route input=\(input) output=\(output) rate=\(audioSession.sampleRate)"
      )
    }
    #endif
    return true
  }

  private func handlePlaybackCompletion(token: UInt64, scheduledAt: TimeInterval) {
    guard let frameCount = scheduledBuffers.removeValue(forKey: token) else { return }
    scheduledFrames = max(0, scheduledFrames - frameCount)
    recordPlayedFrames(frameCount)
    performanceMonitor.recordPlayed(scheduledAt: scheduledAt)
    #if DEBUG
    if !hasLoggedFirstPlayedBuffer {
      hasLoggedFirstPlayedBuffer = true
      print("✅ [RealtimePlayback] 首个 PCM 缓冲已由音频设备播放")
    }
    #endif
    scheduleAvailableAudio()
    if scheduledFrames == 0 {
      emitAudioLevel(0, force: true)
    }
  }

  private func notifyResponsePlaybackCompletionIfNeeded(
    queued: RealtimeAudioJitterBufferSnapshot
  ) {
    guard let generation = activeGeneration,
      activeResponseID > 0,
      !hasNotifiedResponsePlaybackCompletion,
      hasStartedScheduling,
      queued.activeGeneration == generation,
      queued.responseID == activeResponseID,
      queued.responseIsComplete,
      queued.queuedFrames == 0,
      scheduledFrames == 0 else {
      return
    }

    hasNotifiedResponsePlaybackCompletion = true
    let completion = onResponsePlaybackComplete
    Task { @MainActor in
      completion?(generation)
    }
  }

  private func ensurePlayerGraphAndStart() -> Bool {
    if playbackEngine == nil || playerNode == nil || playbackAudioFormat == nil {
      guard let format = AVAudioFormat(
        standardFormatWithSampleRate: outputFormat.sampleRate,
        channels: AVAudioChannelCount(outputFormat.channelCount)
      ) else {
        performanceMonitor.recordEngineStartFailure()
        return false
      }

      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      engine.mainMixerNode.installTap(
        onBus: 0,
        bufferSize: 1_024,
        format: nil
      ) { [weak self] buffer, _ in
        guard let self else { return }
        let level = Self.normalizedAudioLevel(buffer)
        self.queue.async { [weak self] in
          self?.emitAudioLevel(level)
        }
      }
      engine.prepare()
      playbackEngine = engine
      playerNode = player
      playbackAudioFormat = format
    }

    guard let playbackEngine else {
      performanceMonitor.recordEngineStartFailure()
      return false
    }

    if let engineStartOverride {
      if !didStartEngineWithOverride {
        guard engineStartOverride() else {
          performanceMonitor.recordEngineStartFailure()
          return false
        }
        didStartEngineWithOverride = true
      }
      return true
    }

    do {
      if !playbackEngine.isRunning {
        try playbackEngine.start()
      }
      return true
    } catch {
      performanceMonitor.recordEngineStartFailure()
      logger.error("Audio playback engine start failed: \(error.localizedDescription, privacy: .public)")
      #if DEBUG
      print("❌ [RealtimePlayback] 播放引擎启动失败: \(error.localizedDescription)")
      #endif
      return false
    }
  }

  private func resetPlayer(stopEngine: Bool) {
    playerNode?.stop()
    playerNode?.reset()
    if stopEngine {
      playbackEngine?.stop()
      didStartEngineWithOverride = false
    }
  }

  private func discardPlayerGraph() {
    resetPlayer(stopEngine: true)
    playbackEngine?.mainMixerNode.removeTap(onBus: 0)
    playerNode = nil
    playbackAudioFormat = nil
    playbackEngine = nil
  }

  private func resetResponseScheduling(responseID: UInt64) {
    activeResponseID = responseID
    hasStartedScheduling = false
    wasStarved = false
    scheduledFrames = 0
    scheduledBuffers.removeAll(keepingCapacity: true)
    hasNotifiedResponsePlaybackCompletion = false
    // Per-response counter: every new response and every interruption routes
    // through here, so the played-ms figure never leaks across turns.
    resetPlayedFrames()
    #if DEBUG
    hasLoggedFirstScheduledBuffer = false
    hasLoggedFirstPlayedBuffer = false
    #endif
  }

  private func resetAfterInterruption(
    generation: Int,
    responseID: UInt64,
    discardAudioGraph: Bool
  ) {
    guard activeGeneration == generation else { return }
    resetResponseScheduling(responseID: responseID)
    if discardAudioGraph {
      discardPlayerGraph()
    } else {
      resetPlayer(stopEngine: false)
    }
    emitAudioLevel(0, force: true)
    cancelTimer()
  }

  private static func normalizedAudioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return 0 }
    let frameCount = vDSP_Length(buffer.frameLength)
    var peakRMS: Float = 0
    for channelIndex in 0..<Int(buffer.format.channelCount) {
      var rms: Float = 0
      vDSP_rmsqv(channels[channelIndex], 1, &rms, frameCount)
      peakRMS = max(peakRMS, rms)
    }
    return min(max(peakRMS * 8, 0), 1)
  }

  private func emitAudioLevel(_ level: Float, force: Bool = false) {
    let clamped = min(max(level, 0), 1)
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastAudioLevelEmissionAt >= 0.08 else { return }
    guard force || abs(clamped - lastEmittedAudioLevel) >= 0.015 else { return }
    lastEmittedAudioLevel = clamped
    lastAudioLevelEmissionAt = now
    let handler = onAudioLevel
    Task { @MainActor in
      handler?(clamped)
    }
  }

  func makePCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frameCount = data.count / outputFormat.bytesPerFrame
    guard frameCount > 0,
      data.count.isMultiple(of: outputFormat.bytesPerFrame),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      ),
      let channelData = buffer.floatChannelData else {
      return nil
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    switch outputFormat.encoding {
    case .signedInteger16LittleEndian:
      decodePCM16LittleEndian(data, frameCount: frameCount, into: channelData)
    }
    return buffer
  }

  private func decodePCM16LittleEndian(
    _ data: Data,
    frameCount: Int,
    into channelData: UnsafePointer<UnsafeMutablePointer<Float>>
  ) {
    data.withUnsafeBytes { rawBytes in
      guard let baseAddress = rawBytes.baseAddress else { return }

      // Every supported Apple target is little-endian. Owned Data is normally
      // aligned, so Accelerate can convert each interleaved channel directly
      // into the non-interleaved AVAudioPCMBuffer without a temporary array.
      if UInt16(littleEndian: 1) == 1,
        Int(bitPattern: baseAddress).isMultiple(of: MemoryLayout<Int16>.alignment) {
        let samples = baseAddress.assumingMemoryBound(to: Int16.self)
        let sourceStride = vDSP_Stride(outputFormat.channelCount)
        let length = vDSP_Length(frameCount)
        var scale: Float = 1.0 / 32_768.0
        for channelIndex in 0..<outputFormat.channelCount {
          let destination = channelData[channelIndex]
          vDSP_vflt16(
            samples.advanced(by: channelIndex),
            sourceStride,
            destination,
            1,
            length
          )
          vDSP_vsmul(destination, 1, &scale, destination, 1, length)
        }
        return
      }

      let bytes = rawBytes.bindMemory(to: UInt8.self)
      for frameIndex in 0..<frameCount {
        for channelIndex in 0..<outputFormat.channelCount {
          let byteOffset = frameIndex * outputFormat.bytesPerFrame
            + channelIndex * outputFormat.encoding.bytesPerSample
          let sampleBits = UInt16(bytes[byteOffset]) | UInt16(bytes[byteOffset + 1]) << 8
          channelData[channelIndex][frameIndex] = Float(Int16(bitPattern: sampleBits)) / 32_768.0
        }
      }
    }
  }

  private func failPlayback(generation: Int, message: String) {
    guard activeGeneration == generation else { return }

    let invalidatedCurrentIngress = withIngressLock { () -> Bool in
      guard ingressGeneration == generation else { return false }
      ingressGeneration = nil
      responseIsActive = false
      return true
    }
    guard invalidatedCurrentIngress else { return }

    _ = jitterBuffer.deactivateAndClear()
    let failure = onFailure
    emitAudioLevel(0, force: true)
    activeGeneration = nil
    activeResponseID = 0
    hasStartedScheduling = false
    wasStarved = false
    scheduledFrames = 0
    scheduledBuffers.removeAll(keepingCapacity: true)
    onFailure = nil
    onResponsePlaybackComplete = nil
    hasNotifiedResponsePlaybackCompletion = false
    resetPlayer(stopEngine: true)
    cancelTimer()
    Task { @MainActor in
      failure?(message)
    }
  }

  private func reportMetricsIfNeeded() {
    #if DEBUG
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastMetricsReportAt >= 1 else { return }
    lastMetricsReportAt = now

    let metrics = performanceMonitor.snapshot(
      queued: jitterBuffer.snapshot(),
      scheduledFrames: scheduledFrames,
      at: now
    )
    guard !metrics.isEmpty else { return }
    logger.debug(
      "Playback metrics input=\(metrics.receivedChunks) scheduled=\(metrics.scheduledChunks) played=\(metrics.playedChunks) queue=\(metrics.currentQueuedFrames)/\(metrics.queueCapacityFrames) peak=\(metrics.maximumQueuedFrames) scheduledFrames=\(metrics.scheduledFrames) drops=\(metrics.droppedChunks)[inactive=\(metrics.inactiveDrops) stale=\(metrics.staleGenerationDrops) invalidFormat=\(metrics.invalidFormatDrops) invalidAlignment=\(metrics.invalidFrameAlignmentDrops) oversized=\(metrics.oversizedChunkDrops) queueFull=\(metrics.queueFullDrops) replaced=\(metrics.replacedQueuedChunks) responseStart=\(metrics.discardedOnResponseStart) interrupt=\(metrics.discardedOnInterrupt)] underruns=\(metrics.underruns) decodeMs=\(metrics.averageDecodeMilliseconds) ingressMs=\(metrics.averageReceiveToScheduleMilliseconds) playDelayMs=\(metrics.averageScheduleToPlaybackMilliseconds)"
    )
    // Device-console diagnostics are intentionally limited to one summary per
    // second and compiled out of Release builds.
    print(
      "🎚️ [RealtimePlayback] input=\(metrics.receivedChunks) "
        + "scheduled=\(metrics.scheduledChunks) played=\(metrics.playedChunks) "
        + "queue=\(metrics.currentQueuedFrames)/\(metrics.queueCapacityFrames) "
        + "peak=\(metrics.maximumQueuedFrames) "
        + "scheduledFrames=\(metrics.scheduledFrames) replaced=\(metrics.replacedQueuedChunks) "
        + "queueFull=\(metrics.queueFullDrops) "
        + "underruns=\(metrics.underruns) drops=\(metrics.droppedChunks)"
    )
    #endif
  }

  private func synchronouslyOnQueue(_ body: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      body()
    } else {
      queue.sync(execute: body)
    }
  }

  private func withIngressLock<Result>(_ body: () -> Result) -> Result {
    os_unfair_lock_lock(&ingressLock)
    defer { os_unfair_lock_unlock(&ingressLock) }
    return body()
  }
}

protocol RealtimeAudioPlaybackControlling: AnyObject {
  func start(
    generation: Int,
    onFailure: @escaping RealtimeAudioPlaybackPipeline.FailureHandler,
    onResponsePlaybackComplete: @escaping RealtimeAudioPlaybackPipeline.PlaybackCompletionHandler,
    onAudioLevel: @escaping RealtimeAudioPlaybackPipeline.AudioLevelHandler
  )
  func prepare(generation: Int)
  func stop()
  func enqueue(
    _ data: Data,
    generation: Int,
    receivedAt: TimeInterval
  ) -> RealtimeAudioJitterOfferResult
  func finishResponse(generation: Int)
  /// Returns the milliseconds of the active response that actually reached the
  /// speaker, so callers can tell the provider how much the user really heard.
  @discardableResult
  func interrupt(generation: Int) -> Int
  @discardableResult
  func invalidateAudioSystem(generation: Int) -> Int
}

extension RealtimeAudioPlaybackPipeline: RealtimeAudioPlaybackControlling {}
