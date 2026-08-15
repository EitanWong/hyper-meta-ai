/*
 * Hermes Agent Service
 * 通过 Hermes 的 OpenAI 兼容 API Server 驱动完整 Agent
 * 传输: POST /v1/responses (SSE 流式) + GET /health
 * 特性: 服务端多轮上下文 (conversation)、工具调用回放、图片输入、可中断
 */

import Foundation
import UIKit

// MARK: - Connection State

enum HermesConnectionState: Equatable {
    case unknown
    case checking
    case online
    case offline(String)

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

// MARK: - Hermes Service

@MainActor
final class HermesService: ObservableObject {
    static let shared = HermesService()

    // MARK: - Published State

    @Published var connectionState: HermesConnectionState = .unknown
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "hermes_enabled")
    @Published var gatewayHost = UserDefaults.standard.string(forKey: "hermes_host") ?? "127.0.0.1"
    @Published var gatewayPort = UserDefaults.standard.integer(forKey: "hermes_port").nonZeroOrDefault(8642)
    @Published var usesTLS = UserDefaults.standard.bool(forKey: "hermes_uses_tls")
    @Published var modelName = UserDefaults.standard.string(forKey: "hermes_model") ?? "hermes-agent"
    @Published var conversationName = UserDefaults.standard.string(forKey: "hermes_conversation") ?? "hyper-meta-ios"
    @Published var isStreaming = false

    // MARK: - Private Properties

    private let keychainService = "com.smartview.glassai.hermes"
    private let keychainAccount = "api_key"
    private var currentTask: Task<Void, Never>?

    // MARK: - Config

    var baseURLString: String {
        let scheme = usesTLS ? "https" : "http"
        return "\(scheme)://\(gatewayHost):\(gatewayPort)"
    }

    var apiKey: String {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveAPIKey(_ key: String) {
        let data = key.data(using: .utf8) ?? Data()
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ] as CFDictionary)
        guard !key.isEmpty else { return }
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data
        ] as CFDictionary, nil)
    }

    func saveSettings() {
        isEnabled = true
        UserDefaults.standard.set(isEnabled, forKey: "hermes_enabled")
        UserDefaults.standard.set(gatewayHost, forKey: "hermes_host")
        UserDefaults.standard.set(gatewayPort, forKey: "hermes_port")
        UserDefaults.standard.set(usesTLS, forKey: "hermes_uses_tls")
        UserDefaults.standard.set(modelName, forKey: "hermes_model")
        UserDefaults.standard.set(conversationName, forKey: "hermes_conversation")
    }

    // MARK: - Health Check

    func checkHealth() async {
        connectionState = .checking
        guard let url = URL(string: "\(baseURLString)/health") else {
            connectionState = .offline("Invalid base URL")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let key = apiKey
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                connectionState = .offline("Invalid response")
                return
            }
            connectionState = http.statusCode == 200 ? .online : .offline("HTTP \(http.statusCode)")
        } catch {
            connectionState = .offline(error.localizedDescription)
        }
    }

    // MARK: - Send Message (streaming)

    /// Send a message to Hermes and stream the response.
    /// - Parameters:
    ///   - text: user message
    ///   - image: optional glasses frame (compressed to JPEG, sent as input_image)
    ///   - onDelta: streamed text delta
    ///   - onTool: tool name when the agent starts a tool call
    ///   - onComplete: final assembled text
    ///   - onError: error message
    func sendMessage(
        _ text: String,
        image: UIImage? = nil,
        instructions: String? = nil,
        onDelta: @escaping (String) -> Void,
        onTool: @escaping (String) -> Void,
        onToolResult: ((String, String) -> Void)? = nil,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard connectionState.isOnline || isEnabled else {
            onError("hermes.error.notconnected".localized)
            return
        }
        guard let url = URL(string: "\(baseURLString)/v1/responses") else {
            onError("hermes.error.invalidurl".localized)
            return
        }

        var requestBody: HermesResponsesRequest
        if let image {
            guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
                onError("hermes.error.image".localized)
                return
            }
            requestBody = .withImage(
                text,
                jpegBase64: jpeg.base64EncodedString(),
                model: modelName,
                conversation: conversationName,
                instructions: instructions
            )
        } else {
            requestBody = .plainText(
                text,
                model: modelName,
                conversation: conversationName,
                instructions: instructions
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            onError(error.localizedDescription)
            return
        }

        cancel()
        isStreaming = true

        currentTask = Task { [weak self] in
            defer { Task { @MainActor in self?.isStreaming = false } }
            await self?.stream(
                request: request,
                onDelta: onDelta,
                onTool: onTool,
                onToolResult: onToolResult,
                onComplete: onComplete,
                onError: onError
            )
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    /// 开启全新对话：生成新的服务端 conversation 标识并持久化
    func startNewConversation() {
        cancel()
        conversationName = "hyper-meta-ios-\(UUID().uuidString.prefix(8))"
        saveSettings()
    }

    // MARK: - Streaming

    private func stream(
        request: URLRequest,
        onDelta: @escaping (String) -> Void,
        onTool: @escaping (String) -> Void,
        onToolResult: ((String, String) -> Void)?,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                onError("hermes.error.invalidresponse".localized)
                return
            }

            // Non-2xx: try to surface the server error message.
            guard (200...299).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    if Task.isCancelled { return }
                    body.append(byte)
                }
                onError(parseServerError(body: body, status: http.statusCode))
                return
            }

            var accumulator = HermesStreamAccumulator()
            var buffer = ""
            var sawEvent = false
            var rawBody = ""

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                rawBody += line + "\n"
                let events = HermesSSEParser.parse(chunk: line + "\n", into: &buffer)
                sawEvent = sawEvent || !events.isEmpty
                for event in events {
                    if event.isError {
                        onError(event.errorMessage ?? "hermes.error.stream".localized)
                        return
                    }
                    accumulator.apply(event)
                    if let delta = event.textDelta, !delta.isEmpty {
                        onDelta(delta)
                    }
                    if let tool = event.functionCallName ?? event.toolName {
                        onTool(tool)
                    }
                    for result in accumulator.toolResults {
                        onToolResult?(result.callID, result.output)
                    }
                    accumulator.clearToolResults()
                }
            }

            // Non-SSE response (e.g. plain JSON when streaming is unavailable):
            // decode the final payload directly.
            if !sawEvent,
               let data = rawBody.data(using: .utf8),
               let response = try? JSONDecoder().decode(HermesResponsesResponse.self, from: data) {
                for call in response.toolCalls {
                    onTool(call.name)
                }
                for result in response.toolResults {
                    onToolResult?(result.callID, result.output)
                }
                if !response.assembledText.isEmpty {
                    onComplete(response.assembledText)
                } else {
                    onComplete("")
                }
                return
            }

            // Final text may only be present inside the completion payload.
            onComplete(accumulator.text)
        } catch is CancellationError {
            // Interrupted by the user — no error surface.
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func parseServerError(body: Data?, status: Int) -> String {
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }
        return "HTTP \(status)"
    }
}

// MARK: - Helpers

private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int {
        return self != 0 ? self : defaultValue
    }
}
