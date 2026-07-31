/*
 * Qwen-Omni-Realtime WebSocket Service
 * Provides real-time audio and video chat with AI
 */

import Foundation
import UIKit
import AVFoundation
import os

// MARK: - WebSocket Events

enum OmniClientEvent: String {
    case sessionUpdate = "session.update"
    case inputAudioBufferAppend = "input_audio_buffer.append"
    case inputAudioBufferCommit = "input_audio_buffer.commit"
    case inputImageBufferAppend = "input_image_buffer.append"
    case responseCreate = "response.create"
}

enum OmniServerEvent: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
    case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
    case inputAudioBufferCommitted = "input_audio_buffer.committed"
    case responseCreated = "response.created"
    case responseAudioTranscriptDelta = "response.audio_transcript.delta"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseDone = "response.done"
    case conversationItemCreated = "conversation.item.created"
    case conversationItemInputAudioTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case error = "error"
}

#if DEBUG
private struct OmniResponseAudioDebugState {
    private(set) var responseSequence = 0
    private(set) var audioDeltaCount = 0
    private(set) var audioByteCount = 0
    private(set) var rejectedAudioDeltaCount = 0
    private(set) var replacedQueuedChunkCount = 0
    private(set) var replacedQueuedFrameCount = 0
    private var hasStartedResponse = false
    private var hasLoggedFirstAudioDelta = false
    private var hasLoggedRejectedAudioDelta = false
    private var hasLoggedReplacement = false
    private var hasLoggedInvalidAudioPayload = false
    private var hasLoggedCompletion = false

    mutating func beginResponseIfNeeded() -> Int? {
        guard !hasStartedResponse else { return nil }

        responseSequence += 1
        audioDeltaCount = 0
        audioByteCount = 0
        rejectedAudioDeltaCount = 0
        replacedQueuedChunkCount = 0
        replacedQueuedFrameCount = 0
        hasStartedResponse = true
        hasLoggedFirstAudioDelta = false
        hasLoggedRejectedAudioDelta = false
        hasLoggedReplacement = false
        hasLoggedInvalidAudioPayload = false
        hasLoggedCompletion = false
        return responseSequence
    }

    mutating func recordAudioDelta(
        byteCount: Int,
        result: RealtimeAudioJitterOfferResult
    ) -> (
        first: Bool,
        rejected: Bool,
        replacement: Bool,
        replacedChunks: Int,
        replacedFrames: Int
    ) {
        _ = beginResponseIfNeeded()
        audioDeltaCount += 1
        audioByteCount += byteCount

        let first = !hasLoggedFirstAudioDelta
        hasLoggedFirstAudioDelta = true

        let replacement: (chunks: Int, frames: Int)
        switch result {
        case .replacedOldestQueuedChunks(let chunkCount, let frameCount):
            replacement = (chunkCount, frameCount)
            replacedQueuedChunkCount += chunkCount
            replacedQueuedFrameCount += frameCount
        default:
            replacement = (0, 0)
        }
        let shouldLogReplacement = replacement.chunks > 0 && !hasLoggedReplacement
        if replacement.chunks > 0 {
            hasLoggedReplacement = true
        }

        let rejected = !result.isAccepted && !hasLoggedRejectedAudioDelta
        if !result.isAccepted {
            rejectedAudioDeltaCount += 1
            hasLoggedRejectedAudioDelta = true
        }
        return (first, rejected, shouldLogReplacement, replacement.chunks, replacement.frames)
    }

    mutating func recordInvalidAudioPayload() -> Bool {
        _ = beginResponseIfNeeded()
        guard !hasLoggedInvalidAudioPayload else { return false }
        hasLoggedInvalidAudioPayload = true
        return true
    }

    mutating func finishResponse() -> (
        sequence: Int,
        audioDeltas: Int,
        audioBytes: Int,
        rejected: Int,
        replacedChunks: Int,
        replacedFrames: Int
    )? {
        guard hasStartedResponse, !hasLoggedCompletion else { return nil }
        hasLoggedCompletion = true
        hasStartedResponse = false
        return (
            responseSequence,
            audioDeltaCount,
            audioByteCount,
            rejectedAudioDeltaCount,
            replacedQueuedChunkCount,
            replacedQueuedFrameCount
        )
    }
}
#endif

// MARK: - Service Class

class OmniRealtimeService: NSObject {

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let webSocketDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.lunflux.hyper-meta-ai.omni.websocket-events"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    // Configuration
    private let apiKey: String
    private let model = "qwen3-omni-flash-realtime"
    // 根据用户设置的区域动态获取 WebSocket URL（北京/新加坡）
    private var baseURL: String {
        return APIProviderManager.staticLiveAIWebsocketURL
    }

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?
    private let audioControlQueue = DispatchQueue(
        label: "com.lunflux.hyper-meta-ai.omni.audio-control",
        qos: .userInitiated
    )
    private let audioUploadPipeline = RealtimeAudioUploadPipeline(
        label: "com.lunflux.hyper-meta-ai.omni.audio-upload",
        targetSampleRate: RealtimeProviderAudioProfiles.qwen.inputSampleRate
    )
    private var audioUploadGeneration = 0
    private let imageUploadPipeline = RealtimeImageUploadPipeline(
        label: "com.lunflux.hyper-meta-ai.omni.image-upload"
    )

    private let audioPlaybackPipeline = RealtimeAudioPlaybackPipeline(
        label: "com.lunflux.hyper-meta-ai.omni.audio-playback",
        outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
        maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
        maximumBufferedResponseMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumBufferedResponseMilliseconds,
        maximumBufferedResponseChunks: RealtimeProviderAudioProfiles.qwen.maximumBufferedResponseChunkCount,
        responseBufferOverflowPolicy: .rejectIncoming
    )
    private let realtimeSessionLock = NSLock()
    private var realtimeSessionGeneration = 0
    private let sessionConfigurationGate = RealtimeSessionConfigurationGate()
    private let logger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "OmniRealtime"
    )

    // Callbacks
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)? // 用户语音识别结果
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
    private var eventIdCounter = 0
    private let eventIDLock = NSLock()
    #if DEBUG
    // Accessed only from the serial URLSession delegate queue.
    private var responseAudioDebugState = OmniResponseAudioDebugState()
    #endif

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
    }

    // MARK: - WebSocket Connection

    func connect() {
        let generation = beginRealtimeSession()
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Omni] 准备连接 WebSocket: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ [Omni] 无效的 URL")
            onError?("Invalid URL")
            return
        }

        imageUploadPipeline.start(generation: generation)

        audioPlaybackPipeline.start(
            generation: generation,
            onFailure: { [weak self] message in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                self.onError?(message)
            },
            onResponsePlaybackComplete: { [weak self] completedGeneration in
                guard let self, self.isCurrentRealtimeSession(completedGeneration) else { return }
                #if DEBUG
                print("✅ [Omni] 当前响应的音频已实际播放完毕")
                #endif
                self.onAudioDone?()
            }
        )

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: webSocketDelegateQueue
        )

        let task = urlSession?.webSocketTask(with: request)
        webSocket = task
        task?.resume()

        print("🔌 [Omni] WebSocket 任务已启动")
        if let task {
            receiveMessage(on: task, generation: generation)
        }
    }

    func disconnect() {
        print("🔌 [Omni] 断开 WebSocket 连接")
        invalidateRealtimeSession()
        imageUploadPipeline.stop()
        audioPlaybackPipeline.stop()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        audioControlQueue.async { [weak self] in
            self?.stopRecordingOnAudioControlQueue(deactivateAudioSession: true)
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

    private func currentRealtimeSessionGeneration() -> Int {
        realtimeSessionLock.lock()
        defer { realtimeSessionLock.unlock() }
        return realtimeSessionGeneration
    }

    // MARK: - Session Configuration

    private func configureSession() {
        // 根据当前语言设置获取语音和提示词
        let voice = LanguageManager.staticTtsVoice
        let instructions = LiveAIModeManager.staticSystemPrompt

        sendEvent(
            Self.makeSessionConfiguration(
                eventID: generateEventId(),
                voice: voice,
                instructions: instructions
            )
        )
    }

    static func makeSessionConfiguration(
        eventID: String,
        voice: String,
        instructions: String
    ) -> [String: Any] {
        [
            "event_id": eventID,
            "type": OmniClientEvent.sessionUpdate.rawValue,
            "session": [
                "modalities": ["text", "audio"],
                "voice": voice,
                // Qwen Realtime defines both values as the canonical `pcm`;
                // input is 16 kHz PCM16 and output is 24 kHz PCM16.
                "input_audio_format": RealtimeProviderAudioProfiles.qwen.sessionInputFormat,
                "output_audio_format": RealtimeProviderAudioProfiles.qwen.sessionOutputFormat,
                "smooth_output": true,
                "instructions": instructions,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 800
                ]
            ]
        ]
    }

    // MARK: - Audio Recording

    func startRecording() {
        let realtimeGeneration = currentRealtimeSessionGeneration()
        audioControlQueue.async { [weak self] in
            self?.startRecordingOnAudioControlQueue(realtimeGeneration: realtimeGeneration)
        }
    }

    private func startRecordingOnAudioControlQueue(realtimeGeneration: Int) {
        guard isCurrentRealtimeSession(realtimeGeneration) else {
            return
        }
        guard !isRecording else {
            return
        }

        do {
            print("🎤 [Omni] 开始录音")

            if audioEngine == nil {
                setupAudioEngine()
            }

            // Stop engine if already running and remove any existing taps.
            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
            audioUploadPipeline.stop()
            audioUploadGeneration &+= 1
            let generation = audioUploadGeneration

            try AudioSessionCoordinator.shared.activate(.liveAI, profile: .voiceChat)
            let audioSession = AVAudioSession.sharedInstance()
            let inputName = audioSession.currentRoute.inputs.first?.portName ?? "none"
            let outputNames = audioSession.currentRoute.outputs.map(\.portName).joined(separator: ",")
            logger.info(
                "Omni audio route input=\(inputName, privacy: .public) output=\(outputNames, privacy: .public) rate=\(audioSession.sampleRate, privacy: .public)"
            )

            guard let engine = audioEngine else {
                print("❌ [Omni] 音频引擎未初始化")
                AudioSessionCoordinator.shared.deactivate(.liveAI)
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            #if DEBUG
            let inputRoute = audioSession.currentRoute.inputs.map {
                "\($0.portName) [\($0.portType.rawValue)]"
            }.joined(separator: ", ")
            let outputRoute = audioSession.currentRoute.outputs.map {
                "\($0.portName) [\($0.portType.rawValue)]"
            }.joined(separator: ", ")
            print(
                "🎙️ [Omni] 实时音频路由: category=\(audioSession.category.rawValue) "
                    + "mode=\(audioSession.mode.rawValue) input=\(inputRoute) output=\(outputRoute) "
                    + "sessionRate=\(audioSession.sampleRate) inputRate=\(inputFormat.sampleRate) "
                    + "channels=\(inputFormat.channelCount)"
            )
            #endif

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
                messageBuilder: Self.makeAudioUploadMessage,
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
            print("✅ [Omni] 录音已启动")

        } catch {
            audioUploadPipeline.stop()
            AudioSessionCoordinator.shared.deactivate(.liveAI)
            onRecordingStateChanged?(false)
            print("❌ [Omni] 启动录音失败: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        audioControlQueue.async { [weak self] in
            self?.stopRecordingOnAudioControlQueue(deactivateAudioSession: false)
        }
    }

    private func stopRecordingOnAudioControlQueue(deactivateAudioSession: Bool) {
        audioUploadGeneration &+= 1
        audioUploadPipeline.stop()

        if isRecording {
            print("🛑 [Omni] 停止录音")
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            isRecording = false
            onRecordingStateChanged?(false)
        }

        if deactivateAudioSession {
            AudioSessionCoordinator.shared.deactivate(.liveAI)
        }
    }

    // MARK: - Send Events

    private func sendEvent(_ event: [String: Any], generation: Int? = nil) {
        if let generation, !isCurrentRealtimeSession(generation) {
            return
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Omni] 无法序列化事件")
            return
        }

        if let generation, !isCurrentRealtimeSession(generation) {
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                print("❌ [Omni] 发送事件失败: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    private static func makeAudioUploadMessage(_ audioData: Data) -> URLSessionWebSocketTask.Message? {
        let event: [String: Any] = [
            "event_id": "audio_\(UUID().uuidString)",
            "type": OmniClientEvent.inputAudioBufferAppend.rawValue,
            "audio": audioData.base64EncodedString()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return .string(jsonString)
    }

    func sendImageAppend(_ image: UIImage) {
        let generation = currentRealtimeSessionGeneration()
        _ = imageUploadPipeline.submit(image, generation: generation) { [weak self] imageData in
            guard let self, self.isCurrentRealtimeSession(generation) else { return }

            print("📸 [Omni] 发送图片: \(imageData.count) bytes")

            let event: [String: Any] = [
                "event_id": self.generateEventId(),
                "type": OmniClientEvent.inputImageBufferAppend.rawValue,
                "image": imageData.base64EncodedString()
            ]
            self.sendEvent(event, generation: generation)
        }
    }

    func commitAudioBuffer() {
        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputAudioBufferCommit.rawValue
        ]
        sendEvent(event)
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
                print("❌ [Omni] 接收消息失败: \(error.localizedDescription)")
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

        logUnexpectedResponseEvent(type: type, json: json)

        if type == OmniServerEvent.sessionCreated.rawValue {
            logger.debug("Qwen session created; waiting for configuration acknowledgement")
            return
        }

        if type == OmniServerEvent.sessionUpdated.rawValue {
            guard isCurrentRealtimeSession(generation),
                  sessionConfigurationGate.confirm(generation: generation) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRealtimeSession(generation) else { return }
                self.logger.info("Qwen session configuration confirmed")
                self.onConnected?()
            }
            return
        }

        if type == OmniServerEvent.responseCreated.rawValue {
            #if DEBUG
            if let responseSequence = responseAudioDebugState.beginResponseIfNeeded() {
                print("🤖 [Omni] 响应 #\(responseSequence) 已创建，等待首个音频片段")
            }
            #endif
            return
        }

        if type == OmniServerEvent.responseAudioDelta.rawValue {
            guard let base64Audio = json["delta"] as? String,
                  let audioData = Data(base64Encoded: base64Audio) else {
                logger.error("Qwen audio delta was missing valid PCM payload")
                audioPlaybackPipeline.recordUnsupportedFormat()
                #if DEBUG
                if responseAudioDebugState.recordInvalidAudioPayload() {
                    print("❌ [Omni] 响应音频片段缺少有效 PCM Base64 负载")
                }
                #endif
                return
            }
            let result = audioPlaybackPipeline.enqueue(audioData, generation: generation)
            #if DEBUG
            let diagnostics = responseAudioDebugState.recordAudioDelta(
                byteCount: audioData.count,
                result: result
            )
            if diagnostics.first {
                print("🔊 [Omni] 收到首个响应音频片段: \(audioData.count) bytes, enqueue=\(String(describing: result))")
            } else if diagnostics.rejected {
                print("⚠️ [Omni] 响应音频片段被播放队列拒绝: \(String(describing: result))")
            } else if diagnostics.replacement {
                print(
                    "⚠️ [Omni] 响应音频背压替换旧包: "
                        + "chunks=\(diagnostics.replacedChunks), frames=\(diagnostics.replacedFrames)"
                )
            }
            #endif
            if result.isAccepted, isCurrentRealtimeSession(generation) {
                onAudioDelta?(audioData)
            }
            return
        }

        if type == OmniServerEvent.responseAudioDone.rawValue {
            audioPlaybackPipeline.finishResponse(generation: generation)
            logResponseAudioCompletionIfNeeded()
            return
        }

        if type == OmniServerEvent.responseAudioTranscriptDelta.rawValue {
            guard isCurrentRealtimeSession(generation),
                  let delta = json["delta"] as? String else {
                return
            }
            onTranscriptDelta?(delta)
            return
        }

        if type == OmniServerEvent.responseAudioTranscriptDone.rawValue {
            guard isCurrentRealtimeSession(generation) else { return }
            onTranscriptDone?(json["transcript"] as? String ?? json["text"] as? String ?? "")
            return
        }

        if type == OmniServerEvent.responseDone.rawValue {
            audioPlaybackPipeline.finishResponse(generation: generation)
            logResponseAudioCompletionIfNeeded()
            guard isCurrentRealtimeSession(generation) else { return }
            onTranscriptDone?("")
            return
        }

        if type == OmniServerEvent.inputAudioBufferSpeechStarted.rawValue {
            // A new user turn invalidates queued output from the previous turn
            // before it can bleed into the next response.
            audioPlaybackPipeline.interrupt(generation: generation)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentRealtimeSession(generation) else { return }

            switch type {
            case OmniServerEvent.inputAudioBufferSpeechStarted.rawValue:
                print("🎤 [Omni] 检测到语音开始")
                self.onSpeechStarted?()

            case OmniServerEvent.inputAudioBufferSpeechStopped.rawValue:
                print("🛑 [Omni] 检测到语音停止")
                self.onSpeechStopped?()

            case OmniServerEvent.conversationItemInputAudioTranscriptionCompleted.rawValue:
                // 用户语音识别完成
                if let transcript = json["transcript"] as? String {
                    print("👤 [Omni] 用户说: \(transcript)")
                    self.onUserTranscript?(transcript)
                }

            case OmniServerEvent.conversationItemCreated.rawValue:
                // 可能包含其他类型的会话项
                break

            case OmniServerEvent.error.rawValue:
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    print("❌ [Omni] 服务器错误: \(message)")
                    self.onError?(message)
                }

            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private func generateEventId() -> String {
        eventIDLock.lock()
        defer { eventIDLock.unlock() }
        eventIdCounter += 1
        return "event_\(eventIdCounter)_\(UUID().uuidString.prefix(8))"
    }

    private func logUnexpectedResponseEvent(type: String, json: [String: Any]) {
        #if DEBUG
        guard type.hasPrefix("response."),
              type != OmniServerEvent.responseCreated.rawValue,
              type != OmniServerEvent.responseAudioTranscriptDelta.rawValue,
              type != OmniServerEvent.responseAudioTranscriptDone.rawValue,
              type != OmniServerEvent.responseAudioDelta.rawValue,
              type != OmniServerEvent.responseAudioDone.rawValue,
              type != OmniServerEvent.responseDone.rawValue else {
            return
        }
        let keys = json.keys.sorted().joined(separator: ",")
        logger.debug(
            "Unhandled Qwen response event type=\(type, privacy: .public) keys=\(keys, privacy: .public)"
        )
        #endif
    }

    private func logResponseAudioCompletionIfNeeded() {
        #if DEBUG
        guard let summary = responseAudioDebugState.finishResponse() else { return }
        print(
            "🔊 [Omni] 响应 #\(summary.sequence) 音频结束: "
                + "deltas=\(summary.audioDeltas), bytes=\(summary.audioBytes), "
                + "rejected=\(summary.rejected), replacedChunks=\(summary.replacedChunks), "
                + "replacedFrames=\(summary.replacedFrames)"
        )
        #endif
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OmniRealtimeService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Omni] WebSocket 连接已建立, protocol: \(`protocol` ?? "none")")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Omni] WebSocket 已断开, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
    }
}
