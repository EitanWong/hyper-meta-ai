/*
 * RTMP Parallel Streaming
 * 多目的地并行推流：一份画面同时推到多个 RTMP 目的地。
 * 目的地存储与并行会话状态为纯逻辑（可测）；RTMPParallelStreamer
 * 用 HaishinKit 每路一个连接/流，把喂入的帧分发到所有活跃目的地。
 */

import AVFoundation
import Foundation
import HaishinKit
import RTMPHaishinKit
import UIKit
import VideoToolbox
import os.log

private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "RTMPParallel")

// MARK: - Destination Model & Store

/// 一个附加推流目的地（完整推流地址，密钥内嵌 URL 路径）
struct RTMPDestination: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// 完整推流地址（rtmp(s)://host/app/stream-key）
    var url: String
    /// 是否参与推流（可单独停用）
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

/// 附加目的地存储（UserDefaults JSON 持久化，上限 4 个）
enum RTMPDestinationStore {
    static let key = "rtmp.destinations"
    static let maxCount = 4

    static var destinations: [RTMPDestination] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([RTMPDestination].self, from: data)) ?? []
                .sorted { $0.createdAt > $1.createdAt }
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增目的地；空名、空 URL、重复 URL 或已达上限返回 false
    @discardableResult
    static func add(name: String, url: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return false }
        guard !destinations.contains(where: { $0.url == url }) else { return false }
        guard destinations.count < maxCount else { return false }
        var items = destinations
        items.insert(RTMPDestination(name: name, url: url), at: 0)
        destinations = items
        return true
    }

    /// 更新名称/地址（保留启用状态）；空名、空 URL、重复 URL 返回 false
    @discardableResult
    static func update(id: UUID, name: String, url: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return false }
        var items = destinations
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard !items.contains(where: { $0.id != id && $0.url == url }) else { return false }
        items[index].name = name
        items[index].url = url
        destinations = items
        return true
    }

    /// 切换启用状态
    @discardableResult
    static func toggle(id: UUID) -> Bool {
        var items = destinations
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].isEnabled.toggle()
        destinations = items
        return true
    }

    static func delete(id: UUID) {
        destinations = destinations.filter { $0.id != id }
    }
}

// MARK: - Parallel Session State (pure logic)

/// 单个目的地的连接状态
enum RTMPDestinationConnectionState: Equatable {
    case idle
    case connecting
    case streaming
    case failed(String)
}

/// 并行会话中单个目的地的展示状态
struct RTMPParallelDestinationState: Equatable, Identifiable {
    var id: UUID
    var name: String
    var connectionState: RTMPDestinationConnectionState
}

/// 并行会话聚合状态（UI 展示用）
enum RTMPParallelAggregateState: Equatable {
    case idle
    case connecting
    case streaming
    /// 全部启用目的地都失败
    case failed
}

/// 并行会话状态机（纯逻辑，可测）：维护各目的地状态并聚合
struct RTMPParallelSessionState: Equatable {
    private(set) var destinations: [RTMPParallelDestinationState] = []

    /// 以启用目的地列表开始会话（全部进入连接中）
    mutating func begin(destinations: [RTMPDestination]) {
        self.destinations = destinations
            .filter { $0.isEnabled }
            .map { RTMPParallelDestinationState(id: $0.id, name: $0.name, connectionState: .connecting) }
    }

    mutating func markStreaming(id: UUID) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[index].connectionState = .streaming
    }

    mutating func markFailed(id: UUID, message: String) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[index].connectionState = .failed(message)
    }

    mutating func markIdle(id: UUID) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[index].connectionState = .idle
    }

    /// 新增一路（连接中起始；推流中动态添加用）
    mutating func add(_ destination: RTMPDestination) {
        guard !destinations.contains(where: { $0.id == destination.id }) else { return }
        destinations.append(
            RTMPParallelDestinationState(id: destination.id, name: destination.name, connectionState: .connecting)
        )
    }

    /// 移除一路（推流中动态删除用）
    mutating func remove(id: UUID) {
        destinations.removeAll { $0.id == id }
    }

    /// 重试一路（失败 → 连接中）
    mutating func retry(id: UUID) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[index].connectionState = .connecting
    }

    /// 停止全部（进入空闲）
    mutating func stop() {
        for index in destinations.indices {
            destinations[index].connectionState = .idle
        }
    }

    /// 正在推流的目的地数量
    var streamingCount: Int {
        destinations.filter { $0.connectionState == .streaming }.count
    }

    /// 连接中的目的地数量
    var connectingCount: Int {
        destinations.filter { $0.connectionState == .connecting }.count
    }

    /// 失败的目的地数量
    var failedCount: Int {
        destinations.filter { state in
            if case .failed = state.connectionState { return true }
            return false
        }.count
    }

    /// 是否所有目的地都已成功推流（无目的地返回 false）
    var isFullyStreaming: Bool {
        !destinations.isEmpty && streamingCount == destinations.count
    }

    /// 聚合状态：全部失败 → failed；有推流中 → streaming；有连接中 → connecting；否则 idle
    var aggregate: RTMPParallelAggregateState {
        guard !destinations.isEmpty else { return .idle }
        if streamingCount > 0 { return .streaming }
        if failedCount == destinations.count { return .failed }
        if connectingCount > 0 { return .connecting }
        return .idle
    }
}

/// 附加路失败重试策略（纯逻辑，可测）：失败后最多自动重试 maxRetries 次
struct RTMPParallelRetryPolicy: Equatable {
    /// 默认自动重试次数（1 次）
    static let defaultMaxRetries = 1

    var maxRetries: Int

    init(maxRetries: Int = RTMPParallelRetryPolicy.defaultMaxRetries) {
        self.maxRetries = max(0, maxRetries)
    }

    /// 第 attempt 次失败后是否继续重试（attempt 从 0 开始）
    func shouldRetry(afterFailedAttempt attempt: Int) -> Bool {
        attempt < maxRetries
    }
}

// MARK: - Parallel Streamer (service)

/// 并行推流服务：每路一个 HaishinKit 连接/流，帧分发到所有活跃目的地。
/// 附加路不做自适应/重连（主路负责画质与恢复），失败单独上报。
final class RTMPParallelStreamer: NSObject, @unchecked Sendable {

    /// 附加路默认码率（bps）
    static let defaultBitrate = 1_500_000

    private let lock = NSLock()
    private var connections: [UUID: RTMPConnection] = [:]
    private var streams: [UUID: RTMPStream] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 目的地原始信息（重试需要 URL）
    private var destinationByID: [UUID: RTMPDestination] = [:]
    private var videoWidth = 0
    private var videoHeight = 0
    private var bitrate = RTMPParallelStreamer.defaultBitrate
    private var fps = 24.0
    private var currentSession = RTMPParallelSessionState()
    private var retryPolicy = RTMPParallelRetryPolicy()

    /// 会话状态变化回调（主线程）
    var onSessionStateChanged: ((RTMPParallelSessionState) -> Void)?
    /// 单个目的地失败回调（主线程）
    var onDestinationError: ((UUID, String) -> Void)?

    /// 当前会话状态（线程安全拷贝）
    var sessionState: RTMPParallelSessionState {
        lock.lock()
        defer { lock.unlock() }
        return currentSession
    }

    /// 是否为指定目的地推流中
    func isStreaming(destinationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentSession.destinations
            .first { $0.id == destinationID }?
            .connectionState == .streaming
    }

    /// 为所有启用目的地启动并行推流（先停止旧会话）
    func start(
        destinations: [RTMPDestination],
        width: Int,
        height: Int,
        bitrate: Int = RTMPParallelStreamer.defaultBitrate,
        fps: Double = 24
    ) {
        stop()

        lock.lock()
        videoWidth = width
        videoHeight = height
        self.bitrate = bitrate
        self.fps = fps
        destinationByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
        currentSession.begin(destinations: destinations)
        let session = currentSession
        lock.unlock()
        notifyState(session)

        for destination in destinations where destination.isEnabled {
            launch(destination: destination)
        }
    }

    /// 推流中新增一个目的地（立即连接并发布）
    func addDestination(_ destination: RTMPDestination) {
        lock.lock()
        guard currentSession.destinations.first(where: { $0.id == destination.id }) == nil else {
            lock.unlock()
            return
        }
        destinationByID[destination.id] = destination
        currentSession.add(destination)
        let session = currentSession
        lock.unlock()
        notifyState(session)
        launch(destination: destination)
    }

    /// 推流中移除一个目的地（关闭连接并清理状态）
    func removeDestination(id: UUID) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        let stream = streams.removeValue(forKey: id)
        let connection = connections.removeValue(forKey: id)
        destinationByID.removeValue(forKey: id)
        currentSession.remove(id: id)
        let session = currentSession
        lock.unlock()

        task?.cancel()
        if let stream, let connection {
            Task.detached {
                _ = try? await stream.close()
                _ = try? await connection.close()
            }
        }
        notifyState(session)
    }

    /// 重试一个失败的目的地（回到连接中）
    func retryDestination(id: UUID) {
        lock.lock()
        guard let destination = destinationByID[id] else {
            lock.unlock()
            return
        }
        currentSession.retry(id: id)
        let session = currentSession
        lock.unlock()
        notifyState(session)
        launch(destination: destination)
    }

    /// 自动重试次数
    func setRetryPolicy(_ policy: RTMPParallelRetryPolicy) {
        lock.lock()
        retryPolicy = policy
        lock.unlock()
    }

    private func launch(destination: RTMPDestination) {
        let id = destination.id
        tasks[id] = Task { [weak self] in
            await self?.connectAndPublish(destination: destination)
        }
    }

    /// 分发一帧到所有推流中的目的地（每路拷贝，互不影响）
    func appendFrame(_ sourceSampleBuffer: CMSampleBuffer) {
        lock.lock()
        let streamingStreams = streams.compactMap { id, stream -> RTMPStream? in
            let state = currentSession.destinations.first { $0.id == id }?.connectionState
            return state == .streaming ? stream : nil
        }
        lock.unlock()

        for stream in streamingStreams {
            var owned: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sourceSampleBuffer,
                sampleBufferOut: &owned
            ) == noErr, let owned else { continue }
            Task {
                await stream.append(owned)
            }
        }
    }

    /// 停止全部并行推流
    func stop() {
        lock.lock()
        let streamsToClose = Array(streams.values)
        let connectionsToClose = Array(connections.values)
        streams.removeAll()
        connections.removeAll()
        let tasksToCancel = Array(tasks.values)
        tasks.removeAll()
        destinationByID.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
        lock.lock()
        let hadSession = !currentSession.destinations.isEmpty
        currentSession.stop()
        lock.unlock()
        if hadSession {
            notifyState(currentSession)
        }
        Task.detached {
            for stream in streamsToClose {
                _ = try? await stream.close()
            }
            for connection in connectionsToClose {
                _ = try? await connection.close()
            }
        }
    }

    // MARK: - Private

    private func connectAndPublish(
        destination: RTMPDestination,
        failedAttempts: Int = 0
    ) async {
        guard let endpoint = RTMPStreamEndpoint(url: destination.url) else {
            fail(destination: destination, message: "Invalid RTMP URL")
            return
        }

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)

        lock.lock()
        connections[destination.id] = connection
        streams[destination.id] = stream
        let width = videoWidth
        let height = videoHeight
        let bitrate = bitrate
        let fps = fps
        lock.unlock()

        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: width, height: height)
        videoSettings.bitRate = bitrate
        videoSettings.expectedFrameRate = fps
        videoSettings.maxKeyFrameIntervalDuration = 1
        videoSettings.profileLevel = kVTProfileLevel_H264_Main_AutoLevel as String
        _ = try? await stream.setVideoSettings(videoSettings)
        _ = try? await stream.setAudioSettings(makeAudioSettings())

        do {
            logger.info("RTMPParallel: connecting \(destination.name)")
            _ = try await connection.connect(endpoint.serverURL)
            guard !Task.isCancelled else { return }
            logger.info("RTMPParallel: publishing \(destination.name)")
            _ = try await stream.publish(endpoint.streamKey, type: .live)
            guard !Task.isCancelled else { return }
            lock.lock()
            currentSession.markStreaming(id: destination.id)
            let session = currentSession
            lock.unlock()
            notifyState(session)
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            logger.error("RTMPParallel: \(destination.name) failed: \(message)")

            lock.lock()
            let shouldRetry = retryPolicy.shouldRetry(afterFailedAttempt: failedAttempts)
            let failedStream = streams.removeValue(forKey: destination.id)
            let failedConnection = connections.removeValue(forKey: destination.id)
            lock.unlock()
            if let failedStream, let failedConnection {
                Task.detached {
                    _ = try? await failedStream.close()
                    _ = try? await failedConnection.close()
                }
            }

            if shouldRetry {
                logger.info("RTMPParallel: retrying \(destination.name)")
                await connectAndPublish(
                    destination: destination,
                    failedAttempts: failedAttempts + 1
                )
            } else {
                fail(destination: destination, message: message)
            }
        }
    }

    private func fail(destination: RTMPDestination, message: String) {
        lock.lock()
        currentSession.markFailed(id: destination.id, message: message)
        let session = currentSession
        lock.unlock()
        notifyState(session)
        Task { @MainActor [weak self] in
            self?.onDestinationError?(destination.id, message)
        }
    }

    private func makeAudioSettings() -> AudioCodecSettings {
        var settings = AudioCodecSettings()
        settings.bitRate = 96_000
        return settings
    }

    private func notifyState(_ session: RTMPParallelSessionState) {
        Task { @MainActor [weak self] in
            self?.onSessionStateChanged?(session)
        }
    }
}
