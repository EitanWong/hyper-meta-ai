/*
 * Realtime Audio Upload Pipeline
 * Keeps AVAudioEngine taps bounded and moves conversion plus WebSocket work
 * onto one serial upload queue per realtime service.
 */

import Accelerate
import AVFoundation
import Foundation
import os
import os.lock

struct RealtimeAudioCapturePerformanceSnapshot: Equatable, Sendable {
  static let empty = RealtimeAudioCapturePerformanceSnapshot(
    intervalSeconds: 0,
    inputBuffers: 0,
    inputFrames: 0,
    encodedBuffers: 0,
    sentBuffers: 0,
    replacedQueuedBuffers: 0,
    staleFrameAgeDrops: 0,
    staleGenerationDrops: 0,
    inactiveDrops: 0,
    tapLockContentionDrops: 0,
    unsupportedFormatDrops: 0,
    oversizedBufferDrops: 0,
    encodingFailures: 0,
    messageBuildFailures: 0,
    sendFailures: 0,
    sendTimeouts: 0,
    queueFullDrops: 0,
    discardedOnStop: 0,
    currentQueueDepth: 0,
    maximumQueueDepth: 0,
    lastInputSampleRate: 0,
    lastInputChannelCount: 0,
    averageCaptureToSendMilliseconds: 0,
    maximumCaptureToSendMilliseconds: 0,
    averageEncodingMilliseconds: 0,
    maximumEncodingMilliseconds: 0
  )

  let intervalSeconds: TimeInterval
  let inputBuffers: Int
  let inputFrames: Int
  let encodedBuffers: Int
  let sentBuffers: Int
  let replacedQueuedBuffers: Int
  let staleFrameAgeDrops: Int
  let staleGenerationDrops: Int
  let inactiveDrops: Int
  let tapLockContentionDrops: Int
  let unsupportedFormatDrops: Int
  let oversizedBufferDrops: Int
  let encodingFailures: Int
  let messageBuildFailures: Int
  let sendFailures: Int
  let sendTimeouts: Int
  let queueFullDrops: Int
  let discardedOnStop: Int
  let currentQueueDepth: Int
  let maximumQueueDepth: Int
  let lastInputSampleRate: Double
  let lastInputChannelCount: Int
  let averageCaptureToSendMilliseconds: Double
  let maximumCaptureToSendMilliseconds: Double
  let averageEncodingMilliseconds: Double
  let maximumEncodingMilliseconds: Double

  var droppedBuffers: Int {
    replacedQueuedBuffers + staleFrameAgeDrops + staleGenerationDrops + inactiveDrops
      + tapLockContentionDrops + unsupportedFormatDrops + oversizedBufferDrops
      + encodingFailures + messageBuildFailures + sendFailures + sendTimeouts
      + queueFullDrops + discardedOnStop
  }

  var isEmpty: Bool {
    inputBuffers == 0 && encodedBuffers == 0 && sentBuffers == 0 && droppedBuffers == 0
  }
}

enum RealtimeAudioCaptureOfferResult: Equatable, Sendable {
  case accepted
  case replacedOldestQueuedBuffer
  case staleGeneration
  case inactive
  case tapLockContention
  case unsupportedFormat
  case oversizedBuffer
  case queueFull
}

struct RealtimeAudioCapturedFrame: Sendable {
  let samples: [Float]
  let sampleRate: Double
  let sourceChannelCount: Int
  let generation: Int
  let capturedAt: TimeInterval
}

private enum RealtimeAudioCaptureSlotState: Equatable {
  case free
  case ready
  case leased
}

private final class RealtimeAudioCaptureSlot {
  var samples: [Float]
  var state: RealtimeAudioCaptureSlotState = .free
  var generation = 0
  var sampleRate = 0.0
  var sourceChannelCount = 0
  var frameCount = 0
  var capturedAt = 0.0
  var sequence: UInt64 = 0

  init(maximumFramesPerBuffer: Int) {
    samples = [Float](repeating: 0, count: maximumFramesPerBuffer)
  }
}

private struct RealtimeAudioCaptureLease {
  let slot: RealtimeAudioCaptureSlot
  let generation: Int
  let sequence: UInt64
}

private struct RealtimeAudioMetricsWindow {
  var startedAt: TimeInterval
  var inputBuffers = 0
  var inputFrames = 0
  var encodedBuffers = 0
  var sentBuffers = 0
  var replacedQueuedBuffers = 0
  var staleFrameAgeDrops = 0
  var staleGenerationDrops = 0
  var inactiveDrops = 0
  var unsupportedFormatDrops = 0
  var oversizedBufferDrops = 0
  var encodingFailures = 0
  var messageBuildFailures = 0
  var sendFailures = 0
  var sendTimeouts = 0
  var queueFullDrops = 0
  var discardedOnStop = 0
  var maximumQueueDepth = 0
  var lastInputSampleRate = 0.0
  var lastInputChannelCount = 0
  var captureToSendTotalMilliseconds = 0.0
  var captureToSendMaximumMilliseconds = 0.0
  var captureToSendSamples = 0
  var encodingTotalMilliseconds = 0.0
  var encodingMaximumMilliseconds = 0.0
  var encodingSamples = 0
}

/// Fixed-size slots isolate the realtime audio thread from the uploader. The
/// producer only attempts an unfair lock; when it is contended, it drops the
/// callback instead of waiting behind conversion or network work.
final class RealtimeAudioCaptureMailbox: @unchecked Sendable {
  private var lock = os_unfair_lock_s()
  private var contentionLock = os_unfair_lock_s()
  private var activeGeneration: Int?
  private var slots: [RealtimeAudioCaptureSlot]
  private var nextSequence: UInt64 = 0
  private var metrics: RealtimeAudioMetricsWindow
  private var tapLockContentionDrops = 0

  private let maximumFramesPerBuffer: Int

  init(
    slotCount: Int = 6,
    maximumFramesPerBuffer: Int = 4_096,
    windowStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    precondition(slotCount > 0)
    precondition(maximumFramesPerBuffer > 0)

    self.maximumFramesPerBuffer = maximumFramesPerBuffer
    slots = (0..<slotCount).map { _ in
      RealtimeAudioCaptureSlot(maximumFramesPerBuffer: maximumFramesPerBuffer)
    }
    metrics = RealtimeAudioMetricsWindow(startedAt: windowStartedAt)
  }

  @discardableResult
  func activate(generation: Int, inputFormat: AVAudioFormat) -> Int {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    activeGeneration = generation
    metrics.lastInputSampleRate = inputFormat.sampleRate
    metrics.lastInputChannelCount = Int(inputFormat.channelCount)
    return discardReadySlotsUnsafe(recordAsStaleGeneration: true)
  }

  @discardableResult
  func deactivateAndClear() -> Int {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    activeGeneration = nil
    let discarded = discardReadySlotsUnsafe(recordAsStaleGeneration: false)
    metrics.discardedOnStop += discarded
    return discarded
  }

  func capture(
    _ buffer: AVAudioPCMBuffer,
    generation: Int,
    capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeAudioCaptureOfferResult {
    guard os_unfair_lock_trylock(&lock) else {
      recordTapLockContention()
      return .tapLockContention
    }
    defer { os_unfair_lock_unlock(&lock) }

    let frameCount = Int(buffer.frameLength)
    metrics.inputBuffers += 1
    metrics.inputFrames += frameCount
    metrics.lastInputSampleRate = buffer.format.sampleRate
    metrics.lastInputChannelCount = Int(buffer.format.channelCount)

    guard activeGeneration != nil else {
      metrics.inactiveDrops += 1
      return .inactive
    }
    guard activeGeneration == generation else {
      metrics.staleGenerationDrops += 1
      return .staleGeneration
    }
    guard frameCount > 0, frameCount <= maximumFramesPerBuffer else {
      metrics.oversizedBufferDrops += 1
      return .oversizedBuffer
    }
    guard let channel = buffer.floatChannelData?.pointee else {
      metrics.unsupportedFormatDrops += 1
      return .unsupportedFormat
    }

    let result: RealtimeAudioCaptureOfferResult
    let slotIndex: Int
    if let freeSlotIndex = firstFreeSlotIndexUnsafe() {
      slotIndex = freeSlotIndex
      result = .accepted
    } else if let oldestReadySlotIndex = oldestReadySlotIndexUnsafe() {
      slotIndex = oldestReadySlotIndex
      metrics.replacedQueuedBuffers += 1
      result = .replacedOldestQueuedBuffer
    } else {
      metrics.queueFullDrops += 1
      return .queueFull
    }

    let slot = slots[slotIndex]
    slot.samples.withUnsafeMutableBufferPointer { destination in
      guard let baseAddress = destination.baseAddress else { return }
      baseAddress.update(from: channel, count: frameCount)
    }
    nextSequence &+= 1
    slot.state = .ready
    slot.generation = generation
    slot.sampleRate = buffer.format.sampleRate
    slot.sourceChannelCount = Int(buffer.format.channelCount)
    slot.frameCount = frameCount
    slot.capturedAt = capturedAt
    slot.sequence = nextSequence
    metrics.maximumQueueDepth = max(metrics.maximumQueueDepth, occupiedDepthUnsafe())
    return result
  }

  func takeNext(expectedGeneration: Int) -> RealtimeAudioCapturedFrame? {
    guard let lease = leaseNext(expectedGeneration: expectedGeneration) else { return nil }

    // The leased state keeps this slot unavailable to the tap while copying the
    // frame into worker-owned memory outside the realtime lock.
    let slot = lease.slot
    let samples = Array(slot.samples.prefix(slot.frameCount))
    let frame = RealtimeAudioCapturedFrame(
      samples: samples,
      sampleRate: slot.sampleRate,
      sourceChannelCount: slot.sourceChannelCount,
      generation: slot.generation,
      capturedAt: slot.capturedAt
    )
    release(lease)
    return frame
  }

  func recordEncoded(duration: TimeInterval) {
    withLock {
      let milliseconds = max(0, duration) * 1_000
      metrics.encodedBuffers += 1
      metrics.encodingSamples += 1
      metrics.encodingTotalMilliseconds += milliseconds
      metrics.encodingMaximumMilliseconds = max(metrics.encodingMaximumMilliseconds, milliseconds)
    }
  }

  func recordEncodingFailure() {
    withLock { metrics.encodingFailures += 1 }
  }

  func recordMessageBuildFailure() {
    withLock { metrics.messageBuildFailures += 1 }
  }

  func recordStaleFrameAgeDrop() {
    withLock { metrics.staleFrameAgeDrops += 1 }
  }

  func recordSendSuccess(capturedAt: TimeInterval, sentAt: TimeInterval) {
    withLock {
      let milliseconds = max(0, sentAt - capturedAt) * 1_000
      metrics.sentBuffers += 1
      metrics.captureToSendSamples += 1
      metrics.captureToSendTotalMilliseconds += milliseconds
      metrics.captureToSendMaximumMilliseconds = max(metrics.captureToSendMaximumMilliseconds, milliseconds)
    }
  }

  func recordSendFailure() {
    withLock { metrics.sendFailures += 1 }
  }

  func recordSendTimeout() {
    withLock { metrics.sendTimeouts += 1 }
  }

  func snapshot(
    at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RealtimeAudioCapturePerformanceSnapshot {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    os_unfair_lock_lock(&contentionLock)
    let contentionDrops = tapLockContentionDrops
    tapLockContentionDrops = 0
    os_unfair_lock_unlock(&contentionLock)

    let interval = max(0, timestamp - metrics.startedAt)
    let snapshot = RealtimeAudioCapturePerformanceSnapshot(
      intervalSeconds: interval,
      inputBuffers: metrics.inputBuffers,
      inputFrames: metrics.inputFrames,
      encodedBuffers: metrics.encodedBuffers,
      sentBuffers: metrics.sentBuffers,
      replacedQueuedBuffers: metrics.replacedQueuedBuffers,
      staleFrameAgeDrops: metrics.staleFrameAgeDrops,
      staleGenerationDrops: metrics.staleGenerationDrops,
      inactiveDrops: metrics.inactiveDrops,
      tapLockContentionDrops: contentionDrops,
      unsupportedFormatDrops: metrics.unsupportedFormatDrops,
      oversizedBufferDrops: metrics.oversizedBufferDrops,
      encodingFailures: metrics.encodingFailures,
      messageBuildFailures: metrics.messageBuildFailures,
      sendFailures: metrics.sendFailures,
      sendTimeouts: metrics.sendTimeouts,
      queueFullDrops: metrics.queueFullDrops,
      discardedOnStop: metrics.discardedOnStop,
      currentQueueDepth: occupiedDepthUnsafe(),
      maximumQueueDepth: metrics.maximumQueueDepth,
      lastInputSampleRate: metrics.lastInputSampleRate,
      lastInputChannelCount: metrics.lastInputChannelCount,
      averageCaptureToSendMilliseconds: average(
        total: metrics.captureToSendTotalMilliseconds,
        samples: metrics.captureToSendSamples
      ),
      maximumCaptureToSendMilliseconds: metrics.captureToSendMaximumMilliseconds,
      averageEncodingMilliseconds: average(
        total: metrics.encodingTotalMilliseconds,
        samples: metrics.encodingSamples
      ),
      maximumEncodingMilliseconds: metrics.encodingMaximumMilliseconds
    )
    let inputSampleRate = metrics.lastInputSampleRate
    let inputChannelCount = metrics.lastInputChannelCount
    metrics = RealtimeAudioMetricsWindow(startedAt: timestamp)
    metrics.lastInputSampleRate = inputSampleRate
    metrics.lastInputChannelCount = inputChannelCount
    return snapshot
  }

  private func leaseNext(expectedGeneration: Int) -> RealtimeAudioCaptureLease? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard activeGeneration == expectedGeneration,
          let slotIndex = oldestReadySlotIndexUnsafe() else {
      return nil
    }
    guard slots[slotIndex].generation == expectedGeneration else {
      slots[slotIndex].state = .free
      metrics.staleGenerationDrops += 1
      return nil
    }

    slots[slotIndex].state = .leased
    return RealtimeAudioCaptureLease(
      slot: slots[slotIndex],
      generation: slots[slotIndex].generation,
      sequence: slots[slotIndex].sequence
    )
  }

  private func release(_ lease: RealtimeAudioCaptureLease) {
    withLock {
      guard lease.slot.state == .leased,
            lease.slot.generation == lease.generation,
            lease.slot.sequence == lease.sequence else {
        return
      }
      lease.slot.state = .free
      lease.slot.frameCount = 0
    }
  }

  private func discardReadySlotsUnsafe(recordAsStaleGeneration: Bool) -> Int {
    var discarded = 0
    for index in slots.indices where slots[index].state == .ready {
      slots[index].state = .free
      slots[index].frameCount = 0
      discarded += 1
    }
    if recordAsStaleGeneration {
      metrics.staleGenerationDrops += discarded
    }
    return discarded
  }

  private func firstFreeSlotIndexUnsafe() -> Int? {
    for index in slots.indices where slots[index].state == .free {
      return index
    }
    return nil
  }

  private func oldestReadySlotIndexUnsafe() -> Int? {
    var oldestIndex: Int?
    for index in slots.indices where slots[index].state == .ready {
      if let currentOldestIndex = oldestIndex {
        if slots[index].sequence < slots[currentOldestIndex].sequence {
          oldestIndex = index
        }
      } else {
        oldestIndex = index
      }
    }
    return oldestIndex
  }

  private func occupiedDepthUnsafe() -> Int {
    var depth = 0
    for slot in slots where slot.state != .free {
      depth += 1
    }
    return depth
  }

  private func recordTapLockContention() {
    guard os_unfair_lock_trylock(&contentionLock) else { return }
    tapLockContentionDrops += 1
    os_unfair_lock_unlock(&contentionLock)
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

struct RealtimeEncodedAudioFrameStats: Equatable, Sendable {
  let rms: Float
  let sampleCount: Int
}

struct RealtimeCapturedAudioFrameStats: Equatable, Sendable {
  let rms: Float
  let sampleCount: Int
  let sampleRate: Double

  var duration: TimeInterval {
    guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
    return Double(sampleCount) / sampleRate
  }
}

enum RealtimeFloatAudioMeter {
  static func stats(for buffer: AVAudioPCMBuffer) -> RealtimeCapturedAudioFrameStats? {
    let sampleCount = Int(buffer.frameLength)
    let sampleRate = buffer.format.sampleRate
    guard sampleCount > 0,
          sampleRate.isFinite,
          sampleRate > 0,
          let channels = buffer.floatChannelData else {
      return nil
    }

    var peakRMS: Float = 0
    let vectorLength = vDSP_Length(sampleCount)
    for channelIndex in 0..<Int(buffer.format.channelCount) {
      var rms: Float = 0
      vDSP_rmsqv(channels[channelIndex], 1, &rms, vectorLength)
      peakRMS = max(peakRMS, rms)
    }
    return RealtimeCapturedAudioFrameStats(
      rms: peakRMS,
      sampleCount: sampleCount,
      sampleRate: sampleRate
    )
  }
}

struct PCM16EncodedAudioFrame: Sendable {
  let data: Data
  let stats: RealtimeEncodedAudioFrameStats?
}

final class PCM16AudioEncoder {
  private var inputSampleRate: Double?
  private var inputFormat: AVAudioFormat?
  private var targetFormat: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var reusableInputBuffer: AVAudioPCMBuffer?
  private var reusableOutputBuffer: AVAudioPCMBuffer?
  private(set) var allocatedAudioBufferCount = 0

  init(targetSampleRate: Double?) {
    if let targetSampleRate {
      targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: targetSampleRate,
        channels: 1
      )
    }
  }

  func encode(_ frame: RealtimeAudioCapturedFrame) -> Data? {
    encode(frame, includeStats: false)?.data
  }

  func encode(
    _ frame: RealtimeAudioCapturedFrame,
    includeStats: Bool
  ) -> PCM16EncodedAudioFrame? {
    guard !frame.samples.isEmpty,
          frame.sampleRate > 0 else {
      return nil
    }

    guard let targetFormat, targetFormat.sampleRate != frame.sampleRate else {
      return frame.samples.withUnsafeBufferPointer { samples in
        makePCM16Data(from: samples, includeStats: includeStats)
      }
    }

    if inputSampleRate != frame.sampleRate || inputFormat == nil {
      inputSampleRate = frame.sampleRate
      inputFormat = AVAudioFormat(
        standardFormatWithSampleRate: frame.sampleRate,
        channels: 1
      )
      if let inputFormat {
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
      } else {
        converter = nil
      }
      reusableInputBuffer = nil
      reusableOutputBuffer = nil
    }

    guard let inputFormat else { return nil }
    let inputFrameCount = AVAudioFrameCount(frame.samples.count)
    if reusableInputBuffer?.frameCapacity ?? 0 < inputFrameCount {
      reusableInputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: inputFrameCount
      )
      allocatedAudioBufferCount += 1
    }
    guard let inputBuffer = reusableInputBuffer,
          let inputChannel = inputBuffer.floatChannelData?.pointee else {
      return nil
    }

    inputBuffer.frameLength = inputFrameCount
    frame.samples.withUnsafeBufferPointer { source in
      guard let sourceAddress = source.baseAddress else { return }
      inputChannel.update(from: sourceAddress, count: frame.samples.count)
    }

    guard let converter else { return nil }

    let ratio = targetFormat.sampleRate / frame.sampleRate
    let outputCapacity = AVAudioFrameCount(
      max(1, (Double(inputBuffer.frameLength) * ratio).rounded(.up) + 32)
    )
    if reusableOutputBuffer?.frameCapacity ?? 0 < outputCapacity {
      reusableOutputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputCapacity
      )
      allocatedAudioBufferCount += 1
    }
    guard let outputBuffer = reusableOutputBuffer else {
      return nil
    }
    outputBuffer.frameLength = 0

    var didProvideInput = false
    var error: NSError?
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if didProvideInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }
    guard error == nil, status != .error else { return nil }
    guard let channel = outputBuffer.floatChannelData?.pointee else { return nil }
    return makePCM16Data(
      from: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)),
      includeStats: includeStats
    )
  }

  private func makePCM16Data(
    from samples: UnsafeBufferPointer<Float>,
    includeStats: Bool
  ) -> PCM16EncodedAudioFrame? {
    let frameCount = samples.count
    guard frameCount > 0 else { return nil }

    var data = Data(count: frameCount * MemoryLayout<Int16>.size)
    var wroteSamples = false
    var sumOfSquares = 0.0
    data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
      guard let destination = bytes.bindMemory(to: Int16.self).baseAddress else { return }
      wroteSamples = true
      for index in 0..<frameCount {
        let sample = max(-1.0, min(1.0, samples[index]))
        let encoded = Int16(sample * 32_767.0)
        destination[index] = encoded
        if includeStats {
          let value = Double(encoded)
          sumOfSquares += value * value
        }
      }
    }
    guard wroteSamples else { return nil }
    let stats = includeStats
      ? RealtimeEncodedAudioFrameStats(
          rms: Float(sqrt(sumOfSquares / Double(frameCount)) / 32_768),
          sampleCount: frameCount
        )
      : nil
    return PCM16EncodedAudioFrame(data: data, stats: stats)
  }
}

enum RealtimePCM16AudioMeter {
  static func stats(for data: Data) -> RealtimeEncodedAudioFrameStats {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else {
      return RealtimeEncodedAudioFrameStats(rms: 0, sampleCount: 0)
    }

    var sum = 0.0
    data.withUnsafeBytes { raw in
      for sample in raw.bindMemory(to: Int16.self) {
        let value = Double(sample)
        sum += value * value
      }
    }
    return RealtimeEncodedAudioFrameStats(
      rms: Float(sqrt(sum / Double(sampleCount)) / 32_768),
      sampleCount: sampleCount
    )
  }
}

private enum RealtimeAudioPerformanceSignposts {
  static let upload = OSSignposter(
    subsystem: AppIdentity.loggingSubsystem,
    category: "RealtimeAudioUpload"
  )
}

private final class RealtimeCapturedAudioHandlerBox: @unchecked Sendable {
  typealias Handler = RealtimeAudioUploadPipeline.CapturedAudioHandler

  private var lock = os_unfair_lock_s()
  private var handler: Handler?

  func store(_ handler: Handler?) {
    os_unfair_lock_lock(&lock)
    self.handler = handler
    os_unfair_lock_unlock(&lock)
  }

  func load() -> Handler? {
    os_unfair_lock_lock(&lock)
    let handler = handler
    os_unfair_lock_unlock(&lock)
    return handler
  }
}

/// Serializes format conversion and WebSocket delivery. One network send may
/// be in flight at a time; timeout or send failure discards remaining audio and
/// lets the owning service converge through its existing error path.
final class RealtimeAudioUploadPipeline: @unchecked Sendable {
  typealias MessageBuilder = (Data) -> URLSessionWebSocketTask.Message?
  typealias MessageSender = (
    URLSessionWebSocketTask.Message,
    @escaping (Error?) -> Void
  ) -> Void
  typealias FirstAudioHandler = @MainActor () -> Void
  typealias FailureHandler = @MainActor (String) -> Void
  typealias CapturedAudioHandler = @Sendable (RealtimeCapturedAudioFrameStats) -> Void
  typealias EncodedAudioHandler = @MainActor (RealtimeEncodedAudioFrameStats) -> Void

  private let queue: DispatchQueue
  private let drainSource: DispatchSourceUserDataAdd
  private let mailbox: RealtimeAudioCaptureMailbox
  private let encoder: PCM16AudioEncoder
  private let sendTimeout: TimeInterval
  private let maximumQueuedFrameAge: TimeInterval?
  private let capturedAudioHandlerBox = RealtimeCapturedAudioHandlerBox()
  private let logger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "RealtimeAudioUpload"
  )

  private var activeGeneration: Int?
  private var messageBuilder: MessageBuilder?
  private var messageSender: MessageSender?
  private var onFirstAudioSent: FirstAudioHandler?
  private var onFailure: FailureHandler?
  private var onEncodedAudio: EncodedAudioHandler?
  private var didSendFirstAudio = false
  private var nextSendToken: UInt64 = 0
  private var inFlightSendToken: UInt64?
  private var timeoutWorkItem: DispatchWorkItem?
  private var lastMetricsReportAt = ProcessInfo.processInfo.systemUptime

  init(
    label: String,
    targetSampleRate: Double?,
    slotCount: Int = 6,
    maximumFramesPerBuffer: Int = 4_096,
    sendTimeout: TimeInterval = 2,
    maximumQueuedFrameAge: TimeInterval? = nil
  ) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
    mailbox = RealtimeAudioCaptureMailbox(
      slotCount: slotCount,
      maximumFramesPerBuffer: maximumFramesPerBuffer
    )
    encoder = PCM16AudioEncoder(targetSampleRate: targetSampleRate)
    self.sendTimeout = sendTimeout
    if let maximumQueuedFrameAge,
       maximumQueuedFrameAge.isFinite,
       maximumQueuedFrameAge >= 0 {
      self.maximumQueuedFrameAge = maximumQueuedFrameAge
    } else {
      self.maximumQueuedFrameAge = nil
    }

    let drainSource = DispatchSource.makeUserDataAddSource(queue: queue)
    self.drainSource = drainSource
    drainSource.setEventHandler { [weak self] in
      self?.drainOneBuffer()
      self?.reportMetricsIfNeeded()
    }
    drainSource.resume()
  }

  deinit {
    stop()
    drainSource.setEventHandler {}
    drainSource.cancel()
  }

  func start(
    generation: Int,
    inputFormat: AVAudioFormat,
    webSocket: URLSessionWebSocketTask,
    messageBuilder: @escaping MessageBuilder,
    onCapturedAudio: CapturedAudioHandler? = nil,
    onEncodedAudio: EncodedAudioHandler? = nil,
    onFirstAudioSent: @escaping FirstAudioHandler,
    onFailure: @escaping FailureHandler
  ) {
    start(
      generation: generation,
      inputFormat: inputFormat,
      messageBuilder: messageBuilder,
      messageSender: { message, completion in
        webSocket.send(message, completionHandler: completion)
      },
      onCapturedAudio: onCapturedAudio,
      onEncodedAudio: onEncodedAudio,
      onFirstAudioSent: onFirstAudioSent,
      onFailure: onFailure
    )
  }

  func start(
    generation: Int,
    inputFormat: AVAudioFormat,
    messageBuilder: @escaping MessageBuilder,
    messageSender: @escaping MessageSender,
    onCapturedAudio: CapturedAudioHandler? = nil,
    onEncodedAudio: EncodedAudioHandler? = nil,
    onFirstAudioSent: @escaping FirstAudioHandler,
    onFailure: @escaping FailureHandler
  ) {
    capturedAudioHandlerBox.store(onCapturedAudio)
    _ = mailbox.activate(generation: generation, inputFormat: inputFormat)
    queue.sync {
      cancelInFlightSend()
      activeGeneration = generation
      self.messageBuilder = messageBuilder
      self.messageSender = messageSender
      self.onFirstAudioSent = onFirstAudioSent
      self.onFailure = onFailure
      self.onEncodedAudio = onEncodedAudio
      didSendFirstAudio = false
      lastMetricsReportAt = ProcessInfo.processInfo.systemUptime
    }
  }

  func stop() {
    _ = mailbox.deactivateAndClear()
    capturedAudioHandlerBox.store(nil)
    queue.sync {
      activeGeneration = nil
      messageBuilder = nil
      messageSender = nil
      onFirstAudioSent = nil
      onFailure = nil
      onEncodedAudio = nil
      didSendFirstAudio = false
      cancelInFlightSend()
    }
  }

  func capture(
    _ buffer: AVAudioPCMBuffer,
    generation: Int,
    capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    switch mailbox.capture(buffer, generation: generation, capturedAt: capturedAt) {
    case .accepted, .replacedOldestQueuedBuffer:
      if let handler = capturedAudioHandlerBox.load(),
         let stats = RealtimeFloatAudioMeter.stats(for: buffer) {
        handler(stats)
      }
      drainSource.add(data: 1)
    case .staleGeneration, .inactive, .tapLockContention,
         .unsupportedFormat, .oversizedBuffer, .queueFull:
      break
    }
  }

  func snapshot() -> RealtimeAudioCapturePerformanceSnapshot {
    mailbox.snapshot()
  }

  private func cancelInFlightSend() {
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    inFlightSendToken = nil
  }

  private func drainOneBuffer() {
    guard inFlightSendToken == nil,
          let generation = activeGeneration,
          let messageBuilder,
          let messageSender,
          let frame = mailbox.takeNext(expectedGeneration: generation) else {
      return
    }

    if let maximumQueuedFrameAge {
      let frameAge = ProcessInfo.processInfo.systemUptime - frame.capturedAt
      if !frameAge.isFinite || frameAge > maximumQueuedFrameAge {
        mailbox.recordStaleFrameAgeDrop()
        drainSource.add(data: 1)
        return
      }
    }

    let encodingStartedAt = ProcessInfo.processInfo.systemUptime
    let encodingSignpost = RealtimeAudioPerformanceSignposts.upload.beginInterval("PCM16Encode")
    guard let encodedFrame = encoder.encode(
      frame,
      includeStats: onEncodedAudio != nil
    ) else {
      RealtimeAudioPerformanceSignposts.upload.endInterval("PCM16Encode", encodingSignpost)
      mailbox.recordEncodingFailure()
      drainSource.add(data: 1)
      return
    }
    let pcm16Data = encodedFrame.data
    RealtimeAudioPerformanceSignposts.upload.endInterval("PCM16Encode", encodingSignpost)
    mailbox.recordEncoded(duration: ProcessInfo.processInfo.systemUptime - encodingStartedAt)

    if let onEncodedAudio, let stats = encodedFrame.stats {
      Task { @MainActor in
        onEncodedAudio(stats)
      }
    }

    guard let message = messageBuilder(pcm16Data) else {
      mailbox.recordMessageBuildFailure()
      drainSource.add(data: 1)
      return
    }

    nextSendToken &+= 1
    let sendToken = nextSendToken
    inFlightSendToken = sendToken

    let timeout = DispatchWorkItem { [weak self] in
      self?.handleSendTimeout(token: sendToken, generation: generation)
    }
    timeoutWorkItem = timeout
    queue.asyncAfter(deadline: .now() + sendTimeout, execute: timeout)

    let pipeline = self
    messageSender(message) { [weak pipeline] error in
      guard let pipeline else { return }
      pipeline.queue.async {
        pipeline.handleSendCompletion(
          token: sendToken,
          generation: generation,
          capturedAt: frame.capturedAt,
          error: error
        )
      }
    }
  }

  private func handleSendCompletion(
    token: UInt64,
    generation: Int,
    capturedAt: TimeInterval,
    error: Error?
  ) {
    guard inFlightSendToken == token else { return }
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    inFlightSendToken = nil

    guard activeGeneration == generation else { return }
    if let error {
      mailbox.recordSendFailure()
      fail(generation: generation, message: "Audio send failed: \(error.localizedDescription)")
      return
    }

    mailbox.recordSendSuccess(
      capturedAt: capturedAt,
      sentAt: ProcessInfo.processInfo.systemUptime
    )
    if !didSendFirstAudio {
      didSendFirstAudio = true
      let callback = onFirstAudioSent
      Task { @MainActor in
        callback?()
      }
    }
    drainSource.add(data: 1)
  }

  private func handleSendTimeout(token: UInt64, generation: Int) {
    guard inFlightSendToken == token, activeGeneration == generation else { return }
    timeoutWorkItem = nil
    inFlightSendToken = nil
    mailbox.recordSendTimeout()
    fail(generation: generation, message: "Audio send timed out")
  }

  private func fail(generation: Int, message: String) {
    guard activeGeneration == generation else { return }
    _ = mailbox.deactivateAndClear()
    capturedAudioHandlerBox.store(nil)
    let failure = onFailure
    activeGeneration = nil
    messageBuilder = nil
    messageSender = nil
    onFirstAudioSent = nil
    onFailure = nil
    onEncodedAudio = nil
    didSendFirstAudio = false
    cancelInFlightSend()
    Task { @MainActor in
      failure?(message)
    }
  }

  private func reportMetricsIfNeeded() {
    #if DEBUG
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastMetricsReportAt >= 1 else { return }
    lastMetricsReportAt = now

    let metrics = mailbox.snapshot(at: now)
    guard !metrics.isEmpty else { return }
    logger.debug(
      "Audio metrics input=\(metrics.inputBuffers) encoded=\(metrics.encodedBuffers) sent=\(metrics.sentBuffers) queue=\(metrics.currentQueueDepth)/\(metrics.maximumQueueDepth) drops=\(metrics.droppedBuffers) staleAgeDrops=\(metrics.staleFrameAgeDrops) captureToSendMs=\(metrics.averageCaptureToSendMilliseconds) encodeMs=\(metrics.averageEncodingMilliseconds) rate=\(metrics.lastInputSampleRate) channels=\(metrics.lastInputChannelCount)"
    )
    #endif
  }
}
