/*
 * Qwen Gateway Service
 * Qwen 实时语音统一入口：默认使用 App 内置 DashScope 传输，也可连接
 * 外部 qwen-audio-agent 网关。负责协议传输、事件收发与自动重连；
 * 音频采集/播放由上层复用 RealtimeAudioUpload/PlaybackPipeline 接入。
 */

import Foundation

private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int {
        self == 0 ? defaultValue : self
    }
}

enum QwenGatewayConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case sleeping
    case waking
    case failed(String)

    var isOnline: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct QwenRealtimeConnectionStatus: Equatable {
    private(set) var unavailableMessage: String?
    private(set) var sleeping = false
    private(set) var waking = false
    private(set) var ready = false
    private(set) var connecting = false

    var connectionState: QwenGatewayConnectionState {
        if let unavailableMessage { return .failed(unavailableMessage) }
        if sleeping { return .sleeping }
        if waking { return .waking }
        if ready { return .connected }
        if connecting { return .connecting }
        return .disconnected
    }

    mutating func beginConnecting(resetLifecycle: Bool) {
        unavailableMessage = nil
        ready = false
        connecting = true
        if resetLifecycle {
            sleeping = false
            waking = false
        }
    }

    mutating func markReady() {
        ready = true
        connecting = false
    }

    mutating func markConnected() {
        unavailableMessage = nil
        sleeping = false
        waking = false
        ready = true
        connecting = false
    }

    mutating func markUnavailable(_ message: String) {
        unavailableMessage = message
        ready = false
        connecting = false
    }

    mutating func markSleeping() {
        sleeping = true
        waking = false
        ready = false
        connecting = false
    }

    mutating func markWaking() {
        sleeping = false
        waking = true
    }

    mutating func markDisconnected() {
        self = QwenRealtimeConnectionStatus()
    }

    mutating func applyVoiceConnection(state: String, message: String?) {
        switch state {
        case "connected":
            markConnected()
        case "waking":
            markWaking()
        case "connecting":
            beginConnecting(resetLifecycle: false)
        case "sleeping":
            let hasWakeFailure = !(message?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            if !waking || hasWakeFailure {
                markSleeping()
            }
        case "unavailable":
            markUnavailable(message ?? "Voice front end unavailable")
        default:
            break
        }
    }

    mutating func applyVoiceSleep(state: String) {
        switch state {
        case "sleeping" where !waking:
            markSleeping()
        case "detected":
            markWaking()
        default:
            break
        }
    }

    mutating func applyClientState(state: String) {
        switch state {
        case "sleeping" where !waking:
            markSleeping()
        case "awake" where sleeping:
            markWaking()
        default:
            break
        }
    }
}

/// Qwen 实时语音连接来源。
/// 内置模式直接从 App 连接 DashScope Realtime；外部模式连接兼容
/// qwen-audio-agent 网关的 WebSocket 地址。
enum QwenGatewayMode: String, CaseIterable, Codable, Identifiable {
    case builtIn = "built_in"
    case external = "external"

    static let defaultMode: QwenGatewayMode = .builtIn

    /// ``embedded`` 是对内置模式的语义别名，便于调用方表达运行时语义。
    static var embedded: QwenGatewayMode { .builtIn }

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .builtIn: return "qwen.settings.mode.builtin"
        case .external: return "qwen.settings.mode.external"
        }
    }
}

enum QwenGatewayError: LocalizedError {
    case invalidMessage
    case invalidResponse
    case permissionRejected(String)
    case builtInAPIKeyMissing

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Invalid WebSocket message"
        case .invalidResponse:
            return "Invalid gateway response"
        case .permissionRejected(let message):
            return message
        case .builtInAPIKeyMissing:
            return "qwen.error.api.key".localized
        }
    }
}

/// 内置 DashScope Realtime 传输的配置（值类型，便于测试注入）。
struct QwenEmbeddedGatewayConfiguration: Equatable {
    let apiKey: String
    let baseURL: String
    let model: String
    let voice: String
}

/// 权限审批决策（对应网关 /api/permissions/:id 的 decision 取值）
enum QwenPermissionDecision: String, Equatable {
    case allow = "always"
    case deny = "reject"
}

/// 权限审批传输抽象（便于测试注入；QwenGatewayService 为默认实现）
protocol QwenPermissionResponding: AnyObject {
    func respondPermission(id: String, decision: QwenPermissionDecision) async throws -> QwenPermission
}

/// 重连策略：指数退避 + 连续失败上限（纯逻辑，便于测试）
struct QwenReconnectPolicy {
    let maxConsecutiveFailures: Int
    private(set) var consecutiveFailures = 0
    private(set) var nextDelay: TimeInterval = 0.5

    private let maxDelay: TimeInterval = 5.0

    /// 记录一次失败；返回 true 表示允许继续重连
    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        guard consecutiveFailures < maxConsecutiveFailures else { return false }
        nextDelay = min(maxDelay, nextDelay * 2)
        return true
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        nextDelay = 0.5
    }

    mutating func reset() {
        consecutiveFailures = 0
        nextDelay = 0.5
    }
}

/// WebSocket 抽象（便于测试注入）
protocol QwenGatewaySocket: AnyObject {
    func send(_ string: String, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Result<String, Error>) -> Void)
    func sendPing(completion: @escaping (Error?) -> Void)
    func close()
}

/// Internal transports can provide already-decoded events and avoid rebuilding
/// Gateway JSON only for the App to parse it again.
protocol QwenGatewayDecodedEventSocket: AnyObject {
    func receiveEvent(completion: @escaping (Result<QwenGatewayEvent, Error>) -> Void)
}

extension QwenGatewaySocket {
    func sendPing(completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
}

/// Thread-safe audio-only bridge used by the realtime upload queue. Control
/// events remain MainActor-isolated, while PCM serialization and delivery never
/// compete with SwiftUI updates.
final class QwenGatewayAudioTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: QwenGatewaySocket?

    func attach(_ socket: QwenGatewaySocket) {
        lock.lock()
        self.socket = socket
        lock.unlock()
    }

    func detach(_ socket: QwenGatewaySocket?) {
        lock.lock()
        if let socket, self.socket === socket {
            self.socket = nil
        } else if socket == nil {
            self.socket = nil
        }
        lock.unlock()
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completion: @escaping (Error?) -> Void
    ) {
        guard case .string(let text) = message else {
            completion(QwenGatewayError.invalidMessage)
            return
        }
        lock.lock()
        let socket = socket
        lock.unlock()
        guard let socket else {
            completion(URLError(.notConnectedToInternet))
            return
        }
        socket.send(text, completion: completion)
    }
}

private final class QwenGatewaySendSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSettled else { return false }
        isSettled = true
        return true
    }
}

@MainActor
final class QwenGatewayService: ObservableObject, QwenPermissionResponding {
    static let shared = QwenGatewayService()

    nonisolated let audioTransport = QwenGatewayAudioTransport()

    // MARK: - Published State

    @Published private(set) var connectionState: QwenGatewayConnectionState = .disconnected
    @Published private(set) var voiceState: String = "idle"

    /// 网关事件回调（与镜腿触发/上层 UI 解耦）
    var onEvent: ((QwenGatewayEvent) -> Void)?

    // MARK: - 配置（UserDefaults 持久化）

    private static let modeKey = "qwen_gateway_mode"

    /// 默认使用 App 内置 Gateway；旧版本没有该键时自然迁移到内置模式。
    @Published var mode: QwenGatewayMode

    @Published var gatewayHost: String
    @Published var gatewayPort: Int
    @Published var usesTLS: Bool
    @Published var sessionName: String

    // MARK: - Private

    private var socketFactory: (URLRequest) -> QwenGatewaySocket
    private var embeddedSocketFactory: (QwenEmbeddedGatewayConfiguration) -> QwenGatewaySocket
    private var embeddedConfigurationProvider: () -> QwenEmbeddedGatewayConfiguration?
    private let preferences: UserDefaults
    private let decodeQueue = DispatchQueue(
        label: "com.lunflux.hyper-meta-ai.qwen.gateway-decode",
        qos: .userInitiated
    )
    private var socket: QwenGatewaySocket?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatTimeoutTask: Task<Void, Never>?
    private var pendingHeartbeatID: UUID?
    private var isUserDisconnect = false
    private var reconnectPolicy: QwenReconnectPolicy
    private var realtimeConnectionStatus = QwenRealtimeConnectionStatus()
    private let heartbeatInterval: TimeInterval
    private let heartbeatTimeout: TimeInterval
    private let criticalControlTimeout: TimeInterval
    private var clientInstanceId = UUID().uuidString
    /// 是否允许网关输出语音回复（大脑模式关闭：仅作 ASR 听写）
    var outputEnabled = true

    init(
        preferences: UserDefaults = .standard,
        socketFactory: @escaping (URLRequest) -> QwenGatewaySocket = { request in
            QwenURLSessionWebSocket(request: request)
        },
        embeddedSocketFactory: @escaping (QwenEmbeddedGatewayConfiguration) -> QwenGatewaySocket = { configuration in
            QwenEmbeddedGatewaySocket(configuration: configuration)
        },
        embeddedConfigurationProvider: (() -> QwenEmbeddedGatewayConfiguration?)? = nil,
        maxReconnectAttempts: Int = 5,
        heartbeatInterval: TimeInterval = 12,
        heartbeatTimeout: TimeInterval = 5,
        criticalControlTimeout: TimeInterval = RealtimeProviderAudioProfiles.qwen.criticalControlSendTimeout
    ) {
        self.preferences = preferences
        self.mode = QwenGatewayMode(
            rawValue: preferences.string(forKey: Self.modeKey) ?? ""
        ) ?? QwenGatewayMode.defaultMode
        self.gatewayHost = preferences.string(forKey: "qwen_gateway_host") ?? "127.0.0.1"
        self.gatewayPort = preferences.integer(forKey: "qwen_gateway_port").nonZeroOrDefault(3101)
        self.usesTLS = preferences.bool(forKey: "qwen_gateway_uses_tls")
        self.sessionName = preferences.string(forKey: "qwen_gateway_session") ?? "main"
        self.socketFactory = socketFactory
        self.embeddedSocketFactory = embeddedSocketFactory
        self.embeddedConfigurationProvider = embeddedConfigurationProvider ?? {
            QwenGatewayService.currentEmbeddedConfiguration()
        }
        self.reconnectPolicy = QwenReconnectPolicy(
            maxConsecutiveFailures: maxReconnectAttempts
        )
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.criticalControlTimeout = criticalControlTimeout.isFinite
            ? max(0.001, criticalControlTimeout)
            : RealtimeProviderAudioProfiles.qwen.criticalControlSendTimeout
    }

    func saveSettings() {
        preferences.set(mode.rawValue, forKey: Self.modeKey)
        preferences.set(gatewayHost, forKey: "qwen_gateway_host")
        preferences.set(gatewayPort, forKey: "qwen_gateway_port")
        preferences.set(usesTLS, forKey: "qwen_gateway_uses_tls")
        preferences.set(sessionName, forKey: "qwen_gateway_session")
    }

    // MARK: - Connection

    /// The Gateway WebSocket can stay healthy while its realtime provider is
    /// unavailable or reconnecting. Callers use this transport signal instead
    /// of opening a second Gateway owner from provider-level state alone.
    var hasActiveTransport: Bool {
        socket != nil
    }

    func connect() {
        guard !hasActiveTransport else { return }
        if case .connecting = connectionState { return }
        guard !connectionState.isOnline else { return }
        isUserDisconnect = false
        reconnectPolicy.reset()
        reconnectTask?.cancel()
        connectOnce()
    }

    func disconnect() {
        isUserDisconnect = true
        reconnectTask?.cancel()
        receiveTask?.cancel()
        stopHeartbeat()
        let closingSocket = socket
        audioTransport.detach(closingSocket)
        closingSocket?.close()
        socket = nil
        voiceState = "idle"
        realtimeConnectionStatus.markDisconnected()
        publishRealtimeConnectionStatus()
        onEvent?(.gatewayDisconnected)
    }

    /// A timed-out audio send means the realtime stream can no longer meet its
    /// latency contract. Reconnect immediately instead of leaving a visually
    /// connected but silent session running.
    func recoverFromAudioTransportFailure() {
        guard socket != nil, !isUserDisconnect else { return }
        handleSocketClosed()
    }

    private func connectOnce() {
        guard !isUserDisconnect else { return }
        realtimeConnectionStatus.beginConnecting(resetLifecycle: true)
        publishRealtimeConnectionStatus()
        let socket: QwenGatewaySocket
        switch mode {
        case .builtIn:
            guard let configuration = embeddedConfigurationProvider() else {
                realtimeConnectionStatus.markUnavailable(
                    QwenGatewayError.builtInAPIKeyMissing.localizedDescription
                )
                publishRealtimeConnectionStatus()
                onEvent?(.error(message: QwenGatewayError.builtInAPIKeyMissing.localizedDescription))
                return
            }
            socket = embeddedSocketFactory(configuration)
        case .external:
            guard let url = webSocketURL else {
                realtimeConnectionStatus.markUnavailable("Invalid gateway URL")
                publishRealtimeConnectionStatus()
                return
            }
            socket = socketFactory(URLRequest(url: url))
        }
        self.socket = socket
        audioTransport.attach(socket)

        let connectPayload = QwenGatewayClientEvent.connect(
            timeZone: TimeZone.current.identifier,
            locale: Locale.current.identifier,
            voiceEnabled: outputEnabled,
            inputEnabled: true,
            outputEnabled: outputEnabled,
            clientType: "ios",
            clientLabel: "HyperMetaAI",
            clientInstanceId: clientInstanceId
        )
        send(connectPayload, via: socket)

        receiveLoop(on: socket)
        startHeartbeat(on: socket)
    }

    private func handleSocketClosed() {
        guard let closedSocket = self.socket else { return }
        stopHeartbeat()
        audioTransport.detach(closedSocket)
        socket = nil
        closedSocket.close()
        voiceState = "idle"
        realtimeConnectionStatus.markDisconnected()
        publishRealtimeConnectionStatus()
        onEvent?(.gatewayDisconnected)
        scheduleReconnectIfAllowed()
    }

    private func handleConnectionFailure(_ error: Error) {
        stopHeartbeat()
        realtimeConnectionStatus.markUnavailable(error.localizedDescription)
        publishRealtimeConnectionStatus()
        let failedSocket = socket
        audioTransport.detach(failedSocket)
        failedSocket?.close()
        socket = nil
        scheduleReconnectIfAllowed()
    }

    private func scheduleReconnectIfAllowed() {
        guard !isUserDisconnect else { return }
        guard reconnectPolicy.recordFailure() else {
            realtimeConnectionStatus.markUnavailable("qwen.error.reconnect.limit".localized)
            publishRealtimeConnectionStatus()
            onEvent?(.gatewayReconnectFailed)
            return
        }
        onEvent?(.gatewayReconnecting(
            attempt: reconnectPolicy.consecutiveFailures,
            maxAttempts: reconnectPolicy.maxConsecutiveFailures
        ))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.reconnectPolicy.nextDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !self.isUserDisconnect else { return }
            self.connectOnce()
        }
    }

    private func startHeartbeat(on socket: QwenGatewaySocket) {
        stopHeartbeat()
        guard heartbeatInterval > 0 else { return }
        heartbeatTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, self.socket === socket else { return }
                self.sendHeartbeat(on: socket)
            }
        }
    }

    private func sendHeartbeat(on socket: QwenGatewaySocket) {
        guard self.socket === socket, pendingHeartbeatID == nil else { return }
        let heartbeatID = UUID()
        pendingHeartbeatID = heartbeatID

        heartbeatTimeoutTask?.cancel()
        if heartbeatTimeout > 0 {
            heartbeatTimeoutTask = Task { [weak self, weak socket] in
                guard let self, let socket else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatTimeout * 1_000_000_000))
                guard !Task.isCancelled,
                      self.socket === socket,
                      self.pendingHeartbeatID == heartbeatID else { return }
                self.pendingHeartbeatID = nil
                self.handleSocketClosed()
            }
        }

        socket.sendPing { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket,
                      self.socket === socket,
                      self.pendingHeartbeatID == heartbeatID else { return }
                self.pendingHeartbeatID = nil
                self.heartbeatTimeoutTask?.cancel()
                self.heartbeatTimeoutTask = nil
                if error != nil {
                    self.handleSocketClosed()
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = nil
        pendingHeartbeatID = nil
    }

    // MARK: - Receive

    private func nextMessage(from socket: QwenGatewaySocket) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            socket.receive { result in
                switch result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func nextEvent(
        from socket: QwenGatewayDecodedEventSocket
    ) async throws -> QwenGatewayEvent {
        try await withCheckedThrowingContinuation { continuation in
            socket.receiveEvent { result in
                continuation.resume(with: result)
            }
        }
    }

    private func receiveLoop(on socket: QwenGatewaySocket) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard self.socket === socket else { return }
                let event: QwenGatewayEvent?
                do {
                    if let decodedSocket = socket as? QwenGatewayDecodedEventSocket {
                        event = try await self.nextEvent(from: decodedSocket)
                    } else {
                        let message = try await self.nextMessage(from: socket)
                        let receivedAt = ProcessInfo.processInfo.systemUptime
                        event = await self.decode(message, receivedAt: receivedAt)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.handleSocketClosed()
                    return
                }
                guard let event else { continue }
                guard !Task.isCancelled, self.socket === socket else { return }
                self.handle(event)
            }
        }
    }

    private func decode(
        _ message: String,
        receivedAt: TimeInterval
    ) async -> QwenGatewayEvent? {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                guard let data = message.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: QwenGatewayEventParser.parse(
                    json,
                    receivedAt: receivedAt
                ))
            }
        }
    }

    private func handle(_ event: QwenGatewayEvent) {
        switch event {
        case .voiceReady:
            realtimeConnectionStatus.markReady()
            publishRealtimeConnectionStatus()
            reconnectPolicy.recordSuccess()
        case .voiceConnection(let state, let message):
            realtimeConnectionStatus.applyVoiceConnection(state: state, message: message)
            publishRealtimeConnectionStatus()
            if state == "connected" {
                reconnectPolicy.recordSuccess()
            }
        case .voiceState(let state):
            voiceState = state
        case .voiceSleep(let state):
            realtimeConnectionStatus.applyVoiceSleep(state: state)
            publishRealtimeConnectionStatus()
        case .clientState(let state):
            realtimeConnectionStatus.applyClientState(state: state)
            publishRealtimeConnectionStatus()
        case .gatewayDisconnected:
            realtimeConnectionStatus.markDisconnected()
            publishRealtimeConnectionStatus()
        default:
            break
        }
        onEvent?(event)
    }

    // MARK: - Send

    var supportsDirectVision: Bool {
        mode == .builtIn
            && QwenRealtimeModelCatalog.selected.supportsImageInput
    }

    @discardableResult
    func sendImage(jpegData: Data) -> Bool {
        guard supportsDirectVision, connectionState.isOnline, !jpegData.isEmpty else { return false }
        send(QwenGatewayClientEvent.imageAppend(jpegBase64: jpegData.base64EncodedString()))
        return true
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(QwenGatewayClientEvent.textMessage(trimmed))
    }

    /// 打断当前回复。`playedMs` 为用户实际听到的音频毫秒数；内置网关会据此
    /// 补发 `conversation.item.truncate`，避免服务端保留用户没听到的内容。
    func interrupt(playedMs: Int? = nil) {
        sendControl(
            QwenGatewayClientEvent.interrupt(playedMs: playedMs),
            timeout: criticalControlTimeout
        )
    }

    func setInputMuted(_ muted: Bool) {
        sendControl(muted ? QwenGatewayClientEvent.inputMute() : QwenGatewayClientEvent.inputUnmute())
    }

    func notifyPlaybackStarted(responseId: String?) {
        sendControl(QwenGatewayClientEvent.playbackStarted(responseId: responseId))
    }

    func notifyPlaybackEnded(responseId: String?) {
        sendControl(QwenGatewayClientEvent.playbackEnded(responseId: responseId))
    }

    func notifyPlaybackCancelled(responseId: String?, reason: String? = nil) {
        sendControl(QwenGatewayClientEvent.playbackCancelled(
            responseId: responseId,
            reason: reason
        ))
    }

    // MARK: - 权限审批（HTTP）

    /// 请求网关进入休眠（语音前端暂停，等待唤醒词或客户端 wake 事件）
    func requestSleep() {
        sendControl(QwenGatewayClientEvent.sleep())
    }

    /// 请求网关唤醒（复用唤醒词检测之后的同一套重连与退避路径）
    func requestWake() {
        if case .sleeping = connectionState {
            realtimeConnectionStatus.markWaking()
            publishRealtimeConnectionStatus()
        }
        sendControl(QwenGatewayClientEvent.wake())
    }

    private func publishRealtimeConnectionStatus() {
        let nextState = realtimeConnectionStatus.connectionState
        if connectionState != nextState {
            connectionState = nextState
        }
    }

    /// 审批一个任务权限请求。成功后网关会回发 task.permission.resolved 事件。
    func respondPermission(
        id: String,
        decision: QwenPermissionDecision
    ) async throws -> QwenPermission {
        if mode == .builtIn {
            // 内置实时前端的权限决策由 App 侧审批链完成；返回本地已决状态，
            // 使 QwenVoiceSession 无需依赖一个不存在的本地 HTTP 端点。
            return QwenPermission(
                id: id,
                workId: nil,
                status: decision == .allow ? .approved : .denied,
                category: "local",
                summary: ""
            )
        }
        let url = Self.permissionEndpoint(
            host: gatewayHost,
            port: gatewayPort,
            usesTLS: usesTLS,
            id: id
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["decision": decision.rawValue]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0 }?["error"] as? String
                ?? "HTTP \(statusCode)"
            throw QwenGatewayError.permissionRejected(message)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let permission = QwenGatewayEventParser.parsePermission(json)
        else {
            throw QwenGatewayError.invalidResponse
        }
        return permission
    }

    /// 权限审批 HTTP 端点（纯函数，便于测试）
    static func permissionEndpoint(host: String, port: Int, usesTLS: Bool, id: String) -> URL {
        let scheme = usesTLS ? "https" : "http"
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return URL(string: "\(scheme)://\(host):\(port)/api/permissions/\(encoded)")!
    }

    private func send(_ payload: [String: Any]) {
        guard connectionState.isOnline, let socket else { return }
        send(payload, via: socket)
    }

    private func sendControl(
        _ payload: [String: Any],
        timeout: TimeInterval? = nil
    ) {
        guard let socket else { return }
        send(payload, via: socket, timeout: timeout)
    }

    private func send(
        _ payload: [String: Any],
        via socket: QwenGatewaySocket,
        timeout: TimeInterval? = nil
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        guard let timeout, timeout.isFinite, timeout > 0 else {
            socket.send(text) { [weak self, weak socket] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self,
                          let socket,
                          self.socket === socket,
                          !self.isUserDisconnect else { return }
                    self.handleConnectionFailure(error)
                }
            }
            return
        }

        let settlement = QwenGatewaySendSettlement()
        let timeoutNanoseconds = UInt64(
            min(max(timeout, 0.001), 60) * 1_000_000_000
        )
        Task { @MainActor [weak self, weak socket] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled,
                  settlement.claim(),
                  let self,
                  let socket,
                  self.socket === socket,
                  !self.isUserDisconnect else { return }
            self.handleConnectionFailure(URLError(.timedOut))
        }
        socket.send(text) { [weak self, weak socket] error in
            guard settlement.claim(), let error else { return }
            Task { @MainActor in
                guard let self,
                      let socket,
                      self.socket === socket,
                      !self.isUserDisconnect else { return }
                self.handleConnectionFailure(error)
            }
        }
    }

    // MARK: - URL

    private var webSocketURL: URL? {
        let scheme = usesTLS ? "wss" : "ws"
        let encodedSession = sessionName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionName
        return URL(string: "\(scheme)://\(gatewayHost):\(gatewayPort)/api/realtime?sessionId=\(encodedSession)")
    }

    /// 当前内置连接配置。API Key 复用设置页中保存的 DashScope Key，永不落入
    /// UserDefaults 或诊断文本。
    private static func currentEmbeddedConfiguration() -> QwenEmbeddedGatewayConfiguration? {
        let endpoint = APIProviderManager.staticAlibabaEndpoint
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: .alibaba, endpoint: endpoint),
              !apiKey.isEmpty else {
            return nil
        }
        let profile = QwenRealtimeModelCatalog.selected
        return QwenEmbeddedGatewayConfiguration(
            apiKey: apiKey,
            baseURL: endpoint.websocketURL,
            model: profile.id,
            voice: QwenRealtimeModelCatalog.voice(for: profile)
        )
    }

    /// 是否已配置内置模式所需的 DashScope Key。
    var isBuiltInAPIKeyConfigured: Bool {
        let endpoint = APIProviderManager.staticAlibabaEndpoint
        return APIKeyManager.shared.hasAPIKey(for: .alibaba, endpoint: endpoint)
    }

    /// 用于设置页和诊断摘要的安全显示值（不包含密钥）。
    var endpointDisplay: String {
        switch mode {
        case .builtIn:
            return "qwen.settings.mode.builtin".localized
        case .external:
            return "\(usesTLS ? "wss" : "ws")://\(gatewayHost):\(gatewayPort)"
        }
    }
}

// MARK: - URLSession 适配器

private final class QwenURLSessionWebSocket: QwenGatewaySocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.networkServiceType = .responsiveData
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        self.session = session
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ string: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(string), completionHandler: completion)
    }

    func receive(completion: @escaping (Result<String, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    completion(.success(text))
                case .data(let data):
                    completion(.success(String(data: data, encoding: .utf8) ?? ""))
                @unknown default:
                    completion(.failure(QwenGatewayError.invalidMessage))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func sendPing(completion: @escaping (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: completion)
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}

// MARK: - 内置 DashScope Realtime 适配器

/// 把 App 既有的 qwen-audio-agent 客户端事件转换为 DashScope Realtime 事件，
/// 再把提供方事件转换为统一的 QwenGatewayEvent。内置服务直接消费强类型事件，
/// 原有 JSON 接口继续供协议兼容与测试使用。
final class QwenEmbeddedGatewaySocket: QwenGatewaySocket, QwenGatewayDecodedEventSocket {
    private static let responseWatchdogQueue = DispatchQueue(
        label: "com.lunflux.hyper-meta-ai.qwen.response-start-watchdog",
        qos: .userInitiated
    )
    private static let officialResponseStartTimeout: TimeInterval = 30

    private struct DeferredClientEvent {
        let payload: [String: Any]
        let completion: ((Error?) -> Void)?
        let enqueuedAt: TimeInterval
        let maximumAge: TimeInterval?
    }

    private struct GatewayMessage {
        let payload: [String: Any]
        let event: QwenGatewayEvent
    }

    private let providerSocket: QwenGatewaySocket
    private let configuration: QwenEmbeddedGatewayConfiguration
    private let now: () -> TimeInterval
    private let responseStartTimeout: TimeInterval
    private let lock = NSLock()
    private var receiveWaiters: [(Result<GatewayMessage, Error>) -> Void] = []
    private var queuedMessages: [Result<GatewayMessage, Error>] = []
    private var deferredClientEvents: [DeferredClientEvent] = []
    private var connectPayload: [String: Any] = [:]
    private var isConfigured = false
    private var hasConnectPayload = false
    private var providerSessionCreated = false
    private var isClosed = false
    private var inputMuted = false
    private var isSleeping = false
    private var pendingTextItemIDs = Set<String>()
    private var activeProviderResponseID: String?
    private var responseStartWatchdog: DispatchWorkItem?
    private var responseStartWatchdogGeneration: UInt64 = 0
    /// 助手音频所在的 conversation item，用于打断时定位 `conversation.item.truncate`。
    /// 由 `response.audio.delta` 携带的 `item_id`/`content_index` 记录。
    private var activeAssistantAudioItemID: String?
    private var activeAssistantAudioContentIndex = 0

    private var modelProfile: QwenRealtimeModelProfile {
        QwenRealtimeModelCatalog.resolve(configuration.model)
    }

    convenience init(configuration: QwenEmbeddedGatewayConfiguration) {
        let endpoint = Self.realtimeURL(baseURL: configuration.baseURL, model: configuration.model)
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        self.init(
            configuration: configuration,
            providerSocket: QwenURLSessionWebSocket(request: request)
        )
    }

    init(
        configuration: QwenEmbeddedGatewayConfiguration,
        providerSocket: QwenGatewaySocket,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        responseStartTimeout: TimeInterval = QwenEmbeddedGatewaySocket.officialResponseStartTimeout
    ) {
        self.configuration = configuration
        self.providerSocket = providerSocket
        self.now = now
        self.responseStartTimeout = responseStartTimeout.isFinite
            ? max(0, responseStartTimeout)
            : Self.officialResponseStartTimeout
        receiveProviderMessage()
    }

    func send(_ string: String, completion: @escaping (Error?) -> Void) {
        guard let data = string.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else {
            completion(QwenGatewayError.invalidMessage)
            return
        }
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else {
            completion(URLError(.networkConnectionLost))
            return
        }

        switch type {
        case "connect":
            lock.lock()
            connectPayload = payload
            hasConnectPayload = true
            let configured = isConfigured
            let shouldConfigure = providerSessionCreated && !configured
            lock.unlock()
            if shouldConfigure { sendSessionUpdate() }
            if configured { flushDeferredClientEvents() }
        case "audio.append":
            lock.lock()
            let acceptsInput = !inputMuted && !isSleeping
            lock.unlock()
            guard acceptsInput, let audio = payload["audio"] as? String else {
                completion(nil)
                return
            }
            enqueueOrSend(
                ["type": "input_audio_buffer.append", "audio": audio],
                completion: completion,
                maximumAge: RealtimeProviderAudioProfiles.qwen.maximumQueuedInputAge
            )
            return
        case "image.append":
            // The embedded DashScope transport supports the model's native image
            // capability; the external qwen-audio-agent transport remains text/audio-only.
            guard modelProfile.supportsImageInput,
                  let image = payload["image"] as? String,
                  !image.isEmpty else {
                completion(nil)
                return
            }
            enqueueOrSend(["type": "input_image_buffer.append", "image": image])
        case "text.message":
            guard let text = payload["text"] as? String, !text.isEmpty else {
                completion(nil)
                return
            }
            let item: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "id": "item_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]]
                ]
            ]
            if let itemID = (item["item"] as? [String: Any])?["id"] as? String {
                lock.lock(); pendingTextItemIDs.insert(itemID); lock.unlock()
            }
            enqueueOrSend(item)
        case "input.mute":
            lock.lock(); inputMuted = true; lock.unlock()
        case "input.unmute":
            lock.lock(); inputMuted = false; lock.unlock()
        case "interrupt":
            let responseID = currentProviderResponseID()
            let audioItem = currentAssistantAudioItem()
            lock.lock()
            let configured = isConfigured
            lock.unlock()
            let playbackClear: [String: Any] = [
                "type": "playback.clear",
                "reason": "client_interrupt"
            ]
            emit(playbackClear)
            var responseInterrupted: [String: Any] = ["type": "response.interrupted"]
            if let responseID {
                responseInterrupted["responseId"] = responseID
            }
            emit(responseInterrupted)
            clearProviderResponseID(responseID)
            clearAssistantAudioItem()
            guard configured else {
                completion(nil)
                return
            }
            // 先截断再取消：告诉服务端用户实际只听到了 playedMs 毫秒，
            // 否则模型上下文会保留用户从未听到的那段回复，导致后续对话
            // 基于"它以为自己说过的话"推理。截断必须在 cancel 之前发出，
            // 因为 cancel 之后该 item 就不再接受截断了。
            if let audioItem, let playedMs = payload["playedMs"] as? Int, playedMs >= 0 {
                sendProvider([
                    "type": "conversation.item.truncate",
                    "item_id": audioItem.itemID,
                    "content_index": audioItem.contentIndex,
                    "audio_end_ms": playedMs
                ]) { _ in }
            }
            sendProvider(["type": "response.cancel"], completion: completion)
            return
        case "sleep":
            lock.lock()
            isSleeping = true
            activeProviderResponseID = nil
            activeAssistantAudioItemID = nil
            activeAssistantAudioContentIndex = 0
            lock.unlock()
            enqueueOrSend(["type": "response.cancel"])
            emit(["type": "client.state", "state": "sleeping"])
            emit(["type": "voice.connection", "state": "sleeping"])
            emit(["type": "voice.sleep", "state": "sleeping"])
            emit(["type": "voice.state", "state": "idle"])
        case "wake":
            lock.lock()
            isSleeping = false
            let configured = isConfigured
            lock.unlock()
            emit(["type": "voice.sleep", "state": "detected"])
            emit(["type": "voice.connection", "state": "connecting"])
            if configured {
                emit(["type": "voice.connection", "state": "connected"])
                emit(["type": "voice.ready", "inputSampleRate": modelProfile.inputSampleRate])
                emit(["type": "voice.sleep", "state": "awake"])
            }
            emit(["type": "voice.state", "state": "listening"])
        case "playback.started":
            _ = rememberProviderResponseID(payload["responseId"] as? String)
        case "playback.ended", "playback.cancelled":
            clearProviderResponseID(Self.normalizedResponseID(payload["responseId"] as? String))
        default:
            break
        }
        completion(nil)
    }

    func receive(completion: @escaping (Result<String, Error>) -> Void) {
        receiveMessage { result in
            switch result {
            case .success(let message):
                guard let data = try? JSONSerialization.data(withJSONObject: message.payload),
                      let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(QwenGatewayError.invalidMessage))
                    return
                }
                completion(.success(text))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func receiveEvent(completion: @escaping (Result<QwenGatewayEvent, Error>) -> Void) {
        receiveMessage { result in
            completion(result.map(\.event))
        }
    }

    private func receiveMessage(
        completion: @escaping (Result<GatewayMessage, Error>) -> Void
    ) {
        lock.lock()
        if !queuedMessages.isEmpty {
            let message = queuedMessages.removeFirst()
            lock.unlock()
            completion(message)
            return
        }
        if isClosed {
            lock.unlock()
            completion(.failure(URLError(.networkConnectionLost)))
            return
        }
        receiveWaiters.append(completion)
        lock.unlock()
    }

    func sendPing(completion: @escaping (Error?) -> Void) {
        providerSocket.sendPing(completion: completion)
    }

    func close() {
        cancelResponseStartWatchdog()
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        activeProviderResponseID = nil
        activeAssistantAudioItemID = nil
        activeAssistantAudioContentIndex = 0
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        let deferred = deferredClientEvents
        deferredClientEvents.removeAll()
        lock.unlock()
        providerSocket.close()
        waiters.forEach { $0(.failure(URLError(.cancelled))) }
        deferred.forEach { $0.completion?(URLError(.cancelled)) }
    }

    private func receiveProviderMessage() {
        providerSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.handleProviderMessage(text)
                self.receiveProviderMessage()
            case .failure(let error):
                self.closeWith(error: error)
            }
        }
    }

    private func closeWith(error: Error) {
        cancelResponseStartWatchdog()
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        activeProviderResponseID = nil
        activeAssistantAudioItemID = nil
        activeAssistantAudioContentIndex = 0
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        let deferred = deferredClientEvents
        deferredClientEvents.removeAll()
        lock.unlock()
        waiters.forEach { $0(.failure(error)) }
        deferred.forEach { $0.completion?(error) }
    }

    private func handleProviderMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == "session.created" {
            lock.lock()
            providerSessionCreated = true
            let shouldConfigure = hasConnectPayload
            lock.unlock()
            if shouldConfigure { sendSessionUpdate() }
            return
        }
        if type == "session.updated" {
            lock.lock()
            isConfigured = true
            activeProviderResponseID = nil
            activeAssistantAudioItemID = nil
            activeAssistantAudioContentIndex = 0
            lock.unlock()
            emit(["type": "voice.ready", "inputSampleRate": modelProfile.inputSampleRate])
            emit(["type": "voice.connection", "state": "connected"])
            flushDeferredClientEvents()
            return
        }

        if type == "conversation.item.created",
           let itemID = (json["item"] as? [String: Any])?["id"] as? String {
            lock.lock()
            var needsResponse = pendingTextItemIDs.remove(itemID) != nil
            // Qwen3.5 Omni may replace the client item ID. Upstream v1.9+
            // acknowledges the sole pending item in that case.
            if !needsResponse,
               modelProfile.family == .omni,
               pendingTextItemIDs.count == 1,
               let pendingID = pendingTextItemIDs.first {
                pendingTextItemIDs.remove(pendingID)
                needsResponse = true
            }
            lock.unlock()
            if needsResponse { sendProvider(["type": "response.create"]) }
            return
        }

        if type.hasPrefix("response.")
            || type == "error"
            || type == "conversation.item.input_audio_transcription.failed"
            || type == "input_audio_buffer.speech_started" {
            cancelResponseStartWatchdog()
        }

        switch type {
        case "input_audio_buffer.speech_started":
            emit(["type": "turn.started", "turnId": json["item_id"] as? String ?? ""])
            emit(["type": "voice.state", "state": "listening"])
        case "input_audio_buffer.speech_stopped":
            if json["reason"] as? String == "turn_invalid" {
                emit(["type": "transcript.discard"])
                emit(["type": "voice.state", "state": "idle"])
                return
            }
            emit(["type": "voice.state", "state": "thinking"])
            scheduleResponseStartWatchdog()
        case "input_audio_buffer.committed":
            emit(["type": "voice.state", "state": "thinking"])
        case "conversation.item.input_audio_transcription.delta",
             "conversation.item.input_audio_transcription.text":
            let value = (json["text"] as? String ?? "") + (json["stash"] as? String ?? "")
            emit(["type": "transcript.delta", "role": "user", "content": value])
        case "conversation.item.input_audio_transcription.completed":
            emit([
                "type": "transcript.final",
                "role": "user",
                "content": json["transcript"] as? String ?? ""
            ])
        case "conversation.item.input_audio_transcription.failed":
            emit(["type": "transcript.discard"])
            emit(["type": "voice.state", "state": "idle"])
        case "response.created":
            if !outputIsEnabled {
                // 听写转发模式仍需让提供方完成 ASR；只抑制音频/助手文本事件，
                // 不取消响应，避免与 Smart Turn 的自动响应产生竞态。
                return
            }
            let responseID = rememberProviderResponseID(from: json)
            emit(["type": "response.started", "responseId": responseID ?? ""])
        case "response.audio.delta", "response.output_audio.delta":
            guard outputIsEnabled else { return }
            let responseID = providerResponseID(for: json)
            rememberAssistantAudioItem(from: json)
            var audioDelta: [String: Any] = [
                "type": "audio.delta",
                "audio": json["delta"] as? String ?? "",
                "sampleRate": modelProfile.outputSampleRate
            ]
            if let responseID {
                audioDelta["responseId"] = responseID
            }
            emit(audioDelta)
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta",
             "response.text.delta":
            guard outputIsEnabled else { return }
            emit([
                "type": "transcript.delta",
                "role": "assistant",
                "content": json["delta"] as? String ?? ""
            ])
        case "response.audio_transcript.done", "response.output_audio_transcript.done",
             "response.text.done":
            guard outputIsEnabled else { return }
            emit([
                "type": "transcript.final",
                "role": "assistant",
                "content": (json["transcript"] as? String)
                    ?? (json["text"] as? String)
                    ?? ""
            ])
        case "response.audio.done", "response.output_audio.done":
            guard outputIsEnabled else { return }
            let responseID = providerResponseID(for: json)
            var audioDone: [String: Any] = ["type": "audio.done"]
            if let responseID {
                audioDone["responseId"] = responseID
            }
            emit(audioDone)
        case "response.done":
            let responseID = providerResponseID(for: json)
            clearAssistantAudioItem()
            if outputIsEnabled {
                var audioDone: [String: Any] = ["type": "audio.done"]
                if let responseID {
                    audioDone["responseId"] = responseID
                }
                emit(audioDone)
            }
            emit(["type": "voice.state", "state": "idle"])
            if let failure = Self.responseFailureMessage(json) {
                emit(["type": "error", "message": failure])
            }
        case "error":
            let error = json["error"] as? [String: Any]
            emit(["type": "error", "message": error?["message"] as? String ?? "Realtime provider error"])
        default:
            break
        }
    }

    /// Mirrors qwen-audio-agent's response-start watchdog: a valid speech turn
    /// must produce response activity within 30 seconds or the provider socket
    /// is recycled instead of leaving the client in an endless listening state.
    private func scheduleResponseStartWatchdog() {
        guard responseStartTimeout > 0 else { return }

        lock.lock()
        responseStartWatchdog?.cancel()
        responseStartWatchdogGeneration &+= 1
        let generation = responseStartWatchdogGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.responseStartTimedOut(generation: generation)
        }
        responseStartWatchdog = workItem
        lock.unlock()

        Self.responseWatchdogQueue.asyncAfter(
            deadline: .now() + responseStartTimeout,
            execute: workItem
        )
    }

    private func cancelResponseStartWatchdog() {
        lock.lock()
        responseStartWatchdogGeneration &+= 1
        let workItem = responseStartWatchdog
        responseStartWatchdog = nil
        lock.unlock()
        workItem?.cancel()
    }

    private func responseStartTimedOut(generation: UInt64) {
        lock.lock()
        guard !isClosed,
              responseStartWatchdogGeneration == generation,
              responseStartWatchdog != nil else {
            lock.unlock()
            return
        }
        responseStartWatchdog = nil
        lock.unlock()

        emit([
            "type": "error",
            "message": "qwen.error.response.start.timeout".localized
        ])
        emit(["type": "voice.state", "state": "idle"])
        providerSocket.close()
        closeWith(error: URLError(.timedOut))
    }

    private static func responseFailureMessage(_ json: [String: Any]) -> String? {
        guard let response = json["response"] as? [String: Any],
              let status = response["status"] as? String,
              ["failed", "incomplete"].contains(status) else {
            return nil
        }
        let details = response["status_details"] as? [String: Any]
        let error = details?["error"] as? [String: Any]
        return error?["message"] as? String
            ?? details?["reason"] as? String
            ?? "Realtime response \(status)."
    }

    private func sendSessionUpdate() {
        lock.lock()
        let payload = connectPayload
        lock.unlock()
        let outputEnabled = payload["outputEnabled"] as? Bool ?? true
        let inputEnabled = payload["inputEnabled"] as? Bool ?? true
        let profile = modelProfile
        let configuredVoice = configuration.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        var session: [String: Any] = [
            "modalities": outputEnabled ? ["text", "audio"] : ["text"],
            "voice": configuredVoice.isEmpty ? profile.defaultVoice : configuredVoice,
            "input_audio_format": "pcm",
            "output_audio_format": "pcm"
        ]
        session["turn_detection"] = inputEnabled
            ? ["type": profile.turnDetectionType]
            : NSNull()
        if let instructions = AgentSystemPromptBuilder.build(), !instructions.isEmpty {
            session["instructions"] = instructions
        }
        sendProvider(["type": "session.update", "session": session])
    }

    private func enqueueOrSend(
        _ event: [String: Any],
        completion: ((Error?) -> Void)? = nil,
        maximumAge: TimeInterval? = nil
    ) {
        let enqueuedAt = now()
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            completion?(URLError(.networkConnectionLost))
            return
        }
        let configured = isConfigured
        if !configured {
            deferredClientEvents.append(
                DeferredClientEvent(
                    payload: event,
                    completion: completion,
                    enqueuedAt: enqueuedAt,
                    maximumAge: maximumAge
                )
            )
        }
        lock.unlock()
        if configured { sendProvider(event, completion: completion) }
    }

    private func flushDeferredClientEvents() {
        lock.lock()
        guard isConfigured, !deferredClientEvents.isEmpty else {
            lock.unlock()
            return
        }
        let events = deferredClientEvents
        deferredClientEvents.removeAll()
        lock.unlock()
        let flushedAt = now()
        events.forEach { event in
            if let maximumAge = event.maximumAge {
                let age = flushedAt - event.enqueuedAt
                if !age.isFinite || age > maximumAge {
                    event.completion?(URLError(.timedOut))
                    return
                }
            }
            sendProvider(event.payload, completion: event.completion)
        }
    }

    private func sendProvider(
        _ event: [String: Any],
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            completion?(QwenGatewayError.invalidMessage)
            return
        }
        providerSocket.send(text) { error in
            completion?(error)
        }
    }

    private func emit(_ event: [String: Any]) {
        guard let decodedEvent = QwenGatewayEventParser.parse(event, receivedAt: now()) else {
            return
        }
        let message = GatewayMessage(payload: event, event: decodedEvent)
        lock.lock()
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            lock.unlock()
            waiter(.success(message))
        } else {
            queuedMessages.append(.success(message))
            lock.unlock()
        }
    }

    static func realtimeURL(baseURL: String, model: String) -> URL {
        let separator = baseURL.contains("?") ? "&" : "?"
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        return URL(string: "\(baseURL)\(separator)model=\(encoded)")!
    }

    private static func responseID(from json: [String: Any]) -> String {
        json["response_id"] as? String
            ?? (json["response"] as? [String: Any])?["id"] as? String
            ?? json["id"] as? String
            ?? ""
    }

    private static func normalizedResponseID(_ responseID: String?) -> String? {
        let value = responseID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func rememberProviderResponseID(_ responseID: String?) -> String? {
        guard let value = Self.normalizedResponseID(responseID) else { return nil }
        lock.lock()
        activeProviderResponseID = value
        lock.unlock()
        return value
    }

    private func rememberProviderResponseID(from json: [String: Any]) -> String? {
        rememberProviderResponseID(Self.responseID(from: json))
    }

    private func currentProviderResponseID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeProviderResponseID
    }

    private func providerResponseID(for json: [String: Any]) -> String? {
        rememberProviderResponseID(from: json) ?? currentProviderResponseID()
    }

    private func clearProviderResponseID(_ responseID: String?) {
        lock.lock()
        if responseID == nil || activeProviderResponseID == responseID {
            activeProviderResponseID = nil
        }
        lock.unlock()
    }

    /// 记录当前助手音频所属的 conversation item，供打断时截断使用。
    private func rememberAssistantAudioItem(from json: [String: Any]) {
        guard let itemID = Self.normalizedResponseID(json["item_id"] as? String) else { return }
        let contentIndex = json["content_index"] as? Int ?? 0
        lock.lock()
        activeAssistantAudioItemID = itemID
        activeAssistantAudioContentIndex = contentIndex
        lock.unlock()
    }

    private func currentAssistantAudioItem() -> (itemID: String, contentIndex: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let itemID = activeAssistantAudioItemID else { return nil }
        return (itemID, activeAssistantAudioContentIndex)
    }

    private func clearAssistantAudioItem() {
        lock.lock()
        activeAssistantAudioItemID = nil
        activeAssistantAudioContentIndex = 0
        lock.unlock()
    }

    private var outputIsEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectPayload["outputEnabled"] as? Bool ?? true
    }
}
