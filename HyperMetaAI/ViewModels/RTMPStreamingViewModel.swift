/*
 * RTMP Streaming ViewModel
 * Manages RTMP live streaming state and UI interactions
 */

import SwiftUI
import Combine
import Security
import os.log
import AVFoundation

private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "RTMPStreaming")

@MainActor
class RTMPStreamingViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var rtmpUrl: String = ""
    @Published var streamKey: String = ""
    @Published var selectedPlatform: StreamingPlatform = .custom
    @Published var bitrate: Int = 2_000_000 // 2 Mbps
    /// 自适应质量（推流中根据网络丢帧自动升降码率/分辨率/帧率档位）
    @Published var adaptiveQualityEnabled: Bool = true
    /// 推流中的实时码率（bps；自适应调整后展示当前值）
    @Published var currentBitrate: Int = 2_000_000
    /// 推流中的当前质量档位（自适应调整后展示分辨率/帧率）
    @Published var currentQualityPreset: RTMPQualityPreset?
    /// 断线后自动重连（按退避间隔自动恢复推流）
    @Published var autoReconnectEnabled: Bool = true
    /// 音频码率跟随质量档位动态调节（弱网时同步下调音频码率）
    @Published var adaptiveAudioEnabled: Bool = true
    /// 已保存的直播场景（按最近更新时间降序）
    @Published var scenarios: [RTMPStreamScenario] = []
    /// 是否正在本地录制
    @Published var isRecording = false
    /// 当前录制时长（秒）
    @Published var recordingDuration: TimeInterval = 0
    /// 标记按钮反馈闪烁
    @Published var markerFlash = false
    /// 历史录制记录（按开始时间降序）
    @Published var recordingRecords: [RTMPRecordingRecord] = []
    /// 正在回放的录制（非 nil 时展示回放面板）
    @Published var playbackRecord: RTMPRecordingRecord?
    /// 直播场景理解（端侧识别当前视野场景并展示标签）
    @Published var liveSceneAnalysisEnabled: Bool = true
    /// 最近识别的场景标签（如 Restaurant）
    @Published var currentSceneLabel: String?
    /// 最近识别的场景摘要（前 3 分类）
    @Published var currentSceneSummary: String?
    /// 场景 → 标题建议（识别到场景后生成，点击复制）
    @Published var sceneSuggestionsEnabled: Bool = true {
        didSet { refreshSceneSuggestions() }
    }
    /// 当前场景生成的直播标题建议
    @Published var sceneSuggestions: [String] = []
    /// 片段导出窗口：标记前秒数（设置页可调，夹取 0-60s）
    @Published var clipLeadSeconds: Double = RTMPClipWindowSettings.defaultLead {
        didSet { persistClipWindow() }
    }
    /// 片段导出窗口：标记后秒数（设置页可调，夹取 0-60s）
    @Published var clipTailSeconds: Double = RTMPClipWindowSettings.defaultTail {
        didSet { persistClipWindow() }
    }
    /// 场景辅助操作反馈（已复制 / 已存入 / 记忆已满，短暂展示后消失）
    @Published var sceneActionFeedback: String?
    /// 是否正在 AI 润色直播标题（防重复触发，按钮显示进度）
    @Published var isPolishingTitle = false
    /// 是否正在请求 Agent 场景分析（防重复触发，按钮显示进度）
    @Published var isAnalyzingScene = false
    /// Agent 场景分析结果（非 nil 时展示结果弹层）
    @Published var sceneAnalysisResult: String?
    /// 场景 AI 端侧离线兜底开关（未配置网关时用 Apple Intelligence 端侧模型，默认开启）
    @Published var localBrainFallbackEnabled: Bool = LocalBrainSettings.enabled {
        didSet { LocalBrainSettings.enabled = localBrainFallbackEnabled }
    }
    /// 最近一次场景 AI 结果是否由端侧模型生成（弹层展示「端侧 AI」徽标）
    @Published var sceneAssistantUsesLocalBrain = false
    /// 最近一次推流会话的诊断快照
    @Published var lastDiagnostics: RTMPDiagnosticsSnapshot?
    /// 历史诊断日志文件（按时间倒序，停止推流自动落盘）
    @Published var diagnosticsLogs: [RTMPDiagnosticsLogEntry] = []
    /// 多目的地并行推流目的地（附加路）
    @Published var destinations: [RTMPDestination] = []
    /// 并行推流会话状态（每路状态 + 聚合）
    @Published var parallelSession = RTMPParallelSessionState()
    /// 隐私保护盾（开启时画面不发流）
    @Published var privacyShielded = false
    /// 画质锁定（暂停自适应档位调整）
    @Published var qualityLocked = false
    /// 开播清单条目
    @Published var checklistItems: [RTMPChecklistItem] = []
    /// 是否记住清单选择（下次直接开播）
    @Published var checklistRemembered = false
    /// 是否展示开播清单
    @Published var showChecklist = false

    @Published var isStreaming: Bool = false
    @Published var isConnecting: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected

    @Published var framesSent: Int64 = 0
    @Published var currentFps: Double = 0.0
    @Published var connectionTime: TimeInterval = 0
    @Published var bytesSent: Int64 = 0

    @Published var showError: Bool = false
    @Published var errorMessage: String?

    @Published var showSettings: Bool = false

    // MARK: - Types

    enum ConnectionStatus {
        case disconnected
        case connecting
        /// 自动重连等待中（第 attempt 次，delay 秒后重试）
        case reconnecting(attempt: Int, delay: TimeInterval)
        case connected
        case streaming
        case error(String)

        var displayText: String {
            switch self {
            case .disconnected: return "rtmp.status.disconnected".localized
            case .connecting: return "rtmp.status.connecting".localized
            case .reconnecting(let attempt, let delay):
                return String(format: "rtmp.status.reconnecting".localized, attempt, Int(delay))
            case .connected: return "rtmp.status.connected".localized
            case .streaming: return "rtmp.status.streaming".localized
            case .error(let msg): return msg
            }
        }

        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .yellow
            case .reconnecting: return .yellow
            case .connected: return .green
            case .streaming: return .red
            case .error: return .orange
            }
        }
    }

    enum StreamingPlatform: String, CaseIterable {
        case custom = "custom"
        case youtube = "youtube"
        case twitch = "twitch"
        case bilibili = "bilibili"
        case douyin = "douyin"
        case tiktok = "tiktok"
        case facebook = "facebook"

        var displayName: String {
            switch self {
            case .custom: return "rtmp.platform.custom".localized
            case .youtube: return "YouTube Live"
            case .twitch: return "Twitch"
            case .bilibili: return "Bilibili (B站)"
            case .douyin: return "Douyin (抖音)"
            case .tiktok: return "TikTok"
            case .facebook: return "Facebook Live"
            }
        }

        var defaultRtmpUrl: String {
            switch self {
            case .custom: return ""
            case .youtube: return "rtmp://a.rtmp.youtube.com/live2"
            case .twitch: return "rtmp://live.twitch.tv/app"
            case .bilibili: return "rtmp://live-push.bilivideo.com/live-bvc"
            case .douyin: return "rtmp://push-rtmp-l6.douyincdn.com/third"
            case .tiktok: return "rtmp://push.tiktokv.com/live"
            case .facebook: return "rtmps://live-api-s.facebook.com:443/rtmp"
            }
        }

        var icon: String {
            switch self {
            case .custom: return "server.rack"
            case .youtube: return "play.rectangle.fill"
            case .twitch: return "gamecontroller.fill"
            case .bilibili: return "tv.fill"
            case .douyin: return "music.note"
            case .tiktok: return "music.note.tv.fill"
            case .facebook: return "f.circle.fill"
            }
        }
    }

    // MARK: - Private Properties

    private let streamingService: RTMPStreamingService
    private let localBrain: any LocalBrainServicing
    private weak var streamViewModel: StreamSessionViewModel?
    private let openClawService = OpenClawNodeService.shared
    private var rtmpSampleBufferRegistrationID: UUID?
    private var statsTimer: Timer?
    private var recordingTimer: Timer?
    /// 场景辅助操作反馈的清除任务
    private var sceneFeedbackTask: Task<Void, Never>?
    /// 端侧场景 AI 请求任务（deinit 时取消）
    private var sceneLocalTask: Task<Void, Never>?
    private var startTime: Date?

    // MARK: - Initialization

    init() {
        self.streamingService = RTMPStreamingService()
        self.localBrain = LocalBrainService.shared
        setupServiceCallbacks()
        loadSavedSettings()
        refreshScenarios()
        refreshRecordingRecords()
        logger.info("RTMPStreamingViewModel initialized")
    }

    deinit {
        sceneLocalTask?.cancel()
        statsTimer?.invalidate()
        recordingTimer?.invalidate()
        streamingService.stopStreaming()
    }

    // MARK: - Public Methods

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        guard streamViewModel !== viewModel else { return }

        clearStreamViewModel()
        streamViewModel = viewModel
        let service = streamingService
        rtmpSampleBufferRegistrationID = viewModel.attachRTMPSampleBufferConsumer { [weak service] sampleBuffer in
            service?.feedSampleBuffer(sampleBuffer)
        }
    }

    func clearStreamViewModel() {
        if let streamViewModel, let rtmpSampleBufferRegistrationID {
            streamViewModel.detachRTMPSampleBufferConsumer(rtmpSampleBufferRegistrationID)
        }
        rtmpSampleBufferRegistrationID = nil
        streamViewModel = nil
    }

    func selectPlatform(_ platform: StreamingPlatform) {
        selectedPlatform = platform
        if platform != .custom {
            rtmpUrl = platform.defaultRtmpUrl
        }
    }

    /// 开播入口：清单未确认且未记住时先过清单，否则直接推流
    func beginStreamFlow() {
        loadChecklist()
        guard RTMPGoLiveGate.shouldShowChecklist(
            remembered: checklistRemembered,
            itemsConfirmed: RTMPChecklistStore.allConfirmed(checklistItems)
        ) else {
            startStreaming()
            return
        }
        showChecklist = true
    }

    /// 确认清单后开始推流（记住选择则下次跳过）
    func confirmChecklistAndStart() {
        RTMPChecklistStore.save(items: checklistItems, remembered: checklistRemembered)
        showChecklist = false
        startStreaming()
    }

    /// 加载开播清单（条目与记住状态）
    func loadChecklist() {
        checklistItems = RTMPChecklistStore.items
        checklistRemembered = RTMPChecklistStore.remembered
    }

    func startStreaming() {
        guard !isStreaming, !isConnecting else {
            logger.warning("Already streaming")
            return
        }

        guard streamViewModel?.cameraCaptureState.isStreaming == true else {
            showError(message: "rtmp.error.cameraunavailable".localized)
            return
        }

        let fullUrl = buildFullUrl()
        guard !fullUrl.isEmpty else {
            showError(message: "rtmp.error.invalidurl".localized)
            return
        }

        logger.info("Starting RTMP streaming")

        isConnecting = true
        connectionStatus = .connecting

        // Get video dimensions from current frame
        let width = 504  // Default from Ray-Ban Meta
        let height = 504

        streamingService.adaptiveQualityEnabled = adaptiveQualityEnabled
        streamingService.autoReconnectEnabled = autoReconnectEnabled
        streamingService.adaptiveAudioEnabled = adaptiveAudioEnabled
        streamingService.liveSceneAnalysisEnabled = liveSceneAnalysisEnabled
        streamingService.parallelDestinations = destinations
        streamingService.parallelBitrate = RTMPParallelStreamer.defaultBitrate
        currentBitrate = bitrate
        currentQualityPreset = RTMPQualityPreset(
            bitrate: bitrate,
            width: width,
            height: height,
            fps: 24
        )
        streamingService.startStreaming(url: fullUrl, width: width, height: height, bitrate: bitrate)

        saveSettings()
    }

    func stopStreaming() {
        logger.info("Stopping RTMP streaming")
        streamingService.stopStreaming()

        isStreaming = false
        isConnecting = false
        connectionStatus = .disconnected
        currentBitrate = bitrate
        isRecording = false
        recordingDuration = 0
        recordingTimer?.invalidate()
        recordingTimer = nil
        currentSceneLabel = nil
        currentSceneSummary = nil
        sceneSuggestions = []
        sceneActionFeedback = nil
        privacyShielded = false
        streamingService.privacyShielded = false
        qualityLocked = false
        streamingService.qualityLocked = false
        lastDiagnostics = streamingService.diagnosticsSnapshot
        saveDiagnosticsLog()

        statsTimer?.invalidate()
        statsTimer = nil

        framesSent = 0
        currentFps = 0.0
        connectionTime = 0
        bytesSent = 0
    }

    func feedFrame(_ image: UIImage, timestamp: Int64) {
        guard isStreaming else { return }
        streamingService.feedFrame(image, timestamp: timestamp)
    }

    // MARK: - Diagnostics

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private var numberText: (Int64) -> String {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        return { numberFormatter.string(from: NSNumber(value: $0)) ?? "\($0)" }
    }

    private var durationText: (TimeInterval?) -> String {
        { duration in
            guard let duration else { return "00:00" }
            return RTMPRecordingNaming.durationText(duration)
        }
    }

    /// 最近一次会话的诊断报告文本（可分享）
    var diagnosticsReport: String {
        guard let snapshot = lastDiagnostics else {
            return "rtmp.settings.diagnostics.empty".localized
        }
        return RTMPDiagnosticsReport.text(
            from: snapshot,
            durationText: durationText,
            numberText: numberText
        )
    }

    /// 把最近一次会话快照落盘为日志文件，并滚动裁剪到上限
    private func saveDiagnosticsLog() {
        guard let snapshot = lastDiagnostics else { return }
        _ = RTMPDiagnosticsLog.write(
            snapshot: snapshot,
            timestampText: { Self.logTimestampFormatter.string(from: $0) },
            durationText: durationText,
            numberText: numberText
        )
        RTMPDiagnosticsLog.trim()
        refreshDiagnosticsLogs()
    }

    /// 刷新诊断日志列表
    func refreshDiagnosticsLogs() {
        diagnosticsLogs = RTMPDiagnosticsLog.logFiles()
    }

    /// 删除一份诊断日志（返回是否删掉）
    func deleteDiagnosticsLog(_ url: URL) {
        _ = RTMPDiagnosticsLog.delete(url: url)
        refreshDiagnosticsLogs()
    }

    /// 读取一份诊断日志全文（读取失败返回提示文案）
    func diagnosticsLogText(url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))
            ?? "rtmp.settings.logs.unreadable".localized
    }

    // MARK: - Local Recording

    var recordingDurationText: String {
        RTMPRecordingNaming.durationText(recordingDuration)
    }

    func refreshRecordingRecords() {
        recordingRecords = RTMPRecordingStore.records
    }

    func startRecording() {
        guard streamingService.startRecording() else { return }
        isRecording = true
        recordingDuration = 0
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.recordingDuration += 1
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        Task { @MainActor [weak self] in
            _ = await self?.streamingService.stopRecording()
            self?.recordingDuration = 0
            self?.refreshRecordingRecords()
        }
    }

    /// 标记当前画面为精彩瞬间（需录制中）
    func addRecordingMarker() {
        guard isRecording else { return }
        let marker = streamingService.addRecordingMarker(
            label: "rtmp.recording.marker.default".localized
        )
        guard marker != nil else { return }
        markerFlash = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            self.markerFlash = false
        }
    }

    func deleteRecording(id: UUID) {
        RTMPRecordingStore.delete(id: id)
        refreshRecordingRecords()
    }

    // MARK: - Recording Playback

    /// 回放文件 URL（文件不存在时返回 nil）
    var playbackURL: URL? {
        guard let record = playbackRecord else { return nil }
        return RTMPRecordingPlayback.fileExists(fileName: record.fileName)
            ? RTMPRecordingPlayback.fileURL(fileName: record.fileName)
            : nil
    }

    /// 回放标记时间轴（按时间升序）
    var playbackMarkers: [RTMPRecordingPlayback.MarkerEntry] {
        guard let record = playbackRecord else { return [] }
        return RTMPRecordingPlayback.markerEntries(for: record)
    }

    func openPlayback(_ record: RTMPRecordingRecord) {
        playbackRecord = record
    }

    func closePlayback() {
        playbackRecord = nil
    }

    /// 导出标记片段（AVAssetExportSession 按时间范围裁剪到临时目录），
    /// 成功回调临时文件 URL（分享用），失败回调错误文案。
    func exportClip(
        marker: RTMPRecordingMarker,
        completion: @escaping (Result<URL, ClipExportError>) -> Void
    ) {
        guard let url = playbackURL, let record = playbackRecord else {
            completion(.failure(.noFile))
            return
        }
        let lead = RTMPClipWindowSettings.leadSeconds
        let tail = RTMPClipWindowSettings.tailSeconds
        guard let range = RTMPClipSegment.timeRange(
            markerOffset: marker.timeOffset,
            duration: record.duration,
            leadSeconds: lead,
            tailSeconds: tail
        ) else {
            completion(.failure(.invalid))
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HyperMetaClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 清理上次导出的临时片段，避免临时目录堆积
        if let stale = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for file in stale { try? FileManager.default.removeItem(at: file) }
        }
        let startOffset = max(0, marker.timeOffset - lead)
        let outputURL = directory.appendingPathComponent(
            RTMPClipSegment.clipFileName(
                fileName: record.fileName,
                label: marker.label,
                startOffset: startOffset
            )
        )
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(.failure(.failed))
            return
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.timeRange = range
        session.exportAsynchronously {
            Task { @MainActor in
                switch session.status {
                case .completed:
                    completion(.success(outputURL))
                case .cancelled:
                    completion(.failure(.cancelled))
                default:
                    completion(.failure(.failed))
                }
            }
        }
    }

    // MARK: - Privacy Shield

    /// 切换隐私保护盾（同步到推流服务）
    func togglePrivacyShield() {
        privacyShielded.toggle()
        streamingService.privacyShielded = privacyShielded
    }

    // MARK: - Quality Lock

    /// 切换画质锁定（暂停自适应档位调整）
    func toggleQualityLock() {
        qualityLocked.toggle()
        streamingService.qualityLocked = qualityLocked
    }

    // MARK: - Parallel Destinations

    /// 刷新附加目的地列表
    func refreshDestinations() {
        destinations = RTMPDestinationStore.destinations
    }

    /// 新增附加目的地（空名/空 URL/重复 URL/超上限返回 false）；推流中立即启动该路
    func addDestination(name: String, url: String) -> Bool {
        guard RTMPDestinationStore.add(name: name, url: url) else { return false }
        refreshDestinations()
        if isStreaming, let destination = destinations.first(where: { $0.url == url }) {
            streamingService.parallelStreamer.addDestination(destination)
        }
        return true
    }

    /// 更新附加目的地；推流中地址变化时重建该路
    func updateDestination(id: UUID, name: String, url: String) -> Bool {
        let oldURL = destinations.first { $0.id == id }?.url
        guard RTMPDestinationStore.update(id: id, name: name, url: url) else { return false }
        refreshDestinations()
        if isStreaming, let destination = destinations.first(where: { $0.id == id }),
           destination.url != oldURL {
            streamingService.parallelStreamer.removeDestination(id: id)
            streamingService.parallelStreamer.addDestination(destination)
        }
        return true
    }

    /// 切换附加目的地启用状态；推流中同步启停该路
    func toggleDestination(id: UUID) {
        _ = RTMPDestinationStore.toggle(id: id)
        refreshDestinations()
        guard isStreaming, let destination = destinations.first(where: { $0.id == id }) else { return }
        if destination.isEnabled {
            streamingService.parallelStreamer.addDestination(destination)
        } else {
            streamingService.parallelStreamer.removeDestination(id: id)
        }
    }

    /// 删除附加目的地；推流中同步关闭该路
    func deleteDestination(id: UUID) {
        RTMPDestinationStore.delete(id: id)
        refreshDestinations()
        if isStreaming {
            streamingService.parallelStreamer.removeDestination(id: id)
        }
    }

    /// 推流中重试一个失败的目的地
    func retryParallelDestination(id: UUID) {
        streamingService.parallelStreamer.retryDestination(id: id)
    }

    // MARK: - Scene Suggestions & Agent Context

    /// 根据当前场景重新生成标题建议（开关关闭或场景变化时调用）
    func refreshSceneSuggestions() {
        guard sceneSuggestionsEnabled else {
            sceneSuggestions = []
            return
        }
        sceneSuggestions = RTMPSceneTitleSuggester.suggestions(
            sceneLabel: currentSceneLabel,
            summary: currentSceneSummary ?? ""
        )
    }

    /// 复制一条标题建议到剪贴板（短暂展示「已复制」反馈）
    func copySceneSuggestion(_ title: String) {
        UIPasteboard.general.string = title
        flashSceneFeedback("rtmp.scene.suggestions.copied".localized)
    }

    /// AI 润色直播标题：取当前第一条建议 + 场景上下文发给 Hermes，
    /// 成功后用润色变体替换建议列表（解析失败保留原建议并提示）。
    func polishSceneTitle() {
        guard !isPolishingTitle else { return }
        guard let draft = sceneSuggestions.first else {
            flashSceneFeedback("rtmp.scene.title.polish.none".localized)
            return
        }
        isPolishingTitle = true
        let message = RTMPTitlePolishPrompt.message(
            draftTitle: draft,
            sceneLabel: currentSceneLabel,
            summary: currentSceneSummary ?? "",
            platformName: selectedPlatform.displayName
        )
        let dispatched = dispatchSceneAssistantMessage(
            message,
            onComplete: { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPolishingTitle = false
                    let polished = RTMPTitlePolishParser.parse(text)
                    if polished.isEmpty {
                        self.flashSceneFeedback("rtmp.scene.title.polish.empty".localized)
                    } else {
                        self.sceneSuggestions = polished
                        self.flashSceneFeedback(
                            self.sceneAssistantUsesLocalBrain
                                ? "rtmp.scene.title.polish.done.local".localized
                                : "rtmp.scene.title.polish.done".localized
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPolishingTitle = false
                    self.flashSceneFeedback(error)
                }
            }
        )
        if !dispatched {
            isPolishingTitle = false
            flashSceneFeedback("rtmp.scene.assistant.unavailable".localized)
        }
    }

    /// 场景 AI 消息分发（Hermes → OpenClaw → 自定义 Agent → 端侧模型）：
    /// 返回 false 表示没有可用大脑（无网关且端侧 AI 不可用）。
    private func dispatchSceneAssistantMessage(
        _ message: String,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) -> Bool {
        sceneAssistantUsesLocalBrain = false
        let provider = SceneAssistantBrain.resolve(
            hermesAvailable: HermesService.shared.isEnabled,
            openClawAvailable: openClawService.connectionState == .connected,
            customAvailable: !CustomAgentStore.configs.isEmpty,
            localAvailable: localBrain.isAvailable
        )
        switch provider {
        case .hermes:
            HermesService.shared.sendMessage(
                message,
                instructions: nil,
                onDelta: { _ in },
                onTool: { _ in },
                onComplete: onComplete,
                onError: onError
            )
            return true
        case .openclaw:
            // OpenClaw 经 chat.send 全量文本事件返回（[[FINAL]] 为终态，无回声）
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.openClawService.onChatEvent = nil
                onError("rtmp.scene.assistant.timeout".localized)
            }
            openClawService.onChatEvent = { [weak self] delta in
                guard let self else { return }
                if delta.hasPrefix("[[FINAL]]") {
                    let final = String(delta.dropFirst("[[FINAL]]".count))
                    Task { @MainActor in
                        timeoutTask.cancel()
                        self.openClawService.onChatEvent = nil
                        onComplete(final)
                    }
                }
            }
            openClawService.sendChatMessage(message)
            return true
        case .custom:
            guard let config = CustomAgentStore.configs.first else { return false }
            CustomAgentService.shared.sendMessage(
                config: config,
                text: message,
                onDelta: { _ in },
                onComplete: onComplete,
                onError: onError
            )
            return true
        case .local:
            sceneAssistantUsesLocalBrain = true
            sceneLocalTask = LocalBrainResponder.run(
                brain: localBrain,
                message: message,
                onComplete: { text in onComplete(text) },
                onError: { error in onError(error) }
            )
            return true
        case nil:
            return false
        }
    }

    /// Agent 场景分析：把当前场景上下文发给当前大脑（Hermes / OpenClaw / 自定义），成功后在弹层展示建议。
    func analyzeSceneWithAgent() {
        guard !isAnalyzingScene else { return }
        guard currentSceneLabel != nil || !(currentSceneSummary ?? "").isEmpty else {
            flashSceneFeedback("rtmp.scene.analysis.empty".localized)
            return
        }
        isAnalyzingScene = true
        let message = RTMPSceneAnalysisPrompt.message(
            sceneLabel: currentSceneLabel,
            summary: currentSceneSummary ?? "",
            platformName: selectedPlatform.displayName
        )
        let dispatched = dispatchSceneAssistantMessage(
            message,
            onComplete: { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAnalyzingScene = false
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.flashSceneFeedback("rtmp.scene.analysis.empty".localized)
                    } else {
                        self.sceneAnalysisResult = trimmed
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAnalyzingScene = false
                    self.flashSceneFeedback(error)
                }
            }
        )
        if !dispatched {
            isAnalyzingScene = false
            flashSceneFeedback("rtmp.scene.assistant.unavailable".localized)
        }
    }

    /// 关闭场景分析弹层（清除结果）
    func clearSceneAnalysis() {
        sceneAnalysisResult = nil
    }

    /// 把当前场景分析结果存入 Agent 长期记忆（成功返回 true，弹层内就地反馈）
    func saveSceneAnalysisToMemory() -> Bool {
        guard let text = sceneAnalysisResult,
              let memory = RTMPSceneAnalysisMemory.memoryText(text) else { return false }
        return AgentMemoryStore.add(text: memory)
    }

    /// 把当前场景存入 Agent 长期记忆（后续 Agent 请求自动携带）
    func saveSceneToAgentMemory() {
        guard let text = RTMPLiveSceneContextBuilder.memoryText(
            sceneLabel: currentSceneLabel,
            summary: currentSceneSummary ?? "",
            platformName: selectedPlatform.displayName
        ) else { return }
        let saved = AgentMemoryStore.add(text: text)
        flashSceneFeedback(
            saved
                ? "rtmp.scene.suggestions.saved".localized
                : "rtmp.scene.suggestions.memoryFull".localized
        )
    }

    /// 短暂展示场景辅助操作反馈（1.2 秒后清除）
    private func flashSceneFeedback(_ text: String) {
        sceneActionFeedback = text
        sceneFeedbackTask?.cancel()
        sceneFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            self.sceneActionFeedback = nil
        }
    }

    // MARK: - Live Scenarios

    func refreshScenarios() {
        scenarios = RTMPScenarioStore.scenarios
    }

    /// 把当前表单（目的地 + 推流参数）保存为一个命名场景
    @discardableResult
    func saveCurrentAsScenario(name: String) -> Bool {
        let scenario = RTMPStreamScenario(
            name: name,
            platform: selectedPlatform.rawValue,
            rtmpUrl: rtmpUrl,
            bitrate: bitrate,
            adaptiveQualityEnabled: adaptiveQualityEnabled,
            autoReconnectEnabled: autoReconnectEnabled,
            adaptiveAudioEnabled: adaptiveAudioEnabled
        )
        guard RTMPScenarioStore.save(scenario) else { return false }
        refreshScenarios()
        return true
    }

    /// 应用一个场景：把目的地与推流参数写回表单并持久化
    func applyScenario(_ scenario: RTMPStreamScenario) {
        if let platform = StreamingPlatform(rawValue: scenario.platform) {
            selectedPlatform = platform
        } else {
            selectedPlatform = .custom
        }
        rtmpUrl = scenario.rtmpUrl
        bitrate = scenario.bitrate
        adaptiveQualityEnabled = scenario.adaptiveQualityEnabled
        autoReconnectEnabled = scenario.autoReconnectEnabled
        adaptiveAudioEnabled = scenario.adaptiveAudioEnabled
        currentBitrate = scenario.bitrate
        saveSettings()
    }

    func deleteScenario(id: UUID) {
        RTMPScenarioStore.delete(id: id)
        refreshScenarios()
    }

    @discardableResult
    func renameScenario(id: UUID, to name: String) -> Bool {
        guard RTMPScenarioStore.rename(id: id, to: name) else { return false }
        refreshScenarios()
        return true
    }

    var isUsingDirectSampleBufferInput: Bool {
        streamingService.isUsingDirectSampleBufferInput
    }

    func dismissError() {
        showError = false
        errorMessage = nil
    }

    // MARK: - Private Methods

    private func setupServiceCallbacks() {
        streamingService.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }

        streamingService.onStatsUpdated = { [weak self] stats in
            Task { @MainActor in
                self?.framesSent = stats.framesSent
                self?.currentFps = stats.fps
                self?.connectionTime = stats.connectionTime
                self?.bytesSent = stats.bytesSent
            }
        }

        streamingService.onError = { [weak self] error in
            Task { @MainActor in
                self?.showError(message: error)
            }
        }

        streamingService.onBitrateChanged = { [weak self] bitrate in
            Task { @MainActor in
                self?.currentBitrate = bitrate
            }
        }

        streamingService.onQualityChanged = { [weak self] preset in
            Task { @MainActor in
                self?.currentQualityPreset = preset
            }
        }

        streamingService.onSceneDetected = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.currentSceneLabel = snapshot.sceneLabel
                self.currentSceneSummary = snapshot.summary
                self.refreshSceneSuggestions()
            }
        }

        streamingService.onParallelStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.parallelSession = state
            }
        }
    }

    private func handleStateChange(_ state: RTMPStreamingState) {
        switch state {
        case .idle:
            connectionStatus = .disconnected
            isStreaming = false
            isConnecting = false

        case .connecting:
            connectionStatus = .connecting
            isConnecting = true
            isStreaming = false

        case .reconnecting(let attempt, let delay):
            connectionStatus = .reconnecting(attempt: attempt, delay: delay)
            isConnecting = true
            isStreaming = false
            statsTimer?.invalidate()

        case .streaming:
            connectionStatus = .streaming
            isStreaming = true
            isConnecting = false
            startTime = Date()
            startStatsTimer()

        case .disconnected:
            connectionStatus = .disconnected
            isStreaming = false
            isConnecting = false
            statsTimer?.invalidate()

        case .error(let message):
            connectionStatus = .error(message)
            isStreaming = false
            isConnecting = false
            showError(message: message)
        }
    }

    private func buildFullUrl() -> String {
        var url = rtmpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !url.isEmpty else { return "" }

        if !key.isEmpty {
            if !url.hasSuffix("/") {
                url += "/"
            }
            url += key
        }

        return url
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.connectionTime = Date().timeIntervalSince(start)
            }
        }
    }

    /// 夹取并持久化片段导出窗口（didSet 触发）
    private func persistClipWindow() {
        clipLeadSeconds = RTMPClipWindowSettings.clamp(clipLeadSeconds)
        clipTailSeconds = RTMPClipWindowSettings.clamp(clipTailSeconds)
        RTMPClipWindowSettings.leadSeconds = clipLeadSeconds
        RTMPClipWindowSettings.tailSeconds = clipTailSeconds
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }

    private func saveSettings() {
        UserDefaults.standard.set(rtmpUrl, forKey: "rtmp_url")
        UserDefaults.standard.set(selectedPlatform.rawValue, forKey: "rtmp_platform")
        UserDefaults.standard.set(bitrate, forKey: "rtmp_bitrate")
        UserDefaults.standard.set(adaptiveQualityEnabled, forKey: "rtmp_adaptive_quality")
        UserDefaults.standard.set(autoReconnectEnabled, forKey: "rtmp_auto_reconnect")
        UserDefaults.standard.set(adaptiveAudioEnabled, forKey: "rtmp_adaptive_audio")
        UserDefaults.standard.set(liveSceneAnalysisEnabled, forKey: "rtmp_live_scene")
        UserDefaults.standard.set(sceneSuggestionsEnabled, forKey: "rtmp_scene_suggestions")
        // Stream key is sensitive, store in Keychain
        saveStreamKeyToKeychain(streamKey)
    }

    private func loadSavedSettings() {
        if let savedUrl = UserDefaults.standard.string(forKey: "rtmp_url") {
            rtmpUrl = savedUrl
        }
        streamKey = loadStreamKeyFromKeychain() ?? ""
        if let savedPlatform = UserDefaults.standard.string(forKey: "rtmp_platform"),
           let platform = StreamingPlatform(rawValue: savedPlatform) {
            selectedPlatform = platform
        }
        // 新键优先；兼容旧版「自适应码率」键
        if UserDefaults.standard.object(forKey: "rtmp_adaptive_quality") as? Bool == false {
            adaptiveQualityEnabled = false
        } else if UserDefaults.standard.object(forKey: "rtmp_adaptive_bitrate") as? Bool == false {
            adaptiveQualityEnabled = false
        }
        if UserDefaults.standard.object(forKey: "rtmp_auto_reconnect") as? Bool == false {
            autoReconnectEnabled = false
        }
        if UserDefaults.standard.object(forKey: "rtmp_adaptive_audio") as? Bool == false {
            adaptiveAudioEnabled = false
        }
        if UserDefaults.standard.object(forKey: "rtmp_live_scene") as? Bool == false {
            liveSceneAnalysisEnabled = false
        }
        if UserDefaults.standard.object(forKey: "rtmp_scene_suggestions") as? Bool == false {
            sceneSuggestionsEnabled = false
        }
        localBrainFallbackEnabled = LocalBrainSettings.enabled
        clipLeadSeconds = RTMPClipWindowSettings.leadSeconds
        clipTailSeconds = RTMPClipWindowSettings.tailSeconds
        let savedBitrate = UserDefaults.standard.integer(forKey: "rtmp_bitrate")
        if savedBitrate > 0 {
            bitrate = savedBitrate
        }
        // Migrate old UserDefaults key to Keychain
        if let oldKey = UserDefaults.standard.string(forKey: "rtmp_stream_key"), !oldKey.isEmpty {
            saveStreamKeyToKeychain(oldKey)
            if streamKey.isEmpty { streamKey = oldKey }
            UserDefaults.standard.removeObject(forKey: "rtmp_stream_key")
        }
    }

    private func saveStreamKeyToKeychain(_ key: String) {
        let service = "com.smartview.glassai.rtmp"
        let account = "stream_key"
        let data = key.data(using: .utf8) ?? Data()

        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)

        guard !key.isEmpty else { return }
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ] as CFDictionary, nil)
    }

    private func loadStreamKeyFromKeychain() -> String? {
        let service = "com.smartview.glassai.rtmp"
        let account = "stream_key"
        var result: AnyObject?

        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ] as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// String.localized is defined in LanguageManager.swift
