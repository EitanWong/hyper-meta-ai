/*
 * TTS Service
 * 文本转语音服务 - 使用阿里云 qwen3-tts-flash API
 * 使用和 OmniRealtimeService 相同的 AVAudioEngine 方式播放
 */

import AVFoundation
import Accelerate
import Foundation

@MainActor
class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false
    /// Normalized energy at the playback mixer. Used by the assistant orb.
    @Published private(set) var outputLevel: Float = 0

    private let baseURL = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    private let model = "qwen3-tts-flash"

    // 根据当前语言设置获取语音
    private var voice: String {
        return LanguageManager.staticTtsVoice
    }

    // 根据当前语言设置获取语言类型
    private var languageType: String {
        return LanguageManager.staticApiLanguageCode
    }

    // 使用和 OmniRealtimeService 一样的 AVAudioEngine 方式
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    // 使用 Float32 标准格式，兼容 iOS 18+
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private var isPlaybackEngineRunning = false

    private var currentTask: Task<Void, Never>?
    private var streamingContinuation: AsyncStream<String>.Continuation?
    private var systemSynthesizer: AVSpeechSynthesizer?
    private var outputProxyTask: Task<Void, Never>?
    private var lastOutputLevelUpdate = CACurrentMediaTime()
    private var speechGeneration = 0
    private var pendingPlaybackBuffers = 0

    private override init() {
        super.init()
        setupPlaybackEngine()
    }

    // MARK: - Audio Engine Setup (和 OmniRealtimeService 一样)

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [TTS] 无法初始化播放引擎")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            let level = Self.normalizedAudioLevel(buffer)
            Task { @MainActor [weak self] in
                self?.publishOutputLevel(level)
            }
        }
        playbackEngine.prepare()

        print("✅ [TTS] 播放引擎初始化完成: Float32 @ 24kHz")
    }

    /// 配置音频会话（需要在启动播放引擎之前调用）
    private func configureAudioSession() async {
        do {
            try await AudioSessionCoordinator.shared.activateAsync(.textToSpeech, profile: .playback)
            print("✅ [TTS] Audio session 已配置")
        } catch {
            print("⚠️ [TTS] Audio session 配置失败: \(error), 继续尝试播放...")
            // 不要抛出错误，尝试使用现有会话播放
        }
    }

    private func startPlaybackEngine() async {
        guard let playbackEngine = playbackEngine, !isPlaybackEngineRunning else { return }

        await configureAudioSession()
        do {
            try playbackEngine.start()
            playerNode?.play()
            isPlaybackEngineRunning = true
            print("✅ [TTS] 播放引擎已启动")
        } catch {
            print("❌ [TTS] 播放引擎启动失败: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
    }

    nonisolated static func normalizedAudioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return 0 }
        let frameCount = vDSP_Length(buffer.frameLength)
        var peakRMS: Float = 0
        for channelIndex in 0..<Int(buffer.format.channelCount) {
            var rms: Float = 0
            vDSP_rmsqv(channels[channelIndex], 1, &rms, frameCount)
            peakRMS = max(peakRMS, rms)
        }
        return min(max(peakRMS * 8, 0), 1)
    }

    private func publishOutputLevel(_ level: Float) {
        guard isSpeaking else {
            outputLevel = 0
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastOutputLevelUpdate >= 0.08 || level == 0 else { return }
        lastOutputLevelUpdate = now
        outputLevel = min(max(level, 0), 1)
    }

    /// System speech has no PCM tap; provide a low-rate visual proxy only while it speaks.
    private func startOutputProxy() {
        outputProxyTask?.cancel()
        outputProxyTask = Task { @MainActor [weak self] in
            var phase: Float = 0
            while let self, !Task.isCancelled, self.isSpeaking {
                phase += 0.32
                self.outputLevel = 0.18 + 0.12 * abs(sin(phase))
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func stopOutputLevelTracking() {
        outputProxyTask?.cancel()
        outputProxyTask = nil
        outputLevel = 0
    }

    // MARK: - API Request Models

    struct TTSRequest: Codable {
        let model: String
        let input: Input

        struct Input: Codable {
            let text: String
            let voice: String
            let language_type: String
        }
    }

    // MARK: - Public Methods

    /// 预配置音频会话（在停止流之前调用）
    func prepareAudioSession() {
        Task { @MainActor [weak self] in
            await self?.configureAudioSession()
        }
        print("🔊 [TTS] 音频会话已预配置")
    }

    /// 播报文本
    /// - 阿里云 API：使用阿里云 qwen3-tts-flash
    /// - OpenRouter API：使用系统 TTS
    func speak(_ text: String, apiKey: String? = nil) {
        stop()
        let generation = speechGeneration

        // OpenRouter 使用系统 TTS
        if APIProviderManager.staticCurrentProvider == .openrouter {
            print("🔊 [TTS] OpenRouter mode, using system TTS")
            isSpeaking = true
            currentTask = Task { [weak self] in
                guard let self else { return }
                defer { self.finishSpeech(generation: generation) }
                self.startOutputProxy()
                await fallbackToSystemTTS(text: text)
            }
            return
        }

        // 阿里云：使用阿里云 TTS
        let key = apiKey ?? APIKeyManager.shared.getAPIKey(for: .alibaba)

        guard let finalKey = key, !finalKey.isEmpty else {
            print("❌ [TTS] No Alibaba API key, falling back to system TTS")
            isSpeaking = true
            currentTask = Task { [weak self] in
                guard let self else { return }
                defer { self.finishSpeech(generation: generation) }
                self.startOutputProxy()
                await fallbackToSystemTTS(text: text)
            }
            return
        }

        print("🔊 [TTS] Speaking with qwen3-tts-flash: \(text.prefix(50))...")

        isSpeaking = true

        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSpeech(generation: generation) }
            do {
                try await synthesizeAndPlay(
                    text: text,
                    apiKey: finalKey,
                    generation: generation
                )
            } catch {
                if !Task.isCancelled {
                    print("❌ [TTS] Error: \(error)")
                    // 失败时回退到系统 TTS
                    self.stopPlaybackEngine()
                    self.startOutputProxy()
                    await fallbackToSystemTTS(text: text)
                }
            }
        }
    }

    /// Queue a complete phrase as soon as it arrives from a streaming text
    /// model. The service remains in one speaking session across phrases, so
    /// callers can overlap language-model generation with speech playback.
    func enqueueStreamingSpeechSegment(_ text: String, apiKey: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if streamingContinuation == nil {
            startStreamingSpeech(apiKey: apiKey)
        }
        streamingContinuation?.yield(trimmed)
    }

    /// Close the segment stream after the final model delta. Already queued
    /// phrases continue playing before the audio session is released.
    func finishStreamingSpeech() {
        streamingContinuation?.finish()
        streamingContinuation = nil
    }

    /// 停止播报
    func stop() {
        speechGeneration &+= 1
        streamingContinuation?.finish()
        streamingContinuation = nil
        currentTask?.cancel()
        currentTask = nil
        pendingPlaybackBuffers = 0
        stopOutputLevelTracking()
        systemSynthesizer?.stopSpeaking(at: .immediate)
        systemSynthesizer = nil
        stopPlaybackEngine()
        AudioSessionCoordinator.shared.deactivateAsync(.textToSpeech)
        isSpeaking = false
        print("🔊 [TTS] Stopped")
    }

    private func finishSpeech(generation: Int) {
        guard speechGeneration == generation else { return }
        streamingContinuation = nil
        currentTask = nil
        pendingPlaybackBuffers = 0
        systemSynthesizer = nil
        stopPlaybackEngine()
        stopOutputLevelTracking()
        AudioSessionCoordinator.shared.deactivateAsync(.textToSpeech)
        isSpeaking = false
    }

    // MARK: - Private Methods

    private func startStreamingSpeech(apiKey: String?) {
        stop()
        let generation = speechGeneration
        let streamPair = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        streamingContinuation = streamPair.continuation
        isSpeaking = true

        let usesSystemSpeech = APIProviderManager.staticCurrentProvider == .openrouter
        let selectedKey = apiKey ?? APIKeyManager.shared.getAPIKey(for: .alibaba)
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSpeech(generation: generation) }
            for await segment in streamPair.stream {
                guard !Task.isCancelled, self.speechGeneration == generation else { return }
                await self.playStreamingSegment(
                    segment,
                    apiKey: selectedKey,
                    usesSystemSpeech: usesSystemSpeech,
                    generation: generation
                )
            }
        }
    }

    private func playStreamingSegment(
        _ text: String,
        apiKey: String?,
        usesSystemSpeech: Bool,
        generation: Int
    ) async {
        if usesSystemSpeech || apiKey?.isEmpty != false {
            startOutputProxy()
            await fallbackToSystemTTS(text: text)
            stopOutputLevelTracking()
            return
        }

        do {
            try await synthesizeAndPlay(
                text: text,
                apiKey: apiKey!,
                generation: generation
            )
        } catch {
            guard !Task.isCancelled, speechGeneration == generation else { return }
            stopPlaybackEngine()
            startOutputProxy()
            await fallbackToSystemTTS(text: text)
            stopOutputLevelTracking()
        }
    }

    private func synthesizeAndPlay(
        text: String,
        apiKey: String,
        generation: Int
    ) async throws {
        guard let url = URL(string: baseURL) else {
            throw TTSError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.timeoutInterval = 30

        let ttsRequest = TTSRequest(
            model: model,
            input: TTSRequest.Input(
                text: text,
                voice: voice,
                language_type: languageType
            )
        )

        request.httpBody = try JSONEncoder().encode(ttsRequest)

        print("📡 [TTS] Sending request to qwen3-tts-flash...")

        // 使用 URLSession 的 bytes API 处理 SSE
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("❌ [TTS] API error: \(httpResponse.statusCode)")
            throw TTSError.apiError(statusCode: httpResponse.statusCode)
        }

        // 停止当前播放并重置 playerNode 队列
        playerNode?.stop()
        playerNode?.reset()
        pendingPlaybackBuffers = 0

        // 确保播放引擎在运行
        if !isPlaybackEngineRunning {
            await startPlaybackEngine()
        }

        // 提前调用 play()，让 playerNode 准备好接收 buffer
        playerNode?.play()
        print("▶️ [TTS] 播放引擎和 playerNode 已就绪")

        guard isPlaybackEngineRunning else {
            print("❌ [TTS] 播放引擎未运行")
            throw TTSError.playbackFailed
        }

        var chunkCount = 0
        var totalBytes = 0

        for try await line in bytes.lines {
            if Task.isCancelled { return }

            // SSE 格式: "data: {...}"
            if line.hasPrefix("data:") {
                let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                if jsonString == "[DONE]" {
                    break
                }

                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let output = json["output"] as? [String: Any],
                   let audio = output["audio"] as? [String: Any],
                   let audioString = audio["data"] as? String,
                   !audioString.isEmpty,
                   let audioData = Data(base64Encoded: audioString),
                   !audioData.isEmpty {
                    chunkCount += 1
                    totalBytes += audioData.count
                    if chunkCount == 1 {
                        print("🔊 [TTS] 收到第一个音频片段: \(audioData.count) bytes")
                    }
                    // 流式播放每个音频片段
                    await playAudioChunk(audioData, generation: generation)
                }
            }
        }

        if Task.isCancelled { return }
        guard chunkCount > 0 else { throw TTSError.noAudioData }

        print("🔊 [TTS] Received \(chunkCount) chunks, \(totalBytes) bytes total")

        // 等待播放完成
        await waitForPlaybackCompletion(generation: generation)

        print("🔊 [TTS] Finished playing")
    }

    private func playAudioChunk(_ audioData: Data, generation: Int) async {
        // 跳过空数据
        guard !audioData.isEmpty else {
            return
        }

        guard let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("⚠️ [TTS] playerNode 或 playbackFormat 未初始化")
            return
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("⚠️ [TTS] 无法创建 PCM buffer, audioData.count=\(audioData.count)")
            return
        }

        // 确保播放引擎运行中
        if !isPlaybackEngineRunning {
            await startPlaybackEngine()
        }

        // 确保 playerNode 在播放状态（和 OmniRealtimeService 一致）
        if !playerNode.isPlaying {
            playerNode.play()
            print("▶️ [TTS] playerNode.play() 已调用")
        }

        // 调度音频缓冲区播放
        pendingPlaybackBuffers += 1
        playerNode.scheduleBuffer(
            pcmBuffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markPlaybackBufferCompleted(generation: generation)
            }
        }
    }

    private func markPlaybackBufferCompleted(generation: Int) {
        guard speechGeneration == generation, pendingPlaybackBuffers > 0 else { return }
        pendingPlaybackBuffers -= 1
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // 服务器发送的是 PCM16 格式，每帧 2 字节
        let frameCount = data.count / 2
        guard frameCount > 0 else {
            print("⚠️ [TTS] createPCMBuffer: frameCount is 0, data.count=\(data.count)")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("⚠️ [TTS] createPCMBuffer: Failed to create AVAudioPCMBuffer, format=\(format), frameCount=\(frameCount)")
            return nil
        }

        guard let channelData = buffer.floatChannelData else {
            print("⚠️ [TTS] createPCMBuffer: floatChannelData is nil")
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        // 将 PCM16 转换为 Float32（兼容 iOS 18+）
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for i in 0..<frameCount {
                // Int16 范围 -32768 到 32767，转换为 -1.0 到 1.0
                floatData[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }

    private func waitForPlaybackCompletion(generation: Int) async {

        // A bounded drain prevents a broken route from retaining the audio claim.
        let deadline = Date().addingTimeInterval(30)
        while speechGeneration == generation,
              pendingPlaybackBuffers > 0,
              Date() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// 回退到系统 TTS
    private func fallbackToSystemTTS(text: String) async {
        print("🔊 [TTS] Falling back to system TTS")

        await configureAudioSession()

        // 使用实例变量保持强引用，防止被释放
        systemSynthesizer = AVSpeechSynthesizer()

        guard let synthesizer = systemSynthesizer else { return }

        let utterance = AVSpeechUtterance(string: text)
        // 根据当前语言设置选择系统语音
        let voiceLanguage = LanguageManager.staticIsChinese ? "zh-CN" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        print("🔊 [TTS] System TTS speaking: \(text.prefix(30))...")
        synthesizer.speak(utterance)

        // 等待一小段时间让播放开始
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 等待播放完成
        while synthesizer.isSpeaking {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                systemSynthesizer = nil
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        print("✅ [TTS] System TTS finished")
        systemSynthesizer = nil
    }
}

// MARK: - Error Types

enum TTSError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int)
    case noAudioData
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "未配置 API Key"
        case .invalidResponse:
            return "无效的响应"
        case .apiError(let statusCode):
            return "API 错误: \(statusCode)"
        case .noAudioData:
            return "未收到音频数据"
        case .playbackFailed:
            return "音频播放失败"
        }
    }
}
