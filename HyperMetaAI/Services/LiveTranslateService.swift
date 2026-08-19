/*
 * Live Translate WebSocket Service
 * 基于 qwen3-livetranslate-flash-realtime 的实时翻译服务
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - Service Class

class LiveTranslateService: NSObject {

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    private let model = "qwen3-livetranslate-flash-realtime"
    // 根据用户设置的区域动态获取 WebSocket URL
    private var baseURL: String {
        return APIProviderManager.staticLiveAIWebsocketURL
    }

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?
    private let audioControlQueue = DispatchQueue(
        label: "com.lunflux.hyper-meta-ai.translate.audio-control",
        qos: .userInitiated
    )
    private let audioUploadPipeline = RealtimeAudioUploadPipeline(
        label: "com.lunflux.hyper-meta-ai.translate.audio-upload",
        targetSampleRate: RealtimeProviderAudioProfiles.qwen.inputSampleRate
    )
    private var audioUploadGeneration = 0

    private let audioPlaybackPipeline = RealtimeAudioPlaybackPipeline(
        label: "com.lunflux.hyper-meta-ai.translate.audio-playback",
        outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat
    )
    private let realtimeSessionLock = NSLock()
    private var realtimeSessionGeneration = 0
    private let sessionConfigurationGate = RealtimeSessionConfigurationGate()

    // Translation settings
    private var sourceLanguage: TranslateLanguage = .en
    private var targetLanguage: TranslateLanguage = .zh
    private var voice: TranslateVoice = .cherry
    private var audioOutputEnabled = true

    // Callbacks
    var onConnected: (() -> Void)?
    var onTranslationText: ((String) -> Void)?    // 翻译结果文本
    var onTranslationDelta: ((String) -> Void)?   // 增量翻译文本
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    // State
    private var isRecording = false
    private var eventIdCounter = 0

    // Image sending
    private var lastImageSendTime: Date?
    private let imageInterval: TimeInterval = 0.5  // 每0.5秒最多发送一张图片

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
        setupAudioEngine()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
    }

    // MARK: - WebSocket Connection

    func connect() {
        let generation = beginRealtimeSession()
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Translate] 准备连接 WebSocket: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ [Translate] 无效的 URL")
            onError?("Invalid URL")
            return
        }

        audioPlaybackPipeline.start(generation: generation) { [weak self] message in
            guard let self, self.isCurrentRealtimeSession(generation) else { return }
            self.onError?(message)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        let task = urlSession?.webSocketTask(with: request)
        webSocket = task
        task?.resume()

        print("🔌 [Translate] WebSocket 任务已启动")
        if let task {
            receiveMessage(on: task, generation: generation)
        }
    }

    func disconnect() {
        print("🔌 [Translate] 断开 WebSocket 连接")
        invalidateRealtimeSession()
        audioPlaybackPipeline.stop()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        audioControlQueue.async { [weak self] in
            self?.stopRecordingOnAudioControlQueue()
            AudioSessionCoordinator.shared.deactivate(.liveTranslate)
        }
    }

    private func beginRealtimeSession() -> Int {
        realtimeSessionLock.lock()
        realtimeSessionGeneration &+= 1
        let generation = realtimeSessionGeneration
        realtimeSessionLock.unlock()
        sessionConfigurationGate.activate(generation: generation)
        return generation
    }

    private func invalidateRealtimeSession() {
        realtimeSessionLock.lock()
        realtimeSessionGeneration &+= 1
        realtimeSessionLock.unlock()
        sessionConfigurationGate.invalidate()
    }

    private func isCurrentRealtimeSession(_ generation: Int) -> Bool {
        realtimeSessionLock.lock()
        defer { realtimeSessionLock.unlock() }
        return realtimeSessionGeneration == generation
    }

    // MARK: - Configuration

    func updateSettings(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        voice: TranslateVoice,
        audioEnabled: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voice = voice
        self.audioOutputEnabled = audioEnabled

        // 如果已连接，重新配置会话
        if webSocket != nil {
            configureSession()
        }
    }

    private func configureSession() {
        var modalities: [String] = ["text"]
        if audioOutputEnabled {
            modalities.append("audio")
        }

        let sessionConfig: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.sessionUpdate.rawValue,
            "session": [
                "modalities": modalities,
                "voice": voice.rawValue,
                "input_audio_format": RealtimeProviderAudioProfiles.qwen.sessionInputFormat,
                "output_audio_format": RealtimeProviderAudioProfiles.qwen.sessionOutputFormat,
                "input_audio_transcription": [
                    "language": sourceLanguage.rawValue
                ],
                "translation": [
                    "language": targetLanguage.rawValue
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]

        sendEvent(sessionConfig)
        print("📤 [Translate] 配置会话: \(sourceLanguage.rawValue) → \(targetLanguage.rawValue), 音色: \(voice.rawValue)")
    }

    // MARK: - Audio Recording

    func startRecording(usePhoneMic: Bool = false) {
        audioControlQueue.async { [weak self] in
            self?.startRecordingOnAudioControlQueue(usePhoneMic: usePhoneMic)
        }
    }

    private func startRecordingOnAudioControlQueue(usePhoneMic: Bool) {
        guard !isRecording else { return }

        do {
            print("🎤 [Translate] 开始录音, 使用\(usePhoneMic ? "iPhone" : "蓝牙")麦克风")

            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
            audioUploadPipeline.stop()
            audioUploadGeneration &+= 1
            let generation = audioUploadGeneration

            try AudioSessionCoordinator.shared.activate(
                .liveTranslate,
                profile: .translation(usePhoneMic: usePhoneMic)
            )
            let audioSession = AVAudioSession.sharedInstance()

            // 打印当前音频输入设备
            if let inputRoute = audioSession.currentRoute.inputs.first {
                print("🎙️ [Translate] 当前输入设备: \(inputRoute.portName) (\(inputRoute.portType.rawValue))")
            }

            guard let engine = audioEngine else {
                print("❌ [Translate] 音频引擎未初始化")
                AudioSessionCoordinator.shared.deactivate(.liveTranslate)
                return
            }

            try AppleVoiceAudioFrontEnd.configure(engine)
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            print("🎵 [Translate] 输入格式: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
            print("🎵 [Translate] 目标格式: 16000.0 Hz (上传队列重采样)")

            guard let webSocket else {
                AudioSessionCoordinator.shared.deactivate(.liveTranslate)
                onRecordingStateChanged?(false)
                onError?("WebSocket is not connected")
                return
            }

            audioUploadPipeline.start(
                generation: generation,
                inputFormat: inputFormat,
                webSocket: webSocket,
                messageBuilder: Self.makeAudioUploadMessage,
                onFirstAudioSent: {},
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
            print("✅ [Translate] 录音已启动")

        } catch {
            audioUploadPipeline.stop()
            AudioSessionCoordinator.shared.deactivate(.liveTranslate)
            onRecordingStateChanged?(false)
            print("❌ [Translate] 启动录音失败: \(error.localizedDescription)")
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

        print("🛑 [Translate] 停止录音")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        onRecordingStateChanged?(false)
    }

    // MARK: - Image Sending

    func sendImageFrame(_ image: UIImage) {
        // 限制发送频率：每0.5秒最多一张
        let now = Date()
        if let lastTime = lastImageSendTime, now.timeIntervalSince(lastTime) < imageInterval {
            return
        }
        lastImageSendTime = now

        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("❌ [Translate] 无法压缩图片")
            return
        }

        // 限制图片大小 500KB
        guard imageData.count <= 500 * 1024 else {
            print("⚠️ [Translate] 图片过大，跳过发送")
            return
        }

        let base64Image = imageData.base64EncodedString()
        print("📸 [Translate] 发送图片: \(imageData.count) bytes")

        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.inputImageBufferAppend.rawValue,
            "image": base64Image
        ]
        sendEvent(event)
    }

    // MARK: - Send Events

    private func sendEvent(_ event: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Translate] 无法序列化事件")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                print("❌ [Translate] 发送事件失败: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    private static func makeAudioUploadMessage(_ audioData: Data) -> URLSessionWebSocketTask.Message? {
        let event: [String: Any] = [
            "event_id": "translate_audio_\(UUID().uuidString)",
            "type": TranslateClientEvent.inputAudioBufferAppend.rawValue,
            "audio": audioData.base64EncodedString()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return .string(jsonString)
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
                print("❌ [Translate] 接收消息失败: \(error.localizedDescription)")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == TranslateServerEvent.sessionCreated.rawValue {
            return
        }

        if type == TranslateServerEvent.sessionUpdated.rawValue {
            guard isCurrentRealtimeSession(generation),
                  sessionConfigurationGate.confirm(generation: generation) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                self.onConnected?()
            }
            return
        }

        if type == TranslateServerEvent.responseAudioDelta.rawValue,
           let base64Audio = json["delta"] as? String,
           let audioData = Data(base64Encoded: base64Audio) {
            let result = audioPlaybackPipeline.enqueue(audioData, generation: generation)
            if result.isAccepted, isCurrentRealtimeSession(generation) {
                onAudioDelta?(audioData)
            }
            return
        }

        if type == TranslateServerEvent.responseAudioDone.rawValue {
            audioPlaybackPipeline.finishResponse(generation: generation)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                self.onAudioDone?()
            }
            return
        }

        if type == TranslateServerEvent.responseAudioTranscriptText.rawValue {
            guard isCurrentRealtimeSession(generation),
                  let delta = json["delta"] as? String else {
                return
            }
            onTranslationDelta?(delta)
            return
        }

        if (type == TranslateServerEvent.responseAudioTranscriptDone.rawValue
            || type == TranslateServerEvent.responseTextDone.rawValue) {
            guard isCurrentRealtimeSession(generation),
                  let text = json["text"] as? String else {
                return
            }
            onTranslationText?(text)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentRealtimeSession(generation) else { return }

            switch type {
            case TranslateServerEvent.error.rawValue:
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    print("❌ [Translate] 服务器错误: \(message)")
                    self.onError?(message)
                }

            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private func generateEventId() -> String {
        eventIdCounter += 1
        return "translate_\(eventIdCounter)_\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveTranslateService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Translate] WebSocket 连接已建立")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Translate] WebSocket 已断开, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
    }
}
