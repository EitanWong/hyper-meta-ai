/*
 * DAT video presentation
 *
 * DAT owns a VideoFrame sample buffer only during its listener callback. The
 * foreground raw path therefore creates an owned Core Media copy for the
 * display renderer, while Provider snapshots use a separate one-slot mailbox.
 * HVC is decoded once with VideoToolbox, then its CVPixelBuffer output is shared
 * by the direct preview and the bounded Provider snapshot path.
 */

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit
import VideoToolbox

/// An independently-owned image used only by consumers that require a UIKit
/// image, such as a vision provider or the raw-codec fallback preview.
struct RenderedVideoFrame: @unchecked Sendable {
  let image: UIImage
}

/// Opt-in profile for evaluating a display-only phone preview enhancement.
/// It is disabled unless the app launches with `-PhonePreviewSharpeningEnabled YES`.
struct PhonePreviewSharpeningConfiguration: Equatable, Sendable {
  static let launchArgument = "-PhonePreviewSharpeningEnabled"

  static let disabled = Self(
    isEnabled: false,
    maximumFramesPerSecond: 15,
    maximumPixelDimension: 1_280,
    sharpness: 0.25
  )

  static let enabled = Self(
    isEnabled: true,
    maximumFramesPerSecond: 15,
    maximumPixelDimension: 1_280,
    sharpness: 0.25
  )

  let isEnabled: Bool
  let maximumFramesPerSecond: Double
  let maximumPixelDimension: Int
  let sharpness: Float

  static var current: Self {
    from(arguments: ProcessInfo.processInfo.arguments)
  }

  static func runtimeBudget(for requested: Self) -> Self {
    PhonePreviewSharpeningBudget.apply(
      requested: requested,
      isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalState: PhonePreviewSharpeningThermalState(ProcessInfo.processInfo.thermalState)
    )
  }

  static func from(arguments: [String]) -> Self {
    guard let argumentIndex = arguments.firstIndex(of: launchArgument) else {
      return .disabled
    }

    let valueIndex = arguments.index(after: argumentIndex)
    guard valueIndex < arguments.endIndex else {
      return .enabled
    }

    switch arguments[valueIndex].lowercased() {
    case "1", "true", "yes":
      return .enabled
    default:
      return .disabled
    }
  }
}

/// The display-only filter is optional work. Keep its budget independent from
/// DAT transport and provider snapshots so thermal pressure only affects the
/// phone preview.
enum PhonePreviewSharpeningThermalState: Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical

  init(_ thermalState: ProcessInfo.ThermalState) {
    switch thermalState {
    case .nominal:
      self = .nominal
    case .fair:
      self = .fair
    case .serious:
      self = .serious
    case .critical:
      self = .critical
    @unknown default:
      self = .serious
    }
  }
}

enum PhonePreviewSharpeningBudget {
  static func apply(
    requested: PhonePreviewSharpeningConfiguration,
    isLowPowerModeEnabled: Bool,
    thermalState: PhonePreviewSharpeningThermalState
  ) -> PhonePreviewSharpeningConfiguration {
    guard requested.isEnabled else { return requested }

    switch thermalState {
    case .critical:
      return .disabled
    case .serious:
      return reduced(from: requested)
    case .nominal, .fair:
      return isLowPowerModeEnabled ? reduced(from: requested) : requested
    }
  }

  private static func reduced(
    from requested: PhonePreviewSharpeningConfiguration
  ) -> PhonePreviewSharpeningConfiguration {
    PhonePreviewSharpeningConfiguration(
      isEnabled: true,
      maximumFramesPerSecond: min(requested.maximumFramesPerSecond, 10),
      maximumPixelDimension: min(requested.maximumPixelDimension, 960),
      sharpness: min(requested.sharpness, 0.18)
    )
  }
}

struct PhonePreviewSharpeningPerformanceSnapshot: Equatable, Sendable {
  static let disabled = Self(
    isEnabled: false,
    inputFrames: 0,
    renderedFrames: 0,
    throttleDrops: 0,
    renderFailures: 0,
    fallbackFrames: 0,
    averageRenderMilliseconds: 0,
    maximumRenderMilliseconds: 0
  )

  let isEnabled: Bool
  let inputFrames: Int
  let renderedFrames: Int
  let throttleDrops: Int
  let renderFailures: Int
  let fallbackFrames: Int
  let averageRenderMilliseconds: Double
  let maximumRenderMilliseconds: Double

  var isEmpty: Bool {
    inputFrames == 0
      && renderedFrames == 0
      && throttleDrops == 0
      && renderFailures == 0
      && fallbackFrames == 0
  }
}

enum PreviewPixelBufferPreparation {
  case ready(CVPixelBuffer)
  case throttled
}

/// Renders a new BGRA pixel buffer for the phone display only. The source
/// buffer is never modified, so callers can independently keep it for AI snapshots.
final class PhonePreviewSharpeningRenderer: @unchecked Sendable {
  private struct Metrics {
    var inputFrames = 0
    var renderedFrames = 0
    var throttleDrops = 0
    var renderFailures = 0
    var fallbackFrames = 0
    var renderTotalMilliseconds = 0.0
    var renderMaximumMilliseconds = 0.0
  }

  private let configuration: PhonePreviewSharpeningConfiguration
  private let runtimeBudget: @Sendable (PhonePreviewSharpeningConfiguration)
    -> PhonePreviewSharpeningConfiguration
  private let renderQueue = DispatchQueue(
    label: "com.lunflux.hyper-meta-ai.phone-preview-sharpening",
    qos: .userInteractive
  )
  private lazy var context = CIContext(options: [CIContextOption.cacheIntermediates: false])
  private var pixelBufferPool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var lastAcceptedAt: TimeInterval?
  private var metrics = Metrics()

  init(
    configuration: PhonePreviewSharpeningConfiguration,
    runtimeBudget: @escaping @Sendable (PhonePreviewSharpeningConfiguration)
      -> PhonePreviewSharpeningConfiguration = { configuration in configuration }
  ) {
    self.configuration = configuration
    self.runtimeBudget = runtimeBudget
  }

  func prepare(_ sourcePixelBuffer: CVPixelBuffer) -> PreviewPixelBufferPreparation {
    guard configuration.isEnabled else {
      return .ready(sourcePixelBuffer)
    }

    return renderQueue.sync {
      let runtimeConfiguration = self.runtimeBudget(self.configuration)
      guard runtimeConfiguration.isEnabled else {
        return .ready(sourcePixelBuffer)
      }

      self.metrics.inputFrames += 1
      let now = ProcessInfo.processInfo.systemUptime
      guard self.shouldAccept(
        at: now,
        maximumFramesPerSecond: runtimeConfiguration.maximumFramesPerSecond
      ) else {
        self.metrics.throttleDrops += 1
        return .throttled
      }

      let startedAt = now
      let signpost = RealtimePerformanceSignposts.videoPipeline.beginInterval(
        "PhonePreviewSharpen"
      )
      let sharpenedPixelBuffer = self.render(
        sourcePixelBuffer,
        configuration: runtimeConfiguration
      )
      RealtimePerformanceSignposts.videoPipeline.endInterval(
        "PhonePreviewSharpen",
        signpost
      )
      let durationMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

      guard let sharpenedPixelBuffer else {
        self.metrics.renderFailures += 1
        self.metrics.fallbackFrames += 1
        return .ready(sourcePixelBuffer)
      }

      self.metrics.renderedFrames += 1
      self.metrics.renderTotalMilliseconds += durationMilliseconds
      self.metrics.renderMaximumMilliseconds = max(
        self.metrics.renderMaximumMilliseconds,
        durationMilliseconds
      )
      return .ready(sharpenedPixelBuffer)
    }
  }

  func reset() {
    guard configuration.isEnabled else { return }
    renderQueue.sync {
      lastAcceptedAt = nil
    }
  }

  func drainPerformanceSnapshot() -> PhonePreviewSharpeningPerformanceSnapshot {
    guard configuration.isEnabled else { return .disabled }

    return renderQueue.sync {
      let averageRenderMilliseconds = self.metrics.renderedFrames > 0
        ? self.metrics.renderTotalMilliseconds / Double(self.metrics.renderedFrames)
        : 0
      let snapshot = PhonePreviewSharpeningPerformanceSnapshot(
        isEnabled: true,
        inputFrames: self.metrics.inputFrames,
        renderedFrames: self.metrics.renderedFrames,
        throttleDrops: self.metrics.throttleDrops,
        renderFailures: self.metrics.renderFailures,
        fallbackFrames: self.metrics.fallbackFrames,
        averageRenderMilliseconds: averageRenderMilliseconds,
        maximumRenderMilliseconds: self.metrics.renderMaximumMilliseconds
      )
      self.metrics = Metrics()
      return snapshot
    }
  }

  private func shouldAccept(
    at timestamp: TimeInterval,
    maximumFramesPerSecond: Double
  ) -> Bool {
    guard maximumFramesPerSecond > 0 else { return false }
    guard let lastAcceptedAt else {
      self.lastAcceptedAt = timestamp
      return true
    }
    guard timestamp >= lastAcceptedAt + (1 / maximumFramesPerSecond) else {
      return false
    }
    self.lastAcceptedAt = timestamp
    return true
  }

  private func render(
    _ sourcePixelBuffer: CVPixelBuffer,
    configuration: PhonePreviewSharpeningConfiguration
  ) -> CVPixelBuffer? {
    let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
    let sourceExtent = sourceImage.extent.integral
    guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

    let scale = min(
      1,
      CGFloat(configuration.maximumPixelDimension) / max(sourceExtent.width, sourceExtent.height)
    )
    let outputWidth = max(1, Int((sourceExtent.width * scale).rounded(.down)))
    let outputHeight = max(1, Int((sourceExtent.height * scale).rounded(.down)))
    let outputBounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)

    let normalizedImage = sourceImage.transformed(
      by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY)
    )
    let scaledImage = scale < 1
      ? normalizedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      : normalizedImage
    let sharpenedImage = scaledImage
      .cropped(to: outputBounds)
      .applyingFilter(
        "CISharpenLuminance",
        parameters: [kCIInputSharpnessKey: configuration.sharpness]
      )

    guard let destinationPixelBuffer = makeDestinationPixelBuffer(
      width: outputWidth,
      height: outputHeight
    ) else {
      return nil
    }

    context.render(
      sharpenedImage,
      to: destinationPixelBuffer,
      bounds: outputBounds,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return destinationPixelBuffer
  }

  private func makeDestinationPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferMetalCompatibilityKey: true
      ]
      var pool: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nil,
        attributes as CFDictionary,
        &pool
      ) == kCVReturnSuccess, let pool else {
        return nil
      }
      pixelBufferPool = pool
      poolWidth = width
      poolHeight = height
    }

    var pixelBuffer: CVPixelBuffer?
    guard let pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
          ) == kCVReturnSuccess else {
      return nil
    }
    return pixelBuffer
  }
}

enum DirectPreviewEnqueueResult: Sendable {
  /// A frame was accepted by the preview pipeline.
  case enqueued
  case noSurface
  case staleGeneration
  case backpressured
  case rendererFailed
  case ownershipCopyFailed
  /// A decoder reset can only resume at an IDR/sync sample.
  case awaitingSyncFrame
  case decoderSubmissionFailed
}

struct DirectPreviewPerformanceSnapshot: Sendable {
  let enqueuedFrames: Int
  let displaySubmissions: Int
  let displayMailboxReplacements: Int
  let displayBackpressureDrops: Int
  let noSurfaceFrames: Int
  let staleGenerationDrops: Int
  let backpressureDrops: Int
  let rendererFailures: Int
  let ownershipCopyFailures: Int
  let decoderSubmittedFrames: Int
  let decodedFrames: Int
  let awaitingSyncFrames: Int
  let decoderSubmissionFailures: Int
  let decoderOutputFailures: Int
  let decoderFormatResets: Int
  let lastDecoderError: Int32?
  let providerSnapshotFrames: Int
  let providerSnapshotFailures: Int
  let previewSharpening: PhonePreviewSharpeningPerformanceSnapshot

  var isEmpty: Bool {
    enqueuedFrames == 0
      && displaySubmissions == 0
      && displayMailboxReplacements == 0
      && displayBackpressureDrops == 0
      && noSurfaceFrames == 0
      && staleGenerationDrops == 0
      && backpressureDrops == 0
      && rendererFailures == 0
      && ownershipCopyFailures == 0
      && decoderSubmittedFrames == 0
      && decodedFrames == 0
      && awaitingSyncFrames == 0
      && decoderSubmissionFailures == 0
      && decoderOutputFailures == 0
      && decoderFormatResets == 0
      && providerSnapshotFrames == 0
      && providerSnapshotFailures == 0
      && previewSharpening.isEmpty
  }
}

fileprivate struct RawPreviewPresentationMetrics: Sendable {
  static let empty = RawPreviewPresentationMetrics(
    displaySubmissions: 0,
    mailboxReplacements: 0,
    backpressureDrops: 0
  )

  let displaySubmissions: Int
  let mailboxReplacements: Int
  let backpressureDrops: Int
}

/// A short-lived SwiftUI surface for DAT frames. Raw frames enter a one-slot
/// mailbox and are paced to the display renderer, preventing queue latency
/// from growing when the glasses deliver faster than the surface consumes.
final class DirectSampleBufferPreviewRenderer: @unchecked Sendable {
  private struct PixelBufferFormatSignature: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
  }

  private let lock = NSLock()
  private weak var receiver: AVSampleBufferVideoRenderer?
  private var cachedFormatSignature: PixelBufferFormatSignature?
  private var cachedFormatDescription: CMVideoFormatDescription?
  private let rawDisplayMailbox = LatestFrameMailbox<DecodedPixelBufferFrame>()
  private let rawDisplayQueue = DispatchQueue(
    label: "com.lunflux.hyper-meta-ai.raw-preview-display",
    qos: .userInteractive
  )
  private var rawDisplayTimer: DispatchSourceTimer?
  private var rawDisplayGeneration = 0
  private var rawDisplayIsActive = false
  private var rawDisplaySubmissions = 0
  private var rawDisplayMailboxReplacements = 0
  private var rawDisplayBackpressureDrops = 0
  private let phonePreviewSharpeningRenderer: PhonePreviewSharpeningRenderer?

  init() {
    let configuration = PhonePreviewSharpeningConfiguration.current
    phonePreviewSharpeningRenderer = configuration.isEnabled
      ? PhonePreviewSharpeningRenderer(
        configuration: configuration,
        runtimeBudget: { PhonePreviewSharpeningConfiguration.runtimeBudget(for: $0) }
      )
      : nil
  }

  @MainActor
  func attach(to displayLayer: AVSampleBufferDisplayLayer) {
    displayLayer.videoGravity = .resizeAspectFill
    displayLayer.backgroundColor = UIColor.black.cgColor

    let timerToStart: DispatchSourceTimer?
    lock.lock()
    let newReceiver = displayLayer.sampleBufferRenderer
    if receiver !== newReceiver || !rawDisplayIsActive {
      receiver = newReceiver
      cachedFormatSignature = nil
      cachedFormatDescription = nil
      rawDisplayGeneration &+= 1
      if rawDisplayMailbox.activate(generation: rawDisplayGeneration) {
        rawDisplayMailboxReplacements += 1
      }
      rawDisplayIsActive = true
    }
    if rawDisplayTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: rawDisplayQueue)
      timer.schedule(
        deadline: .now(),
        repeating: .milliseconds(67),
        leeway: .milliseconds(4)
      )
      timer.setEventHandler { [weak self] in
        self?.drainLatestRawFrame()
      }
      rawDisplayTimer = timer
      timerToStart = timer
    } else {
      timerToStart = nil
    }
    lock.unlock()
    timerToStart?.resume()
  }

  /// Called from the VideoToolbox completion handler. The renderer owns the
  /// generated sample buffer and therefore retains its CVPixelBuffer until the
  /// frame is displayed or dropped.
  func enqueueDecodedPixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    presentationTimeStamp: CMTime
  ) -> DirectPreviewEnqueueResult {
    let receiver: AVSampleBufferVideoRenderer?
    lock.lock()
    receiver = self.receiver
    lock.unlock()

    guard let receiver else { return .noSurface }

    // A display renderer can require a flush after a decoder-resource change.
    // Our input is already decoded, so any subsequent pixel buffer can resume
    // presentation immediately after the flush.
    if receiver.requiresFlushToResumeDecoding || receiver.status == .failed {
      receiver.flush()
    }
    guard receiver.status != .failed else { return .rendererFailed }
    guard receiver.isReadyForMoreMediaData else { return .backpressured }

    let displayPixelBuffer: CVPixelBuffer
    switch prepareDisplayPixelBuffer(pixelBuffer) {
    case .ready(let preparedPixelBuffer):
      displayPixelBuffer = preparedPixelBuffer
    case .throttled:
      return .enqueued
    }

    let formatDescription: CMVideoFormatDescription?
    lock.lock()
    formatDescription = displayFormatDescriptionLocked(for: displayPixelBuffer)
    lock.unlock()
    guard let formatDescription else { return .rendererFailed }
    guard let displaySampleBuffer = Self.makeDisplaySampleBuffer(
      pixelBuffer: displayPixelBuffer,
      formatDescription: formatDescription,
      presentationTimeStamp: presentationTimeStamp
    ) else {
      return .rendererFailed
    }

    let queuedReceiver: any AVQueuedSampleBufferRendering = receiver
    queuedReceiver.enqueue(displaySampleBuffer)
    return .enqueued
  }

  /// Captures the latest raw frame before the DAT listener returns. The timer
  /// later submits at most one current frame per display interval, so slow
  /// presentation drops stale work instead of accumulating it.
  func enqueueRawSampleBuffer(_ sourceSampleBuffer: CMSampleBuffer) -> DirectPreviewEnqueueResult {
    guard CMSampleBufferDataIsReady(sourceSampleBuffer),
          CMSampleBufferGetImageBuffer(sourceSampleBuffer) != nil else {
      return .rendererFailed
    }

    let displayGeneration: Int
    lock.lock()
    guard receiver != nil else {
      lock.unlock()
      return .noSurface
    }
    displayGeneration = rawDisplayGeneration
    lock.unlock()

    var ownedSampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateCopy(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sourceSampleBuffer,
      sampleBufferOut: &ownedSampleBuffer
    ) == noErr,
      let ownedSampleBuffer,
      let pixelBuffer = CMSampleBufferGetImageBuffer(ownedSampleBuffer) else {
      return .ownershipCopyFailed
    }

    switch rawDisplayMailbox.offer(
      LatestFrameMailboxItem(
        value: DecodedPixelBufferFrame(
          pixelBuffer: pixelBuffer,
          presentationTimeStamp: .zero,
          generation: displayGeneration,
          backingSampleBuffer: ownedSampleBuffer
        ),
        generation: displayGeneration,
        receivedAt: ProcessInfo.processInfo.systemUptime
      )
    ) {
    case .accepted(let replacedExistingFrame):
      if replacedExistingFrame {
        lock.lock()
        rawDisplayMailboxReplacements += 1
        lock.unlock()
      }
      return .enqueued
    case .staleGeneration:
      return .staleGeneration
    }
  }

  func reset() {
    let receiver: AVSampleBufferVideoRenderer?
    let timer: DispatchSourceTimer?
    lock.lock()
    receiver = self.receiver
    cachedFormatSignature = nil
    cachedFormatDescription = nil
    rawDisplayGeneration &+= 1
    rawDisplayIsActive = false
    if rawDisplayMailbox.deactivateAndClear() {
      rawDisplayMailboxReplacements += 1
    }
    timer = rawDisplayTimer
    rawDisplayTimer = nil
    lock.unlock()
    timer?.cancel()
    phonePreviewSharpeningRenderer?.reset()
    receiver?.flush()
  }

  fileprivate func drainRawPreviewPresentationMetrics() -> RawPreviewPresentationMetrics {
    lock.lock()
    let metrics = RawPreviewPresentationMetrics(
      displaySubmissions: rawDisplaySubmissions,
      mailboxReplacements: rawDisplayMailboxReplacements,
      backpressureDrops: rawDisplayBackpressureDrops
    )
    rawDisplaySubmissions = 0
    rawDisplayMailboxReplacements = 0
    rawDisplayBackpressureDrops = 0
    lock.unlock()
    return metrics
  }

  fileprivate func drainPreviewSharpeningPerformanceSnapshot()
    -> PhonePreviewSharpeningPerformanceSnapshot {
    phonePreviewSharpeningRenderer?.drainPerformanceSnapshot() ?? .disabled
  }

  private func drainLatestRawFrame() {
    guard let item = rawDisplayMailbox.takeLatest() else { return }

    let receiver: AVSampleBufferVideoRenderer?
    lock.lock()
    guard rawDisplayIsActive, item.value.generation == rawDisplayGeneration else {
      lock.unlock()
      return
    }
    receiver = self.receiver
    lock.unlock()

    guard let receiver else { return }
    if receiver.requiresFlushToResumeDecoding || receiver.status == .failed {
      receiver.flush()
    }
    guard receiver.status != .failed else { return }
    guard receiver.isReadyForMoreMediaData else {
      lock.lock()
      rawDisplayBackpressureDrops += 1
      lock.unlock()
      return
    }

    let displayPixelBuffer: CVPixelBuffer
    switch prepareDisplayPixelBuffer(item.value.pixelBuffer) {
    case .ready(let preparedPixelBuffer):
      displayPixelBuffer = preparedPixelBuffer
    case .throttled:
      return
    }

    let formatDescription: CMVideoFormatDescription?
    lock.lock()
    formatDescription = displayFormatDescriptionLocked(for: displayPixelBuffer)
    lock.unlock()
    guard let formatDescription else { return }
    guard let displaySampleBuffer = Self.makeDisplaySampleBuffer(
      pixelBuffer: displayPixelBuffer,
      formatDescription: formatDescription,
      presentationTimeStamp: .zero
    ) else {
      return
    }

    let queuedReceiver: any AVQueuedSampleBufferRendering = receiver
    queuedReceiver.enqueue(displaySampleBuffer)
    lock.lock()
    rawDisplaySubmissions += 1
    lock.unlock()
  }

  private func prepareDisplayPixelBuffer(
    _ sourcePixelBuffer: CVPixelBuffer
  ) -> PreviewPixelBufferPreparation {
    phonePreviewSharpeningRenderer?.prepare(sourcePixelBuffer) ?? .ready(sourcePixelBuffer)
  }

  private func displayFormatDescriptionLocked(
    for pixelBuffer: CVPixelBuffer
  ) -> CMVideoFormatDescription? {
    let signature = PixelBufferFormatSignature(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer),
      pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
    )
    if signature == cachedFormatSignature, let cachedFormatDescription {
      return cachedFormatDescription
    }

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    ) == noErr, let formatDescription else {
      return nil
    }

    cachedFormatSignature = signature
    cachedFormatDescription = formatDescription
    return formatDescription
  }

  private static func makeDisplaySampleBuffer(
    pixelBuffer: CVPixelBuffer,
    formatDescription: CMVideoFormatDescription,
    presentationTimeStamp: CMTime
  ) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: presentationTimeStamp.isValid ? presentationTimeStamp : .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else {
      return nil
    }

    markForImmediateDisplay(sampleBuffer)
    return sampleBuffer
  }
}

/// A retained decoder output. CoreVideo retains the pixel buffer while the
/// bounded preview and provider mailboxes consume it.
private final class DecodedPixelBufferFrame: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  let presentationTimeStamp: CMTime
  let generation: Int
  // Raw provider snapshots retain this Core Media copy until CI has consumed
  // its pixel buffer after the DAT listener has returned.
  let backingSampleBuffer: CMSampleBuffer?

  init(
    pixelBuffer: CVPixelBuffer,
    presentationTimeStamp: CMTime,
    generation: Int,
    backingSampleBuffer: CMSampleBuffer? = nil
  ) {
    self.pixelBuffer = pixelBuffer
    self.presentationTimeStamp = presentationTimeStamp
    self.generation = generation
    self.backingSampleBuffer = backingSampleBuffer
  }
}

private enum HVCDecoderSubmissionResult {
  case submitted
  case staleGeneration
  case awaitingSyncFrame
  case ownershipCopyFailed
  case failed(OSStatus)
}

enum HVCDecoderFailurePolicy {
  /// Corrupt or missing compressed pictures do not invalidate VideoToolbox's
  /// decoder state. Continuing to submit the stream lets the existing hardware
  /// decoder resume at the next intact random-access picture.
  static func shouldResetSession(after status: OSStatus) -> Bool {
    switch status {
    case kVTVideoDecoderBadDataErr, kVTVideoDecoderReferenceMissingErr:
      return false
    default:
      return true
    }
  }
}

/// Serializes decoder lifecycle and HVC submission. It never retains a DAT
/// sample buffer; only the deep copy crosses the DAT listener boundary.
private final class HVCVideoDecoder: @unchecked Sendable {
  private let stateQueue = DispatchQueue(
    label: "com.lunflux.hyper-meta-ai.hvc-video-decoder",
    qos: .userInitiated
  )
  private var activeGeneration: Int?
  private var decoderSession: VTDecompressionSession?
  /// Invalidates callbacks from a decoder that has already been replaced.
  /// A stream generation is too coarse because one stream can recreate its
  /// decoder several times while recovering from a missing reference frame.
  private var decoderEpoch: UInt64 = 0
  private var requiresSyncSample = true
  private let onDecodedFrame: @Sendable (DecodedPixelBufferFrame) -> Void
  private let onDecodeFailure: @Sendable (Int, OSStatus) -> Void
  private let onFormatReset: @Sendable (Int) -> Void

  init(
    onDecodedFrame: @escaping @Sendable (DecodedPixelBufferFrame) -> Void,
    onDecodeFailure: @escaping @Sendable (Int, OSStatus) -> Void,
    onFormatReset: @escaping @Sendable (Int) -> Void
  ) {
    self.onDecodedFrame = onDecodedFrame
    self.onDecodeFailure = onDecodeFailure
    self.onFormatReset = onFormatReset
  }

  func activate(generation: Int) {
    stateQueue.sync {
      invalidateSessionLocked()
      activeGeneration = generation
      requiresSyncSample = true
    }
  }

  func deactivate() {
    stateQueue.sync {
      activeGeneration = nil
      invalidateSessionLocked()
    }
  }

  func submit(
    sourceSampleBuffer: CMSampleBuffer,
    generation: Int
  ) -> HVCDecoderSubmissionResult {
    stateQueue.sync {
      guard activeGeneration == generation else { return .staleGeneration }
      guard let sampleBuffer = CompressedSampleBufferCopy.copy(sourceSampleBuffer) else {
        return .ownershipCopyFailed
      }
      guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video else {
        return .failed(kVTParameterErr)
      }

      if let decoderSession,
         !VTDecompressionSessionCanAcceptFormatDescription(
           decoderSession,
           formatDescription: formatDescription
         ) {
        invalidateSessionLocked()
        requiresSyncSample = true
        onFormatReset(generation)
      }
      if requiresSyncSample {
        guard HVCBitstreamInspector.isRandomAccessSample(sampleBuffer) else {
          return .awaitingSyncFrame
        }
        let createStatus = createSessionLocked(formatDescription: formatDescription)
        guard createStatus == noErr else {
          return .failed(createStatus)
        }
        requiresSyncSample = false
      }

      guard let decoderSession else { return .failed(kVTInvalidSessionErr) }
      let submissionEpoch = decoderEpoch
      var decodeInfoFlags: VTDecodeInfoFlags = []
      let decodeStatus = VTDecompressionSessionDecodeFrame(
        decoderSession,
        sampleBuffer: sampleBuffer,
        flags: VTDecodeFrameFlags(rawValue: 1),
        infoFlagsOut: &decodeInfoFlags,
        completionHandler: {
          [weak self] status, infoFlags, imageBuffer, _, presentationTimeStamp, _ in
          self?.handleDecodeCompletion(
            status: status,
            infoFlags: infoFlags,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            generation: generation,
            decoderEpoch: submissionEpoch
          )
        }
      )
      guard decodeStatus == noErr else {
        if HVCDecoderFailurePolicy.shouldResetSession(after: decodeStatus) {
          invalidateSessionLocked()
          requiresSyncSample = true
        }
        return .failed(decodeStatus)
      }
      return .submitted
    }
  }

  private func createSessionLocked(formatDescription: CMVideoFormatDescription) -> OSStatus {
    var newSession: VTDecompressionSession?
    let decoderSpecification = [
      kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
    ] as CFDictionary
    let createStatus = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: decoderSpecification,
      imageBufferAttributes: nil,
      decompressionSessionOut: &newSession
    )
    guard createStatus == noErr, let newSession else {
      return createStatus
    }

    _ = VTSessionSetProperty(
      newSession,
      key: kVTDecompressionPropertyKey_RealTime,
      value: kCFBooleanTrue
    )
    decoderEpoch &+= 1
    decoderSession = newSession
    return noErr
  }

  private func handleDecodeCompletion(
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    generation: Int,
    decoderEpoch: UInt64
  ) {
    // VideoToolbox callbacks are not guaranteed to arrive in display order.
    // Validate both stream generation and decoder epoch on our serial state
    // queue so a late failure from an invalidated decoder cannot tear down the
    // decoder that has already recovered at a later IDR.
    stateQueue.async { [weak self] in
      guard let self,
            self.activeGeneration == generation,
            self.decoderEpoch == decoderEpoch else {
        return
      }

      guard status == noErr else {
        self.onDecodeFailure(generation, status)
        if HVCDecoderFailurePolicy.shouldResetSession(after: status) {
          self.invalidateSessionLocked()
          self.requiresSyncSample = true
        }
        return
      }

      // A real-time decoder may intentionally drop output while preserving its
      // reference state. Resetting here would unnecessarily freeze until the
      // next IDR, so only a genuine decode error starts recovery.
      guard let pixelBuffer = imageBuffer else {
        if !infoFlags.contains(.frameDropped) {
          self.onDecodeFailure(generation, kVTVideoDecoderBadDataErr)
        }
        return
      }

      self.onDecodedFrame(
        DecodedPixelBufferFrame(
          pixelBuffer: pixelBuffer,
          presentationTimeStamp: presentationTimeStamp,
          generation: generation
        )
      )
    }
  }

  private func invalidateSessionLocked() {
    if let decoderSession {
      VTDecompressionSessionInvalidate(decoderSession)
    }
    decoderSession = nil
    decoderEpoch &+= 1
  }
}

/// Identifies a true HEVC random-access picture from the compressed payload.
/// DAT buffers have not consistently carried enough sample attachments to use
/// `NotSync` as the only recovery signal, so the NAL unit type is authoritative.
enum HVCBitstreamInspector {
  static func isRandomAccessSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
    if let payloadResult = randomAccessResult(from: sampleBuffer) {
      return payloadResult
    }
    return attachmentSyncResult(from: sampleBuffer) ?? false
  }

  /// Testable parser for ISO/IEC 14496-15 length-prefixed HEVC samples.
  static func containsRandomAccessNALUnit(
    _ bytes: [UInt8],
    nalUnitLengthFieldSize: Int
  ) -> Bool? {
    bytes.withUnsafeBytes { rawBuffer in
      containsRandomAccessNALUnit(
        rawBuffer,
        nalUnitLengthFieldSize: nalUnitLengthFieldSize
      )
    }
  }

  private static func randomAccessResult(from sampleBuffer: CMSampleBuffer) -> Bool? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC,
          let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      return nil
    }

    var nalUnitLengthFieldSize: Int32 = 0
    guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
      formatDescription,
      parameterSetIndex: 0,
      parameterSetPointerOut: nil,
      parameterSetSizeOut: nil,
      parameterSetCountOut: nil,
      nalUnitHeaderLengthOut: &nalUnitLengthFieldSize
    ) == noErr else {
      return nil
    }

    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
      dataBuffer,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer
    ) == noErr,
      lengthAtOffset == totalLength,
      totalLength > 0,
      let dataPointer else {
      return nil
    }

    return containsRandomAccessNALUnit(
      UnsafeRawBufferPointer(start: dataPointer, count: totalLength),
      nalUnitLengthFieldSize: Int(nalUnitLengthFieldSize)
    )
  }

  private static func containsRandomAccessNALUnit(
    _ bytes: UnsafeRawBufferPointer,
    nalUnitLengthFieldSize: Int
  ) -> Bool? {
    guard (1...4).contains(nalUnitLengthFieldSize), !bytes.isEmpty else {
      return nil
    }

    var offset = 0
    var foundNALUnit = false
    while offset < bytes.count {
      guard offset + nalUnitLengthFieldSize <= bytes.count else { return nil }

      var nalUnitLength = 0
      for byteOffset in 0..<nalUnitLengthFieldSize {
        nalUnitLength = (nalUnitLength << 8) | Int(bytes[offset + byteOffset])
      }
      offset += nalUnitLengthFieldSize

      guard nalUnitLength >= 2, offset + nalUnitLength <= bytes.count else {
        return nil
      }
      foundNALUnit = true

      let nalUnitType = (bytes[offset] >> 1) & 0x3F
      // BLA, IDR and CRA pictures are the HEVC random-access VCL types.
      if (16...21).contains(nalUnitType) {
        return true
      }
      offset += nalUnitLength
    }

    return foundNALUnit ? false : nil
  }

  private static func attachmentSyncResult(from sampleBuffer: CMSampleBuffer) -> Bool? {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false
    ), let attachment = CFArrayGetValueAtIndex(attachments, 0) else {
      return nil
    }

    let dictionary = unsafeBitCast(attachment, to: CFDictionary.self)
    if isTrue(
      CFDictionaryGetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
      )
    ) || isTrue(
      CFDictionaryGetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque()
      )
    ) {
      return false
    }
    return true
  }

  private static func isTrue(_ value: UnsafeRawPointer?) -> Bool {
    guard let value else { return false }
    return value == Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
  }
}

private enum CompressedSampleBufferCopy {
  static func copy(_ source: CMSampleBuffer) -> CMSampleBuffer? {
    let sampleCount = CMSampleBufferGetNumSamples(source)
    guard sampleCount > 0,
          let sourceDataBuffer = CMSampleBufferGetDataBuffer(source),
          let formatDescription = CMSampleBufferGetFormatDescription(source) else {
      return nil
    }

    let dataLength = CMBlockBufferGetDataLength(sourceDataBuffer)
    guard dataLength > 0 else { return nil }

    var copiedDataBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateContiguous(
      allocator: kCFAllocatorDefault,
      sourceBuffer: sourceDataBuffer,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: dataLength,
      flags: kCMBlockBufferAlwaysCopyDataFlag,
      blockBufferOut: &copiedDataBuffer
    ) == noErr, let copiedDataBuffer else {
      return nil
    }

    let count = Int(sampleCount)
    var timingInfos = Array(repeating: CMSampleTimingInfo(), count: count)
    guard CMSampleBufferGetSampleTimingInfoArray(
      source,
      entryCount: count,
      arrayToFill: &timingInfos,
      entriesNeededOut: nil
    ) == noErr else {
      return nil
    }

    var sampleSizes = Array(repeating: 0, count: count)
    guard CMSampleBufferGetSampleSizeArray(
      source,
      entryCount: count,
      arrayToFill: &sampleSizes,
      entriesNeededOut: nil
    ) == noErr, sampleSizes.allSatisfy({ $0 > 0 }) else {
      return nil
    }

    var copiedSampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: copiedDataBuffer,
      formatDescription: formatDescription,
      sampleCount: sampleCount,
      sampleTimingEntryCount: count,
      sampleTimingArray: &timingInfos,
      sampleSizeEntryCount: count,
      sampleSizeArray: &sampleSizes,
      sampleBufferOut: &copiedSampleBuffer
    ) == noErr, let copiedSampleBuffer else {
      return nil
    }

    CMPropagateAttachments(source, destination: copiedSampleBuffer)
    copySampleAttachments(from: source, to: copiedSampleBuffer)
    return copiedSampleBuffer
  }

  private static func copySampleAttachments(
    from source: CMSampleBuffer,
    to destination: CMSampleBuffer
  ) {
    guard let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(
      source,
      createIfNecessary: false
    ), let destinationAttachments = CMSampleBufferGetSampleAttachmentsArray(
      destination,
      createIfNecessary: true
    ) else {
      return
    }

    let attachmentCount = min(
      CFArrayGetCount(sourceAttachments),
      CFArrayGetCount(destinationAttachments)
    )
    for index in 0..<attachmentCount {
      guard let sourceValue = CFArrayGetValueAtIndex(sourceAttachments, index),
            let destinationValue = CFArrayGetValueAtIndex(destinationAttachments, index) else {
        continue
      }
      let sourceDictionary = unsafeBitCast(sourceValue, to: CFDictionary.self)
      let destinationDictionary = unsafeBitCast(destinationValue, to: CFMutableDictionary.self)
      CFDictionaryApplyFunction(
        sourceDictionary,
        { key, value, context in
          guard let context else { return }
          let destination = Unmanaged<CFMutableDictionary>
            .fromOpaque(context)
            .takeUnretainedValue()
          CFDictionarySetValue(destination, key, value)
        },
        Unmanaged.passUnretained(destinationDictionary).toOpaque()
      )
    }
  }
}

private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
  guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
    sampleBuffer,
    createIfNecessary: true
  ), let attachment = CFArrayGetValueAtIndex(attachments, 0) else {
    return
  }

  let dictionary = unsafeBitCast(attachment, to: CFMutableDictionary.self)
  CFDictionarySetValue(
    dictionary,
    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
  )
}

/// Holds the visible renderer weakly and owns isolated HVC decoding plus a
/// one-slot Provider snapshot mailbox. A stopped stream cannot emit into a new
/// session.
final class DirectSampleBufferPreviewHub: @unchecked Sendable {
  typealias ProviderSnapshotConsumer = @Sendable (
    RenderedVideoFrame,
    Int,
    TimeInterval,
    TimeInterval
  ) -> Void

  private struct Metrics {
    var enqueuedFrames = 0
    var noSurfaceFrames = 0
    var staleGenerationDrops = 0
    var backpressureDrops = 0
    var rendererFailures = 0
    var ownershipCopyFailures = 0
    var decoderSubmittedFrames = 0
    var decodedFrames = 0
    var awaitingSyncFrames = 0
    var decoderSubmissionFailures = 0
    var decoderOutputFailures = 0
    var decoderFormatResets = 0
    var lastDecoderError: Int32?
    var providerSnapshotFrames = 0
    var providerSnapshotFailures = 0
  }

  private let lock = NSLock()
  private weak var renderer: DirectSampleBufferPreviewRenderer?
  private var activeGeneration: Int?
  private var providerSnapshotConsumer: ProviderSnapshotConsumer?
  private var metrics = Metrics()
  private let snapshotThrottle = FrameIngressThrottle(maximumFramesPerSecond: 2)
  private let snapshotMailbox = LatestFrameMailbox<DecodedPixelBufferFrame>()
  private let snapshotRenderQueue = DispatchQueue(
    label: "com.lunflux.hyper-meta-ai.hvc-provider-snapshot",
    qos: .userInitiated
  )
  private let snapshotRenderer = PixelBufferSnapshotRenderer(maximumPixelDimension: 1_024)
  private var snapshotWorkerScheduled = false
  private lazy var decoder = HVCVideoDecoder(
    onDecodedFrame: { [weak self] frame in
      self?.receiveDecodedFrame(frame)
    },
    onDecodeFailure: { [weak self] generation, status in
      self?.recordDecoderOutputFailure(generation: generation, status: status)
    },
    onFormatReset: { [weak self] generation in
      self?.recordDecoderFormatReset(generation: generation)
    }
  )

  func attach(_ renderer: DirectSampleBufferPreviewRenderer) {
    lock.lock()
    self.renderer = renderer
    lock.unlock()
  }

  func detach(_ renderer: DirectSampleBufferPreviewRenderer) {
    let shouldReset: Bool
    lock.lock()
    shouldReset = self.renderer === renderer
    if shouldReset {
      self.renderer = nil
    }
    lock.unlock()

    if shouldReset {
      renderer.reset()
    }
  }

  func activate(
    generation: Int,
    providerSnapshotConsumer: @escaping ProviderSnapshotConsumer
  ) {
    activateProviderSnapshotMailbox(
      generation: generation,
      providerSnapshotConsumer: providerSnapshotConsumer
    )
    decoder.activate(generation: generation)
  }

  /// The foreground raw path does not involve VideoToolbox decompression. A
  /// one-slot display mailbox and a separate snapshot mailbox keep its preview
  /// and visual Provider consumers independent.
  func activateRaw(
    generation: Int,
    providerSnapshotConsumer: @escaping ProviderSnapshotConsumer
  ) {
    activateProviderSnapshotMailbox(
      generation: generation,
      providerSnapshotConsumer: providerSnapshotConsumer
    )
    decoder.deactivate()
  }

  private func activateProviderSnapshotMailbox(
    generation: Int,
    providerSnapshotConsumer: @escaping ProviderSnapshotConsumer
  ) {
    lock.lock()
    activeGeneration = generation
    self.providerSnapshotConsumer = providerSnapshotConsumer
    let didReplaceSnapshot = snapshotMailbox.activate(generation: generation)
    if didReplaceSnapshot {
      metrics.staleGenerationDrops += 1
    }
    lock.unlock()
    snapshotThrottle.reset()
  }

  func deactivate() {
    let renderer: DirectSampleBufferPreviewRenderer?
    lock.lock()
    activeGeneration = nil
    providerSnapshotConsumer = nil
    renderer = self.renderer
    let didClearSnapshot = snapshotMailbox.deactivateAndClear()
    if didClearSnapshot {
      metrics.staleGenerationDrops += 1
    }
    lock.unlock()
    snapshotThrottle.reset()
    decoder.deactivate()
    renderer?.reset()
  }

  func enqueueCompressedSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    generation: Int
  ) -> DirectPreviewEnqueueResult {
    let isActive: Bool
    lock.lock()
    isActive = activeGeneration == generation
    lock.unlock()
    guard isActive else {
      record(.staleGeneration)
      return .staleGeneration
    }

    switch decoder.submit(sourceSampleBuffer: sampleBuffer, generation: generation) {
    case .submitted:
      recordDecoderSubmission()
      return .enqueued
    case .staleGeneration:
      record(.staleGeneration)
      return .staleGeneration
    case .awaitingSyncFrame:
      recordAwaitingSyncFrame()
      return .awaitingSyncFrame
    case .ownershipCopyFailed:
      record(.ownershipCopyFailed)
      return .ownershipCopyFailed
    case .failed(let status):
      recordDecoderSubmissionFailure(status: status)
      return .decoderSubmissionFailed
    }
  }

  func enqueueRawSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    generation: Int
  ) -> DirectPreviewEnqueueResult {
    let renderer: DirectSampleBufferPreviewRenderer?
    lock.lock()
    guard activeGeneration == generation else {
      metrics.staleGenerationDrops += 1
      lock.unlock()
      return .staleGeneration
    }
    renderer = self.renderer
    lock.unlock()

    let result = renderer?.enqueueRawSampleBuffer(sampleBuffer) ?? .noSurface
    record(result)

    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
       snapshotThrottle.shouldAccept(at: ProcessInfo.processInfo.systemUptime),
       let snapshotFrame = makeOwnedRawSnapshotFrame(
         pixelBuffer: pixelBuffer,
         sourceSampleBuffer: sampleBuffer,
         generation: generation
       ) {
      let shouldScheduleSnapshot: Bool
      lock.lock()
      guard activeGeneration == generation else {
        metrics.staleGenerationDrops += 1
        lock.unlock()
        return result
      }
      switch snapshotMailbox.offer(
        LatestFrameMailboxItem(
          value: snapshotFrame,
          generation: generation,
          receivedAt: ProcessInfo.processInfo.systemUptime
        )
      ) {
      case .accepted:
        break
      case .staleGeneration:
        metrics.staleGenerationDrops += 1
      }
      shouldScheduleSnapshot = scheduleProviderSnapshotWorkerLocked()
      lock.unlock()

      if shouldScheduleSnapshot {
        snapshotRenderQueue.async { [weak self] in
          self?.renderNextProviderSnapshot()
        }
      }
    }

    return result
  }

  func drainPerformanceSnapshot() -> DirectPreviewPerformanceSnapshot {
    let metricsSnapshot: Metrics
    let renderer: DirectSampleBufferPreviewRenderer?
    lock.lock()
    metricsSnapshot = self.metrics
    self.metrics = Metrics()
    renderer = self.renderer
    lock.unlock()
    let presentationMetrics = renderer?.drainRawPreviewPresentationMetrics()
      ?? .empty
    let previewSharpening = renderer?.drainPreviewSharpeningPerformanceSnapshot()
      ?? .disabled

    return DirectPreviewPerformanceSnapshot(
      enqueuedFrames: metricsSnapshot.enqueuedFrames,
      displaySubmissions: presentationMetrics.displaySubmissions,
      displayMailboxReplacements: presentationMetrics.mailboxReplacements,
      displayBackpressureDrops: presentationMetrics.backpressureDrops,
      noSurfaceFrames: metricsSnapshot.noSurfaceFrames,
      staleGenerationDrops: metricsSnapshot.staleGenerationDrops,
      backpressureDrops: metricsSnapshot.backpressureDrops,
      rendererFailures: metricsSnapshot.rendererFailures,
      ownershipCopyFailures: metricsSnapshot.ownershipCopyFailures,
      decoderSubmittedFrames: metricsSnapshot.decoderSubmittedFrames,
      decodedFrames: metricsSnapshot.decodedFrames,
      awaitingSyncFrames: metricsSnapshot.awaitingSyncFrames,
      decoderSubmissionFailures: metricsSnapshot.decoderSubmissionFailures,
      decoderOutputFailures: metricsSnapshot.decoderOutputFailures,
      decoderFormatResets: metricsSnapshot.decoderFormatResets,
      lastDecoderError: metricsSnapshot.lastDecoderError,
      providerSnapshotFrames: metricsSnapshot.providerSnapshotFrames,
      providerSnapshotFailures: metricsSnapshot.providerSnapshotFailures,
      previewSharpening: previewSharpening
    )
  }

  private func receiveDecodedFrame(_ frame: DecodedPixelBufferFrame) {
    let renderer: DirectSampleBufferPreviewRenderer?
    let shouldScheduleSnapshot: Bool
    lock.lock()
    guard activeGeneration == frame.generation else {
      metrics.staleGenerationDrops += 1
      lock.unlock()
      return
    }
    metrics.decodedFrames += 1
    renderer = self.renderer
    if snapshotThrottle.shouldAccept(at: ProcessInfo.processInfo.systemUptime) {
      switch snapshotMailbox.offer(
        LatestFrameMailboxItem(
          value: frame,
          generation: frame.generation,
          receivedAt: ProcessInfo.processInfo.systemUptime
        )
      ) {
      case .accepted:
        break
      case .staleGeneration:
        metrics.staleGenerationDrops += 1
      }
      shouldScheduleSnapshot = scheduleProviderSnapshotWorkerLocked()
    } else {
      shouldScheduleSnapshot = false
    }
    lock.unlock()

    if let renderer {
      record(
        renderer.enqueueDecodedPixelBuffer(
          frame.pixelBuffer,
          presentationTimeStamp: frame.presentationTimeStamp
        )
      )
    } else {
      record(.noSurface)
    }

    if shouldScheduleSnapshot {
      snapshotRenderQueue.async { [weak self] in
        self?.renderNextProviderSnapshot()
      }
    }
  }

  private func renderNextProviderSnapshot() {
    guard let item = snapshotMailbox.takeLatest() else {
      finishProviderSnapshotWorker()
      return
    }

    guard isActive(generation: item.generation) else {
      record(.staleGeneration)
      finishProviderSnapshotWorker()
      return
    }

    let startedAt = ProcessInfo.processInfo.systemUptime
    let signpost = RealtimePerformanceSignposts.videoPipeline.beginInterval(
      "DATProviderImageSnapshot"
    )
    let renderedFrame = snapshotRenderer.render(pixelBuffer: item.value.pixelBuffer)
    RealtimePerformanceSignposts.videoPipeline.endInterval(
      "DATProviderImageSnapshot",
      signpost
    )
    let conversionDuration = ProcessInfo.processInfo.systemUptime - startedAt
    let consumer = currentProviderSnapshotConsumer(generation: item.generation)

    if let renderedFrame, let consumer {
      recordProviderSnapshotSuccess()
      consumer(
        renderedFrame,
        item.generation,
        ProcessInfo.processInfo.systemUptime,
        conversionDuration
      )
    } else {
      recordProviderSnapshotFailure()
    }
    finishProviderSnapshotWorker()
  }

  private func finishProviderSnapshotWorker() {
    let shouldScheduleNext: Bool
    lock.lock()
    snapshotWorkerScheduled = false
    shouldScheduleNext = activeGeneration != nil
      && snapshotMailbox.depth > 0
      && scheduleProviderSnapshotWorkerLocked()
    lock.unlock()

    if shouldScheduleNext {
      snapshotRenderQueue.async { [weak self] in
        self?.renderNextProviderSnapshot()
      }
    }
  }

  private func scheduleProviderSnapshotWorkerLocked() -> Bool {
    guard !snapshotWorkerScheduled else { return false }
    snapshotWorkerScheduled = true
    return true
  }

  private func makeOwnedRawSnapshotFrame(
    pixelBuffer: CVPixelBuffer,
    sourceSampleBuffer: CMSampleBuffer,
    generation: Int
  ) -> DecodedPixelBufferFrame? {
    var ownedSampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateCopy(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sourceSampleBuffer,
      sampleBufferOut: &ownedSampleBuffer
    ) == noErr, let ownedSampleBuffer else {
      recordProviderSnapshotFailure()
      return nil
    }

    return DecodedPixelBufferFrame(
      pixelBuffer: pixelBuffer,
      presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sourceSampleBuffer),
      generation: generation,
      backingSampleBuffer: ownedSampleBuffer
    )
  }

  private func currentProviderSnapshotConsumer(
    generation: Int
  ) -> ProviderSnapshotConsumer? {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == generation else { return nil }
    return providerSnapshotConsumer
  }

  private func isActive(generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeGeneration == generation
  }

  private func recordDecoderSubmission() {
    lock.lock()
    metrics.decoderSubmittedFrames += 1
    lock.unlock()
  }

  private func recordAwaitingSyncFrame() {
    lock.lock()
    metrics.awaitingSyncFrames += 1
    lock.unlock()
  }

  private func recordDecoderSubmissionFailure(status: OSStatus) {
    lock.lock()
    metrics.decoderSubmissionFailures += 1
    metrics.lastDecoderError = status
    lock.unlock()
  }

  private func recordDecoderOutputFailure(generation: Int, status: OSStatus) {
    lock.lock()
    guard activeGeneration == generation else {
      metrics.staleGenerationDrops += 1
      lock.unlock()
      return
    }
    metrics.decoderOutputFailures += 1
    metrics.lastDecoderError = status
    lock.unlock()
  }

  private func recordDecoderFormatReset(generation: Int) {
    lock.lock()
    guard activeGeneration == generation else {
      metrics.staleGenerationDrops += 1
      lock.unlock()
      return
    }
    metrics.decoderFormatResets += 1
    lock.unlock()
  }

  private func recordProviderSnapshotSuccess() {
    lock.lock()
    metrics.providerSnapshotFrames += 1
    lock.unlock()
  }

  private func recordProviderSnapshotFailure() {
    lock.lock()
    metrics.providerSnapshotFailures += 1
    lock.unlock()
  }

  private func record(_ result: DirectPreviewEnqueueResult) {
    lock.lock()
    defer { lock.unlock() }

    switch result {
    case .enqueued:
      metrics.enqueuedFrames += 1
    case .noSurface:
      metrics.noSurfaceFrames += 1
    case .staleGeneration:
      metrics.staleGenerationDrops += 1
    case .backpressured:
      metrics.backpressureDrops += 1
    case .rendererFailed:
      metrics.rendererFailures += 1
    case .ownershipCopyFailed:
      metrics.ownershipCopyFailures += 1
    case .awaitingSyncFrame:
      metrics.awaitingSyncFrames += 1
    case .decoderSubmissionFailed:
      metrics.decoderSubmissionFailures += 1
    }
  }
}

/// SwiftUI bridge for the direct HVC display path. The UIView's backing layer
/// is the AVSampleBufferDisplayLayer, so preview never enters a SwiftUI Image
/// or UIImage update loop.
struct DirectSampleBufferPreview: UIViewRepresentable {
  let streamViewModel: StreamSessionViewModel

  func makeCoordinator() -> Coordinator {
    Coordinator(streamViewModel: streamViewModel)
  }

  func makeUIView(context: Context) -> SampleBufferPreviewView {
    let view = SampleBufferPreviewView(frame: .zero)
    streamViewModel.attachDirectPreviewRenderer(view.previewRenderer)
    return view
  }

  func updateUIView(_ uiView: SampleBufferPreviewView, context: Context) {
    streamViewModel.attachDirectPreviewRenderer(uiView.previewRenderer)
  }

  static func dismantleUIView(_ uiView: SampleBufferPreviewView, coordinator: Coordinator) {
    coordinator.streamViewModel?.detachDirectPreviewRenderer(uiView.previewRenderer)
  }

  final class Coordinator {
    weak var streamViewModel: StreamSessionViewModel?

    init(streamViewModel: StreamSessionViewModel) {
      self.streamViewModel = streamViewModel
    }
  }
}

final class SampleBufferPreviewView: UIView {
  let previewRenderer = DirectSampleBufferPreviewRenderer()

  override class var layerClass: AnyClass {
    AVSampleBufferDisplayLayer.self
  }

  private var displayLayer: AVSampleBufferDisplayLayer {
    layer as! AVSampleBufferDisplayLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = .black
    previewRenderer.attach(to: displayLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }
}

/// Converts decoded pixel buffers only for provider snapshots. It runs on the
/// hub's serial snapshot queue and never participates in preview rendering.
private final class PixelBufferSnapshotRenderer: @unchecked Sendable {
  private let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
  private let maximumPixelDimension: CGFloat

  init(maximumPixelDimension: CGFloat) {
    self.maximumPixelDimension = max(1, maximumPixelDimension)
  }

  func render(pixelBuffer: CVPixelBuffer) -> RenderedVideoFrame? {
    render(CIImage(cvPixelBuffer: pixelBuffer))
  }

  private func render(_ sourceImage: CIImage) -> RenderedVideoFrame? {
    let extent = sourceImage.extent
    guard extent.width > 0, extent.height > 0 else { return nil }

    let longestSide = max(extent.width, extent.height)
    let scale = min(1, maximumPixelDimension / longestSide)
    let outputImage = scale < 1
      ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      : sourceImage
    let outputExtent = outputImage.extent.integral

    guard let cgImage = context.createCGImage(outputImage, from: outputExtent) else {
      return nil
    }
    return RenderedVideoFrame(image: UIImage(cgImage: cgImage))
  }
}

/// Keeps the raw-codec path synchronous with the DAT listener callback. It is
/// not used by HVC preview, which uses the persistent decoder above.
final class VideoFrameRenderer: @unchecked Sendable {
  private let imageRenderQueue: DispatchQueue
  private lazy var context = CIContext(options: [CIContextOption.cacheIntermediates: false])
  private let maximumPixelDimension: CGFloat

  init(
    imageRenderQueue: DispatchQueue,
    maximumPixelDimension: CGFloat = 1_024
  ) {
    self.imageRenderQueue = imageRenderQueue
    self.maximumPixelDimension = max(1, maximumPixelDimension)
  }

  /// Must run before the DAT frame listener returns.
  func renderRawSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> RenderedVideoFrame? {
    dispatchPrecondition(condition: .onQueue(imageRenderQueue))
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return nil
    }
    return render(CIImage(cvPixelBuffer: pixelBuffer))
  }

  private func render(_ sourceImage: CIImage) -> RenderedVideoFrame? {
    let extent = sourceImage.extent
    guard extent.width > 0, extent.height > 0 else { return nil }

    let longestSide = max(extent.width, extent.height)
    let scale = min(1, maximumPixelDimension / longestSide)
    let outputImage = scale < 1
      ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      : sourceImage
    let outputExtent = outputImage.extent.integral

    guard let cgImage = context.createCGImage(outputImage, from: outputExtent) else {
      return nil
    }
    return RenderedVideoFrame(image: UIImage(cgImage: cgImage))
  }
}
