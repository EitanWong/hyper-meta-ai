/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import MWDATCamera
import MWDATCore
import CoreMedia
import SwiftUI
import os.log

private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "StreamSession")

/// Hands raw DAT frames to the RTMP encoder while the SDK-owned sample buffer
/// is valid. Registrations are identity-scoped so a disappearing view cannot
/// detach a newer RTMP screen's consumer.
final class RTMPSampleBufferRelay: @unchecked Sendable {
  typealias Consumer = @Sendable (CMSampleBuffer) -> Void

  private let lock = NSLock()
  private var registration: (id: UUID, consumer: Consumer)?

  @discardableResult
  func attach(_ consumer: @escaping Consumer) -> UUID {
    let id = UUID()
    lock.lock()
    registration = (id, consumer)
    lock.unlock()
    return id
  }

  func detach(_ id: UUID) {
    lock.lock()
    if registration?.id == id {
      registration = nil
    }
    lock.unlock()
  }

  func forward(_ sampleBuffer: CMSampleBuffer) {
    lock.lock()
    let consumer = registration?.consumer
    lock.unlock()
    consumer?(sampleBuffer)
  }
}

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// A feature must hold a lease while it needs frames from the glasses. This
/// prevents one feature from stopping a shared device session owned by another.
enum StreamSessionOwner: Hashable {
  case manual
  case cameraPreview
  case liveAI
  case quickVision
  case quickVisionRequest(UUID)
  case liveTranslate
  case rtmp
  case simpleLiveStream
  case agentChat
  /// Agent 交互页持有的轻量会话（只收镜腿触发事件，不采集视频）
  case agentTrigger
  case openClawRemote
}

enum StreamSessionState: Equatable {
  case idle
  case starting
  case streaming
  case paused
  case stopping
  case failed(String)
}

/// 首选眼镜设备偏好（UserDefaults 持久化；多副眼镜时指定使用哪一副）
enum DevicePreferenceStore {
    static let key = "device.preferred.id"

    static var preferredDeviceID: String? {
        get {
            UserDefaults.standard.string(forKey: key)
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

private struct StreamStartupWaiter {
  let attempt: Int
  let continuation: CheckedContinuation<Bool, Never>
}

/// Canonical camera state exposed to every feature screen. UI must use this
/// value instead of inferring camera availability from a frame or a
/// feature-specific connection flag.
enum CameraCaptureState: Equatable {
  case unavailable
  case idle
  case starting
  case streaming
  case paused
  case stopping
  case failed(String)

  var isStreaming: Bool {
    self == .streaming
  }

  var isUnavailable: Bool {
    self == .unavailable
  }

  var isFailed: Bool {
    if case .failed = self {
      return true
    }
    return false
  }

  var isBusy: Bool {
    switch self {
    case .starting, .stopping:
      return true
    case .unavailable, .idle, .streaming, .paused, .failed:
      return false
    }
  }

  var symbolName: String {
    switch self {
    case .unavailable:
      return "eyeglasses"
    case .idle:
      return "video.slash"
    case .starting:
      return "video.badge.waveform"
    case .streaming:
      return "video.fill"
    case .paused:
      return "pause.circle"
    case .stopping:
      return "stop.circle"
    case .failed:
      return "exclamationmark.triangle"
    }
  }

  var localizedText: String {
    switch self {
    case .unavailable:
      return "camera.status.unavailable".localized
    case .idle:
      return "camera.status.idle".localized
    case .starting:
      return "camera.status.starting".localized
    case .streaming:
      return "camera.status.streaming".localized
    case .paused:
      return "camera.status.paused".localized
    case .stopping:
      return "camera.status.stopping".localized
    case .failed:
      return "camera.status.failed".localized
    }
  }
}

enum StreamSessionRecoveryPolicy {
  static func shouldRetry(_ error: StreamError) -> Bool {
    switch error {
    case .internalError, .deviceNotFound, .deviceNotConnected, .timeout, .videoStreamingError:
      return true
    case .permissionDenied, .hingesClosed, .thermalCritical, .thermalEmergency,
         .peakPowerShutdown, .batteryCritical:
      return false
    @unknown default:
      return false
    }
  }

  static func shouldRetry(_ error: DeviceSessionError) -> Bool {
    switch error {
    case .noEligibleDevice, .sessionAlreadyStopped, .unexpectedError:
      return true
    case .sessionAlreadyExists, .sessionIdle, .capabilityAlreadyActive, .capabilityNotFound,
         .thermalCritical, .thermalEmergency, .peakPowerShutdown, .batteryCritical,
         .datAppOnTheGlassesUpdateRequired, .dwaUnavailable:
      return false
    @unknown default:
      return false
    }
  }
}

struct DATGlassesAppUpdateRetryGate {
  private(set) var isUpdateRequired = false
  private(set) var isRetryArmed = false

  mutating func requireUpdate() {
    isUpdateRequired = true
    isRetryArmed = false
  }

  mutating func markUpdateDestinationOpened() {
    guard isUpdateRequired else { return }
    isRetryArmed = true
  }

  mutating func consumeRetry() -> Bool {
    guard isUpdateRequired, isRetryArmed else { return false }
    reset()
    return true
  }

  mutating func reset() {
    isUpdateRequired = false
    isRetryArmed = false
  }
}

enum DATGlassesAppUpdateGuidance {
  static var alertTitle: String {
    "stream.dat_update.title".localized
  }

  static var instructions: String {
    "stream.dat_update.message".localized
  }

  static var openUpdateActionTitle: String {
    "stream.dat_update.action".localized
  }

  static var openUpdateFailureMessage: String {
    "stream.dat_update.open_failed".localized
  }

  static func isRequired(for error: DeviceSessionError) -> Bool {
    switch error {
    case .datAppOnTheGlassesUpdateRequired:
      return true
    case .unexpectedError(let description):
      return isRequired(message: description)
    default:
      return false
    }
  }

  static func isRequired(message: String) -> Bool {
    let normalized = message
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized.contains("直播软件更新")
      || normalized.contains("最新版本后重试")
      || normalized.contains("dat app update")
      || normalized.contains("dat sdk update")
      || normalized.contains("glasses app update required")
  }
}

struct StreamSessionLeaseRegistry {
  private(set) var owners: Set<StreamSessionOwner> = []

  var isEmpty: Bool {
    owners.isEmpty
  }

  /// Live AI owns a direct foreground preview. This flag retains the raw direct
  /// path as a fallback when a future transport profile selects raw frames.
  var usesDirectRawPreview: Bool {
    owners.contains(.liveAI)
  }

  /// A realtime conversation uses the glasses camera, microphone, and speaker
  /// concurrently. Keep the profile independent of the selected AI provider.
  var requiresFullDuplexTransportProfile: Bool {
    owners.contains(.liveAI)
  }

  mutating func acquire(_ owner: StreamSessionOwner) -> Bool {
    owners.insert(owner).inserted
  }

  mutating func release(_ owner: StreamSessionOwner) -> Bool {
    owners.remove(owner) != nil
  }

  mutating func removeAll() {
    owners.removeAll()
  }
}

struct CameraStreamTransportProfile: Equatable {
  let videoCodec: VideoCodec
  let resolution: StreamingResolution
  let frameRate: UInt

  static func make(savedQuality: String, requiresFullDuplexTransport: Bool) -> Self {
    if requiresFullDuplexTransport {
      // DAT 0.8's raw decoder can remain frozen after a missing reference
      // frame. HVC keeps the glasses-to-phone payload compressed and lets the
      // app recover VideoToolbox at the next IDR without restarting DAT.
      return Self(videoCodec: .hvc1, resolution: .low, frameRate: 24)
    }

    let resolution: StreamingResolution
    switch savedQuality {
    case "low":
      resolution = .low
    case "high":
      resolution = .high
    default:
      resolution = .medium
    }
    return Self(videoCodec: .raw, resolution: resolution, frameRate: 24)
  }
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published private(set) var sessionState: StreamSessionState = .idle
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published private(set) var requiresDATGlassesAppUpdate = false
  @Published var hasActiveDevice: Bool = false
  /// 当前可用的眼镜设备列表（多设备选择用）
  @Published private(set) var availableDevices: [String] = []
  /// 当前会话正在使用的设备 ID（无会话/未连接时为 nil）
  @Published private(set) var activeDeviceID: String?
  @Published private(set) var videoPerformanceMetrics: VideoFramePerformanceSnapshot = .empty
  @Published private(set) var usesDirectSampleBufferPreview = false

  /// Single source of truth for camera UI and feature coordination.
  /// Availability is evaluated first so a disconnected device can never leave
  /// a page displaying a stale frame or a stale streaming state.
  var cameraCaptureState: CameraCaptureState {
    guard hasActiveDevice, !requiresSessionResetAfterDisconnect else { return .unavailable }

    switch sessionState {
    case .idle:
      return .idle
    case .starting:
      return .starting
    case .streaming:
      return streamingStatus == .streaming ? .streaming : .starting
    case .paused:
      return .paused
    case .stopping:
      return .stopping
    case .failed(let message):
      return .failed(message)
    }
  }

  var isCameraInUse: Bool {
    cameraCaptureState.isStreaming
  }

  var isStreaming: Bool {
    cameraCaptureState.isStreaming
  }

  var isSessionBusy: Bool {
    switch sessionState {
    case .starting, .streaming, .paused, .stopping:
      return true
    case .idle, .failed:
      return false
    }
  }

  // Timer properties
  @Published var activeTimeLimit: StreamTimeLimit = .noLimit
  @Published var remainingTime: TimeInterval = 0

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var showVisionRecognition: Bool = false
  @Published var showOmniRealtime: Bool = false
  @Published var showLeanEat: Bool = false

  private var timerTask: Task<Void, Never>?
  // DAT 0.8 scopes camera capabilities to a DeviceSession. A stopped session
  // cannot be restarted, so each streaming run owns a fresh session and stream.
  private var deviceSession: DeviceSession?
  private var stream: MWDATCamera.Stream?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private var deviceSessionStateTask: Task<Void, Never>?
  private var deviceSessionErrorTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var deviceSelector: any DeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var deviceListTask: Task<Void, Never>?
  private var startTask: Task<Bool, Never>?
  private var streamStartupWaiter: StreamStartupWaiter?
  private var streamStartupTimeoutTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var stopOperationGeneration = 0
  private var startAttemptGeneration = 0
  private var recoveryTask: Task<Void, Never>?
  private var recoveryAttempts = 0
  private var terminalDeviceSessionError: DeviceSessionError?
  private var automaticRecoveryIsSuppressed = false
  private var datGlassesAppUpdateRetryGate = DATGlassesAppUpdateRetryGate()
  private var isStoppingUnderlyingSession = false
  /// 眼镜物理触发事件回调（Agent 页设置；同一时间仅一个页面活跃）
  var onDeviceTrigger: ((AgentDeviceTrigger) -> Void)?
  /// 设备断连后重新可用回调（Agent 页用于提示「单击恢复交互」）
  var onDeviceReconnected: (() -> Void)?
  /// 眼镜变为可用回调（系统级功能监听：连接问候等；进入页面首次可用即触发）
  var onDeviceAvailable: (() -> Void)? {
    didSet {
      // 可用事件可能早于监听赋值（启动竞态）：赋值时若设备已可用立即补发
      guard onDeviceAvailable != nil, hasActiveDevice else { return }
      onDeviceAvailable?()
    }
  }
  /// 是否在存在重连监听时经历过断连（避免进入页面时的首次连接误报）
  private var lostDeviceWhileReconnectListenerActive = false
  /// 设备会话意外结束的瞬态标志（由 onDeviceTrigger 消费方读取并清除）
  private(set) var lastDeviceSessionEndWasUnexpected = false
  private var deviceTriggerDetector = AgentDeviceTriggerDetector()
  private var isApplicationActive = true
  private var leases = StreamSessionLeaseRegistry()
  private var frameUpdateThrottle = FrameUpdateThrottle(maximumFramesPerSecond: 15)
  private let rawFrameIngressThrottle = FrameIngressThrottle(maximumFramesPerSecond: 15)
  private let videoFrameMetrics = VideoFramePerformanceMonitor()
  private let renderedVideoFrameMailbox = LatestFrameMailbox<RenderedVideoFrame>()
  private let rawVideoFrameConversionQueue = DispatchQueue(
    label: "com.lunflux.hyper-meta-ai.raw-video-frame-renderer",
    qos: .userInitiated
  )
  private lazy var rawVideoFrameRenderer = VideoFrameRenderer(
    imageRenderQueue: rawVideoFrameConversionQueue
  )
  private let directSampleBufferPreviewHub = DirectSampleBufferPreviewHub()
  private let rtmpSampleBufferRelay = RTMPSampleBufferRelay()
  private var frameMailboxDeliveryTask: Task<Void, Never>?
  private var performanceMetricsTask: Task<Void, Never>?
  #if DEBUG
  private var consecutiveNoInputFrameWindows = 0
  private var consecutiveNoPublishedFrameWindows = 0
  #endif
  private var streamGeneration = 0
  private var requiresSessionResetAfterDisconnect = false

  private let maximumRecoveryAttempts = 3
  private let streamStartTimeout: TimeInterval = 8
  private let streamStopTimeout: TimeInterval = 3

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    logger.info("🟢 StreamSessionViewModel init")
    self.deviceSelector = Self.makeSelector(wearables: wearables)
    self.availableDevices = wearables.devices

    startDeviceMonitoring()
    startVideoPerformanceReporting()
    logger.info("🟢 StreamSessionViewModel init complete")
  }

  /// 首选设备：按偏好创建 SpecificDeviceSelector，否则自动选择
  private static func makeSelector(wearables: WearablesInterface) -> any DeviceSelector {
    if let preferredID = DevicePreferenceStore.preferredDeviceID,
       wearables.devices.contains(preferredID) {
        return SpecificDeviceSelector(device: preferredID)
    }
    return AutoDeviceSelector(wearables: wearables)
  }

  /// 切换首选设备：持久化偏好；后续会话按新选择器创建
  func setPreferredDevice(_ deviceID: String?) {
    DevicePreferenceStore.preferredDeviceID = deviceID
    deviceSelector = Self.makeSelector(wearables: wearables)
    hasActiveDevice = deviceSelector.activeDevice != nil
  }

  /// 设备显示名（无名称时回退为 ID）
  func deviceDisplayName(_ deviceID: String) -> String {
    wearables.deviceForIdentifier(deviceID)?.nameOrId() ?? deviceID
  }

  /// The Live AI view owns the visible AVSampleBufferDisplayLayer. Keeping the
  /// surface weak prevents an off-screen page from retaining camera resources.
  func attachDirectPreviewRenderer(_ renderer: DirectSampleBufferPreviewRenderer) {
    directSampleBufferPreviewHub.attach(renderer)
  }

  func detachDirectPreviewRenderer(_ renderer: DirectSampleBufferPreviewRenderer) {
    directSampleBufferPreviewHub.detach(renderer)
  }

  @discardableResult
  func attachRTMPSampleBufferConsumer(
    _ consumer: @escaping RTMPSampleBufferRelay.Consumer
  ) -> UUID {
    rtmpSampleBufferRelay.attach(consumer)
  }

  func detachRTMPSampleBufferConsumer(_ registrationID: UUID) {
    rtmpSampleBufferRelay.detach(registrationID)
  }

  /// Acquires the shared glasses camera session for a feature. The call only
  /// returns after the stream is ready or a bounded startup attempt has failed.
  @discardableResult
  func acquireStream(for owner: StreamSessionOwner) async -> Bool {
    if requiresDATGlassesAppUpdate, datGlassesAppUpdateRetryGate.consumeRetry() {
      resetTerminalFailure()
    }

    guard terminalDeviceSessionError == nil else {
      let message = terminalDeviceSessionError.map(formatDeviceSessionError)
        ?? "The glasses session must be resolved before streaming can restart."
      sessionState = .failed(message)
      if message != errorMessage {
        showError(message)
      }
      return false
    }

    _ = leases.acquire(owner)

    guard isApplicationActive, !requiresSessionResetAfterDisconnect else {
      return false
    }

    if streamingStatus == .streaming {
      sessionState = .streaming
      return true
    }

    guard hasActiveDevice else {
      sessionState = .failed("Device not found. Please ensure your device is connected.")
      errorMessage = "Device not found. Please ensure your device is connected."
      return false
    }

    return await ensureStreamIsRunning()
  }

  /// Releases only the caller's lease. The hardware session stops after the
  /// last owner releases it.
  func releaseStream(for owner: StreamSessionOwner) async {
    guard leases.release(owner) else { return }

    guard leases.isEmpty else { return }

    recoveryTask?.cancel()
    recoveryTask = nil
    cancelStartAttempt()
    stopUnderlyingSession(preservingFailure: sessionState.isFailure)
    await waitForPendingStop()
  }

  /// Agent 交互页专用：启动一个不采集视频的轻量会话，让镜腿触发事件
  /// （单击/长按）在语音与聊天页面始终可用，不占用摄像头资源。
  /// 与其他功能共用底层 DeviceSession，并持有 lease 防止被提前停止。
  @discardableResult
  func acquireAgentTriggerSession() async -> Bool {
    _ = leases.acquire(.agentTrigger)

    guard !requiresDATGlassesAppUpdate || datGlassesAppUpdateRetryGate.consumeRetry() else {
      return false
    }
    guard terminalDeviceSessionError == nil,
          !requiresSessionResetAfterDisconnect,
          isApplicationActive else {
      return false
    }
    guard hasActiveDevice else {
      // 镜腿触发是可选增强：无眼镜时语音/聊天仍可独立工作，不污染全局会话状态
      return false
    }

    do {
      try createDeviceSessionIfNeeded()
      guard let deviceSession else { return false }
      if deviceSession.state != .started {
        try deviceSession.start()
      }
      guard await waitForDeviceSessionToBecomeReady(attempt: makeAgentTriggerAttempt()) else {
        return false
      }
      return true
    } catch {
      logger.error("❌ Failed to start agent trigger session: \(error.localizedDescription)")
      return false
    }
  }

  /// 释放 Agent 交互轻量会话；仅当没有其他功能占用时停止底层会话。
  func releaseAgentTriggerSession() async {
    await releaseStream(for: .agentTrigger)
  }

  /// 读取并清除"设备会话意外结束"标志（供触发回调消费）
  @discardableResult
  func consumeUnexpectedDeviceEndFlag() -> Bool {
    let value = lastDeviceSessionEndWasUnexpected
    lastDeviceSessionEndWasUnexpected = false
    return value
  }

  private func makeAgentTriggerAttempt() -> Int {
    startAttemptGeneration &+= 1
    return startAttemptGeneration
  }

  /// Compatibility entry point for legacy manual controls.
  func handleStartStreaming() async {
    guard prepareForManualStreamStart() else { return }

    let started = await acquireStream(for: .manual)
    if !started {
      await releaseStream(for: .manual)
    }
  }

  /// Compatibility entry point for older feature code. New callers acquire a
  /// named lease instead.
  func startSession() async {
    await handleStartStreaming()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    await releaseStream(for: .manual)
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func openDATGlassesAppUpdate() {
    guard requiresDATGlassesAppUpdate else { return }

    showError = false
    Task { @MainActor [weak self, wearables] in
      do {
        try await wearables.openDATGlassesAppUpdate()
        self?.datGlassesAppUpdateRetryGate.markUpdateDestinationOpened()
      } catch {
        self?.showError(
          "\(DATGlassesAppUpdateGuidance.openUpdateFailureMessage)\n\n\(error.localizedDescription)"
        )
      }
    }
  }

  func recordDATGlassesAppUpdateRequirement(message: String) {
    guard DATGlassesAppUpdateGuidance.isRequired(message: message) else { return }
    datGlassesAppUpdateRetryGate.requireUpdate()
    requiresDATGlassesAppUpdate = true
    automaticRecoveryIsSuppressed = true
  }

  func setTimeLimit(_ limit: StreamTimeLimit) {
    activeTimeLimit = limit
    remainingTime = limit.durationInSeconds ?? 0

    if limit.isTimeLimited {
      startTimer()
    } else {
      stopTimer()
    }
  }

  func capturePhoto() {
    guard cameraCaptureState.isStreaming, let stream else {
      showError("Start streaming before capturing a photo.")
      return
    }
    _ = stream.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func startTimer() {
    stopTimer()
    timerTask = Task { @MainActor [weak self] in
      while let self, remainingTime > 0 {
        try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        guard !Task.isCancelled else { break }
        remainingTime -= 1
      }
      if let self, !Task.isCancelled {
        await releaseStream(for: .cameraPreview)
      }
    }
  }

  private func stopTimer() {
    timerTask?.cancel()
    timerTask = nil
  }

  private func createDeviceSessionIfNeeded() throws {
    guard deviceSession == nil else { return }

    let deviceSession = try wearables.createSession(deviceSelector: deviceSelector)
    streamGeneration &+= 1
    let generation = streamGeneration
    self.deviceSession = deviceSession
    // 会话创建后挂载眼镜端状态显示（无显示能力时静默降级）
    AgentDisplayHub.shared.attach(to: deviceSession)
    subscribe(to: deviceSession, generation: generation)
  }

  private func createStreamIfNeeded() throws {
    guard stream == nil else { return }
    guard let deviceSession else {
      throw StreamingSetupError.deviceSessionUnavailable
    }
    guard deviceSession.state == .started else {
      throw StreamingSetupError.deviceSessionNotReady
    }
    guard let stream = try deviceSession.addStream(config: makeStreamConfiguration()) else {
      throw StreamingSetupError.streamUnavailable
    }

    self.stream = stream
    subscribe(to: stream, generation: streamGeneration)
    updateStatusFromState(stream.state)
  }

  private func subscribe(to deviceSession: DeviceSession, generation: Int) {
    deviceSessionStateTask = Task { @MainActor [weak self] in
      for await state in deviceSession.stateStream() {
        guard !Task.isCancelled, let self, self.streamGeneration == generation else { return }
        self.handleDeviceSessionStateChange(state, generation: generation)
      }
    }

    deviceSessionErrorTask = Task { @MainActor [weak self] in
      for await error in deviceSession.errorStream() {
        guard !Task.isCancelled, let self, self.streamGeneration == generation else { return }
        self.handleDeviceSessionError(error, generation: generation)
      }
    }
  }

  private func subscribe(to stream: MWDATCamera.Stream, generation: Int) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.streamGeneration == generation else { return }
        logger.info("📊 State changed: \(String(describing: state))")
        self.updateStatusFromState(state)
      }
    }

    rawFrameIngressThrottle.reset()
    if renderedVideoFrameMailbox.activate(generation: generation) {
      videoFrameMetrics.recordDrop(.staleGeneration)
    }

    let usesCompressedVideoTransport: Bool
    switch stream.streamConfiguration.videoCodec {
    case .hvc1:
      usesCompressedVideoTransport = true
    case .raw:
      usesCompressedVideoTransport = false
    @unknown default:
      usesCompressedVideoTransport = false
    }

    let metrics = videoFrameMetrics
    let rawIngressThrottle = rawFrameIngressThrottle
    let renderedMailbox = renderedVideoFrameMailbox
    let rawRenderer = rawVideoFrameRenderer
    let rawConversionQueue = rawVideoFrameConversionQueue
    let directPreviewHub = directSampleBufferPreviewHub
    let rtmpSampleBufferRelay = self.rtmpSampleBufferRelay

    let usesDirectRawPreview = !usesCompressedVideoTransport && leases.usesDirectRawPreview
    let providerSnapshotConsumer: DirectSampleBufferPreviewHub.ProviderSnapshotConsumer = {
      renderedFrame,
      snapshotGeneration,
      receivedAt,
      conversionDuration in
      metrics.recordImageConversion(duration: conversionDuration, published: false)
      switch renderedMailbox.offer(
        LatestFrameMailboxItem(
          value: renderedFrame,
          generation: snapshotGeneration,
          receivedAt: receivedAt
        )
      ) {
      case .accepted(let replacedExistingFrame):
        metrics.recordMailboxOffer(replacedExistingFrame: replacedExistingFrame)
      case .staleGeneration:
        metrics.recordDrop(.staleGeneration)
      }
    }

    usesDirectSampleBufferPreview = usesCompressedVideoTransport || usesDirectRawPreview
    if usesCompressedVideoTransport {
      directPreviewHub.activate(
        generation: generation,
        providerSnapshotConsumer: providerSnapshotConsumer
      )
    } else if usesDirectRawPreview {
      directPreviewHub.activateRaw(
        generation: generation,
        providerSnapshotConsumer: providerSnapshotConsumer
      )
    } else {
      directPreviewHub.deactivate()
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen {
      [
        metrics,
        rawIngressThrottle,
        renderedMailbox,
        rawRenderer,
        rawConversionQueue,
        directPreviewHub,
        rtmpSampleBufferRelay,
        usesCompressedVideoTransport,
        usesDirectRawPreview
      ]
      videoFrame in
      let receivedAt = ProcessInfo.processInfo.systemUptime
      metrics.recordFrameReceived()

      if usesCompressedVideoTransport {
        switch directPreviewHub.enqueueCompressedSampleBuffer(
          videoFrame.sampleBuffer,
          generation: generation
        ) {
        case .enqueued, .noSurface:
          break
        case .staleGeneration:
          metrics.recordDrop(.staleGeneration)
        case .backpressured, .awaitingSyncFrame:
          metrics.recordDrop(.decoderBackpressure)
        case .rendererFailed, .ownershipCopyFailed, .decoderSubmissionFailed:
          metrics.recordDrop(.imageConversionFailure)
        }
        return
      }

      // The relay creates its own CMSampleBuffer copy synchronously. It only
      // consumes raw DAT input, leaving compressed HVC for the preview decoder.
      rtmpSampleBufferRelay.forward(videoFrame.sampleBuffer)

      if usesDirectRawPreview {
        switch directPreviewHub.enqueueRawSampleBuffer(
          videoFrame.sampleBuffer,
          generation: generation
        ) {
        case .enqueued, .noSurface:
          break
        case .staleGeneration:
          metrics.recordDrop(.staleGeneration)
        case .backpressured:
          metrics.recordDrop(.decoderBackpressure)
        case .rendererFailed, .ownershipCopyFailed:
          metrics.recordDrop(.imageConversionFailure)
        case .awaitingSyncFrame, .decoderSubmissionFailed:
          metrics.recordDrop(.decoderBackpressure)
        }
        return
      }

      // DAT owns this sample buffer until the listener returns, so raw frames
      // are rendered synchronously on the conversion queue at a bounded rate.
      guard rawIngressThrottle.shouldAccept(at: receivedAt) else {
        metrics.recordDrop(.throttle)
        return
      }

      let conversionStartedAt = ProcessInfo.processInfo.systemUptime
      let conversionSignpost = RealtimePerformanceSignposts.videoPipeline.beginInterval(
        "DATRawSampleBufferRender"
      )
      rawConversionQueue.sync {
        defer {
          RealtimePerformanceSignposts.videoPipeline.endInterval(
            "DATRawSampleBufferRender",
            conversionSignpost
          )
        }

        guard let renderedFrame = rawRenderer.renderRawSampleBuffer(videoFrame.sampleBuffer) else {
          let conversionDuration = ProcessInfo.processInfo.systemUptime - conversionStartedAt
          metrics.recordImageConversion(duration: conversionDuration, published: false)
          metrics.recordDrop(.imageConversionFailure)
          return
        }

        let conversionDuration = ProcessInfo.processInfo.systemUptime - conversionStartedAt
        metrics.recordImageConversion(duration: conversionDuration, published: false)
        switch renderedMailbox.offer(
          LatestFrameMailboxItem(
            value: renderedFrame,
            generation: generation,
            receivedAt: receivedAt
          )
        ) {
        case .accepted(let replacedExistingFrame):
          metrics.recordMailboxOffer(replacedExistingFrame: replacedExistingFrame)
        case .staleGeneration:
          metrics.recordDrop(.staleGeneration)
        }
      }
    }
    startFrameMailboxDelivery(generation: generation)

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.streamGeneration == generation else { return }
        logger.error("❌ Stream error: \(String(describing: error))")
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          self.showError(newErrorMessage)
        }
        self.sessionState = .failed(newErrorMessage)
        self.recoverFromStreamErrorIfNeeded(error, generation: generation)
      }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.streamGeneration == generation else { return }
        logger.info("📸 Photo captured - size: \(photoData.data.count) bytes")
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
          // 本地存档：拍摄的照片进入 App 图库（本地优先，不上云）
          if let jpeg = uiImage.jpegData(compressionQuality: 0.9),
             let record = CapturedPhotoStore.addPhoto(data: jpeg) {
            // 端侧场景识别回填 AI 描述（Apple Vision 离线，画面不出设备）
            Task {
              let result = await VisionSceneService.analyze(uiImage)
              let summary = VisionSceneTextProcessor.summaryText(from: result)
              guard !summary.isEmpty else { return }
              CapturedPhotoStore.updateDescription(id: record.id, description: summary)
            }
          }
        }
      }
    }
  }

  private func publish(_ renderedFrame: RenderedVideoFrame, receivedAt: TimeInterval) {
    // DAT can deliver a queued frame after stop/disconnect. Drop it before it
    // can repopulate the UI with an image from a previous session.
    guard hasActiveDevice, streamingStatus == .streaming,
          sessionState == .streaming else {
      videoFrameMetrics.recordDrop(.inactiveStream)
      return
    }

    guard frameUpdateThrottle.shouldPublish(at: Date.timeIntervalSinceReferenceDate) else {
      videoFrameMetrics.recordDrop(.throttle)
      return
    }

    currentVideoFrame = renderedFrame.image
    videoFrameMetrics.recordPublishedFrame()
    if !hasReceivedFirstFrame {
      logger.info("🎥 First rendered frame published after \(ProcessInfo.processInfo.systemUptime - receivedAt)s")
      hasReceivedFirstFrame = true
    }
  }

  private func releaseStreamResources() {
    // Listener publishers may already have queued events when a DAT session is
    // replaced. Advancing the generation makes those stale events no-ops.
    streamGeneration &+= 1
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = nil
    deviceSessionErrorTask?.cancel()
    deviceSessionErrorTask = nil
    cancelStreamStartupWaiter()
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
    frameMailboxDeliveryTask?.cancel()
    frameMailboxDeliveryTask = nil
    rawFrameIngressThrottle.reset()
    usesDirectSampleBufferPreview = false
    directSampleBufferPreviewHub.deactivate()
    if renderedVideoFrameMailbox.deactivateAndClear() {
      videoFrameMetrics.recordDrop(.staleGeneration)
    }
    stream = nil
    deviceSession = nil
    AgentDisplayHub.shared.detach()
  }

  private func updateStatusFromState(_ state: StreamState) {
    logger.info("📊 updateStatusFromState: \(String(describing: state)) -> streamingStatus update")
    switch state {
    case .stopped:
      logger.info("📊 State is STOPPED - clearing frame")
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      if isStoppingUnderlyingSession || leases.isEmpty {
        sessionState = .idle
      } else if sessionState == .starting {
        // A newly created DAT stream reports `stopped` before its device
        // session has started. The in-flight startup attempt owns this state.
        return
      } else if sessionState == .paused {
        return
      } else {
        sessionState = .failed("The glasses camera stream stopped unexpectedly.")
        scheduleRecoveryIfNeeded()
      }
    case .waitingForDevice, .starting, .stopping:
      logger.info("📊 State is WAITING (\(String(describing: state)))")
      streamingStatus = .waiting
      if sessionState != .stopping {
        sessionState = .starting
      }
    case .paused:
      streamingStatus = .waiting
      if sessionState != .stopping {
        sessionState = .paused
      }
    case .streaming:
      logger.info("📊 State is STREAMING ✅")
      streamingStatus = .streaming
      sessionState = .streaming
      recoveryAttempts = 0
      finishStreamStartupWaiter(result: true)
    }
  }

  private func handleDeviceSessionStateChange(_ state: DeviceSessionState, generation: Int) {
    guard streamGeneration == generation else { return }

    logger.info("📱 Device session state changed: \(String(describing: state))")
    if let trigger = deviceTriggerDetector.consume(
      sessionState: state,
      isAppStopping: isStoppingUnderlyingSession
    ) {
      if AgentDeviceEndDetector.isUnexpectedEnd(
        sessionState: state,
        isAppStopping: isStoppingUnderlyingSession
      ) {
        lastDeviceSessionEndWasUnexpected = true
      }
      onDeviceTrigger?(trigger)
    }
    switch state {
    case .idle, .starting:
      if sessionState != .stopping {
        sessionState = .starting
      }
    case .started:
      if sessionState == .paused {
        sessionState = .starting
      }
    case .paused:
      streamingStatus = .waiting
      if sessionState != .stopping {
        sessionState = .paused
      }
    case .stopping:
      sessionState = .stopping
    case .stopped:
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped

      if isStoppingUnderlyingSession || leases.isEmpty {
        sessionState = .idle
        return
      }

      releaseStreamResources()
      sessionState = .failed("The glasses device session stopped unexpectedly.")
      scheduleRecoveryIfNeeded()
    }
  }

  private func handleDeviceSessionError(_ error: DeviceSessionError, generation: Int) {
    guard streamGeneration == generation else { return }

    let message = formatDeviceSessionError(error)
    let isRecoverable = recordDeviceSessionError(error)
    logger.error("❌ Device session error: \(message)")
    if message != errorMessage {
      showError(message)
    }
    sessionState = .failed(message)
    if isRecoverable {
      recoverFromDeviceSessionErrorIfNeeded(error, generation: generation)
    } else {
      // Terminal failures (including the DAT update requirement) must release
      // the SDK session before the feature page is dismissed.
      stopUnderlyingSession(preservingFailure: true)
    }
  }

  /// The SDK can report a device-session failure through its error stream or
  /// synchronously from `DeviceSession.start()`. Both routes must apply the
  /// same update-required state and retry policy.
  @discardableResult
  private func recordDeviceSessionError(_ error: DeviceSessionError) -> Bool {
    let isRecoverable = StreamSessionRecoveryPolicy.shouldRetry(error)
    guard !isRecoverable else { return true }

    terminalDeviceSessionError = error
    automaticRecoveryIsSuppressed = true
    recoveryTask?.cancel()
    recoveryTask = nil

    if DATGlassesAppUpdateGuidance.isRequired(for: error) {
      datGlassesAppUpdateRetryGate.requireUpdate()
      requiresDATGlassesAppUpdate = true
    } else {
      datGlassesAppUpdateRetryGate.reset()
      requiresDATGlassesAppUpdate = false
    }

    return false
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "Glasses hinges are closed. Please open them to continue."
    case .thermalCritical:
      return "Device temperature is too high. Streaming paused."
    case .thermalEmergency:
      return "Device temperature is critical. Streaming stopped."
    case .peakPowerShutdown:
      return "The glasses stopped streaming to protect their battery."
    case .batteryCritical:
      return "The glasses battery is too low to stream."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  private func formatDeviceSessionError(_ error: DeviceSessionError) -> String {
    switch error {
    case .noEligibleDevice:
      return "No eligible glasses device is available."
    case .sessionAlreadyStopped:
      return "The glasses device session has already stopped."
    case .sessionAlreadyExists:
      return "Another glasses device session is already active."
    case .sessionIdle:
      return "The glasses device session is not ready yet."
    case .capabilityAlreadyActive:
      return "The glasses camera capability is already active."
    case .capabilityNotFound:
      return "The requested glasses capability is unavailable."
    case .unexpectedError(let description):
      return description
    case .thermalCritical:
      return "Device temperature is too high. Streaming paused."
    case .thermalEmergency:
      return "Device temperature is critical. Streaming stopped."
    case .peakPowerShutdown:
      return "The glasses stopped streaming to protect their battery."
    case .batteryCritical:
      return "The glasses battery is too low to stream."
    case .datAppOnTheGlassesUpdateRequired:
      return DATGlassesAppUpdateGuidance.instructions
    case .dwaUnavailable:
      return "The Meta Wearables service is temporarily unavailable."
    @unknown default:
      return error.description
    }
  }

  /// Releases the preview lease. Device monitoring stays active for the shared
  /// application-level view model and is only cancelled during shutdown.
  func cleanup() async {
    await releaseStream(for: .cameraPreview)
  }

  /// Used only when the application-level coordinator is being torn down.
  func shutdown() async {
    leases.removeAll()
    recoveryTask?.cancel()
    recoveryTask = nil
    cancelStartAttempt()
    deviceMonitorTask?.cancel()
    deviceMonitorTask = nil
    stopUnderlyingSession()
    await waitForPendingStop()
    performanceMetricsTask?.cancel()
    performanceMetricsTask = nil
    videoPerformanceMetrics = videoFrameMetrics.snapshot()
  }

  /// Stops hardware capture while the app is in the background without
  /// discarding feature ownership. Active features resume through the same
  /// bounded recovery path when the app returns to the foreground.
  func suspendForBackground() async {
    guard isApplicationActive else { return }

    isApplicationActive = false
    recoveryTask?.cancel()
    recoveryTask = nil
    cancelStartAttempt()
    stopUnderlyingSession()
    await waitForPendingStop()
  }

  func resumeAfterForeground() {
    guard !isApplicationActive else { return }

    isApplicationActive = true
    recoveryAttempts = 0
    scheduleRecoveryIfNeeded()
  }

  private func ensureStreamIsRunning() async -> Bool {
    guard isApplicationActive, !requiresSessionResetAfterDisconnect else { return false }

    guard sessionState != .paused else {
      return false
    }

    await waitForPendingStop()
    guard isApplicationActive, !requiresSessionResetAfterDisconnect,
          !Task.isCancelled else {
      return false
    }

    if streamingStatus == .streaming {
      sessionState = .streaming
      return true
    }

    if let startTask {
      return await startTask.value
    }

    startAttemptGeneration &+= 1
    let attempt = startAttemptGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      return await self.startUnderlyingSession(attempt: attempt)
    }
    startTask = task
    let started = await task.value
    if isCurrentStartAttempt(attempt) {
      startTask = nil
    }
    return started
  }

  private func startUnderlyingSession(attempt: Int) async -> Bool {
    guard isCurrentStartAttempt(attempt), !leases.isEmpty else { return false }
    guard isApplicationActive else { return false }
    guard hasActiveDevice else { return false }

    sessionState = .starting
    streamingStatus = .waiting
    RealtimePerformanceSignposts.videoPipeline.emitEvent("DATCameraSessionStart")
    activeTimeLimit = .noLimit
    remainingTime = 0
    stopTimer()
    hasReceivedFirstFrame = false
    frameUpdateThrottle.reset()
    #if DEBUG
    consecutiveNoInputFrameWindows = 0
    consecutiveNoPublishedFrameWindows = 0
    #endif

    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      let granted: Bool
      if status == .granted {
        granted = true
      } else {
        granted = try await wearables.requestPermission(permission) == .granted
      }

      guard isCurrentStartAttempt(attempt), !Task.isCancelled, isApplicationActive else {
        return false
      }

      guard granted else {
        sessionState = .failed("Camera permission denied.")
        showError("Camera permission denied.")
        return false
      }

      guard isCurrentStartAttempt(attempt),
            !Task.isCancelled,
            isApplicationActive,
            hasActiveDevice,
            !leases.isEmpty else {
        return false
      }

      try createDeviceSessionIfNeeded()
      guard let deviceSession else {
        throw StreamingSetupError.deviceSessionUnavailable
      }
      // 轻量会话（agentTrigger）可能已把会话启动为 started，重复 start 直接复用
      if deviceSession.state != .started {
        try deviceSession.start()
      }
      guard await waitForDeviceSessionToBecomeReady(attempt: attempt) else {
        if let terminalDeviceSessionError {
          throw StreamingSetupError.deviceSessionFailed(formatDeviceSessionError(terminalDeviceSessionError))
        }
        throw StreamingSetupError.deviceSessionNotReady
      }

      try createStreamIfNeeded()
      guard let stream else {
        throw StreamingSetupError.streamUnavailable
      }
      stream.start()
      let streamReady = await waitForStreamToBecomeReady(attempt: attempt)
      guard streamReady else {
        guard isCurrentStartAttempt(attempt),
              !Task.isCancelled,
              isApplicationActive,
              !requiresSessionResetAfterDisconnect else {
          return false
        }
        if let terminalDeviceSessionError {
          throw StreamingSetupError.deviceSessionFailed(formatDeviceSessionError(terminalDeviceSessionError))
        }
        return finishStartFailure(StreamingSetupError.streamStartTimedOut, attempt: attempt)
      }
      return true
    } catch let error as DeviceSessionError {
      recordDeviceSessionError(error)
      return finishStartFailure(error, attempt: attempt)
    } catch {
      return finishStartFailure(error, attempt: attempt)
    }
  }

  private func finishStartFailure(_ error: Error, attempt: Int) -> Bool {
    guard isCurrentStartAttempt(attempt) else { return false }

    let terminalError = terminalDeviceSessionError
    let message = terminalError.map(formatDeviceSessionError) ?? error.localizedDescription
    recordDATGlassesAppUpdateRequirement(message: message)
    logger.error("❌ Failed to start stream: \(message)")
    streamingStatus = .stopped
    sessionState = .failed(message)
    stopUnderlyingSession(preservingFailure: true)
    if message != errorMessage {
      showError(message)
    }
    if terminalError == nil, !automaticRecoveryIsSuppressed {
      scheduleRecoveryIfNeeded()
    }
    return false
  }

  private func waitForStreamToBecomeReady(attempt: Int) async -> Bool {
    guard isCurrentStartAttempt(attempt),
          isApplicationActive,
          !requiresSessionResetAfterDisconnect,
          terminalDeviceSessionError == nil else {
      return false
    }

    if streamingStatus == .streaming {
      sessionState = .streaming
      recoveryAttempts = 0
      return true
    }

    return await withCheckedContinuation { continuation in
      guard isCurrentStartAttempt(attempt),
            isApplicationActive,
            !requiresSessionResetAfterDisconnect,
            terminalDeviceSessionError == nil else {
        continuation.resume(returning: false)
        return
      }

      cancelStreamStartupWaiter()
      streamStartupWaiter = StreamStartupWaiter(attempt: attempt, continuation: continuation)
      let timeoutNanoseconds = UInt64(streamStartTimeout * 1_000_000_000)
      streamStartupTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(nanoseconds: timeoutNanoseconds)
        } catch {
          return
        }
        guard let self else { return }
        self.finishStreamStartupWaiter(result: false)
      }

      // `Stream.state` is authoritative. Re-check after installing the
      // waiter so a state change between the first check and this point
      // cannot leave startup waiting for its timeout.
      if self.streamingStatus == .streaming || self.stream?.state == .streaming {
        self.finishStreamStartupWaiter(result: true)
      }
    }
  }

  private func waitForDeviceSessionToBecomeReady(attempt: Int) async -> Bool {
    guard let deviceSession else { return false }

    switch deviceSession.state {
    case .started:
      return true
    case .stopped:
      return false
    case .idle, .starting, .paused, .stopping:
      break
    }

    let reachedTerminalStartupState = await waitForDeviceSessionState(
      deviceSession,
      timeout: streamStartTimeout
    ) { state in
      switch state {
      case .started, .stopped:
        return true
      case .idle, .starting, .paused, .stopping:
        return false
      }
    }

    guard reachedTerminalStartupState else {
      return false
    }

    guard case .started = deviceSession.state else {
      return false
    }

    guard isCurrentStartAttempt(attempt),
          !Task.isCancelled,
          isApplicationActive,
          !requiresSessionResetAfterDisconnect,
          terminalDeviceSessionError == nil else {
      return false
    }
    return true
  }

  private func stopUnderlyingSession(preservingFailure: Bool = false) {
    guard stopTask == nil else { return }

    let failureState = preservingFailure ? sessionState.failureState : nil

    isStoppingUnderlyingSession = true
    cancelStreamStartupWaiter()
    sessionState = .stopping
    RealtimePerformanceSignposts.videoPipeline.emitEvent("DATCameraSessionStop")
    stopTimer()

    // Clear published state before stopping SDK objects. Some SDK publishers
    // synchronously emit a final frame/state from stop().
    clearPublishedCameraState()
    let stoppingDeviceSession = deviceSession
    stream?.stop()
    stoppingDeviceSession?.stop()

    stopOperationGeneration &+= 1
    let operation = stopOperationGeneration
    stopTask = Task { @MainActor [weak self, stoppingDeviceSession] in
      await Task.yield()
      guard let self else { return }

      if let stoppingDeviceSession {
        let stopped = await self.waitForDeviceSessionState(
          stoppingDeviceSession,
          timeout: self.streamStopTimeout
        ) { state in
          if case .stopped = state { return true }
          return false
        }
        if !stopped {
          logger.error("DAT device session did not reach stopped before release timeout")
        }
      }

      guard self.stopOperationGeneration == operation else { return }
      self.releaseStreamResources()
      self.sessionState = failureState ?? .idle
      self.isStoppingUnderlyingSession = false
      self.stopTask = nil
    }
  }

  private func waitForPendingStop() async {
    if let stopTask {
      await stopTask.value
    }
  }

  private func waitForDeviceSessionState(
    _ deviceSession: DeviceSession,
    timeout: TimeInterval,
    matches: @escaping @Sendable (DeviceSessionState) -> Bool
  ) async -> Bool {
    if matches(deviceSession.state) {
      return true
    }

    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await state in deviceSession.stateStream() {
          if matches(state) {
            return true
          }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
      }

      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  private func finishStreamStartupWaiter(result: Bool) {
    guard let waiter = streamStartupWaiter else { return }
    streamStartupWaiter = nil
    streamStartupTimeoutTask?.cancel()
    streamStartupTimeoutTask = nil
    waiter.continuation.resume(returning: result)
  }

  private func cancelStreamStartupWaiter() {
    finishStreamStartupWaiter(result: false)
  }

  private func startDeviceMonitoring() {
    guard deviceMonitorTask == nil else { return }

    hasActiveDevice = deviceSelector.activeDevice != nil
    let selector = deviceSelector
    let wearables = self.wearables
    deviceListTask = Task { @MainActor [weak self, wearables] in
      for await devices in wearables.devicesStream() {
        guard !Task.isCancelled, let self else { break }
        self.availableDevices = devices
        // 首选设备不在可用列表时回退自动选择
        if let preferred = DevicePreferenceStore.preferredDeviceID,
           !devices.contains(preferred) {
          self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        }
      }
    }
    deviceMonitorTask = Task { @MainActor [weak self] in
      for await device in selector.activeDeviceStream() {
        guard !Task.isCancelled else { break }
        guard let self else { break }
        self.activeDeviceID = device
        self.handleDeviceAvailabilityChanged(device != nil)
      }
    }
  }

  private func startVideoPerformanceReporting() {
    guard performanceMetricsTask == nil else { return }

    performanceMetricsTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        guard !Task.isCancelled, let self else { return }

        let currentMailboxDepth = self.renderedVideoFrameMailbox.depth
        let metrics = self.videoFrameMetrics.snapshot(currentMailboxDepth: currentMailboxDepth)
        self.videoPerformanceMetrics = metrics

        #if DEBUG
        let directPreviewMetrics = self.directSampleBufferPreviewHub.drainPerformanceSnapshot()
        if !metrics.isEmpty || !directPreviewMetrics.isEmpty {
          logger.debug(
            "Video metrics input=\(metrics.inputFrames) delivered=\(metrics.mainActorDeliveries) published=\(metrics.publishedFrames) queue=\(metrics.maximumQueueDepth) drops=\(metrics.droppedFrames) decodeSubmitted=\(directPreviewMetrics.decoderSubmittedFrames) decoded=\(directPreviewMetrics.decodedFrames) previewQueued=\(directPreviewMetrics.enqueuedFrames) displaySubmitted=\(directPreviewMetrics.displaySubmissions) previewMailboxReplacements=\(directPreviewMetrics.displayMailboxReplacements) displayBackpressure=\(directPreviewMetrics.displayBackpressureDrops) decoderFailures=\(directPreviewMetrics.decoderSubmissionFailures + directPreviewMetrics.decoderOutputFailures) decoderFormatResets=\(directPreviewMetrics.decoderFormatResets) decoderError=\(directPreviewMetrics.lastDecoderError.map { String($0) } ?? "none") snapshots=\(directPreviewMetrics.providerSnapshotFrames) snapshotFailures=\(directPreviewMetrics.providerSnapshotFailures) sharpened=\(directPreviewMetrics.previewSharpening.renderedFrames)/\(directPreviewMetrics.previewSharpening.inputFrames) sharpenThrottle=\(directPreviewMetrics.previewSharpening.throttleDrops) sharpenFailures=\(directPreviewMetrics.previewSharpening.renderFailures) sharpenMs=\(directPreviewMetrics.previewSharpening.averageRenderMilliseconds) dispatchMs=\(metrics.averageMainActorDispatchLatencyMilliseconds) convertMs=\(metrics.averageImageConversionMilliseconds)"
          )
          print(
            "🎞️ [Video] input=\(metrics.inputFrames) delivered=\(metrics.mainActorDeliveries) "
              + "providerSnapshots=\(metrics.publishedFrames) providerMailbox=\(self.renderedVideoFrameMailbox.depth) "
              + "decodeSubmitted=\(directPreviewMetrics.decoderSubmittedFrames) "
              + "decoded=\(directPreviewMetrics.decodedFrames) "
              + "previewQueued=\(directPreviewMetrics.enqueuedFrames) "
              + "displaySubmitted=\(directPreviewMetrics.displaySubmissions) "
              + "previewMailboxReplacements=\(directPreviewMetrics.displayMailboxReplacements) "
              + "displayBackpressure=\(directPreviewMetrics.displayBackpressureDrops) "
              + "decoderFailures=\(directPreviewMetrics.decoderSubmissionFailures + directPreviewMetrics.decoderOutputFailures) "
              + "decoderFormatResets=\(directPreviewMetrics.decoderFormatResets) "
              + "decoderError=\(directPreviewMetrics.lastDecoderError.map { String($0) } ?? "none") "
              + "snapshotFrames=\(directPreviewMetrics.providerSnapshotFrames) "
              + "snapshotFailures=\(directPreviewMetrics.providerSnapshotFailures) "
              + "sharpened=\(directPreviewMetrics.previewSharpening.renderedFrames)/\(directPreviewMetrics.previewSharpening.inputFrames) "
              + "sharpenThrottle=\(directPreviewMetrics.previewSharpening.throttleDrops) "
              + "sharpenFailures=\(directPreviewMetrics.previewSharpening.renderFailures) "
              + "sharpenMs=\(directPreviewMetrics.previewSharpening.averageRenderMilliseconds) "
              + "\(self.videoLivenessDebugContext())"
          )
        }
        self.reportVideoStallIfNeeded(metrics)
        #endif
      }
    }
  }

  private func startFrameMailboxDelivery(generation: Int) {
    guard frameMailboxDeliveryTask == nil else { return }

    frameMailboxDeliveryTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: NSEC_PER_SEC / 15)
        guard !Task.isCancelled, let self, self.streamGeneration == generation else { return }
        self.publishLatestMailboxFrame(expectedGeneration: generation)
      }
    }
  }

  private func publishLatestMailboxFrame(expectedGeneration: Int) {
    guard streamGeneration == expectedGeneration else { return }
    guard let item = renderedVideoFrameMailbox.takeLatest() else { return }

    videoFrameMetrics.recordMainActorEntry(
      at: ProcessInfo.processInfo.systemUptime,
      receivedAt: item.receivedAt
    )
    guard item.generation == streamGeneration else {
      videoFrameMetrics.recordDrop(.staleGeneration)
      return
    }
    publish(item.value, receivedAt: item.receivedAt)
  }

  #if DEBUG
  private func videoLivenessDebugContext() -> String {
    let currentStream = stream
    let configuration = currentStream?.streamConfiguration
    let streamState = currentStream.map { String(describing: $0.state) } ?? "nil"
    let deviceState = deviceSession.map { String(describing: $0.state) } ?? "nil"
    let codec = configuration.map { String(describing: $0.videoCodec) } ?? "nil"
    let resolution = configuration.map { String(describing: $0.resolution) } ?? "nil"
    let frameRate = configuration.map { String($0.frameRate) } ?? "nil"

    return "stream=\(streamState) device=\(deviceState) codec=\(codec) "
      + "resolution=\(resolution) fps=\(frameRate) providerMailbox=\(renderedVideoFrameMailbox.depth) "
      + "generation=\(streamGeneration)"
  }

  private func reportVideoStallIfNeeded(_ metrics: VideoFramePerformanceSnapshot) {
    guard streamingStatus == .streaming, sessionState == .streaming else {
      consecutiveNoInputFrameWindows = 0
      consecutiveNoPublishedFrameWindows = 0
      return
    }

    if metrics.inputFrames == 0 {
      consecutiveNoInputFrameWindows += 1
      consecutiveNoPublishedFrameWindows = 0
      if consecutiveNoInputFrameWindows == 2 {
        print(
          "⚠️ [Video] DAT 上游连续 2 秒未交付帧，等待 SDK 状态或设备事件; "
            + "\(videoLivenessDebugContext())"
        )
      }
      return
    }

    if consecutiveNoInputFrameWindows >= 2 {
      print("✅ [Video] DAT 上游帧已恢复: \(metrics.inputFrames) fps-window")
    }
    consecutiveNoInputFrameWindows = 0

    if metrics.publishedFrames == 0 {
      consecutiveNoPublishedFrameWindows += 1
      if consecutiveNoPublishedFrameWindows == 2 {
        print(
          "⚠️ [Video] 上游仍有 \(metrics.inputFrames) 帧，但 AI 图像快照连续 2 秒未发布; "
            + "conversionFailures=\(metrics.imageConversionFailures)"
        )
      }
    } else {
      if consecutiveNoPublishedFrameWindows >= 2 {
        print("✅ [Video] AI 图像快照已恢复: \(metrics.publishedFrames) fps-window")
      }
      consecutiveNoPublishedFrameWindows = 0
    }
  }
  #endif

  private func handleDeviceAvailabilityChanged(_ isAvailable: Bool) {
    logger.info("📱 Device changed: \(isAvailable ? "connected" : "disconnected")")
    hasActiveDevice = isAvailable

    guard isAvailable else {
      if onDeviceReconnected != nil {
        lostDeviceWhileReconnectListenerActive = true
      }
      cancelStartAttempt()
      recoveryTask?.cancel()
      recoveryTask = nil
      // hasActiveDevice immediately makes cameraCaptureState unavailable.
      // Defer SDK cleanup until after this DAT callback returns: the SDK may
      // still be dismantling its device channel while delivering the event.
      requiresSessionResetAfterDisconnect = true
      let generationToStop = streamGeneration
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.streamGeneration == generationToStop {
          self.stopUnderlyingSession()
        }
        await self.waitForPendingStop()
        self.requiresSessionResetAfterDisconnect = false
        self.objectWillChange.send()
        if self.hasActiveDevice {
          self.recoveryAttempts = 0
          self.scheduleRecoveryIfNeeded()
        }
      }
      return
    }

    // A new device availability event is a fresh recovery opportunity, not a
    // continuation of failures from a disconnected device session.
    recoveryAttempts = 0
    scheduleRecoveryIfNeeded()
    onDeviceAvailable?()

    if lostDeviceWhileReconnectListenerActive {
      lostDeviceWhileReconnectListenerActive = false
      onDeviceReconnected?()
    }
  }

  private func clearPublishedCameraState() {
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    frameUpdateThrottle.reset()
  }

  private func scheduleRecoveryIfNeeded() {
    guard !leases.isEmpty,
          isApplicationActive,
          hasActiveDevice,
          !requiresSessionResetAfterDisconnect,
          streamingStatus != .streaming,
          sessionState != .paused,
          !automaticRecoveryIsSuppressed,
          recoveryAttempts < maximumRecoveryAttempts,
          recoveryTask == nil else {
      return
    }

    recoveryAttempts += 1
    let delay = min(Double(recoveryAttempts), 3.0)
    recoveryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, !Task.isCancelled else { return }

      self.recoveryTask = nil
      guard !self.leases.isEmpty, self.hasActiveDevice else { return }

      _ = await self.ensureStreamIsRunning()
    }
  }

  private func recoverFromStreamErrorIfNeeded(_ error: StreamError, generation: Int) {
    guard StreamSessionRecoveryPolicy.shouldRetry(error),
          streamGeneration == generation,
          !leases.isEmpty else {
      return
    }

    Task { @MainActor [weak self] in
      guard let self, self.streamGeneration == generation else { return }
      self.stopUnderlyingSession()
      self.scheduleRecoveryIfNeeded()
    }
  }

  private func recoverFromDeviceSessionErrorIfNeeded(_ error: DeviceSessionError, generation: Int) {
    guard StreamSessionRecoveryPolicy.shouldRetry(error),
          streamGeneration == generation,
          !leases.isEmpty else {
      return
    }

    Task { @MainActor [weak self] in
      guard let self, self.streamGeneration == generation else { return }
      self.stopUnderlyingSession()
      self.scheduleRecoveryIfNeeded()
    }
  }

  private func makeStreamConfiguration() -> StreamConfiguration {
    let savedQuality = UserDefaults.standard.string(forKey: "video_quality") ?? "medium"
    let profile = CameraStreamTransportProfile.make(
      savedQuality: savedQuality,
      requiresFullDuplexTransport: leases.requiresFullDuplexTransportProfile
    )
    logger.info(
      "🟢 Using video quality: \(savedQuality) -> \(String(describing: profile.resolution)), codec: \(String(describing: profile.videoCodec)), fps: \(profile.frameRate), fullDuplex: \(self.leases.requiresFullDuplexTransportProfile)"
    )
    return StreamConfiguration(
      videoCodec: profile.videoCodec,
      resolution: profile.resolution,
      frameRate: profile.frameRate
    )
  }

  private func cancelStartAttempt() {
    startAttemptGeneration &+= 1
    cancelStreamStartupWaiter()
    startTask?.cancel()
    startTask = nil
  }

  private func isCurrentStartAttempt(_ attempt: Int) -> Bool {
    startAttemptGeneration == attempt
  }

  private func resetTerminalFailure() {
    terminalDeviceSessionError = nil
    automaticRecoveryIsSuppressed = false
    datGlassesAppUpdateRetryGate.reset()
    requiresDATGlassesAppUpdate = false
  }

  private func prepareForManualStreamStart() -> Bool {
    if requiresDATGlassesAppUpdate {
      guard datGlassesAppUpdateRetryGate.consumeRetry() else {
        let message = "Update the Meta AI glasses app first, then return here and start streaming again."
        sessionState = .failed(message)
        showError(message)
        return false
      }
    }

    resetTerminalFailure()
    return true
  }
}

private enum StreamingSetupError: LocalizedError {
  case streamUnavailable
  case streamStartTimedOut
  case deviceSessionUnavailable
  case deviceSessionNotReady
  case deviceSessionFailed(String)

  var errorDescription: String? {
    switch self {
    case .streamUnavailable:
      return "Unable to create a camera stream for the connected device."
    case .streamStartTimedOut:
      return "Timed out while starting the glasses camera stream."
    case .deviceSessionUnavailable:
      return "Unable to create a device session for the connected glasses."
    case .deviceSessionNotReady:
      return "The glasses device session did not become ready in time."
    case .deviceSessionFailed(let message):
      return message
    }
  }
}

private extension StreamSessionState {
  var isFailure: Bool {
    if case .failed = self {
      return true
    }
    return false
  }

  var failureState: StreamSessionState? {
    if case .failed = self {
      return self
    }
    return nil
  }
}
