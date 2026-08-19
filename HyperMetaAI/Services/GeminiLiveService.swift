/*
 * Gemini Live WebSocket Service
 * Provides real-time audio chat with Google Gemini AI
 * Uses gemini-2.0-flash-exp model for real-time audio conversation
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - Gemini Live Service

class GeminiLiveService: NSObject {

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    private let model: String

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?
    private let audioControlQueue = DispatchQueue(
        label: "com.lunflux.hyper-meta-ai.gemini.audio-control",
        qos: .userInitiated
    )
    private let audioUploadPipeline = RealtimeAudioUploadPipeline(
        label: "com.lunflux.hyper-meta-ai.gemini.audio-upload",
        targetSampleRate: 16_000
    )
    private var audioUploadGeneration = 0
    private let imageUploadPipeline = RealtimeImageUploadPipeline(
        label: "com.lunflux.hyper-meta-ai.gemini.image-upload"
    )

    private let audioPlaybackPipeline = RealtimeAudioPlaybackPipeline(
        label: "com.lunflux.hyper-meta-ai.gemini.audio-playback"
    )
    private let realtimeSessionLock = NSLock()
    private var realtimeSessionGeneration = 0

    // Callbacks
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFirstAudioSent: (() -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    // State
    private var isRecording = false
    private var isSessionConfigured = false

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        self.model = model ?? "gemini-2.0-flash-exp"
        super.init()
        setupAudioEngine()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
    }

    private func configureAudioSession() -> Bool {
        do {
            try AudioSessionCoordinator.shared.activate(.liveAI, profile: .voiceChat)
            return true
        } catch {
            print("⚠️ [Gemini] Audio session 配置失败: \(error)")
            return false
        }
    }

    // MARK: - WebSocket Connection

    func connect() {
        let generation = beginRealtimeSession()
        // Gemini Live WebSocket URL with API key
        let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        let urlString = "\(baseURL)?key=\(apiKey)"

        print("🔌 [Gemini] 准备连接 WebSocket")

        guard let url = URL(string: urlString) else {
            print("❌ [Gemini] 无效的 URL")
            onError?("Invalid URL")
            return
        }

        imageUploadPipeline.start(generation: generation)

        audioPlaybackPipeline.start(generation: generation) { [weak self] message in
            guard let self, self.isCurrentRealtimeSession(generation) else { return }
            self.onError?(message)
        }

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        let task = urlSession?.webSocketTask(with: url)
        webSocket = task
        task?.resume()

        print("🔌 [Gemini] WebSocket 任务已启动")
        if let task {
            receiveMessage(on: task, generation: generation)
        }
    }

    func disconnect() {
        print("🔌 [Gemini] 断开 WebSocket 连接")
        invalidateRealtimeSession()
        imageUploadPipeline.stop()
        audioPlaybackPipeline.stop()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        audioControlQueue.async { [weak self] in
            self?.stopRecordingOnAudioControlQueue()
            AudioSessionCoordinator.shared.deactivate(.liveAI)
        }
        isSessionConfigured = false
    }

    private func beginRealtimeSession() -> Int {
        realtimeSessionLock.lock()
        defer { realtimeSessionLock.unlock() }
        realtimeSessionGeneration &+= 1
        return realtimeSessionGeneration
    }

    private func invalidateRealtimeSession() {
        realtimeSessionLock.lock()
        realtimeSessionGeneration &+= 1
        realtimeSessionLock.unlock()
    }

    private func isCurrentRealtimeSession(_ generation: Int) -> Bool {
        realtimeSessionLock.lock()
        defer { realtimeSessionLock.unlock() }
        return realtimeSessionGeneration == generation
    }

    private func currentRealtimeSessionGeneration() -> Int {
        realtimeSessionLock.lock()
        defer { realtimeSessionLock.unlock() }
        return realtimeSessionGeneration
    }

    // MARK: - Session Configuration

    private func configureSession() {
        guard !isSessionConfigured else { return }

        // 根据当前 Live AI 模式获取系统提示词
        let instructions = LiveAIModeManager.staticSystemPrompt

        // Gemini Live API setup message
        let setupMessage: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generation_config": [
                    "response_modalities": ["AUDIO"],
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": "Aoede"  // Gemini voice options: Aoede, Charon, Fenrir, Kore, Puck
                            ]
                        ]
                    ]
                ],
                "system_instruction": [
                    "parts": [
                        ["text": instructions]
                    ]
                ]
            ]
        ]

        sendJSON(setupMessage)
        print("⚙️ [Gemini] 发送会话配置")
    }

    // MARK: - Audio Recording

    func startRecording() {
        audioControlQueue.async { [weak self] in
            self?.startRecordingOnAudioControlQueue()
        }
    }

    private func startRecordingOnAudioControlQueue() {
        guard !isRecording else { return }

        do {
            print("🎤 [Gemini] 开始录音")

            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startRecording()
                        } else {
                            self?.onError?("Microphone permission denied")
                        }
                    }
                }
                return
            case .denied:
                onError?("Microphone permission denied")
                return
            case .granted:
                break
            @unknown default:
                break
            }

            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
            audioUploadPipeline.stop()
            audioUploadGeneration &+= 1
            let generation = audioUploadGeneration

            guard configureAudioSession() else {
                onError?("Microphone is already in use by another feature")
                return
            }

            guard let engine = audioEngine else {
                print("❌ [Gemini] 音频引擎未初始化")
                return
            }

            try AppleVoiceAudioFrontEnd.configure(engine)
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard let webSocket else {
                AudioSessionCoordinator.shared.deactivate(.liveAI)
                onRecordingStateChanged?(false)
                onError?("WebSocket is not connected")
                return
            }

            audioUploadPipeline.start(
                generation: generation,
                inputFormat: inputFormat,
                webSocket: webSocket,
                messageBuilder: Self.makeRealtimeAudioUploadMessage,
                onFirstAudioSent: { [weak self] in
                    guard let self, self.audioUploadGeneration == generation else { return }
                    self.onFirstAudioSent?()
                },
                onFailure: { [weak self] message in
                    guard let self, self.audioUploadGeneration == generation else { return }
                    self.stopRecording()
                    self.onError?(message)
                }
            )
            let uploadPipeline = audioUploadPipeline

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [uploadPipeline] buffer, _ in
                uploadPipeline.capture(buffer, generation: generation)
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            onRecordingStateChanged?(true)
            print("✅ [Gemini] 录音已启动")

        } catch {
            audioUploadPipeline.stop()
            AudioSessionCoordinator.shared.deactivate(.liveAI)
            onRecordingStateChanged?(false)
            print("❌ [Gemini] 启动录音失败: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        audioControlQueue.async { [weak self] in
            self?.stopRecordingOnAudioControlQueue()
        }
    }

    private func stopRecordingOnAudioControlQueue() {
        audioUploadGeneration &+= 1
        audioUploadPipeline.stop()
        guard isRecording else { return }

        print("🛑 [Gemini] 停止录音")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        onRecordingStateChanged?(false)
    }

    // MARK: - Send Events

    private func sendJSON(_ json: [String: Any], generation: Int? = nil) {
        if let generation, !isCurrentRealtimeSession(generation) {
            return
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Gemini] 无法序列化 JSON")
            return
        }

        if let generation, !isCurrentRealtimeSession(generation) {
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                print("❌ [Gemini] 发送失败: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    private static func makeRealtimeAudioUploadMessage(
        _ audioData: Data
    ) -> URLSessionWebSocketTask.Message? {
        let message: [String: Any] = [
            "realtime_input": [
                "media_chunks": [
                    [
                        "mime_type": "audio/pcm;rate=16000",
                        "data": audioData.base64EncodedString()
                    ]
                ]
            ]
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return .string(jsonString)
    }

    func sendImageInput(_ image: UIImage) {
        let generation = currentRealtimeSessionGeneration()
        _ = imageUploadPipeline.submit(image, generation: generation) { [weak self] imageData in
            guard let self, self.isCurrentRealtimeSession(generation) else { return }

            print("📸 [Gemini] 发送图片: \(imageData.count) bytes")

            let message: [String: Any] = [
                "realtime_input": [
                    "media_chunks": [
                        [
                            "mime_type": "image/jpeg",
                            "data": imageData.base64EncodedString()
                        ]
                    ]
                ]
            ]
            self.sendJSON(message, generation: generation)
        }
    }

    // MARK: - Receive Messages

    private func receiveMessage(on task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.isCurrentRealtimeSession(generation) else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message, generation: generation)
                guard self.isCurrentRealtimeSession(generation) else { return }
                self.receiveMessage(on: task, generation: generation)

            case .failure(let error):
                print("❌ [Gemini] 接收消息失败: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentRealtimeSession(generation) else { return }
                    self.onError?("Receive error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, generation: Int) {
        switch message {
        case .string(let text):
            handleServerEvent(text, generation: generation)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleServerEvent(text, generation: generation)
            }
        @unknown default:
            break
        }
    }

    private func handleServerEvent(_ jsonString: String, generation: Int) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if json["setupComplete"] != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                print("✅ [Gemini] 会话配置完成")
                self.isSessionConfigured = true
                self.onConnected?()
            }
            return
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent, generation: generation)
            return
        }

        if json["toolCall"] is [String: Any] {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                if let toolCall = json["toolCall"] as? [String: Any] {
                    print("🔧 [Gemini] Tool call: \(toolCall)")
                }
            }
            return
        }

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                print("❌ [Gemini] 服务器错误: \(message)")
                self.onError?(message)
            }
        }
    }

    private func handleServerContent(_ content: [String: Any], generation: Int) {
        // Check for model turn
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // Handle text response
                if let text = part["text"] as? String,
                   isCurrentRealtimeSession(generation) {
                    onTranscriptDelta?(text)
                }

                // Handle inline audio data
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   let audioFormat = RealtimePCMOutputFormat.pcm16LittleEndian(
                    mimeType: mimeType,
                    defaultSampleRate: 24_000,
                    defaultChannelCount: 1
                   ),
                   audioFormat == .realtimePCM16Mono24kHz,
                   let base64Audio = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {
                    let result = audioPlaybackPipeline.enqueue(audioData, generation: generation)
                    if result.isAccepted, isCurrentRealtimeSession(generation) {
                        onAudioDelta?(audioData)
                    }
                } else if part["inlineData"] != nil {
                    audioPlaybackPipeline.recordUnsupportedFormat()
                }
            }
        }

        // Check for interrupted flag
        if let interrupted = content["interrupted"] as? Bool, interrupted {
            audioPlaybackPipeline.interrupt(generation: generation)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                print("⚠️ [Gemini] 回复被中断")
            }
        }

        // Handle input transcription (user speech)
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                print("👤 [Gemini] 用户说: \(text)")
                self.onUserTranscript?(text)
            }
        }

        // Handle output transcription (AI speech text)
        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String,
           isCurrentRealtimeSession(generation) {
            onTranscriptDelta?(text)
        }

        // Finish only after every text field in this server payload has entered
        // the coalescer, so a same-payload output transcription cannot start a
        // second response after the completion boundary.
        if let turnComplete = content["turnComplete"] as? Bool, turnComplete {
            audioPlaybackPipeline.finishResponse(generation: generation)
            guard isCurrentRealtimeSession(generation) else { return }
            onTranscriptDone?("")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                print("✅ [Gemini] AI回复完成")
                self.onAudioDone?()
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GeminiLiveService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Gemini] WebSocket 连接已建立")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Gemini] WebSocket 已断开, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
    }
}
