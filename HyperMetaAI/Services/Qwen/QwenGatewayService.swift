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
    case failed(String)

    var isOnline: Bool {
        if case .connected = self { return true }
        return false
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
    func close()
}

@MainActor
final class QwenGatewayService: ObservableObject, QwenPermissionResponding {
    static let shared = QwenGatewayService()

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
    private var socket: QwenGatewaySocket?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isUserDisconnect = false
    private var reconnectPolicy: QwenReconnectPolicy
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
        maxReconnectAttempts: Int = 5
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
    }

    func saveSettings() {
        preferences.set(mode.rawValue, forKey: Self.modeKey)
        preferences.set(gatewayHost, forKey: "qwen_gateway_host")
        preferences.set(gatewayPort, forKey: "qwen_gateway_port")
        preferences.set(usesTLS, forKey: "qwen_gateway_uses_tls")
        preferences.set(sessionName, forKey: "qwen_gateway_session")
    }

    // MARK: - Connection

    func connect() {
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
        socket?.close()
        socket = nil
        voiceState = "idle"
        connectionState = .disconnected
        onEvent?(.gatewayDisconnected)
    }

    private func connectOnce() {
        guard !isUserDisconnect else { return }
        connectionState = .connecting
        let socket: QwenGatewaySocket
        switch mode {
        case .builtIn:
            guard let configuration = embeddedConfigurationProvider() else {
                connectionState = .failed(QwenGatewayError.builtInAPIKeyMissing.localizedDescription)
                onEvent?(.error(message: QwenGatewayError.builtInAPIKeyMissing.localizedDescription))
                return
            }
            socket = embeddedSocketFactory(configuration)
        case .external:
            guard let url = webSocketURL else {
                connectionState = .failed("Invalid gateway URL")
                return
            }
            socket = socketFactory(URLRequest(url: url))
        }
        self.socket = socket

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
    }

    private func handleSocketClosed() {
        guard self.socket != nil else { return }
        socket = nil
        voiceState = "idle"
        connectionState = .disconnected
        onEvent?(.gatewayDisconnected)
        scheduleReconnectIfAllowed()
    }

    private func handleConnectionFailure(_ error: Error) {
        connectionState = .failed(error.localizedDescription)
        socket?.close()
        socket = nil
        scheduleReconnectIfAllowed()
    }

    private func scheduleReconnectIfAllowed() {
        guard !isUserDisconnect else { return }
        guard reconnectPolicy.recordFailure() else {
            connectionState = .failed("qwen.error.reconnect.limit".localized)
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

    private func receiveLoop(on socket: QwenGatewaySocket) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard self.socket === socket else { return }
                let message: String
                do {
                    message = try await self.nextMessage(from: socket)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.handleSocketClosed()
                    return
                }
                guard let data = message.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = QwenGatewayEventParser.parse(json)
                else {
                    continue
                }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: QwenGatewayEvent) {
        switch event {
        case .voiceReady:
            connectionState = .connected
            reconnectPolicy.recordSuccess()
        case .voiceConnection(let state, _):
            if state == "connected" {
                connectionState = .connected
                reconnectPolicy.recordSuccess()
            } else if state == "unavailable" {
                connectionState = .failed("Voice front end unavailable")
            }
        case .voiceState(let state):
            voiceState = state
        case .gatewayDisconnected:
            connectionState = .disconnected
        default:
            break
        }
        onEvent?(event)
    }

    // MARK: - Send

    func sendAudio(pcmData: Data) {
        send(QwenGatewayClientEvent.audioAppend(pcmBase64: pcmData.base64EncodedString()))
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(QwenGatewayClientEvent.textMessage(trimmed))
    }

    func interrupt() {
        send(QwenGatewayClientEvent.interrupt())
    }

    func setInputMuted(_ muted: Bool) {
        send(muted ? QwenGatewayClientEvent.inputMute() : QwenGatewayClientEvent.inputUnmute())
    }

    func notifyPlaybackStarted(responseId: String?) {
        send(QwenGatewayClientEvent.playbackStarted(responseId: responseId))
    }

    func notifyPlaybackEnded(responseId: String?) {
        send(QwenGatewayClientEvent.playbackEnded(responseId: responseId))
    }

    func notifyPlaybackCancelled(responseId: String?) {
        send(QwenGatewayClientEvent.playbackCancelled(responseId: responseId))
    }

    // MARK: - 权限审批（HTTP）

    /// 请求网关进入休眠（语音前端暂停，等待唤醒词或客户端 wake 事件）
    func requestSleep() {
        send(QwenGatewayClientEvent.sleep())
    }

    /// 请求网关唤醒（复用唤醒词检测之后的同一套重连与退避路径）
    func requestWake() {
        send(QwenGatewayClientEvent.wake())
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

    private func send(_ payload: [String: Any], via socket: QwenGatewaySocket) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        socket.send(text) { _ in }
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
        return QwenEmbeddedGatewayConfiguration(
            apiKey: apiKey,
            baseURL: endpoint.websocketURL,
            model: QwenRealtimeModelCatalog.selected.id,
            voice: UserDefaults.standard.string(forKey: "qwen_realtime_voice") ?? "longanqian"
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
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let session = URLSession(configuration: .default)
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

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - 内置 DashScope Realtime 适配器

/// 把 App 既有的 qwen-audio-agent 客户端事件转换为 DashScope Realtime 事件，
/// 再把提供方事件转换回 QwenGatewayEvent JSON。这样上层语音会话无需知道连接
/// 来源，外部网关协议也保持完全兼容。
final class QwenEmbeddedGatewaySocket: QwenGatewaySocket {
    private let providerSocket: QwenGatewaySocket
    private let configuration: QwenEmbeddedGatewayConfiguration
    private let lock = NSLock()
    private var receiveWaiters: [(Result<String, Error>) -> Void] = []
    private var queuedMessages: [Result<String, Error>] = []
    private var deferredClientEvents: [[String: Any]] = []
    private var connectPayload: [String: Any] = [:]
    private var isConfigured = false
    private var hasConnectPayload = false
    private var providerSessionCreated = false
    private var isClosed = false
    private var inputMuted = false
    private var pendingTextItemIDs = Set<String>()

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
        providerSocket: QwenGatewaySocket
    ) {
        self.configuration = configuration
        self.providerSocket = providerSocket
        receiveProviderMessage()
    }

    func send(_ string: String, completion: @escaping (Error?) -> Void) {
        guard let data = string.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else {
            completion(QwenGatewayError.invalidMessage)
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
            let acceptsInput = !inputMuted
            lock.unlock()
            guard acceptsInput, let audio = payload["audio"] as? String else {
                completion(nil)
                return
            }
            enqueueOrSend(["type": "input_audio_buffer.append", "audio": audio])
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
            enqueueOrSend(["type": "response.cancel"])
            emit(["type": "playback.clear", "reason": "client_interrupt"])
            emit(["type": "response.interrupted"])
        case "sleep":
            enqueueOrSend(["type": "response.cancel"])
            emit(["type": "client.state", "state": "sleeping"])
            emit(["type": "voice.state", "state": "idle"])
        case "wake":
            emit(["type": "client.state", "state": "awake"])
            emit(["type": "voice.state", "state": "listening"])
        case "playback.started", "playback.ended", "playback.cancelled":
            // DashScope 不需要客户端播放回执。
            break
        default:
            break
        }
        completion(nil)
    }

    func receive(completion: @escaping (Result<String, Error>) -> Void) {
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

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        lock.unlock()
        providerSocket.close()
        waiters.forEach { $0(.failure(URLError(.cancelled))) }
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
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0(.failure(error)) }
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
            lock.lock(); isConfigured = true; lock.unlock()
            emit(["type": "voice.ready", "inputSampleRate": 16_000])
            emit(["type": "voice.connection", "state": "connected"])
            flushDeferredClientEvents()
            return
        }

        if type == "conversation.item.created",
           let itemID = (json["item"] as? [String: Any])?["id"] as? String {
            lock.lock()
            let needsResponse = pendingTextItemIDs.remove(itemID) != nil
            lock.unlock()
            if needsResponse { sendProvider(["type": "response.create"]) }
            return
        }

        switch type {
        case "input_audio_buffer.speech_started":
            emit(["type": "turn.started", "turnId": json["item_id"] as? String ?? ""])
            emit(["type": "voice.state", "state": "listening"])
        case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed":
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
        case "response.created":
            if !outputIsEnabled {
                // 听写转发模式仍需让提供方完成 ASR；只抑制音频/助手文本事件，
                // 不取消响应，避免与 Smart Turn 的自动响应产生竞态。
                return
            }
            emit(["type": "response.started", "responseId": Self.responseID(from: json)])
        case "response.audio.delta", "response.output_audio.delta":
            guard outputIsEnabled else { return }
            emit([
                "type": "audio.delta",
                "audio": json["delta"] as? String ?? "",
                "sampleRate": 24_000,
                "responseId": Self.responseID(from: json)
            ])
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
            emit(["type": "audio.done", "responseId": Self.responseID(from: json)])
        case "response.done":
            guard outputIsEnabled else { return }
            emit(["type": "audio.done", "responseId": Self.responseID(from: json)])
            emit(["type": "voice.state", "state": "idle"])
        case "error":
            let error = json["error"] as? [String: Any]
            emit(["type": "error", "message": error?["message"] as? String ?? "Realtime provider error"])
        default:
            break
        }
    }

    private func sendSessionUpdate() {
        lock.lock()
        let payload = connectPayload
        lock.unlock()
        let outputEnabled = payload["outputEnabled"] as? Bool ?? true
        let inputEnabled = payload["inputEnabled"] as? Bool ?? true
        var session: [String: Any] = [
            "modalities": outputEnabled ? ["text", "audio"] : ["text"],
            "voice": configuration.voice,
            "input_audio_format": "pcm",
            "output_audio_format": "pcm"
        ]
        session["turn_detection"] = inputEnabled ? ["type": "smart_turn"] : NSNull()
        if let instructions = AgentSystemPromptBuilder.build(), !instructions.isEmpty {
            session["instructions"] = instructions
        }
        sendProvider(["type": "session.update", "session": session])
    }

    private func enqueueOrSend(_ event: [String: Any]) {
        lock.lock()
        let configured = isConfigured
        if !configured {
            deferredClientEvents.append(event)
        }
        lock.unlock()
        if configured { sendProvider(event) }
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
        events.forEach(sendProvider)
    }

    private func sendProvider(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        providerSocket.send(text) { _ in }
    }

    private func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            lock.unlock()
            waiter(.success(text))
        } else {
            queuedMessages.append(.success(text))
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

    private var outputIsEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectPayload["outputEnabled"] as? Bool ?? true
    }
}
