/*
 * Live Translate ViewModel
 * 实时翻译状态管理
 */

import Foundation
import SwiftUI
import UIKit

@MainActor
class LiveTranslateViewModel: ObservableObject {

    // MARK: - Connection State
    @Published var isConnected = false
    @Published var isRecording = false

    // MARK: - Translation State
    @Published var currentTranslation = ""       // 当前翻译结果
    @Published var currentOriginal = ""          // 当前原文（暂不支持，保留字段）
    @Published var streamingTranslation = ""     // 流式翻译片段
    @Published var translationHistory: [TranslateRecord] = []

    // MARK: - Error State
    @Published var errorMessage: String?
    @Published var showError = false

    // MARK: - Settings (持久化)
    @Published var sourceLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_source_language")
            updateServiceSettings()
        }
    }

    @Published var targetLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_target_language")
            updateServiceSettings()
        }
    }

    @Published var selectedVoice: TranslateVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: "translate_voice")
            updateServiceSettings()
        }
    }

    @Published var audioOutputEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioOutputEnabled, forKey: "translate_audio_enabled")
            updateServiceSettings()
        }
    }

    @Published var imageEnhanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(imageEnhanceEnabled, forKey: "translate_image_enhance")
        }
    }

    /// 使用 iPhone 麦克风（而非眼镜麦克风）
    /// 眼镜麦克风适合翻译自己说的话，iPhone 麦克风适合翻译对方说的话
    @Published var usePhoneMic: Bool {
        didSet {
            UserDefaults.standard.set(usePhoneMic, forKey: "translate_use_phone_mic")
        }
    }

    // MARK: - Video Frame (for image enhancement)
    var currentVideoFrame: UIImage?

    // MARK: - Private
    private var translateService: LiveTranslateService?
    private var imageTimer: Timer?
    private let translationCoalescer = RealtimeTextDeltaCoalescer(
        label: "com.lunflux.hypermetaai.realtime-text.translate"
    )
    private var translationSessionGeneration = 0
    private var activeTranslationResponseID: UInt64 = 0
    private var latestTranslationSequence: UInt64 = 0

    // MARK: - Init

    init() {
        // 从 UserDefaults 加载设置
        let savedSource = UserDefaults.standard.string(forKey: "translate_source_language") ?? "en"
        self.sourceLanguage = TranslateLanguage(rawValue: savedSource) ?? .en

        let savedTarget = UserDefaults.standard.string(forKey: "translate_target_language") ?? "zh"
        self.targetLanguage = TranslateLanguage(rawValue: savedTarget) ?? .zh

        let savedVoice = UserDefaults.standard.string(forKey: "translate_voice") ?? "Cherry"
        self.selectedVoice = TranslateVoice(rawValue: savedVoice) ?? .cherry

        self.audioOutputEnabled = UserDefaults.standard.object(forKey: "translate_audio_enabled") as? Bool ?? true
        self.imageEnhanceEnabled = UserDefaults.standard.object(forKey: "translate_image_enhance") as? Bool ?? false
        self.usePhoneMic = UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? false
    }

    // MARK: - Connection

    func connect() {
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "livetranslate.error.noApiKey".localized
            showError = true
            return
        }

        startTranslationSession()
        translateService = LiveTranslateService(apiKey: apiKey)
        setupCallbacks()

        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )

        translateService?.connect()
    }

    func disconnect() {
        stopImageTimer()
        stopTranslationSession()
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isRecording = false
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        translateService?.startRecording(usePhoneMic: usePhoneMic)
    }

    func stopRecording() {
        translateService?.stopRecording()
        isRecording = false
        stopImageTimer()

        // 保存当前翻译到历史
        if !currentTranslation.isEmpty {
            let record = TranslateRecord(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                originalText: currentOriginal,
                translatedText: currentTranslation
            )
            translationHistory.insert(record, at: 0)

            // 限制历史记录数量
            if translationHistory.count > 50 {
                translationHistory = Array(translationHistory.prefix(50))
            }
        }
    }

    // MARK: - Language Swap

    func swapLanguages() {
        // 只有当两种语言都支持作为目标语言时才能交换
        guard sourceLanguage.supportsAudioOutput && targetLanguage.supportsAudioOutput else {
            errorMessage = "livetranslate.error.cannotSwap".localized
            showError = true
            return
        }

        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp

        // 清空当前翻译
        currentTranslation = ""
        streamingTranslation = ""
    }

    // MARK: - Video Frame

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    // MARK: - Private Methods

    private func setupCallbacks() {
        translateService?.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
                print("✅ [TranslateVM] 已连接")
            }
        }

        let translationCoalescer = translationCoalescer
        translateService?.onTranslationDelta = { [weak translationCoalescer] delta in
            translationCoalescer?.append(delta)
        }

        translateService?.onTranslationText = { [weak translationCoalescer] text in
            translationCoalescer?.finish(finalText: text)
        }

        translateService?.onAudioDone = {
            DispatchQueue.main.async {
                print("🔊 [TranslateVM] 音频播放完成")
            }
        }

        translateService?.onRecordingStateChanged = { [weak self] isRecording in
            DispatchQueue.main.async {
                self?.isRecording = isRecording
                if isRecording, self?.imageEnhanceEnabled == true {
                    self?.startImageTimer()
                } else if !isRecording {
                    self?.stopImageTimer()
                }
            }
        }

        translateService?.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = error
                self?.showError = true
                self?.isRecording = false
                self?.stopImageTimer()
            }
        }
    }

    private func updateServiceSettings() {
        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )
    }

    private func startTranslationSession() {
        translationSessionGeneration &+= 1
        activeTranslationResponseID = 0
        latestTranslationSequence = 0
        streamingTranslation = ""

        let generation = translationSessionGeneration
        translationCoalescer.start(generation: generation) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.consumeTranslationSnapshot(snapshot)
            }
        }
    }

    private func stopTranslationSession() {
        translationSessionGeneration &+= 1
        activeTranslationResponseID = 0
        latestTranslationSequence = 0
        translationCoalescer.stop()
        streamingTranslation = ""
    }

    private func consumeTranslationSnapshot(_ snapshot: RealtimeTextDeltaSnapshot) {
        guard snapshot.sessionGeneration == translationSessionGeneration else { return }

        if snapshot.responseID > activeTranslationResponseID {
            activeTranslationResponseID = snapshot.responseID
            latestTranslationSequence = 0
            streamingTranslation = ""
        }
        guard snapshot.responseID == activeTranslationResponseID,
              snapshot.sequence > latestTranslationSequence else {
            return
        }
        latestTranslationSequence = snapshot.sequence

        if snapshot.isFinal {
            currentTranslation = snapshot.text
            streamingTranslation = ""
        } else {
            streamingTranslation = snapshot.text
        }
    }

    // MARK: - Image Timer

    private func startImageTimer() {
        stopImageTimer()
        imageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendCurrentFrame()
            }
        }
    }

    private func stopImageTimer() {
        imageTimer?.invalidate()
        imageTimer = nil
    }

    private func sendCurrentFrame() {
        guard imageEnhanceEnabled, let frame = currentVideoFrame else { return }
        translateService?.sendImageFrame(frame)
    }

    // MARK: - Clear

    func clearTranslation() {
        currentTranslation = ""
        streamingTranslation = ""
        currentOriginal = ""
    }

    func clearHistory() {
        translationHistory.removeAll()
    }
}
