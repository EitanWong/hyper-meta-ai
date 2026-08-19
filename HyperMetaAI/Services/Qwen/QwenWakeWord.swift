/*
+ * Qwen Wake Word（语音唤醒）
+ * 对应 qwen-audio-agent v1.5+ 的「你好千问」唤醒词能力。
+ * 桌面版唤醒词由网关侧 sherpa-onnx 本地模型监听；iOS 版由 App 原生监听
+ * iPhone 麦克风（Speech framework 中文识别），匹配后向网关发送 wake 事件，
+ * 走与镜腿唤醒相同的重连与退避路径。
+ */

import AVFoundation
import Foundation
import Speech

// MARK: - 唤醒词匹配（纯逻辑，可测）

/// 唤醒词匹配器：对实时转写文本做归一化匹配
struct QwenWakeWordMatcher {
    /// 默认唤醒词（qwen-audio-agent 默认「你好千问」及常见变体）
    static let defaultKeywords = [
        "你好千问",
        "你好，千问",
        "你好 千问",
        "嗨千问",
        "千问",
    ]

    let keywords: [String]

    init(keywords: [String] = QwenWakeWordMatcher.defaultKeywords) {
        self.keywords = keywords
    }

    /// 判断转写文本是否包含任一唤醒词（归一化：去空白/标点、统一大小写）
    func containsWakeWord(in transcript: String) -> Bool {
        let normalized = Self.normalize(transcript)
        guard !normalized.isEmpty else { return false }
        return keywords.contains { keyword in
            let normalizedKeyword = Self.normalize(keyword)
            return !normalizedKeyword.isEmpty && normalized.contains(normalizedKeyword)
        }
    }

    /// 归一化：小写、去空白、去标点（保留中日韩与字母数字）
    static func normalize(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        )
    }
}

// MARK: - 唤醒监听协议（可注入测试）

/// 唤醒词监听器抽象：QwenVoiceSession 依赖此协议，测试注入 Mock
protocol QwenWakeWordListening: AnyObject {
    var isMonitoring: Bool { get }
    /// 匹配到唤醒词（携带命中的原始转写片段）
    var onWakeWord: ((String) -> Void)? { get set }
    /// 实时转写（供 UI 显示）
    var onTranscript: ((String) -> Void)? { get set }

    func startMonitoring() async throws
    func stopMonitoring()
}

// MARK: - Speech framework 实现

/// iOS 原生唤醒词监听：AVAudioEngine 采集 + SFSpeechRecognizer 中文实时识别
final class QwenSpeechWakeWordMonitor: NSObject, QwenWakeWordListening, SFSpeechRecognitionTaskDelegate, SFSpeechRecognizerDelegate {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?
    private let matcher: QwenWakeWordMatcher
    private(set) var isMonitoring = false

    var onWakeWord: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?

    init(matcher: QwenWakeWordMatcher = QwenWakeWordMatcher()) {
        self.matcher = matcher
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        super.init()
        recognizer?.delegate = self
    }

    func startMonitoring() async throws {
        guard !isMonitoring else { return }
        // 语音识别权限：未决定时弹系统授权，拒绝/受限时直接失败（UI 会提示去设置）
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else { throw QwenWakeWordError.recognizerUnavailable }
        case .authorized:
            break
        default:
            throw QwenWakeWordError.recognizerUnavailable
        }
        guard let recognizer, recognizer.isAvailable else {
            throw QwenWakeWordError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        try AppleVoiceAudioFrontEnd.configure(audioEngine)
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.onTranscript?(text)
                if result.isFinal, self.matcher.containsWakeWord(in: text) {
                    self.onWakeWord?(text)
                } else if !result.isFinal, self.matcher.containsWakeWord(in: text) {
                    // 部分结果命中即唤醒（更跟手），随后由会话层停止监听
                    self.onWakeWord?(text)
                }
            }
            if error != nil {
                self.stopMonitoring()
            }
        }
        isMonitoring = true
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isMonitoring = false
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            stopMonitoring()
        }
    }
}

enum QwenWakeWordError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "语音识别不可用"
        }
    }
}

// MARK: - 休眠/唤醒状态机（纯逻辑，可测）

/// 会话休眠与唤醒的状态机：
///   idle → sleeping（网关休眠 / 用户手动休眠）
///   sleeping → listening（开始唤醒词监听）
///   listening → waking（命中唤醒词，正在请求网关唤醒）
///   waking → idle（唤醒完成，会话恢复）
///   sleeping/listening → idle（用户手动唤醒）
struct QwenWakeSessionController: Equatable {
    enum Phase: Equatable {
        case idle
        case sleeping
        case listening
        case waking
    }

    private(set) var phase: Phase = .idle

    mutating func enterSleep() {
        guard phase == .idle || phase == .waking else { return }
        phase = .sleeping
    }

    mutating func startListening() {
        guard phase == .sleeping else { return }
        phase = .listening
    }

    /// 命中唤醒词：请求网关唤醒（带退避，由会话层负责重试）
    mutating func matchWakeWord() {
        guard phase == .listening else { return }
        phase = .waking
    }

    /// 唤醒成功或用户手动唤醒：回到 idle
    mutating func wakeCompleted() {
        phase = .idle
    }

    /// 唤醒失败（网关未连接/监听启动失败）：回到 sleeping 继续监听
    mutating func wakeFailed() {
        switch phase {
        case .listening, .waking:
            phase = .sleeping
        default:
            break
        }
    }
}
