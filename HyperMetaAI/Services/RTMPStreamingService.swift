/*
 * RTMP Streaming Service
 * Streams video from Ray-Ban Meta glasses to any RTMP server
 * Supports all major live streaming platforms: YouTube, Twitch, Bilibili, Douyin, TikTok, etc.
 *
 * Uses HaishinKit for RTMP streaming with H.264 encoding
 */

import Foundation
import UIKit
import AVFoundation
import VideoToolbox
import HaishinKit
import RTMPHaishinKit
import os.log

private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "RTMPStreaming")

// MARK: - Streaming State

enum RTMPStreamingState: Sendable {
    case idle
    case connecting
    /// 断线后自动重连等待中（第 attempt 次，delay 秒后重试）
    case reconnecting(attempt: Int, delay: TimeInterval)
    case streaming
    case disconnected
    case error(String)
}

// MARK: - Streaming Stats

struct RTMPStreamingStats: Sendable {
    var framesSent: Int64 = 0
    var framesDropped: Int64 = 0
    var bytesSent: Int64 = 0
    var fps: Double = 0
    var connectionTime: TimeInterval = 0
}

/// A validated RTMP publish endpoint split into the connection URL and the
/// publish name. Keeping this parsing outside the networking service makes the
/// user-input boundary deterministic and testable.
struct RTMPStreamEndpoint: Equatable {
    let serverURL: String
    let streamKey: String

    init?(url rawURL: String) {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let pathComponents = components.percentEncodedPath.split(separator: "/")
        guard pathComponents.count >= 2,
              let encodedStreamKey = pathComponents.last,
              !encodedStreamKey.isEmpty else {
            return nil
        }

        var serverComponents = URLComponents()
        serverComponents.scheme = scheme
        serverComponents.user = components.user
        serverComponents.password = components.password
        serverComponents.host = host
        serverComponents.port = components.port
        serverComponents.percentEncodedPath = "/"
            + pathComponents.dropLast().joined(separator: "/")

        guard let serverURL = serverComponents.url?.absoluteString else {
            return nil
        }

        self.serverURL = serverURL
        if let query = components.percentEncodedQuery, !query.isEmpty {
            streamKey = "\(encodedStreamKey)?\(query)"
        } else {
            streamKey = String(encodedStreamKey)
        }
    }
}

enum RTMPFrameInput: Equatable {
    case renderedImage
    case directSampleBuffer
}

/// Direct DAT sample buffers are the preferred RTMP input. The UIImage path
/// remains available for compressed transport and for a stream that has not
/// delivered its first raw sample buffer yet.
struct RTMPFrameInputArbiter: Equatable {
    private(set) var usesDirectSampleBuffers = false

    mutating func accepts(_ input: RTMPFrameInput) -> Bool {
        switch input {
        case .directSampleBuffer:
            usesDirectSampleBuffers = true
            return true
        case .renderedImage:
            return !usesDirectSampleBuffers
        }
    }

    mutating func reset() {
        usesDirectSampleBuffers = false
    }
}

// MARK: - Adaptive Bitrate Control

/// 自适应码率决策（纯逻辑，可测）：按周期丢帧率升降码率档位。
/// 规则：
///   丢帧率 > downshiftDropThreshold 且距上次调整 >= downshiftCooldown → 降一档；
///   周期内零丢帧 且距上次调整 >= upshiftCooldown → 升一档；
///   其余保持。冷却期防止抖动，升档比降档更保守。
struct RTMPAdaptiveBitrateController {
    struct Decision: Equatable {
        enum Action: Equatable {
            case hold
            case upshift
            case downshift
        }

        let action: Action
        let targetBitrate: Int
    }

    /// 默认码率档位（bps）
    static let defaultBitrates: [Int] = [
        1_000_000, 1_500_000, 2_000_000, 2_500_000, 3_000_000, 4_000_000
    ]

    let bitrates: [Int]
    /// 触发降档的丢帧率阈值（0.05 = 5%）
    let downshiftDropThreshold: Double
    /// 降档最小间隔（秒）
    let downshiftCooldown: TimeInterval
    /// 升档最小间隔（秒）
    let upshiftCooldown: TimeInterval

    private(set) var currentIndex: Int
    private(set) var lastChangeAt: TimeInterval

    init(
        bitrates: [Int] = RTMPAdaptiveBitrateController.defaultBitrates,
        initialBitrate: Int,
        downshiftDropThreshold: Double = 0.05,
        downshiftCooldown: TimeInterval = 8,
        upshiftCooldown: TimeInterval = 20,
        now: TimeInterval = 0
    ) {
        self.bitrates = bitrates
        self.downshiftDropThreshold = downshiftDropThreshold
        self.downshiftCooldown = downshiftCooldown
        self.upshiftCooldown = upshiftCooldown
        self.currentIndex = Self.clampIndex(for: initialBitrate, bitrates: bitrates)
        self.lastChangeAt = now
    }

    /// 当前档位码率（bps）
    var currentBitrate: Int {
        guard bitrates.indices.contains(currentIndex) else { return bitrates.last ?? 0 }
        return bitrates[currentIndex]
    }

    /// 把任意码率归一为最近档位下标
    static func clampIndex(for bitrate: Int, bitrates: [Int] = RTMPAdaptiveBitrateController.defaultBitrates) -> Int {
        guard !bitrates.isEmpty else { return 0 }
        return bitrates.indices.min(by: {
            abs(bitrates[$0] - bitrate) < abs(bitrates[$1] - bitrate)
        }) ?? 0
    }

    /// 消费一个采样周期：返回码率决策。
    /// - Parameters:
    ///   - droppedFrames: 周期内丢帧数
    ///   - totalFrames: 周期内总帧数（含丢帧）
    ///   - now: 当前相对时间（秒），与构造时的 now 同一时钟
    mutating func decide(droppedFrames: Int, totalFrames: Int, now: TimeInterval) -> Decision {
        let elapsed = max(0, now - lastChangeAt)
        let total = max(0, totalFrames)
        let dropped = max(0, droppedFrames)

        if total > 0, Double(dropped) / Double(total) > downshiftDropThreshold {
            guard elapsed >= downshiftCooldown, currentIndex > 0 else {
                return Decision(action: .hold, targetBitrate: currentBitrate)
            }
            currentIndex -= 1
            lastChangeAt = now
            return Decision(action: .downshift, targetBitrate: currentBitrate)
        }

        if total > 0, dropped == 0, elapsed >= upshiftCooldown, currentIndex < bitrates.count - 1 {
            currentIndex += 1
            lastChangeAt = now
            return Decision(action: .upshift, targetBitrate: currentBitrate)
        }

        return Decision(action: .hold, targetBitrate: currentBitrate)
    }
}

// MARK: - Adaptive Quality

/// 自适应质量档位：码率 + 编码分辨率 + 编码帧率。
/// 弱网时整体降质（分辨率/帧率先降，码率同步降），恢复后逐级回升。
struct RTMPQualityPreset: Equatable {
    let bitrate: Int
    let width: Int
    let height: Int
    let fps: Int

    /// 展示用短标签，如 "504p30"
    var shortLabel: String {
        "\(width)×\(height)@\(fps)"
    }
}

/// 自适应质量决策（纯逻辑，可测）：按周期丢帧率在质量档位间升降。
/// 规则与码率自适应一致：丢帧率 > 阈值且冷却 ≥ 8s 降一档；
/// 周期内零丢帧且冷却 ≥ 20s 升一档；空周期不动作。
struct RTMPAdaptiveQualityController {
    struct Decision: Equatable {
        enum Action: Equatable {
            case hold
            case upshift
            case downshift
        }

        let action: Action
        let preset: RTMPQualityPreset
    }

    /// 默认质量档位（从高到低）
    static let defaultPresets: [RTMPQualityPreset] = [
        RTMPQualityPreset(bitrate: 4_000_000, width: 504, height: 504, fps: 30),
        RTMPQualityPreset(bitrate: 3_000_000, width: 504, height: 504, fps: 24),
        RTMPQualityPreset(bitrate: 2_500_000, width: 504, height: 504, fps: 24),
        RTMPQualityPreset(bitrate: 2_000_000, width: 420, height: 420, fps: 24),
        RTMPQualityPreset(bitrate: 1_500_000, width: 360, height: 360, fps: 20),
        RTMPQualityPreset(bitrate: 1_000_000, width: 288, height: 288, fps: 15),
    ]

    let presets: [RTMPQualityPreset]
    /// 触发降档的丢帧率阈值（0.05 = 5%）
    let downshiftDropThreshold: Double
    /// 降档最小间隔（秒）
    let downshiftCooldown: TimeInterval
    /// 升档最小间隔（秒）
    let upshiftCooldown: TimeInterval

    private(set) var currentIndex: Int
    private(set) var lastChangeAt: TimeInterval

    init(
        presets: [RTMPQualityPreset] = RTMPAdaptiveQualityController.defaultPresets,
        initialPreset: RTMPQualityPreset? = nil,
        initialBitrate: Int? = nil,
        downshiftDropThreshold: Double = 0.05,
        downshiftCooldown: TimeInterval = 8,
        upshiftCooldown: TimeInterval = 20,
        now: TimeInterval = 0
    ) {
        self.presets = presets
        self.downshiftDropThreshold = downshiftDropThreshold
        self.downshiftCooldown = downshiftCooldown
        self.upshiftCooldown = upshiftCooldown
        if let initialPreset, let index = presets.firstIndex(of: initialPreset) {
            self.currentIndex = index
        } else if let initialBitrate {
            self.currentIndex = Self.clampIndex(for: initialBitrate, presets: presets)
        } else {
            self.currentIndex = presets.isEmpty ? 0 : presets.startIndex
        }
        self.lastChangeAt = now
    }

    /// 当前档位
    var currentPreset: RTMPQualityPreset {
        guard presets.indices.contains(currentIndex) else {
            return RTMPQualityPreset(bitrate: 0, width: 0, height: 0, fps: 0)
        }
        return presets[currentIndex]
    }

    /// 把任意码率归一为最近档位下标
    static func clampIndex(
        for bitrate: Int,
        presets: [RTMPQualityPreset] = RTMPAdaptiveQualityController.defaultPresets
    ) -> Int {
        guard !presets.isEmpty else { return 0 }
        return presets.indices.min(by: {
            abs(presets[$0].bitrate - bitrate) < abs(presets[$1].bitrate - bitrate)
        }) ?? 0
    }

    /// 消费一个采样周期：返回质量档位决策。
    mutating func decide(droppedFrames: Int, totalFrames: Int, now: TimeInterval) -> Decision {
        let elapsed = max(0, now - lastChangeAt)
        let total = max(0, totalFrames)
        let dropped = max(0, droppedFrames)

        if total > 0, Double(dropped) / Double(total) > downshiftDropThreshold {
            // 档位表从高到低：降档走向更高下标
            guard elapsed >= downshiftCooldown, currentIndex < presets.count - 1 else {
                return Decision(action: .hold, preset: currentPreset)
            }
            currentIndex += 1
            lastChangeAt = now
            return Decision(action: .downshift, preset: currentPreset)
        }

        if total > 0, dropped == 0, elapsed >= upshiftCooldown, currentIndex > 0 {
            currentIndex -= 1
            lastChangeAt = now
            return Decision(action: .upshift, preset: currentPreset)
        }

        return Decision(action: .hold, preset: currentPreset)
    }
}

// MARK: - Audio Bitrate Policy

/// 画质锁定策略（纯逻辑，可测）：锁定时不执行任何自适应档位调整
enum RTMPQualityLockPolicy {
    /// 该决策在锁定状态下是否应执行
    static func shouldApply(
        decision: RTMPAdaptiveQualityController.Decision,
        locked: Bool
    ) -> Bool {
        !locked && decision.action != .hold
    }
}

/// 音频码率策略（纯逻辑，可测）：把质量档位指数映射为音频编码码率。
/// 质量档位越低，音频码率同步下调——弱网时控制总带宽的同时优先保住语音清晰度。
struct RTMPAudioBitratePolicy: Equatable {
    /// 默认映射表：与默认 6 档质量档位一一对应（index 0 = 最高画质）
    static let defaultBitrates: [Int] = [
        128_000, 128_000, 96_000, 96_000, 64_000, 64_000
    ]

    /// 质量档位指数 → 音频码率（bps）；越界按最近档 clamp，空表返回 0
    let bitrates: [Int]

    init(bitrates: [Int] = RTMPAudioBitratePolicy.defaultBitrates) {
        self.bitrates = bitrates
    }

    func audioBitrate(forQualityIndex index: Int) -> Int {
        guard !bitrates.isEmpty else { return 0 }
        return bitrates[min(max(0, index), bitrates.count - 1)]
    }
}

// MARK: - Reconnect Policy

/// 网络恢复策略（纯逻辑，可测）：断线/连接失败后按退避间隔自动重连。
/// 等待间隔随尝试次数递增（2s / 4s / 8s / 16s / 30s），超过最大尝试次数后放弃并报错。
struct RTMPReconnectPolicy: Equatable {
    /// 默认退避间隔表（秒）：第 N 次重连前的等待时间
    static let defaultBackoffDelays: [TimeInterval] = [2, 4, 8, 16, 30]
    /// 默认最大重连尝试次数
    static let defaultMaxAttempts = 5

    /// 第 attempt 次（1-based）重连前的等待间隔；超过表长按最后一项封顶
    let backoffDelays: [TimeInterval]
    /// 最多重连尝试次数（超过后放弃）
    let maxAttempts: Int

    init(
        backoffDelays: [TimeInterval] = RTMPReconnectPolicy.defaultBackoffDelays,
        maxAttempts: Int = RTMPReconnectPolicy.defaultMaxAttempts
    ) {
        self.backoffDelays = backoffDelays
        self.maxAttempts = maxAttempts
    }

    /// 第 attempt 次重连（1-based）的等待间隔；尝试次数越界或表为空返回 nil（表示放弃）
    func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts, !backoffDelays.isEmpty else { return nil }
        return backoffDelays[min(attempt - 1, backoffDelays.count - 1)]
    }

    /// 已失败 failed 次后是否还可以再试一次（下一次尝试必须有可用的退避间隔）
    func canAttempt(afterFailedAttempts failed: Int) -> Bool {
        delay(forAttempt: failed + 1) != nil
    }
}

// MARK: - RTMP Streaming Service

class RTMPStreamingService: NSObject, @unchecked Sendable {

    // MARK: - Constants

    private static let defaultBitrate: Int = 2_000_000 // 2 Mbps
    private static let defaultFPS: Int = 24

    // MARK: - Properties

    private let lock = NSLock()

    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?

    private var rtmpUrl: String = ""
    private var streamKey: String = ""
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    private var bitrate: Int = RTMPStreamingService.defaultBitrate

    // State
    private(set) var isStreaming = false
    private var isConnecting = false
    private var startTime: Date?
    // Async connection callbacks are tagged with this value. A callback from
    // an older start must never revive state after stop/restart.
    private var operationGeneration = 0

    // Frame tracking
    private var totalFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private let imageFrameIngressThrottle = FrameIngressThrottle(maximumFramesPerSecond: 15)
    private let directFrameIngressThrottle = FrameIngressThrottle(
        maximumFramesPerSecond: Double(RTMPStreamingService.defaultFPS)
    )
    private var frameInputArbiter = RTMPFrameInputArbiter()

    // Callbacks
    var onStateChanged: ((RTMPStreamingState) -> Void)?
    var onStatsUpdated: ((RTMPStreamingStats) -> Void)?
    var onError: ((String) -> Void)?
    /// 自适应质量调整后的当前码率（bps）
    var onBitrateChanged: ((Int) -> Void)?
    /// 自适应质量调整后的当前档位（分辨率/帧率/码率）
    var onQualityChanged: ((RTMPQualityPreset) -> Void)?
    /// 音频码率调整后的当前码率（bps）
    var onAudioBitrateChanged: ((Int) -> Void)?

    /// 音频码率是否跟随质量档位动态调节（默认开启；推流开始前设置生效）
    var adaptiveAudioEnabled = true

    // Adaptive quality
    /// 自适应质量开关（默认开启；推流开始前设置生效）
    var adaptiveQualityEnabled = true
    private var adaptiveQualityController: RTMPAdaptiveQualityController?
    private var adaptiveTask: Task<Void, Never>?
    /// 上次采样快照（帧计数），用于计算周期增量
    private var lastAdaptiveTotalFrames: Int64 = 0
    private var lastAdaptiveDroppedFrames: Int64 = 0
    /// 自适应时钟（相对时间，秒；由 adaptiveTask 推进）
    private var adaptiveNow: TimeInterval = 0
    /// 档位帧率节流：按当前档位 fps 静默丢帧（不计数，避免与丢帧统计自激）
    private var qualityFrameThrottle: FrameIngressThrottle?
    /// 当前音频编码码率（bps）
    private var audioBitrate: Int = RTMPAudioBitratePolicy.defaultBitrates.first ?? 128_000

    /// 推流中本地录制器（视频轨）
    private let recorder = RTMPStreamRecorder()

    /// 画质锁定：锁定时暂停自适应档位调整（保持当前档位）
    var qualityLocked = false

    /// 多目的地并行推流器（附加路；主路负责画质自适应与重连）
    let parallelStreamer = RTMPParallelStreamer()
    /// 并行目的地（推流开始前设置；空数组则不启动附加路）
    var parallelDestinations: [RTMPDestination] = []
    /// 附加路码率（bps）
    var parallelBitrate: Int = RTMPParallelStreamer.defaultBitrate
    /// 并行会话状态回调（主线程）
    var onParallelStateChanged: ((RTMPParallelSessionState) -> Void)?
    /// 附加路失败回调（主线程）
    var onParallelError: ((UUID, String) -> Void)?

    /// 直播场景理解开关（默认开启；推流开始前设置生效）
    var liveSceneAnalysisEnabled = true
    /// 直播场景识别结果回调
    var onSceneDetected: ((RTMPLiveSceneSnapshot) -> Void)?
    /// 场景采样调度（周期 + 变化检测）
    private var sceneScheduler = RTMPLiveSceneScheduler(sampleInterval: 10)
    /// 上一次场景识别是否仍在进行（防止堆积）
    private var sceneAnalysisInFlight = false

    /// 推流会话诊断采集器
    private var diagnostics = RTMPDiagnosticsCollector()

    /// 隐私保护盾：开启时不发送任何画面帧（不编码不上传，录制与场景识别同步暂停）
    var privacyShielded = false
    /// 最近一次推流会话的诊断快照（停止后保留，供诊断面板展示）
    private var lastDiagnosticsSnapshot: RTMPDiagnosticsSnapshot?

    // Auto reconnect
    /// 断线后自动重连开关（默认开启；推流开始前设置生效）
    var autoReconnectEnabled = true
    /// 重连策略（退避间隔 / 最大尝试次数）
    var reconnectPolicy = RTMPReconnectPolicy()
    /// 当前会话累计失败重连次数（推流成功后归零）
    private(set) var failedReconnectAttempts = 0
    /// 已有一次重连在等待/进行中（防止同一断线的多个状态事件重复调度）
    private var reconnectPending = false
    private var reconnectTask: Task<Void, Never>?

    // Status monitoring task
    private var statusTask: Task<Void, Never>?
    private var streamStatusTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    // MARK: - Initialization

    override init() {
        super.init()
        parallelStreamer.onSessionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.onParallelStateChanged?(state)
            }
        }
        parallelStreamer.onDestinationError = { [weak self] id, message in
            Task { @MainActor in
                self?.onParallelError?(id, message)
            }
        }
        logger.info("RTMPStreamingService initialized with HaishinKit")
    }

    deinit {
        stopStreaming()
    }

    var isUsingDirectSampleBufferInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frameInputArbiter.usesDirectSampleBuffers
    }

    // MARK: - Public Methods

    /// Start RTMP streaming
    func startStreaming(url: String, width: Int, height: Int, bitrate: Int = defaultBitrate) {
        guard !isStreaming, !isConnecting else {
            logger.warning("Already streaming or connecting")
            return
        }

        operationGeneration &+= 1
        let generation = operationGeneration

        logger.info("Starting RTMP streaming")
        logger.info("Video: \(width)x\(height) @ \(bitrate) bps")

        self.videoWidth = width
        self.videoHeight = height
        self.bitrate = bitrate

        guard let endpoint = RTMPStreamEndpoint(url: url) else {
            onStateChanged?(.error("Invalid RTMP URL"))
            onError?("Invalid RTMP URL format")
            return
        }

        lock.lock()
        frameInputArbiter.reset()
        totalFrames = 0
        droppedFrames = 0
        qualityFrameThrottle = FrameIngressThrottle(
            maximumFramesPerSecond: Double(RTMPStreamingService.defaultFPS)
        )
        lock.unlock()
        imageFrameIngressThrottle.reset()
        directFrameIngressThrottle.reset()

        self.rtmpUrl = endpoint.serverURL
        self.streamKey = endpoint.streamKey
        isConnecting = true

        adaptiveQualityController = RTMPAdaptiveQualityController(initialBitrate: bitrate)
        diagnostics.begin()
        sceneScheduler.reset()
        sceneAnalysisInFlight = false
        lastAdaptiveTotalFrames = 0
        lastAdaptiveDroppedFrames = 0
        adaptiveNow = 0
        failedReconnectAttempts = 0
        reconnectPending = false

        parallelStreamer.start(
            destinations: parallelDestinations,
            width: width,
            height: height,
            bitrate: parallelBitrate
        )

        onStateChanged?(.connecting)

        // Create connection and stream
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.setupAndConnect(generation: generation)
        }
    }

    /// Stop streaming
    func stopStreaming() {
        logger.info("Stopping RTMP streaming")

        operationGeneration &+= 1

        isStreaming = false
        isConnecting = false

        connectTask?.cancel()
        connectTask = nil

        let statusTaskToStop = statusTask
        statusTask = nil
        statusTaskToStop?.cancel()

        let adaptiveTaskToStop = adaptiveTask
        adaptiveTask = nil
        adaptiveTaskToStop?.cancel()

        let streamStatusTaskToStop = streamStatusTask
        streamStatusTask = nil
        streamStatusTaskToStop?.cancel()

        let reconnectTaskToStop = reconnectTask
        reconnectTask = nil
        reconnectTaskToStop?.cancel()
        failedReconnectAttempts = 0
        reconnectPending = false

        parallelStreamer.stop()

        if recorder.isRecording {
            Task { [weak self] in
                guard let record = await self?.recorder.finish() else { return }
                RTMPRecordingStore.add(record)
            }
        }

        let streamToClose = rtmpStream
        let connectionToClose = rtmpConnection
        rtmpStream = nil
        rtmpConnection = nil

        shutdownTask?.cancel()
        shutdownTask = Task.detached { [statusTaskToStop, streamStatusTaskToStop, streamToClose, connectionToClose] in
            _ = await statusTaskToStop?.value
            _ = await streamStatusTaskToStop?.value
            if let streamToClose {
                _ = try? await streamToClose.close()
            }
            if let connectionToClose {
                _ = try? await connectionToClose.close()
            }
        }

        diagnostics.end()
        lastDiagnosticsSnapshot = diagnostics.snapshot

        // Reset state
        lock.lock()
        totalFrames = 0
        droppedFrames = 0
        frameInputArbiter.reset()
        qualityFrameThrottle = nil
        lock.unlock()
        imageFrameIngressThrottle.reset()
        directFrameIngressThrottle.reset()
        startTime = nil

        onStateChanged?(.idle)
        logger.info("RTMP streaming stopped")
    }

    /// Fallback for a rendered preview when DAT cannot hand us a raw frame.
    func feedFrame(_ image: UIImage, timestamp: Int64) {
        guard !privacyShielded else { return }
        lock.lock()
        let streaming = isStreaming
        let stream = rtmpStream
        let acceptsRenderedImage = frameInputArbiter.accepts(.renderedImage)
        lock.unlock()

        guard streaming, let stream, acceptsRenderedImage else { return }
        guard imageFrameIngressThrottle.shouldAccept(at: Double(timestamp) / 1_000_000) else {
            recordFrameDrop()
            return
        }

        guard let sampleBuffer = image.toCMSampleBuffer(timestamp: timestamp) else {
            logger.warning("Failed to create CMSampleBuffer from UIImage")
            recordFrameDrop()
            return
        }

        append(sampleBuffer, to: stream)
    }

    /// Captures an owned Core Media copy before the DAT frame callback returns.
    /// It does not alter the source pixel buffer used by the display or AI paths.
    func feedSampleBuffer(_ sourceSampleBuffer: CMSampleBuffer) {
        guard !privacyShielded else { return }
        lock.lock()
        let isReadyToRelay = isStreaming && rtmpStream != nil
        lock.unlock()
        guard isReadyToRelay else { return }

        guard CMSampleBufferDataIsReady(sourceSampleBuffer) else {
            recordFrameDrop()
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sourceSampleBuffer)
        let timestamp = presentationTime.isValid && presentationTime.seconds.isFinite
            ? presentationTime.seconds
            : ProcessInfo.processInfo.systemUptime
        lock.lock()
        let qualityThrottle = qualityFrameThrottle
        lock.unlock()
        if let qualityThrottle, !qualityThrottle.shouldAccept(at: timestamp) {
            // 档位降帧：有意静默丢弃，不进入丢帧统计
            return
        }
        guard directFrameIngressThrottle.shouldAccept(at: timestamp) else {
            recordFrameDrop()
            return
        }

        var ownedSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sourceSampleBuffer,
            sampleBufferOut: &ownedSampleBuffer
        ) == noErr, let ownedSampleBuffer else {
            logger.warning("Failed to create owned CMSampleBuffer for RTMP")
            recordFrameDrop()
            return
        }

        lock.lock()
        let streaming = isStreaming
        let stream = rtmpStream
        let acceptsDirectSampleBuffer = frameInputArbiter.accepts(.directSampleBuffer)
        let recording = recorder.isRecording
        lock.unlock()

        guard streaming, let stream, acceptsDirectSampleBuffer else { return }
        if recording {
            recorder.append(ownedSampleBuffer)
        }

        lock.lock()
        let shouldAnalyze = liveSceneAnalysisEnabled
            && !sceneAnalysisInFlight
            && sceneScheduler.shouldSample(now: ProcessInfo.processInfo.systemUptime)
        if shouldAnalyze {
            sceneAnalysisInFlight = true
        }
        let generation = operationGeneration
        lock.unlock()

        if shouldAnalyze {
            analyzeLiveScene(sampleBuffer: ownedSampleBuffer, generation: generation)
        }

        append(ownedSampleBuffer, to: stream)
        parallelStreamer.appendFrame(ownedSampleBuffer)
    }

    /// 对采样帧做端侧场景识别；完成后在主线程回调并更新调度器。
    private func analyzeLiveScene(sampleBuffer: CMSampleBuffer, generation: Int) {
        Task { [weak self] in
            defer { self?.markSceneAnalysisDone() }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let result = await VisionSceneService.analyze(pixelBuffer)
            await self?.handleSceneResult(result, generation: generation)
        }
    }

    private func markSceneAnalysisDone() {
        lock.lock()
        sceneAnalysisInFlight = false
        lock.unlock()
    }

    /// 场景识别结果：更新调度器、推送快照；录制中场景变化自动打标记。
    @MainActor
    private func handleSceneResult(_ result: VisionSceneResult, generation: Int) {
        guard isCurrentOperation(generation), isStreaming else { return }

        let summary = VisionSceneTextProcessor.summaryText(from: result)
        let label = RTMPLiveSceneProcessor.sceneLabel(from: result)

        lock.lock()
        let isChanged = sceneScheduler.consume(summary: summary)
        let recording = recorder.isRecording
        lock.unlock()

        let snapshot = RTMPLiveSceneSnapshot(
            sceneLabel: label,
            summary: summary,
            isChanged: isChanged,
            detectedAt: Date()
        )

        if isChanged {
            diagnostics.recordSceneChange()
            if recording, recorder.addMarker(label: label ?? "Scene") != nil {
                diagnostics.recordRecordingMarker()
            }
        }
        onSceneDetected?(snapshot)
    }

    // MARK: - Local Recording

    /// 是否正在本地录制
    var isRecording: Bool {
        recorder.isRecording
    }

    /// 最近一次推流会话的诊断快照
    var diagnosticsSnapshot: RTMPDiagnosticsSnapshot? {
        lastDiagnosticsSnapshot
    }

    /// 开始本地录制（视频轨）；未在推流或已在录制中返回 false
    @discardableResult
    func startRecording() -> Bool {
        guard isStreaming else { return false }
        return recorder.start(dimensions: CGSize(width: videoWidth, height: videoHeight))
    }

    /// 添加一个录制事件标记（相对录制开始自动计时）
    @discardableResult
    func addRecordingMarker(label: String) -> RTMPRecordingMarker? {
        guard let marker = recorder.addMarker(label: label) else { return nil }
        diagnostics.recordRecordingMarker()
        return marker
    }

    /// 结束录制并保存记录；未在录制中返回 nil
    func stopRecording() async -> RTMPRecordingRecord? {
        guard let record = await recorder.finish() else { return nil }
        RTMPRecordingStore.add(record)
        return record
    }

    // MARK: - Private Methods

    private func setupAndConnect(generation: Int) async {
        guard isCurrentOperation(generation) else { return }

        // Create RTMP connection
        let connection = RTMPConnection()
        self.rtmpConnection = connection

        // Monitor connection status
        statusTask = Task { [weak self] in
            for await status in await connection.status {
                guard !Task.isCancelled else { return }
                await self?.handleConnectionStatus(status, generation: generation)
            }
        }

        // Connect to server
        let url = self.rtmpUrl
        do {
            logger.info("RTMP: Connecting")
            _ = try await connection.connect(url)
            guard isCurrentOperation(generation), !Task.isCancelled else { return }
            logger.info("RTMP: Connected successfully")

            // Create stream and publish
            await createStreamAndPublish(connection: connection, generation: generation)
        } catch {
            guard isCurrentOperation(generation), !Task.isCancelled else { return }
            logger.error("RTMP: Connection failed: \(error.localizedDescription)")
            await MainActor.run {
                guard self.isCurrentOperation(generation) else { return }
                self.scheduleReconnect(generation: generation)
            }
        }
    }

    private func createStreamAndPublish(connection: RTMPConnection, generation: Int) async {
        guard isCurrentOperation(generation), !Task.isCancelled else { return }

        // Create RTMP stream
        let stream = RTMPStream(connection: connection)
        self.rtmpStream = stream

        // Configure video settings
        try? await stream.setVideoSettings(makeVideoSettings(preset: initialQualityPreset))

        // Configure audio settings
        try? await stream.setAudioSettings(makeAudioSettings(bitrate: audioBitrate))

        // Monitor stream status
        streamStatusTask = Task { [weak self] in
            for await status in await stream.status {
                guard !Task.isCancelled else { return }
                await self?.handleStreamStatus(status, generation: generation)
            }
        }

        // Publish
        let key = self.streamKey
        do {
            logger.info("RTMP: Publishing stream")
            _ = try await stream.publish(key, type: .live)
            guard isCurrentOperation(generation), !Task.isCancelled else { return }
            logger.info("RTMP: Publish started")

            await MainActor.run { [weak self] in
                guard let self, self.isCurrentOperation(generation) else { return }
                self.isStreaming = true
                self.isConnecting = false
                self.failedReconnectAttempts = 0
                self.reconnectPending = false
                self.startTime = Date()
                self.onStateChanged?(.streaming)
                self.startAdaptiveQualityTask(generation: generation)
            }
        } catch {
            guard isCurrentOperation(generation), !Task.isCancelled else { return }
            logger.error("RTMP: Publish failed: \(error.localizedDescription)")
            await MainActor.run {
                guard self.isCurrentOperation(generation) else { return }
                self.scheduleReconnect(generation: generation)
            }
        }
    }

    @MainActor
    private func handleConnectionStatus(_ status: RTMPStatus, generation: Int) {
        guard isCurrentOperation(generation) else { return }
        logger.info("RTMP: Connection status: \(status.code)")

        if status.code == RTMPConnection.Code.connectFailed.rawValue {
            scheduleReconnect(generation: generation)
        } else if status.code == RTMPConnection.Code.connectClosed.rawValue {
            scheduleReconnect(generation: generation)
        } else if status.code == RTMPConnection.Code.connectRejected.rawValue {
            isStreaming = false
            isConnecting = false
            reconnectPending = false
            onStateChanged?(.error("Connection rejected: \(status.description)"))
            onError?("Connection rejected by server")
        }
    }

    @MainActor
    private func handleStreamStatus(_ status: RTMPStatus, generation: Int) {
        guard isCurrentOperation(generation) else { return }
        logger.info("RTMP: Stream status: \(status.code)")

        if status.code == RTMPStream.Code.publishStart.rawValue {
            isStreaming = true
            isConnecting = false
            failedReconnectAttempts = 0
            reconnectPending = false
            startTime = Date()
            onStateChanged?(.streaming)
        } else if status.code == RTMPStream.Code.publishBadName.rawValue {
            isStreaming = false
            isConnecting = false
            reconnectPending = false
            onStateChanged?(.error("Invalid stream name"))
            onError?("Invalid stream name")
        } else if status.code == RTMPStream.Code.connectClosed.rawValue ||
                  status.code == RTMPStream.Code.connectFailed.rawValue {
            scheduleReconnect(generation: generation)
        }
    }

    private func isCurrentOperation(_ generation: Int) -> Bool {
        operationGeneration == generation
    }

    // MARK: - Auto Reconnect

    /// 断线/连接失败后按退避策略调度自动重连；超过最大尝试次数后放弃并报错。
    /// 同一断线的多个状态事件只调度一次；用户主动停止（generation 失效）不重连。
    @MainActor
    private func scheduleReconnect(generation: Int) {
        guard autoReconnectEnabled, isCurrentOperation(generation) else { return }
        guard !reconnectPending else { return }

        reconnectPending = true
        failedReconnectAttempts += 1
        diagnostics.recordReconnect()

        guard let delay = reconnectPolicy.delay(forAttempt: failedReconnectAttempts) else {
            reconnectPending = false
            isStreaming = false
            isConnecting = false
            let message = String(
                format: "rtmp.error.reconnect.failed".localized,
                failedReconnectAttempts
            )
            onStateChanged?(.error(message))
            onError?(message)
            return
        }

        isStreaming = false
        isConnecting = true
        onStateChanged?(.reconnecting(attempt: failedReconnectAttempts, delay: delay))

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isCurrentOperation(generation) else { return }
            await self.performReconnect(generation: generation)
        }
    }

    /// 执行一次重连：关闭旧连接后重新走连接流程。
    private func performReconnect(generation: Int) async {
        let streamToClose = rtmpStream
        let connectionToClose = rtmpConnection
        rtmpStream = nil
        rtmpConnection = nil
        if let streamToClose {
            _ = try? await streamToClose.close()
        }
        if let connectionToClose {
            _ = try? await connectionToClose.close()
        }
        reconnectPending = false
        guard isCurrentOperation(generation) else { return }
        await setupAndConnect(generation: generation)
    }

    // MARK: - Adaptive Quality

    private func makeAudioSettings(bitrate: Int) -> AudioCodecSettings {
        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = bitrate
        return audioSettings
    }

    private func makeVideoSettings(preset: RTMPQualityPreset) -> VideoCodecSettings {
        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: preset.width, height: preset.height)
        videoSettings.bitRate = preset.bitrate
        videoSettings.expectedFrameRate = Double(preset.fps)
        videoSettings.maxKeyFrameIntervalDuration = 1
        videoSettings.profileLevel = kVTProfileLevel_H264_Main_AutoLevel as String
        return videoSettings
    }

    /// 初始编码档位：保持用户显式选择的分辨率/帧率，直到首次自适应调整。
    private var initialQualityPreset: RTMPQualityPreset {
        RTMPQualityPreset(
            bitrate: bitrate,
            width: videoWidth,
            height: videoHeight,
            fps: RTMPStreamingService.defaultFPS
        )
    }

    /// 推流成功后启动自适应质量任务：每 3 秒按丢帧率在质量档位间升降。
    private func startAdaptiveQualityTask(generation: Int) {
        adaptiveTask?.cancel()
        guard adaptiveQualityEnabled else { return }
        let controller = adaptiveQualityController
            ?? RTMPAdaptiveQualityController(initialBitrate: bitrate)
        adaptiveQualityController = controller

        adaptiveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.isCurrentOperation(generation) else { return }
                guard self.isStreaming else { return }
                await self.evaluateAdaptiveQuality()
            }
        }
    }

    /// 采样一个周期（3s）：计算丢帧增量，按质量控制器决策动态调整码率/分辨率/帧率。
    @MainActor
    private func evaluateAdaptiveQuality() async {
        lock.lock()
        let totalNow = totalFrames
        let droppedNow = droppedFrames
        lock.unlock()
        diagnostics.recordFrameStats(total: totalNow, dropped: droppedNow)

        let totalDelta = Int64(max(0, totalNow - lastAdaptiveTotalFrames))
        let droppedDelta = Int64(max(0, droppedNow - lastAdaptiveDroppedFrames))
        lastAdaptiveTotalFrames = totalNow
        lastAdaptiveDroppedFrames = droppedNow
        adaptiveNow += 3

        guard var controller = adaptiveQualityController else { return }
        let decision = controller.decide(
            droppedFrames: Int(droppedDelta),
            totalFrames: Int(totalDelta),
            now: adaptiveNow
        )
        adaptiveQualityController = controller

        guard RTMPQualityLockPolicy.shouldApply(decision: decision, locked: qualityLocked),
              let stream = rtmpStream else { return }
        let preset = decision.preset
        bitrate = preset.bitrate
        diagnostics.recordQualityChange(
            upshift: decision.action == .upshift,
            presetLabel: preset.shortLabel
        )
        lock.lock()
        qualityFrameThrottle = FrameIngressThrottle(
            maximumFramesPerSecond: Double(preset.fps)
        )
        lock.unlock()
        try? await stream.setVideoSettings(makeVideoSettings(preset: preset))
        let direction = decision.action == .upshift ? "up" : "down"
        logger.info(
            "RTMP: Adaptive quality \(direction) to \(preset.shortLabel) at \(preset.bitrate) bps"
        )
        onBitrateChanged?(preset.bitrate)
        onQualityChanged?(preset)

        if adaptiveAudioEnabled {
            let policy = RTMPAudioBitratePolicy()
            let newAudioBitrate = policy.audioBitrate(forQualityIndex: controller.currentIndex)
            if newAudioBitrate != audioBitrate {
                audioBitrate = newAudioBitrate
                try? await stream.setAudioSettings(makeAudioSettings(bitrate: newAudioBitrate))
                logger.info("RTMP: Adaptive audio bitrate to \(newAudioBitrate) bps")
                onAudioBitrateChanged?(newAudioBitrate)
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to stream: RTMPStream) {
        lock.lock()
        totalFrames += 1
        lock.unlock()

        Task {
            await stream.append(sampleBuffer)
        }
        updateStats()
    }

    private func recordFrameDrop() {
        lock.lock()
        droppedFrames += 1
        lock.unlock()
    }

    private func updateStats() {
        lock.lock()
        let start = startTime
        let frameCount = totalFrames
        let droppedFrameCount = droppedFrames
        lock.unlock()

        guard let start else { return }

        let elapsed = Date().timeIntervalSince(start)
        let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0

        let stats = RTMPStreamingStats(
            framesSent: frameCount,
            framesDropped: droppedFrameCount,
            bytesSent: 0, // HaishinKit doesn't expose this directly
            fps: fps,
            connectionTime: elapsed
        )

        onStatsUpdated?(stats)
    }
}

// MARK: - UIImage Extension

extension UIImage {
    func toCMSampleBuffer(timestamp: Int64) -> CMSampleBuffer? {
        guard let cgImage = cgImage else { return nil }

        let width = Int(size.width)
        let height = Int(size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create format description
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )

        guard let format = formatDescription else { return nil }

        // Create timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    func toPixelBuffer() -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        guard let cgImage = cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }
}
