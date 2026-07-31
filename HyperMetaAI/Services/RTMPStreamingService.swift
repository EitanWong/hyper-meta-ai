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

    // Status monitoring task
    private var statusTask: Task<Void, Never>?
    private var streamStatusTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    // MARK: - Initialization

    override init() {
        super.init()
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
        lock.unlock()
        imageFrameIngressThrottle.reset()
        directFrameIngressThrottle.reset()

        self.rtmpUrl = endpoint.serverURL
        self.streamKey = endpoint.streamKey
        isConnecting = true

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

        let streamStatusTaskToStop = streamStatusTask
        streamStatusTask = nil
        streamStatusTaskToStop?.cancel()

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

        // Reset state
        lock.lock()
        totalFrames = 0
        droppedFrames = 0
        frameInputArbiter.reset()
        lock.unlock()
        imageFrameIngressThrottle.reset()
        directFrameIngressThrottle.reset()
        startTime = nil

        onStateChanged?(.idle)
        logger.info("RTMP streaming stopped")
    }

    /// Fallback for a rendered preview when DAT cannot hand us a raw frame.
    func feedFrame(_ image: UIImage, timestamp: Int64) {
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
        lock.unlock()

        guard streaming, let stream, acceptsDirectSampleBuffer else { return }
        append(ownedSampleBuffer, to: stream)
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
                self.isConnecting = false
                self.isStreaming = false
                onStateChanged?(.error(error.localizedDescription))
                onError?(error.localizedDescription)
            }
        }
    }

    private func createStreamAndPublish(connection: RTMPConnection, generation: Int) async {
        guard isCurrentOperation(generation), !Task.isCancelled else { return }

        // Create RTMP stream
        let stream = RTMPStream(connection: connection)
        self.rtmpStream = stream

        // Configure video settings
        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: videoWidth, height: videoHeight)
        videoSettings.bitRate = bitrate
        videoSettings.maxKeyFrameIntervalDuration = 1
        videoSettings.profileLevel = kVTProfileLevel_H264_Main_AutoLevel as String
        try? await stream.setVideoSettings(videoSettings)

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
                self.startTime = Date()
                self.onStateChanged?(.streaming)
            }
        } catch {
            guard isCurrentOperation(generation), !Task.isCancelled else { return }
            logger.error("RTMP: Publish failed: \(error.localizedDescription)")
            await MainActor.run {
                guard self.isCurrentOperation(generation) else { return }
                self.isConnecting = false
                self.isStreaming = false
                onStateChanged?(.error(error.localizedDescription))
                onError?(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func handleConnectionStatus(_ status: RTMPStatus, generation: Int) {
        guard isCurrentOperation(generation) else { return }
        logger.info("RTMP: Connection status: \(status.code)")

        if status.code == RTMPConnection.Code.connectFailed.rawValue {
            isStreaming = false
            isConnecting = false
            onStateChanged?(.error("Connection failed: \(status.description)"))
            onError?("Failed to connect to RTMP server")
        } else if status.code == RTMPConnection.Code.connectClosed.rawValue {
            isStreaming = false
            isConnecting = false
            onStateChanged?(.disconnected)
        } else if status.code == RTMPConnection.Code.connectRejected.rawValue {
            isStreaming = false
            isConnecting = false
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
            startTime = Date()
            onStateChanged?(.streaming)
        } else if status.code == RTMPStream.Code.publishBadName.rawValue {
            isStreaming = false
            isConnecting = false
            onStateChanged?(.error("Invalid stream name"))
            onError?("Invalid stream name")
        } else if status.code == RTMPStream.Code.connectClosed.rawValue ||
                  status.code == RTMPStream.Code.connectFailed.rawValue {
            isStreaming = false
            isConnecting = false
            onStateChanged?(.disconnected)
        }
    }

    private func isCurrentOperation(_ generation: Int) -> Bool {
        operationGeneration == generation
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
