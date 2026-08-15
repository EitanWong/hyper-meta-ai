/*
 * RTMP Streaming View
 * Live streaming interface with video preview and RTMP controls
 *
 * Supports all major streaming platforms:
 * - YouTube Live, Twitch, Bilibili, Douyin, TikTok, Facebook Live
 * - Any custom RTMP server (MediaMTX, nginx-rtmp, etc.)
 */

import SwiftUI

enum RTMPStreamingCameraTransition: Equatable {
    case waiting
    case ready
    case unavailable
}

enum RTMPStreamingViewLifecyclePolicy {
    static func transition(for state: CameraCaptureState) -> RTMPStreamingCameraTransition {
        switch state {
        case .streaming:
            return .ready
        case .unavailable, .failed:
            return .unavailable
        case .idle, .starting, .paused, .stopping:
            return .waiting
        }
    }
}

struct RTMPStreamingView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @StateObject private var rtmpViewModel = RTMPStreamingViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showUI = true
    @State private var frameTimer: Timer?
    @State private var isClosing = false
    @State private var showControlPanel = false
    @State private var sceneAnalysisCopied = false

    var body: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            // Live preview: 有帧即显示（连接前预览 / 推流中）
            if let videoFrame = streamViewModel.currentVideoFrame {
                GeometryReader { geometry in
                    Image(uiImage: videoFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            } else if streamViewModel.cameraCaptureState.isUnavailable
                        || streamViewModel.cameraCaptureState.isFailed {
                // 相机不可用：权限 / 连接引导
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.6))
                    Text("rtmp.preview.cameraUnavailable".localized)
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                    Button {
                        openSystemSettings()
                    } label: {
                        Text("rtmp.preview.openSettings".localized)
                            .font(AppTypography.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.sm)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            } else {
                // 相机启动中
                VStack(spacing: AppSpacing.lg) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("rtmp.preview.starting".localized)
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                }
            }

            // 连接中叠加提示（保留实时预览）
            if rtmpViewModel.isConnecting, streamViewModel.currentVideoFrame != nil {
                VStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .tint(.white)
                    Text("rtmp.preview.connecting".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(Color.black.opacity(0.6))
                .cornerRadius(AppCornerRadius.md)
                .padding(.top, 120)
            }

            // 隐私保护盾遮罩（推流中隐藏画面）
            if rtmpViewModel.isStreaming, rtmpViewModel.privacyShielded {
                Color.black.opacity(0.92)
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: AppSpacing.sm) {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.yellow)
                            Text("rtmp.privacy.shielded".localized)
                                .font(AppTypography.body)
                                .foregroundColor(.white)
                        }
                    )
            }

            // 预览中标签（未推流且未连接时）
            if !rtmpViewModel.isStreaming,
               !rtmpViewModel.isConnecting,
               streamViewModel.currentVideoFrame != nil {
                VStack {
                    HStack {
                        HStack(spacing: AppSpacing.xs) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("rtmp.preview.live".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.sm)
            }

            // UI Overlay
            if showUI {
                VStack(spacing: 0) {
                    // Header
                    headerView
                        .transition(.move(edge: .top).combined(with: .opacity))

                    Spacer()

                    // Stats (when streaming)
                    if rtmpViewModel.isStreaming {
                        statsView
                            .transition(.opacity)

                        // Parallel destination status
                        if !rtmpViewModel.parallelSession.destinations.isEmpty {
                            parallelStatusView
                                .transition(.opacity)
                        }

                        // Live scene understanding label + AI suggestions
                        if let label = rtmpViewModel.currentSceneLabel {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                HStack(spacing: AppSpacing.sm) {
                                    Image(systemName: "eye.fill")
                                        .font(.caption)
                                        .foregroundColor(.yellow)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(label)
                                            .font(AppTypography.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                        if let summary = rtmpViewModel.currentSceneSummary {
                                            Text(summary)
                                                .font(AppTypography.footnote)
                                                .foregroundColor(.white.opacity(0.7))
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                if !rtmpViewModel.sceneSuggestions.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: AppSpacing.sm) {
                                            ForEach(
                                                Array(rtmpViewModel.sceneSuggestions.enumerated()),
                                                id: \.offset
                                            ) { _, title in
                                                Button {
                                                    rtmpViewModel.copySceneSuggestion(title)
                                                } label: {
                                                    Text(title)
                                                        .font(AppTypography.footnote)
                                                        .foregroundColor(.white)
                                                        .lineLimit(1)
                                                        .padding(.horizontal, AppSpacing.sm)
                                                        .padding(.vertical, 6)
                                                        .background(Color.white.opacity(0.15))
                                                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                                HStack(spacing: AppSpacing.sm) {
                                    Button {
                                        rtmpViewModel.saveSceneToAgentMemory()
                                    } label: {
                                        Label(
                                            "rtmp.scene.suggestions.toMemory".localized,
                                            systemImage: "brain"
                                        )
                                        .font(AppTypography.footnote)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, AppSpacing.sm)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.35))
                                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        rtmpViewModel.polishSceneTitle()
                                    } label: {
                                        if rtmpViewModel.isPolishingTitle {
                                            ProgressView()
                                                .tint(.white)
                                                .scaleEffect(0.8)
                                                .frame(width: 16, height: 16)
                                        } else {
                                            Label(
                                                "rtmp.scene.title.polish".localized,
                                                systemImage: "sparkles"
                                            )
                                            .font(AppTypography.footnote)
                                            .foregroundColor(.white)
                                        }
                                    }
                                    .disabled(rtmpViewModel.isPolishingTitle)
                                    .padding(.horizontal, AppSpacing.sm)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
                                    .buttonStyle(.plain)

                                    Button {
                                        rtmpViewModel.analyzeSceneWithAgent()
                                    } label: {
                                        if rtmpViewModel.isAnalyzingScene {
                                            ProgressView()
                                                .tint(.white)
                                                .scaleEffect(0.8)
                                                .frame(width: 16, height: 16)
                                        } else {
                                            Label(
                                                "rtmp.scene.analysis.button".localized,
                                                systemImage: "text.magnifyingglass"
                                            )
                                            .font(AppTypography.footnote)
                                            .foregroundColor(.white)
                                        }
                                    }
                                    .disabled(rtmpViewModel.isAnalyzingScene)
                                    .padding(.horizontal, AppSpacing.sm)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
                                    .buttonStyle(.plain)
                                }
                                if let feedback = rtmpViewModel.sceneActionFeedback {
                                    Text(feedback)
                                        .font(AppTypography.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.sm)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(AppCornerRadius.md)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.top, AppSpacing.sm)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: rtmpViewModel.sceneActionFeedback)
                        }
                    }

                    // Controls
                    controlsView
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showUI.toggle()
            }
        }
        .onAppear {
            guard !AppIdentity.isRunningPreview else { return }

            rtmpViewModel.setStreamViewModel(streamViewModel)
            startVideoStream()
        }
        .onDisappear {
            guard !AppIdentity.isRunningPreview else { return }

            stopAll()
        }
        .onChange(of: streamViewModel.cameraCaptureState) { _, state in
            guard !AppIdentity.isRunningPreview else { return }
            handleCameraTransition(for: state)
        }
        .sheet(isPresented: $rtmpViewModel.showSettings) {
            RTMPSettingsView(viewModel: rtmpViewModel)
        }
        .sheet(isPresented: $rtmpViewModel.showChecklist) {
            goLiveChecklistView
        }
        .sheet(isPresented: $showControlPanel) {
            controlPanelView
        }
        .sheet(isPresented: Binding(
            get: { rtmpViewModel.sceneAnalysisResult != nil },
            set: { if !$0 { rtmpViewModel.clearSceneAnalysis() } }
        )) {
            SceneAnalysisSheet(
                text: rtmpViewModel.sceneAnalysisResult ?? "",
                isLocal: rtmpViewModel.sceneAssistantUsesLocalBrain,
                copied: $sceneAnalysisCopied,
                onClose: { rtmpViewModel.clearSceneAnalysis() },
                onSaveToMemory: { rtmpViewModel.saveSceneAnalysisToMemory() }
            )
        }
        .alert("error".localized, isPresented: $rtmpViewModel.showError) {
            Button("ok".localized) {
                rtmpViewModel.dismissError()
            }
        } message: {
            if let error = rtmpViewModel.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Control Panel

    /// 推流中控制面板：画质锁定 / 隐私盾 / 快捷标记 / 停止推流
    private var controlPanelView: some View {
        NavigationView {
            List {
                Section {
                    Toggle("rtmp.panel.qualityLock".localized, isOn: Binding(
                        get: { rtmpViewModel.qualityLocked },
                        set: { _ in rtmpViewModel.toggleQualityLock() }
                    ))
                    if let preset = rtmpViewModel.currentQualityPreset {
                        LabeledContent(
                            "rtmp.quality.live".localized,
                            value: preset.shortLabel
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                } header: {
                    Text("rtmp.panel.quality".localized)
                } footer: {
                    Text("rtmp.panel.qualityLock.description".localized)
                }

                Section {
                    Toggle("rtmp.privacy.shield".localized, isOn: Binding(
                        get: { rtmpViewModel.privacyShielded },
                        set: { _ in rtmpViewModel.togglePrivacyShield() }
                    ))
                } header: {
                    Text("rtmp.panel.privacy".localized)
                }

                Section {
                    Button {
                        if rtmpViewModel.isRecording {
                            rtmpViewModel.stopRecording()
                        } else {
                            rtmpViewModel.startRecording()
                        }
                    } label: {
                        HStack {
                            Circle()
                                .fill(rtmpViewModel.isRecording ? Color.red : Color.gray)
                                .frame(width: 10, height: 10)
                            Text(rtmpViewModel.isRecording
                                 ? "rtmp.recording.stop".localized
                                 : "rtmp.recording.start".localized)
                                .foregroundColor(.primary)
                        }
                    }
                    if rtmpViewModel.isRecording {
                        Button {
                            rtmpViewModel.addRecordingMarker()
                            showControlPanel = false
                        } label: {
                            Label("rtmp.recording.marker.default".localized, systemImage: "flag.fill")
                                .foregroundColor(.primary)
                        }
                    }
                } header: {
                    Text("rtmp.panel.recording".localized)
                }

                Section {
                    Button(role: .destructive) {
                        showControlPanel = false
                        rtmpViewModel.stopStreaming()
                    } label: {
                        Label("rtmp.panel.stop".localized, systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("rtmp.panel.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done".localized) {
                        showControlPanel = false
                    }
                }
            }
        }
    }

    // MARK: - Go-Live Checklist

    /// 开播前合规清单（全部勾选才可开始；可记住选择下次跳过）
    private var goLiveChecklistView: some View {
        NavigationView {
            List {
                Section {
                    Text("rtmp.checklist.subtitle".localized)
                        .font(AppTypography.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    ForEach($rtmpViewModel.checklistItems) { $item in
                        Toggle(item.titleKey.localized, isOn: $item.isChecked)
                    }
                } footer: {
                    Text("rtmp.checklist.footer".localized)
                }
                Section {
                    Toggle("rtmp.checklist.remember".localized, isOn: $rtmpViewModel.checklistRemembered)
                } footer: {
                    Text("rtmp.checklist.remember.footer".localized)
                }
            }
            .navigationTitle("rtmp.checklist.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel".localized) {
                        rtmpViewModel.showChecklist = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("rtmp.checklist.start".localized) {
                        rtmpViewModel.confirmChecklistAndStart()
                    }
                    .disabled(!RTMPChecklistStore.allConfirmed(rtmpViewModel.checklistItems))
                }
            }
        }
    }

    // MARK: - Preview Helpers

    /// 打开系统设置（相机权限引导）
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Parallel Status

    /// 多目的地并行推流状态行（每路一个状态胶囊 + 聚合文案）
    private var parallelStatusView: some View {
        let session = rtmpViewModel.parallelSession
        return VStack(spacing: AppSpacing.xs) {
            if session.destinations.count > 1 {
                Text(String(
                    format: "rtmp.parallel.summary".localized,
                    session.streamingCount,
                    session.destinations.count
                ))
                .font(AppTypography.footnote)
                .foregroundColor(.white.opacity(0.8))
            }
            HStack(spacing: AppSpacing.sm) {
                ForEach(session.destinations) { state in
                    HStack(spacing: 3) {
                        Image(systemName: Self.parallelIcon(for: state.connectionState))
                            .font(.caption)
                        Text(state.name)
                            .font(AppTypography.caption)
                            .lineLimit(1)
                        if case .failed = state.connectionState {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 4)
                    .background(Self.parallelColor(for: state.connectionState).opacity(0.35))
                    .clipShape(Capsule())
                    .onTapGesture {
                        if case .failed = state.connectionState {
                            rtmpViewModel.retryParallelDestination(id: state.id)
                        }
                    }
                    .accessibilityLabel(
                        Self.parallelIsFailed(state.connectionState)
                            ? "rtmp.parallel.retry".localized
                            : state.name
                    )
                }
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(Color.black.opacity(0.6))
        .cornerRadius(AppCornerRadius.md)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
    }

    private static func parallelIcon(for state: RTMPDestinationConnectionState) -> String {
        switch state {
        case .idle: return "circle"
        case .connecting: return "arrow.clockwise.circle.fill"
        case .streaming: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private static func parallelIsFailed(_ state: RTMPDestinationConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func parallelColor(for state: RTMPDestinationConnectionState) -> Color {
        switch state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .streaming: return .green
        case .failed: return .red
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Button {
                closeAndStop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white)
            }

            Spacer()

            // Connection status
            HStack(spacing: AppSpacing.sm) {
                Circle()
                    .fill(rtmpViewModel.connectionStatus.color)
                    .frame(width: 10, height: 10)

                Text(rtmpViewModel.connectionStatus.displayText)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)

                if rtmpViewModel.isStreaming {
                    // Blinking record indicator
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .modifier(BlinkingModifier())
                }
            }

            CameraCaptureStatusView(state: streamViewModel.cameraCaptureState)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.black.opacity(0.6))
            .cornerRadius(AppCornerRadius.lg)

            Spacer()

            // Settings button
            Button {
                rtmpViewModel.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
        }
        .padding(AppSpacing.md)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.7), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Stats View

    private var statsView: some View {
        HStack(spacing: AppSpacing.lg) {
            StatItem(label: "FPS", value: String(format: "%.1f", rtmpViewModel.currentFps))
            StatItem(label: "rtmp.frames".localized, value: "\(rtmpViewModel.framesSent)")
            StatItem(label: "rtmp.time".localized, value: formatTime(rtmpViewModel.connectionTime))
            StatItem(label: "rtmp.data".localized, value: formatBytes(rtmpViewModel.bytesSent))
            StatItem(
                label: "rtmp.bitrate.live".localized,
                value: String(format: "%.1f Mbps", Double(rtmpViewModel.currentBitrate) / 1_000_000)
            )
            if let preset = rtmpViewModel.currentQualityPreset {
                StatItem(label: "rtmp.quality.live".localized, value: preset.shortLabel)
            }
        }
        .padding(AppSpacing.md)
        .background(Color.black.opacity(0.6))
        .cornerRadius(AppCornerRadius.md)
        .padding(.horizontal, AppSpacing.lg)
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: AppSpacing.md) {
            // Scenario selector
            if !rtmpViewModel.isStreaming && !rtmpViewModel.scenarios.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(rtmpViewModel.scenarios) { scenario in
                            ScenarioChip(
                                scenario: scenario,
                                isSelected: rtmpViewModel.rtmpUrl == scenario.rtmpUrl
                            ) {
                                rtmpViewModel.applyScenario(scenario)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
            }

            // Platform selector
            if !rtmpViewModel.isStreaming {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(RTMPStreamingViewModel.StreamingPlatform.allCases, id: \.self) { platform in
                            PlatformButton(
                                platform: platform,
                                isSelected: rtmpViewModel.selectedPlatform == platform
                            ) {
                                rtmpViewModel.selectPlatform(platform)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
            }

            // URL and Stream Key inputs (when not streaming)
            if !rtmpViewModel.isStreaming && !rtmpViewModel.isConnecting {
                VStack(spacing: AppSpacing.sm) {
                    // RTMP URL
                    HStack {
                        Image(systemName: "link")
                            .foregroundColor(.white.opacity(0.6))
                        TextField("rtmp.url.placeholder".localized, text: $rtmpViewModel.rtmpUrl)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(AppSpacing.sm)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(AppCornerRadius.sm)

                    // Stream Key
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(.white.opacity(0.6))
                        SecureField("rtmp.key.placeholder".localized, text: $rtmpViewModel.streamKey)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                    }
                    .padding(AppSpacing.sm)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(AppCornerRadius.sm)
                }
                .padding(.horizontal, AppSpacing.lg)
            }

            // Recording controls (while streaming)
            if rtmpViewModel.isStreaming {
                HStack(spacing: AppSpacing.md) {
                    // 控制面板入口
                    Button {
                        showControlPanel = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16))
                            .padding(AppSpacing.sm)
                            .background(Color.white.opacity(0.15))
                            .foregroundColor(.white)
                            .cornerRadius(AppCornerRadius.sm)
                    }
                    .accessibilityLabel("rtmp.panel.open".localized)

                    Button {
                        if rtmpViewModel.isRecording {
                            rtmpViewModel.stopRecording()
                        } else {
                            rtmpViewModel.startRecording()
                        }
                    } label: {
                        HStack(spacing: AppSpacing.sm) {
                            Circle()
                                .fill(rtmpViewModel.isRecording ? Color.red : Color.white.opacity(0.6))
                                .frame(width: 10, height: 10)
                            Text(rtmpViewModel.isRecording
                                 ? "rtmp.recording.stop".localized
                                 : "rtmp.recording.start".localized)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(
                            rtmpViewModel.isRecording
                                ? Color.red.opacity(0.25)
                                : Color.white.opacity(0.15)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(AppCornerRadius.sm)
                    }

                    if rtmpViewModel.isRecording {
                        Text(rtmpViewModel.recordingDurationText)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white)

                        Button {
                            rtmpViewModel.addRecordingMarker()
                        } label: {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 16))
                                .padding(AppSpacing.sm)
                                .background(
                                    rtmpViewModel.markerFlash
                                        ? Color.yellow.opacity(0.35)
                                        : Color.white.opacity(0.15)
                                )
                                .foregroundColor(rtmpViewModel.markerFlash ? .yellow : .white)
                                .cornerRadius(AppCornerRadius.sm)
                        }
                    }

                    // 隐私保护盾（推流中一键隐藏画面）
                    Button {
                        rtmpViewModel.togglePrivacyShield()
                    } label: {
                        Image(systemName: rtmpViewModel.privacyShielded ? "shield.fill" : "shield")
                            .font(.system(size: 16))
                            .padding(AppSpacing.sm)
                            .background(
                                rtmpViewModel.privacyShielded
                                    ? Color.yellow.opacity(0.35)
                                    : Color.white.opacity(0.15)
                            )
                            .foregroundColor(rtmpViewModel.privacyShielded ? .yellow : .white)
                            .cornerRadius(AppCornerRadius.sm)
                    }
                    .accessibilityLabel("rtmp.privacy.shield".localized)
                }
                .padding(.horizontal, AppSpacing.lg)
            }

            // Start/Stop button
            Button {
                if rtmpViewModel.isStreaming || rtmpViewModel.isConnecting {
                    rtmpViewModel.stopStreaming()
                } else {
                    rtmpViewModel.beginStreamFlow()
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    if rtmpViewModel.isConnecting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: rtmpViewModel.isStreaming ? "stop.fill" : "video.fill")
                    }
                    Text((rtmpViewModel.isStreaming || rtmpViewModel.isConnecting)
                         ? "rtmp.stop".localized
                         : "rtmp.start".localized)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(rtmpViewModel.isStreaming ? Color.red : AppColors.primary)
                .foregroundColor(.white)
                .cornerRadius(AppCornerRadius.md)
            }
            .buttonStyle(.borderedProminent)
            .tint(rtmpViewModel.isStreaming || rtmpViewModel.isConnecting ? .red : .blue)
            .disabled(
                !rtmpViewModel.isStreaming && !rtmpViewModel.isConnecting &&
                (!streamViewModel.cameraCaptureState.isStreaming || rtmpViewModel.rtmpUrl.isEmpty)
            )
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.vertical, AppSpacing.lg)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Helper Methods

    private func startVideoStream() {
        Task {
            let streamReady = await streamViewModel.acquireStream(for: .rtmp)
            guard !isClosing else {
                await streamViewModel.releaseStream(for: .rtmp)
                return
            }
            if streamReady {
                startFrameFeed()
            }
        }
    }

    private func handleCameraTransition(for state: CameraCaptureState) {
        switch RTMPStreamingViewLifecyclePolicy.transition(for: state) {
        case .ready:
            startFrameFeed()
        case .unavailable:
            stopFrameFeed()
            if rtmpViewModel.isStreaming || rtmpViewModel.isConnecting {
                rtmpViewModel.stopStreaming()
            }
        case .waiting:
            break
        }
    }

    private func startFrameFeed() {
        guard frameTimer == nil else { return }

        // This fallback feeds rendered frames only until raw DAT sample buffers
        // reach the RTMP service. Once the direct path is active, stop the timer
        // so it cannot create duplicate UIImage conversions.
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            Task { @MainActor in
                guard !rtmpViewModel.isUsingDirectSampleBufferInput else {
                    stopFrameFeed()
                    return
                }
                if streamViewModel.cameraCaptureState.isStreaming,
                   let frame = streamViewModel.currentVideoFrame {
                    let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
                    rtmpViewModel.feedFrame(frame, timestamp: timestamp)
                }
            }
        }
    }

    private func stopFrameFeed() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func stopAll() {
        stopFrameFeed()

        if rtmpViewModel.isStreaming || rtmpViewModel.isConnecting {
            rtmpViewModel.stopStreaming()
        }
        rtmpViewModel.clearStreamViewModel()

        Task {
            await streamViewModel.releaseStream(for: .rtmp)
        }
    }

    private func closeAndStop() {
        guard !isClosing else { return }
        isClosing = true
        stopAll()
        dismiss()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1024)
        } else {
            return String(format: "%.1f MB", mb)
        }
    }
}

// MARK: - Supporting Views

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(AppTypography.headline)
                .foregroundColor(.white)
            Text(label)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

struct PlatformButton: View {
    let platform: RTMPStreamingViewModel.StreamingPlatform
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: platform.icon)
                    .font(.system(size: 20))
                Text(platform.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.sm)
            .background(isSelected ? AppColors.primary : Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(AppCornerRadius.sm)
        }
    }
}

struct ScenarioChip: View {
    let scenario: RTMPStreamScenario
    let isSelected: Bool
    let action: () -> Void

    private var platform: RTMPStreamingViewModel.StreamingPlatform {
        RTMPStreamingViewModel.StreamingPlatform(rawValue: scenario.platform) ?? .custom
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: platform.icon)
                    .font(.system(size: 20))
                Text(scenario.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.sm)
            .background(isSelected ? AppColors.primary : Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(AppCornerRadius.sm)
        }
    }
}

struct BlinkingModifier: ViewModifier {
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    isVisible.toggle()
                }
            }
    }
}

// MARK: - RTMP Settings View

struct RTMPSettingsView: View {
    @ObservedObject var viewModel: RTMPStreamingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showSaveScenarioAlert = false
    @State private var newScenarioName = ""
    @State private var renameTarget: RTMPStreamScenario?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    /// 正在查看全文的诊断日志
    @State private var selectedLog: RTMPDiagnosticsLogEntry?
    /// 目的地添加/编辑弹窗
    @State private var showDestinationAlert = false
    @State private var destinationName = ""
    @State private var destinationURL = ""
    /// 非 nil 时为编辑模式
    @State private var editingDestinationID: UUID?

    let bitrateOptions = [
        (1_000_000, "1 Mbps"),
        (2_000_000, "2 Mbps (rtmp.recommended".localized + ")"),
        (3_000_000, "3 Mbps"),
        (4_000_000, "4 Mbps")
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(bitrateOptions, id: \.0) { option in
                        Button {
                            viewModel.bitrate = option.0
                        } label: {
                            HStack {
                                Text(option.1)
                                    .foregroundColor(.primary)
                                Spacer()
                                if viewModel.bitrate == option.0 {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("rtmp.settings.bitrate".localized)
                } footer: {
                    Text("rtmp.settings.bitrate.description".localized)
                }

                Section {
                    Toggle("rtmp.settings.adaptive.toggle".localized, isOn: $viewModel.adaptiveQualityEnabled)
                } footer: {
                    Text("rtmp.settings.adaptive.description".localized)
                }

                Section {
                    Toggle("rtmp.settings.reconnect.toggle".localized, isOn: $viewModel.autoReconnectEnabled)
                } footer: {
                    Text("rtmp.settings.reconnect.description".localized)
                }

                Section {
                    Toggle("rtmp.settings.audio.toggle".localized, isOn: $viewModel.adaptiveAudioEnabled)
                } footer: {
                    Text("rtmp.settings.audio.description".localized)
                }

                Section {
                    ForEach(RTMPStreamingViewModel.StreamingPlatform.allCases, id: \.self) { platform in
                        Button {
                            viewModel.selectPlatform(platform)
                        } label: {
                            HStack {
                                Image(systemName: platform.icon)
                                    .frame(width: 24)
                                Text(platform.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if viewModel.selectedPlatform == platform {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("rtmp.settings.platform".localized)
                }

                Section {
                    if viewModel.scenarios.isEmpty {
                        Text("rtmp.settings.scenarios.empty".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.scenarios) { scenario in
                            Button {
                                viewModel.applyScenario(scenario)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(scenario.name)
                                            .foregroundColor(.primary)
                                        Text(scenarioSummary(scenario))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if viewModel.rtmpUrl == scenario.rtmpUrl {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteScenario(id: scenario.id)
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                                Button {
                                    renameTarget = scenario
                                    renameText = scenario.name
                                    showRenameAlert = true
                                } label: {
                                    Label("rename".localized, systemImage: "pencil")
                                }
                            }
                        }
                    }

                    Button {
                        newScenarioName = ""
                        showSaveScenarioAlert = true
                    } label: {
                        Label("rtmp.settings.scenarios.save".localized, systemImage: "plus.circle")
                    }
                } header: {
                    Text("rtmp.settings.scenarios".localized)
                } footer: {
                    Text("rtmp.settings.scenarios.footer".localized)
                }

                Section {
                    if viewModel.recordingRecords.isEmpty {
                        Text("rtmp.settings.recordings.empty".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.recordingRecords) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(RTMPRecordingNaming.durationText(record.duration))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(String(
                                        format: "rtmp.recording.markers.count".localized,
                                        record.markers.count
                                    ))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    Button {
                                        viewModel.openPlayback(record)
                                    } label: {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(.blue)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("rtmp.settings.recordings.playback".localized)
                                }
                                Text(record.fileName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteRecording(id: record.id)
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("rtmp.settings.recordings".localized)
                } footer: {
                    Text("rtmp.settings.recordings.footer".localized)
                }

                Section {
                    Toggle("rtmp.settings.scene.toggle".localized, isOn: $viewModel.liveSceneAnalysisEnabled)
                } footer: {
                    Text("rtmp.settings.scene.description".localized)
                }

                Section {
                    Toggle("rtmp.settings.suggestions.toggle".localized, isOn: $viewModel.sceneSuggestionsEnabled)
                } footer: {
                    Text("rtmp.settings.suggestions.description".localized)
                }

                Section {
                    Toggle("rtmp.settings.localbrain.toggle".localized, isOn: $viewModel.localBrainFallbackEnabled)
                } footer: {
                    Text("rtmp.settings.localbrain.footer".localized)
                }

                Section {
                    Stepper(value: $viewModel.clipLeadSeconds, in: 0...60, step: 1) {
                        Text(String(format: "rtmp.settings.clip.lead".localized, Int(viewModel.clipLeadSeconds)))
                    }
                    Stepper(value: $viewModel.clipTailSeconds, in: 0...60, step: 1) {
                        Text(String(format: "rtmp.settings.clip.tail".localized, Int(viewModel.clipTailSeconds)))
                    }
                } footer: {
                    Text("rtmp.settings.clip.description".localized)
                }

                Section {
                    if let snapshot = viewModel.lastDiagnostics {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RTMPRecordingNaming.durationText(snapshot.duration ?? 0))
                                    .foregroundColor(.primary)
                                Text(String(
                                    format: "rtmp.settings.diagnostics.summary".localized,
                                    snapshot.reconnectAttempts,
                                    snapshot.qualityUpshifts,
                                    snapshot.qualityDownshifts
                                ))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            ShareLink(item: viewModel.diagnosticsReport) {
                                Label("rtmp.settings.diagnostics.share".localized, systemImage: "square.and.arrow.up")
                            }
                        }
                    } else {
                        Text("rtmp.settings.diagnostics.empty".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("rtmp.settings.diagnostics".localized)
                } footer: {
                    Text("rtmp.settings.diagnostics.footer".localized)
                }

                Section {
                    if viewModel.diagnosticsLogs.isEmpty {
                        Text("rtmp.settings.logs.empty".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.diagnosticsLogs) { entry in
                            Button {
                                selectedLog = entry
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.fileName)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.byteCountText(entry.fileSize))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteDiagnosticsLog(entry.url)
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("rtmp.settings.logs".localized)
                } footer: {
                    Text("rtmp.settings.logs.footer".localized)
                }

                Section {
                    if viewModel.destinations.isEmpty {
                        Text("rtmp.settings.destinations.empty".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.destinations) { destination in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { destination.isEnabled },
                                    set: { _ in viewModel.toggleDestination(id: destination.id) }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(destination.url)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .onTapGesture {
                                editingDestinationID = destination.id
                                destinationName = destination.name
                                destinationURL = destination.url
                                showDestinationAlert = true
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteDestination(id: destination.id)
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                                Button {
                                    editingDestinationID = destination.id
                                    destinationName = destination.name
                                    destinationURL = destination.url
                                    showDestinationAlert = true
                                } label: {
                                    Label("rename".localized, systemImage: "pencil")
                                }
                            }
                        }
                    }
                    Button {
                        editingDestinationID = nil
                        destinationName = ""
                        destinationURL = ""
                        showDestinationAlert = true
                    } label: {
                        Label("rtmp.settings.destinations.add".localized, systemImage: "plus.circle")
                    }
                } header: {
                    Text("rtmp.settings.destinations".localized)
                } footer: {
                    Text("rtmp.settings.destinations.footer".localized)
                }

                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("rtmp.settings.experimental".localized)
                            .font(AppTypography.headline)
                            .foregroundColor(.orange)

                        Text("rtmp.settings.experimental.description".localized)
                            .font(AppTypography.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, AppSpacing.sm)
                } header: {
                    Text("rtmp.settings.note".localized)
                }
            }
            .navigationTitle("rtmp.settings".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .alert("rtmp.settings.scenarios.save".localized, isPresented: $showSaveScenarioAlert) {
                TextField("rtmp.settings.scenarios.name".localized, text: $newScenarioName)
                Button("save".localized) {
                    let name = newScenarioName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    if !viewModel.saveCurrentAsScenario(name: name) {
                        newScenarioName = name
                    }
                }
                Button("cancel".localized, role: .cancel) {}
            } message: {
                Text("rtmp.settings.scenarios.save.message".localized)
            }
            .alert("rename".localized, isPresented: $showRenameAlert) {
                TextField("rtmp.settings.scenarios.name".localized, text: $renameText)
                Button("rename".localized) {
                    if let renameTarget {
                        _ = viewModel.renameScenario(id: renameTarget.id, to: renameText)
                    }
                }
                Button("cancel".localized, role: .cancel) {}
            }
            .alert(
                editingDestinationID == nil
                    ? "rtmp.settings.destinations.add".localized
                    : "rtmp.settings.destinations.edit".localized,
                isPresented: $showDestinationAlert
            ) {
                TextField("rtmp.settings.destinations.name".localized, text: $destinationName)
                TextField("rtmp.settings.destinations.url".localized, text: $destinationURL)
                Button("save".localized) {
                    if let id = editingDestinationID {
                        _ = viewModel.updateDestination(id: id, name: destinationName, url: destinationURL)
                    } else {
                        _ = viewModel.addDestination(name: destinationName, url: destinationURL)
                    }
                }
                Button("cancel".localized, role: .cancel) {}
            } message: {
                Text("rtmp.settings.destinations.add.message".localized)
            }
            .onAppear {
                viewModel.refreshDiagnosticsLogs()
                viewModel.refreshDestinations()
            }
        }
        .sheet(item: $viewModel.playbackRecord) { _ in
            RecordingPlaybackView(viewModel: viewModel)
        }
        .sheet(item: $selectedLog) { entry in
            NavigationView {
                ScrollView {
                    Text(viewModel.diagnosticsLogText(url: entry.url))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("rtmp.settings.logs".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("done".localized) {
                            selectedLog = nil
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ShareLink(item: entry.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    /// 文件大小展示（如 "1.2 KB"）
    private static func byteCountText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func scenarioSummary(_ scenario: RTMPStreamScenario) -> String {
        let bitrateText = String(format: "%.1f Mbps", Double(scenario.bitrate) / 1_000_000)
        let timeText = scenario.updatedAt.formatted(.relative(presentation: .named))
        return "\(bitrateText) · \(timeText)"
    }
}

#if DEBUG
@MainActor
private struct RTMPStreamingPreview: View {
    @StateObject private var dependencies = PreviewDependencies()

    var body: some View {
        RTMPStreamingView(streamViewModel: dependencies.streamViewModel)
    }
}

#Preview("RTMP Streaming") {
    RTMPStreamingPreview()
}
#endif


// MARK: - Scene Analysis Sheet

/// Agent 场景分析结果弹层（复制 / 系统分享 / 存入 Agent 记忆）
private struct SceneAnalysisSheet: View {
  let text: String
  let isLocal: Bool
  @Binding var copied: Bool
  let onClose: () -> Void
  let onSaveToMemory: () -> Bool
  @State private var savedToMemory = false

  var body: some View {
    NavigationView {
      VStack(alignment: .leading, spacing: 12) {
        if isLocal {
          Label("rtmp.scene.assistant.local".localized, systemImage: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityLabel("rtmp.scene.assistant.local.hint".localized)
        }
        ScrollView {
          Text(text)
            .font(.system(size: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        HStack(spacing: 12) {
          Button {
            UIPasteboard.general.string = text
            copied = true
          } label: {
            Label(
              copied ? "settings.diagnostics.copied".localized : "settings.diagnostics.copy".localized,
              systemImage: copied ? "checkmark" : "doc.on.doc"
            )
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
          }

          ShareLink(item: text) {
            Label("settings.diagnostics.share".localized, systemImage: "square.and.arrow.up")
              .font(.system(size: 14, weight: .semibold))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
              .background(Color.gray.opacity(0.2))
              .cornerRadius(10)
          }

          Button {
            if onSaveToMemory() {
              savedToMemory = true
            }
          } label: {
            Label(
              savedToMemory ? "rtmp.scene.analysis.saved".localized : "rtmp.scene.suggestions.toMemory".localized,
              systemImage: savedToMemory ? "checkmark" : "brain"
            )
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.25))
            .cornerRadius(10)
          }
          .disabled(text.isEmpty || savedToMemory)
        }
        .padding(.horizontal)
      }
      .navigationTitle("rtmp.scene.analysis.title".localized)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("done".localized) { onClose() }
        }
      }
    }
  }
}
