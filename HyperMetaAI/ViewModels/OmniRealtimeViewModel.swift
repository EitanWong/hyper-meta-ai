/*
 * Omni Realtime ViewModel
 * Manages real-time multimodal conversation with AI
 * Supports both Alibaba Qwen Omni and Google Gemini Live
 */

import Foundation
import SwiftUI
import AVFoundation

@MainActor
class OmniRealtimeViewModel: ObservableObject {

    // Published state
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var currentTranscript = ""
    @Published var conversationHistory: [ConversationMessage] = []
    @Published var errorMessage: String?
    @Published var showError = false

    // Services (use one based on provider)
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private let provider: LiveAIProvider
    private let apiKey: String

    // Video frame
    private var currentVideoFrame: UIImage?
    private var isImageSendingEnabled = false // 是否已启用图片发送（第一次音频后）
    private var hasPersistedConversation = false
    private let transcriptCoalescer = RealtimeTextDeltaCoalescer(
        label: "com.lunflux.hypermetaai.realtime-text.omni"
    )
    private var transcriptSessionGeneration = 0
    private var activeTranscriptResponseID: UInt64 = 0
    private var latestTranscriptSequence: UInt64 = 0

    init(apiKey: String) {
        self.apiKey = apiKey
        self.provider = APIProviderManager.staticLiveAIProvider

        // Initialize appropriate service based on provider
        switch provider {
        case .alibaba:
            self.omniService = OmniRealtimeService(apiKey: apiKey)
        case .google:
            self.geminiService = GeminiLiveService(apiKey: apiKey)
        }

        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        switch provider {
        case .alibaba:
            setupOmniCallbacks()
        case .google:
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [OmniVM] 收到第一次音频发送回调，启用图片发送")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                    print("📸 [OmniVM] 图片发送已启用（语音触发模式）")
                }
            }
        }

        omniService.onRecordingStateChanged = { [weak self] isRecording in
            Task { @MainActor in
                self?.isRecording = isRecording
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = true

                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [OmniVM] 检测到用户语音，发送当前视频帧")
                    strongSelf.omniService?.sendImageAppend(frame)
                }
            }
        }

        omniService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        let transcriptCoalescer = transcriptCoalescer
        omniService.onTranscriptDelta = { [weak transcriptCoalescer] delta in
            transcriptCoalescer?.append(delta)
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [OmniVM] 保存用户语音: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak transcriptCoalescer] fullText in
            transcriptCoalescer?.finish(finalText: fullText)
        }

        omniService.onAudioDone = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [GeminiVM] 收到第一次音频发送回调，启用图片发送")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                    print("📸 [GeminiVM] 图片发送已启用（语音触发模式）")
                }
            }
        }

        geminiService.onRecordingStateChanged = { [weak self] isRecording in
            Task { @MainActor in
                self?.isRecording = isRecording
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = true

                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [GeminiVM] 检测到用户语音，发送当前视频帧")
                    strongSelf.geminiService?.sendImageInput(frame)
                }
            }
        }

        geminiService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        let transcriptCoalescer = transcriptCoalescer
        geminiService.onTranscriptDelta = { [weak transcriptCoalescer] (delta: String) in
            transcriptCoalescer?.append(delta)
        }

        geminiService.onUserTranscript = { [weak self] (userText: String) in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [GeminiVM] 保存用户语音: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak transcriptCoalescer] (fullText: String) in
            transcriptCoalescer?.finish(finalText: fullText)
        }

        geminiService.onAudioDone = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        geminiService.onError = { [weak self] (error: String) in
            Task { @MainActor in
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }
        hasPersistedConversation = false
        startTranscriptSession()

        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    func disconnect() {
        saveConversationIfNeeded()
        stopTranscriptSession()

        stopRecording()

        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        isConnected = false
        isImageSendingEnabled = false
    }

    private func startTranscriptSession() {
        transcriptSessionGeneration &+= 1
        activeTranscriptResponseID = 0
        latestTranscriptSequence = 0
        currentTranscript = ""

        let generation = transcriptSessionGeneration
        transcriptCoalescer.start(generation: generation) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.consumeTranscriptSnapshot(snapshot)
            }
        }
    }

    private func stopTranscriptSession() {
        transcriptSessionGeneration &+= 1
        activeTranscriptResponseID = 0
        latestTranscriptSequence = 0
        transcriptCoalescer.stop()
        currentTranscript = ""
    }

    private func consumeTranscriptSnapshot(_ snapshot: RealtimeTextDeltaSnapshot) {
        guard snapshot.sessionGeneration == transcriptSessionGeneration else { return }

        if snapshot.responseID > activeTranscriptResponseID {
            activeTranscriptResponseID = snapshot.responseID
            latestTranscriptSequence = 0
            currentTranscript = ""
        }
        guard snapshot.responseID == activeTranscriptResponseID,
              snapshot.sequence > latestTranscriptSequence else {
            return
        }
        latestTranscriptSequence = snapshot.sequence

        if snapshot.isFinal {
            guard !snapshot.text.isEmpty else {
                currentTranscript = ""
                return
            }
            conversationHistory.append(
                ConversationMessage(role: .assistant, content: snapshot.text)
            )
            currentTranscript = ""
        } else {
            currentTranscript = snapshot.text
        }
    }

    private func saveConversationIfNeeded() {
        guard !hasPersistedConversation else { return }
        hasPersistedConversation = true

        guard !conversationHistory.isEmpty else { return }

        let aiModel: String
        switch provider {
        case .alibaba:
            aiModel = "qwen3-omni-flash-realtime"
        case .google:
            aiModel = "gemini-2.0-flash-exp"
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: aiModel,
            language: "zh-CN" // TODO: 从设置中获取
        )

        ConversationStorage.shared.saveConversation(record)
        print("💾 [LiveAI] 对话已保存: \(conversationHistory.count) 条消息")
    }

    // MARK: - Recording

    func startRecording() {
        guard isConnected else {
            print("⚠️ [LiveAI] 未连接，无法开始录音")
            errorMessage = "请先连接服务器"
            showError = true
            return
        }

        print("🎤 [LiveAI] 开始录音（语音触发模式）- Provider: \(provider.displayName)")

        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }

    }

    func stopRecording() {
        print("🛑 [LiveAI] 停止录音")

        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }

        isRecording = false
    }

    // MARK: - Video Frames

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    // MARK: - Manual Mode (if needed)

    func sendMessage() {
        omniService?.commitAudioBuffer()
    }

    // MARK: - Cleanup

    func dismissError() {
        showError = false
    }

    nonisolated deinit {
        Task { @MainActor [weak omniService, weak geminiService] in
            omniService?.disconnect()
            geminiService?.disconnect()
        }
    }
}

// MARK: - Conversation Message

struct ConversationMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
    }
}
