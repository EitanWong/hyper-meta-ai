/*
 * OpenClaw Node Service
 * 将 Ray-Ban Meta 眼镜作为 OpenClaw 设备节点
 * 通过 WebSocket 连接到本地 Gateway，暴露摄像头和音频能力
 */

import Foundation
import UIKit

// MARK: - Connection State

enum OpenClawConnectionState: Equatable {
    case disconnected
    case connecting
    case waitingForPairing
    case connected
    case error(String)

    static func == (lhs: OpenClawConnectionState, rhs: OpenClawConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.waitingForPairing, .waitingForPairing),
             (.connected, .connected):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct OpenClawGatewayEndpoint: Equatable {
    let host: String
    let port: Int
    let usesTLS: Bool

    var url: URL? {
        let normalizedHost = normalizedHost
        guard !normalizedHost.isEmpty, (1...65535).contains(port) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = usesTLS ? "wss" : "ws"
        components.host = normalizedHost
        components.port = port
        return components.url
    }

    private var normalizedHost: String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        for prefix in ["ws://", "wss://"] where lowercased.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - OpenClaw Node Service

@MainActor
final class OpenClawNodeService: NSObject, ObservableObject {
    static let shared = OpenClawNodeService()

    // MARK: - Published State

    @Published var connectionState: OpenClawConnectionState = .disconnected
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "openclaw_enabled")
    @Published var gatewayHost = UserDefaults.standard.string(forKey: "openclaw_host") ?? "127.0.0.1"
    @Published var gatewayPort = UserDefaults.standard.integer(forKey: "openclaw_port").nonZeroOrDefault(18789)
    @Published var usesTLS = UserDefaults.standard.bool(forKey: "openclaw_uses_tls")

    // MARK: - Private Properties

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var commandRouter: OpenClawCommandRouter?
    private var reconnectTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var connectRequestID: String?
    private let nodeId: String
    private var pendingNonce: String?
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private let deviceIdentity: OpenClawDeviceIdentity

    // Gateway token stored in Keychain
    private let keychainService = "com.smartview.glassai.openclaw"
    private let keychainAccount = "gateway_token"

    // Protocol
    private static let protocolVersion = 3
    private static let tickInterval: TimeInterval = 15
    private static let handshakeTimeout: TimeInterval = 10
    private static let maxReconnectAttempts = 5

    // Supported commands
    private static let commands = [
        "camera.snap",
        "camera.list",
        "device.status",
        "device.info",
        "vision.ocr",
        "vision.scene",
        "vision.objects"
    ]

    private static let caps = [
        "camera"
    ]

    // MARK: - Init

    private override init() {
        let identity = OpenClawDeviceIdentityStore.loadOrCreate()
        self.deviceIdentity = identity
        // The protocol result must use the same stable identity advertised in
        // the signed connect request.
        self.nodeId = identity.deviceId
        super.init()
    }

    // MARK: - Public Methods

    func setCommandRouter(_ router: OpenClawCommandRouter) {
        self.commandRouter = router
    }

    var nodeIdentifier: String {
        nodeId
    }

    func connect() {
        guard connectionState != .connecting else { return }
        guard connectionState != .connected else { return }

        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownConnection()
        shouldReconnect = true
        isEnabled = true
        saveSettings()
        startConnection()
    }

    /// Send chat message to OpenClaw AI (with optional image)
    func sendChatMessage(_ text: String, image: UIImage? = nil) {
        guard connectionState == .connected else { return }

        var attachments: [[String: Any]] = []
        if let img = image, let jpegData = img.jpegData(compressionQuality: 0.7) {
            attachments.append([
                "type": "image",
                "mimeType": "image/jpeg",
                "content": jpegData.base64EncodedString()
            ])
        }

        var params: [String: Any] = [
            "sessionKey": chatSessionKey,
            "message": text,
            "idempotencyKey": UUID().uuidString
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }

        let frame: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "chat.send",
            "params": params
        ]
        sendJSON(frame)
        print("[OpenClaw] Sent chat message (\(text.utf8.count) bytes)")
    }

    /// 当前聊天会话标识（持久化；切换即开启新会话，旧会话仍在网关侧保留）
    @Published var chatSessionKey: String = {
        UserDefaults.standard.string(forKey: "openclaw_chat_session") ?? "turbometa-chat"
    }()

    /// 开启全新会话：生成新的 sessionKey 并持久化
    func startNewChat() {
        chatSessionKey = "turbometa-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(chatSessionKey, forKey: "openclaw_chat_session")
    }

    /// Chat event callback
    var onChatEvent: ((String) -> Void)?

    func disconnect() {
        shouldReconnect = false
        isEnabled = false
        saveSettings()
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownConnection()
        connectionState = .disconnected
        print("[OpenClaw] Disconnected")
    }

    func saveGatewayToken(_ token: String) {
        let data = token.data(using: .utf8) ?? Data()
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ] as CFDictionary)

        guard !token.isEmpty else { return }
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data
        ] as CFDictionary, nil)
    }

    func loadGatewayToken() -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Connection Logic

    private func startConnection() {
        guard let url = makeGatewayURL() else {
            connectionState = .error("Invalid gateway URL")
            shouldReconnect = false
            isEnabled = false
            saveSettings()
            return
        }

        connectionState = .connecting
        connectRequestID = nil

        print("[OpenClaw] Connecting to \(url.scheme ?? "ws")://\(gatewayHost):\(gatewayPort)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        // 绕过系统代理，直连局域网 Gateway
        config.connectionProxyDictionary = [:]
        let delegateQueue = OperationQueue()
        delegateQueue.name = "openclaw-ws"
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)

        guard let webSocket = urlSession?.webSocketTask(with: url) else {
            connectionState = .error("Could not create gateway connection")
            shouldReconnect = false
            isEnabled = false
            saveSettings()
            return
        }
        self.webSocket = webSocket
        webSocket.maximumMessageSize = 16 * 1024 * 1024
        webSocket.resume()
        startHandshakeWatchdog(for: webSocket)
        // receiveMessage() is called in didOpen delegate
    }

    private func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "openclaw_enabled")
        UserDefaults.standard.set(gatewayHost, forKey: "openclaw_host")
        UserDefaults.standard.set(gatewayPort, forKey: "openclaw_port")
        UserDefaults.standard.set(usesTLS, forKey: "openclaw_uses_tls")
    }

    // MARK: - WebSocket Messaging

    private func receiveMessage() {
        guard let webSocket else { return }
        receiveMessage(on: webSocket)
    }

    private func receiveMessage(on webSocket: URLSessionWebSocketTask) {
        webSocket.receive { [weak self, weak webSocket] result in
            Task { @MainActor in
                guard let self, let webSocket, self.webSocket === webSocket else { return }

                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessage(on: webSocket)
                case .failure(let error):
                    print("[OpenClaw] Receive error: \(error.localizedDescription)")
                    self.handleDisconnect()
                }
            }
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }

        guard let webSocket else { return }
        webSocket.send(.string(text)) { [weak self, weak webSocket] error in
            if let error {
                print("[OpenClaw] Send error: \(error.localizedDescription)")
                Task { @MainActor in
                    guard let self, let webSocket, self.webSocket === webSocket else { return }
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s):
            text = s
            print("[OpenClaw] Received text message (\(s.utf8.count) bytes)")
        case .data(let d):
            text = String(data: d, encoding: .utf8) ?? ""
            print("[OpenClaw] RAW DATA: \(d.count) bytes")
        @unknown default: return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String
        let method = json["method"] as? String

        let event = json["event"] as? String

        // OpenClaw protocol: type="event", event="connect.challenge"
        if type == "event" && event == "connect.challenge" {
            if let payload = json["payload"] as? [String: Any],
               let nonce = payload["nonce"] as? String {
                handleChallenge(nonce: nonce)
            }
            return
        }

        // Response frame
        if type == "res" {
            let ok = json["ok"] as? Bool ?? false
            let id = json["id"] as? String
            if id == connectRequestID, ok {
                handleHelloOk(json: json)
            } else {
                handleResponse(json: json)
            }
            return
        }

        switch type {
        case "evt", "event":
            handleEvent(method: event ?? method, json: json)
        case "req", "request":
            handleRequest(json: json)
        case "res", "response":
            handleResponse(json: json)
        default:
            print("[OpenClaw] Unknown message type: \(type ?? "nil")")
        }
    }

    // MARK: - Handshake

    private func handleChallenge(nonce: String) {
        print("[OpenClaw] Received challenge, nonce: \(nonce.prefix(8))...")
        pendingNonce = nonce

        let token = loadGatewayToken() ?? ""
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]
        let clientId = "openclaw-ios"
        let clientMode = "node"
        let platform = "ios"
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Build device signature (v3)
        let signature = deviceIdentity.sign(
            clientId: clientId,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            signedAtMs: signedAtMs,
            token: token.isEmpty ? nil : token,
            nonce: nonce,
            platform: platform,
            deviceFamily: nil
        )

        var auth: [String: Any] = [:]
        if !token.isEmpty {
            auth["token"] = token
        }

        let connectParams: [String: Any] = [
            "minProtocol": Self.protocolVersion,
            "maxProtocol": Self.protocolVersion,
            "client": [
                "id": clientId,
                "displayName": "Ray-Ban Meta Glasses",
                "version": "2.0.0",
                "mode": clientMode,
                "platform": platform,
                "modelIdentifier": UIDevice.current.model
            ] as [String: Any],
            "role": role,
            "scopes": scopes,
            "caps": Self.caps,
            "commands": Self.commands,
            "auth": auth,
            "device": [
                "id": deviceIdentity.deviceId,
                "publicKey": deviceIdentity.publicKeyBase64Url,
                "signature": signature,
                "signedAt": signedAtMs,
                "nonce": nonce
            ] as [String: Any]
        ] as [String: Any]

        let requestID = UUID().uuidString
        let frame: [String: Any] = [
            "type": "req",
            "id": requestID,
            "method": "connect",
            "params": connectParams
        ]

        connectRequestID = requestID
        print("[OpenClaw] Sending connect request (node + device identity)...")
        sendJSON(frame)
    }

    private func handleHelloOk(json: [String: Any]) {
        print("[OpenClaw] Connected to gateway!")
        connectRequestID = nil
        pendingNonce = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        connectionState = .connected
        reconnectAttempts = 0
        startTickWatchdog()
    }

    // MARK: - Event Handling

    private func handleEvent(method: String?, json: [String: Any]) {
        guard let method else { return }

        switch method {
        case "node.invoke.request", "node.invoke":
            print("[OpenClaw] >>> INVOKE RECEIVED: \(method)")
            handleInvokeRequest(json: json)
        case "chat":
            if let payload = json["payload"] as? [String: Any],
               let state = payload["state"] as? String,
               let message = payload["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                // Extract text from content array
                let text = content.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty {
                    onChatEvent?(state == "final" ? "[[FINAL]]\(text)" : text)
                }
            }
        case "tick", "health":
            break // suppress noise
        default:
            print("[OpenClaw] Event: \(method)")
        }
    }

    private func handleRequest(json: [String: Any]) {
        let method = json["method"] as? String ?? ""
        let id = json["id"] as? String ?? ""

        switch method {
        case "node.invoke":
            if let params = json["params"] as? [String: Any] {
                handleInvokeFromRequest(id: id, params: params)
            }
        default:
            print("[OpenClaw] Request: \(method)")
            sendJSON([
                "type": "res",
                "id": id,
                "ok": false,
                "error": ["code": "UNSUPPORTED", "message": "Unknown method: \(method)"]
            ])
        }
    }

    private func handleResponse(json: [String: Any]) {
        let id = json["id"] as? String ?? ""
        let ok = json["ok"] as? Bool ?? false

        if !ok {
            let error = json["error"] as? [String: Any]
            let code = error?["code"] as? String ?? ""
            let message = error?["message"] as? String ?? ""
            print("[OpenClaw] Response error for \(id): \(code) - \(message)")

            if code == "NOT_PAIRED" {
                connectionState = .waitingForPairing
                connectRequestID = nil
                pendingNonce = nil
                handshakeTask?.cancel()
                handshakeTask = nil
            } else if id == connectRequestID {
                connectRequestID = nil
                handleDisconnect()
            }
        }
    }

    // MARK: - Invoke Handling

    private func handleInvokeRequest(json: [String: Any]) {
        guard let params = json["params"] as? [String: Any] else { return }
        let invokeId = params["id"] as? String ?? ""
        handleInvokeFromRequest(id: invokeId, params: params)
    }

    private func handleInvokeFromRequest(id: String, params: [String: Any]) {
        let command = params["command"] as? String ?? ""
        let cmdParams = params["params"] as? [String: Any]
            ?? (params["paramsjson"] as? String).flatMap { str in
                try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any]
            }

        print("[OpenClaw] Invoke: \(command) (id: \(id.prefix(8)))")

        let request = OpenClawNodeInvokeRequest(
            id: id,
            command: command,
            params: cmdParams,
            timeoutMs: params["timeoutms"] as? Int ?? params["timeoutMs"] as? Int
        )

        Task { @MainActor in
            let result = await self.commandRouter?.handleCommand(request)
                ?? self.makeErrorResult(id: id, code: "NO_ROUTER", message: "Command router not configured")
            self.sendInvokeResult(result)
        }
    }

    private func sendInvokeResult(_ result: OpenClawNodeInvokeResult) {
        var payload: [String: Any] = [
            "id": result.id,
            "nodeId": nodeId,
            "ok": result.ok
        ]

        if let p = result.payload {
            // For large payloads (images), use payloadjson
            if let data = try? JSONEncoder().encode(p),
               let jsonStr = String(data: data, encoding: .utf8) {
                payload["payloadjson"] = jsonStr
            }
        }

        if let error = result.error {
            var errDict: [String: Any] = [:]
            if let code = error.code { errDict["code"] = code }
            if let message = error.message { errDict["message"] = message }
            payload["error"] = errDict
        }

        sendJSON([
            "type": "req",
            "id": UUID().uuidString,
            "method": "node.invoke.result",
            "params": payload
        ])
    }

    private func makeErrorResult(id: String, code: String, message: String) -> OpenClawNodeInvokeResult {
        return OpenClawNodeInvokeResult(
            id: id,
            nodeId: nodeId,
            ok: false,
            payload: nil,
            error: OpenClawError(code: code, message: message)
        )
    }

    // MARK: - Keepalive

    private func startTickWatchdog() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.sendJSON([
                    "type": "req",
                    "id": UUID().uuidString,
                    "method": "tick",
                    "params": ["ts": Int64(Date().timeIntervalSince1970 * 1000)]
                ] as [String: Any])
            }
        }
    }

    private func startHandshakeWatchdog(for webSocket: URLSessionWebSocketTask) {
        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self, weak webSocket] in
            try? await Task.sleep(nanoseconds: UInt64(Self.handshakeTimeout * 1_000_000_000))
            guard let self,
                  let webSocket,
                  !Task.isCancelled,
                  self.webSocket === webSocket,
                  self.connectionState == .connecting else {
                return
            }

            self.handshakeTask = nil
            print("[OpenClaw] Gateway handshake timed out")
            self.handleDisconnect()
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        guard connectionState != .disconnected || webSocket != nil else { return }

        tearDownConnection()

        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }

        reconnectAttempts += 1
        if reconnectAttempts > Self.maxReconnectAttempts {
            print("[OpenClaw] Max reconnect attempts reached, giving up")
            connectionState = .error("连接失败，已重试 \(Self.maxReconnectAttempts) 次")
            shouldReconnect = false
            return
        }

        let delay = min(Double(1 << reconnectAttempts), 30.0) // 2, 4, 8, 16, 30s
        print("[OpenClaw] Reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts) in \(delay)s")
        connectionState = .disconnected
        scheduleReconnect(delay: delay)
    }

    private func scheduleReconnect(delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.startConnection()
        }
    }

    private func tearDownConnection() {
        connectRequestID = nil
        pendingNonce = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        tickTask?.cancel()
        tickTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func makeGatewayURL() -> URL? {
        OpenClawGatewayEndpoint(host: gatewayHost, port: gatewayPort, usesTLS: usesTLS).url
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenClawNodeService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.webSocket === webSocketTask else { return }
            print("[OpenClaw] WebSocket opened, starting receive loop")
            self.receiveMessage(on: webSocketTask)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, self.webSocket === webSocketTask else { return }
            print("[OpenClaw] WebSocket closed: \(closeCode.rawValue)")
            self.handleDisconnect()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let webSocketTask = task as? URLSessionWebSocketTask,
                  self.webSocket === webSocketTask else { return }
            print("[OpenClaw] Connection error: \(error.localizedDescription)")
            self.handleDisconnect()
        }
    }
}

// MARK: - Helpers

private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int {
        return self != 0 ? self : defaultValue
    }
}
