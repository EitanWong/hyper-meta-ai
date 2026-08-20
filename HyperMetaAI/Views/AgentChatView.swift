/*
 * Agent Chat View
 * 统一的 Agent 聊天界面，支持 OpenClaw / Hermes 等所有已接入 Agent
 * 能力: 语音转录、眼镜拍照、文字输入、流式输出、工具进度、可打断(Hermes)
 */

import SwiftUI
import Translation
import PhotosUI

struct AgentChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let text: String
    let image: UIImage?
    let timestamp = Date()
}

struct AgentChatView: View {
    let kind: AgentKind
    @ObservedObject var streamViewModel: StreamSessionViewModel
    /// 指定恢复的历史会话 ID；nil 时恢复最近一次会话
    private let initialRecordID: UUID?
    /// 任务结果「在聊天中追问」：打开聊天页时载入的结果上下文（nil 表示普通进入）
    private let initialTaskResult: String?
    /// 自定义 HTTP Agent 配置；nil 表示内置 Agent（OpenClaw / Hermes）
    private let customConfig: CustomAgentConfig?
    @ObservedObject private var voiceSession = QwenVoiceSession.shared
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @ObservedObject private var hermesService = HermesService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [AgentChatMessage] = []
    @State private var inputText = ""
    @State private var pendingResponse = ""
    @State private var isSending = false
    @State private var activeTool: String?
    @State private var healthChecked = false

    // ASR states
    @State private var isListening = false
    @State private var asrText = ""
    @State private var asrPartial = ""
    @State private var asrService: OpenClawASRService?
    @State private var showTextInput = false
    @State private var triggerBanner: String?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var voiceReplyEnabled = AgentVoiceSettings.replyEnabled
    @State private var showQwenVoice = false
    /// 统一回合状态机：镜腿触发语义 + 眼镜端状态显示
    @State private var turnMachine = AgentTurnStateMachine()
    /// 已持久化的消息数（防止同页重复保存历史）
    @State private var lastPersistedMessageCount = 0
    /// 当前会话对应的「记录」条目 ID（恢复历史 / 新建后首次落盘时确定），
    /// 后续落盘复用该 ID 覆盖更新，避免同一对话在记录页 / Hub 时间线重复出现
    @State private var persistedRecordID: UUID?
    /// 是否已恢复上次会话（显示提示条）
    @State private var restoredFromHistory = false
    @State private var showNewChatConfirm = false
    @State private var thinkingHintTask: Task<Void, Never>?
    /// 视野上下文：最近一次发送/拍摄的眼镜画面，后续追问自动携带（可清除）
    @State private var visionContext: UIImage?
    /// 端侧 OCR 取词状态与结果
    @State private var isOCRing = false
    @State private var showOCRResult = false
    @State private var ocrResultText = ""
    /// 无眼镜画面帧时回退到相册选图（模拟器 / 无眼镜场景的稳定路径）
    @State private var showFallbackPhotoPicker = false
    @State private var fallbackPhotoItem: PhotosPickerItem?
    @State private var fallbackAction: FallbackVisionAction = .ocr
    /// 图库照片直达：进入聊天页后立即发送的照片（发送后清空）
    @State private var pendingPhoto: UIImage?
    /// 图库 OCR 直达：进入聊天页后立即作为用户消息发送的文字（发送后清空）
    @State private var pendingUserText: String?
    /// 任务结果「在聊天中追问」：首条用户消息自动携带结果上下文（一次性）
    @State private var followUpWrapGate = TaskFollowUpWrapGate()

    /// 回退选图后要执行的端侧视觉动作
    private enum FallbackVisionAction {
        case sendPhoto
        case ocr
        case scene
    }

    init(
        kind: AgentKind,
        streamViewModel: StreamSessionViewModel,
        initialRecordID: UUID? = nil,
        customConfig: CustomAgentConfig? = nil,
        pendingPhoto: UIImage? = nil,
        pendingUserText: String? = nil,
        initialTaskResult: String? = nil
    ) {
        self.kind = kind
        self.streamViewModel = streamViewModel
        self.initialRecordID = initialRecordID
        self.customConfig = customConfig
        self.initialTaskResult = initialTaskResult
        _pendingPhoto = State(initialValue: pendingPhoto)
        _pendingUserText = State(initialValue: pendingUserText)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection status
                if !connectionState.isOnline {
                    HStack(spacing: 8) {
                        if connectionState.isBusy {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 12))
                        }
                        Text(statusText)
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
                }

                // 镜腿触发提示（打断/恢复/结束）
                if let triggerBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 12))
                        Text(triggerBanner)
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.purple.opacity(0.15))
                }

                // 恢复历史提示
                if restoredFromHistory {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                        Text("agent.chat.history.restored".localized)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6).opacity(0.6))
                }

                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // 后台任务列表（与语音页共享同一会话状态）
                            if !voiceSession.sortedAgentTasks.isEmpty {
                                AgentTaskListView(
                                    tasks: voiceSession.sortedAgentTasks,
                                    onReplay: replayChatTask,
                                    onFollowUpInChat: startTaskFollowUpInChat
                                )
                                .padding(.vertical, 4)
                            }
                            ForEach(messages) { msg in
                                AgentChatBubble(message: msg).id(msg.id)
                            }
                            if !pendingResponse.isEmpty {
                                AgentChatBubble(message: AgentChatMessage(
                                    role: "assistant", text: pendingResponse, image: nil
                                ))
                                .id("agent-streaming")
                            }
                            if let tool = activeTool {
                                HStack(spacing: 6) {
                                    Image(systemName: "hammer.fill")
                                        .font(.system(size: 11))
                                    Text("hermes.chat.tool".localized(tool))
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: pendingResponse) { _, _ in
                        guard !pendingResponse.isEmpty else { return }
                        proxy.scrollTo("agent-streaming", anchor: .bottom)
                    }
                    .onChange(of: activeTool) { _, _ in
                        guard !pendingResponse.isEmpty else { return }
                        proxy.scrollTo("agent-streaming", anchor: .bottom)
                    }
                }

                Divider()

                // Bottom control area
                VStack(spacing: 12) {
                    // ASR transcription preview
                    if isListening || !asrText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayASRText)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(.systemGray6))
                                .cornerRadius(12)

                            if !isListening && !asrText.isEmpty {
                                HStack(spacing: 12) {
                                    Button {
                                        asrText = ""
                                        asrPartial = ""
                                    } label: {
                                        Text("cancel".localized)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.gray)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(Color(.systemGray5))
                                            .cornerRadius(10)
                                    }

                                    Button {
                                        sendASRText()
                                    } label: {
                                        Text("openclaw.chat.sendvoice".localized)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(Color.purple)
                                            .cornerRadius(10)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Main action buttons
                    HStack(spacing: 16) {
                        // Camera snap
                        Button {
                            Task { await snapAndSend() }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: runtimeCapabilities.preferredVisualInput == .glassesCamera
                                    ? "camera.fill"
                                    : "photo.on.rectangle")
                                    .font(.system(size: 22))
                                Text(runtimeCapabilities.preferredVisualInput == .glassesCamera
                                    ? "openclaw.chat.snap".localized
                                    : "agent.vision.photo.button".localized)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(isSending ? .gray : .purple)
                            .frame(width: 60, height: 60)
                        }
                        .disabled(
                            isSending ||
                            !connectionState.isOnline
                        )

                        // On-device OCR (offline)
                        Button {
                            Task { await runOCR() }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 22))
                                Text("agent.vision.ocr.button".localized)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(isOCRing ? .gray : .teal)
                            .frame(width: 60, height: 60)
                        }
                        .disabled(
                            isOCRing ||
                            isSending
                        )

                        // Big mic / stop button
                        Button {
                            if isStreamingActive {
                                cancelActiveStream()
                                flushPendingResponse()
                            } else {
                                toggleListening()
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        isListening
                                            ? LinearGradient(colors: [.red, .orange], startPoint: .top, endPoint: .bottom)
                                            : LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom)
                                    )
                                    .frame(width: 72, height: 72)
                                    .shadow(color: isListening ? .red.opacity(0.4) : .purple.opacity(0.3), radius: 10)

                                if isListening {
                                    Circle()
                                        .stroke(Color.red.opacity(0.3), lineWidth: 3)
                                        .frame(width: 88, height: 88)
                                        .scaleEffect(isListening ? 1.1 : 1.0)
                                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isListening)
                                }

                                Image(systemName: iconName)
                                    .font(.system(size: isListening ? 24 : 28))
                                    .foregroundColor(.white)
                            }
                        }
                        .disabled(!connectionState.isOnline)

                        // Text input toggle
                        Button {
                            showTextInput.toggle()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "keyboard")
                                    .font(.system(size: 22))
                                Text("openclaw.chat.text".localized)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.purple)
                            .frame(width: 60, height: 60)
                        }

                        // Realtime voice session
                        Button {
                            stopListening()
                            showQwenVoice = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 22))
                                Text("qwen.voice.title".localized)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.blue)
                            .frame(width: 60, height: 60)
                        }
                    }
                    .padding(.vertical, 4)

                    // Text input bar (toggleable)
                    if showTextInput {
                        if visionContext != nil {
                            HStack(spacing: 8) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 13))
                                    .foregroundColor(.purple)
                                Text("agent.vision.context.chip".localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    clearVisionContext()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        HStack(spacing: 10) {
                            TextField("openclaw.chat.placeholder".localized, text: $inputText)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.send)
                                .onSubmit { sendText() }

                            Button {
                                sendText()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(inputText.isEmpty ? .gray : .purple)
                            }
                            .disabled(inputText.isEmpty || !connectionState.isOnline)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
            }
            .navigationTitle(customConfig?.name ?? kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 14) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                        }
                        Button { showNewChatConfirm = true } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionState.isOnline ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        if customConfig == nil {
                        NavigationLink {
                            AgentSettingsView(initialKind: kind)
                        } label: {
                            Image(systemName: "gear")
                                .font(.system(size: 14))
                        }
                    }
                    }
                    CameraCaptureStatusView(state: streamViewModel.cameraCaptureState)
                }
            }
            .fullScreenCover(isPresented: $showQwenVoice, onDismiss: {
                importVoiceTranscripts()
                // 语音会话页接管了镜腿触发回调，返回后恢复本页的处理
                streamViewModel.onDeviceTrigger = { [self] trigger in
                    self.handleDeviceTrigger(trigger)
                }
            }) {
                QwenVoiceView(streamViewModel: streamViewModel, isEmbeddedInChat: true)
            }
            .sheet(isPresented: $showOCRResult) {
                NavigationView {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(ocrResultText)
                                    .font(.system(size: 15))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if #available(iOS 18.0, *) {
                                    OnDeviceTranslationView(text: ocrResultText)
                                } else {
                                    Text("agent.vision.ocr.translate.unsupported".localized)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding()
                        }
                        HStack(spacing: 12) {
                            Button {
                                sendOCRText()
                            } label: {
                                Label("agent.vision.ocr.send".localized, systemImage: "paperplane.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .disabled(!connectionState.isOnline)

                            Button {
                                copyOCRText()
                            } label: {
                                Label("agent.vision.ocr.copy".localized, systemImage: "doc.on.doc")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                speakOCRText()
                            } label: {
                                Label("agent.vision.ocr.speak".localized, systemImage: "speaker.wave.2")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                    .navigationTitle("agent.vision.ocr.title".localized)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("agent.vision.ocr.close".localized) {
                                showOCRResult = false
                            }
                        }
                    }
                }
            }
            .alert("agent.chat.new.title".localized, isPresented: $showNewChatConfirm) {
                Button("agent.chat.new.confirm".localized, role: .destructive) {
                    startNewChat()
                }
                Button("cancel".localized, role: .cancel) {}
            } message: {
                Text("agent.chat.new.message".localized)
            }
        }
        .onAppear {
            guard !AppIdentity.isRunningPreview else { return }

            streamViewModel.onDeviceTrigger = { [self] trigger in
                self.handleDeviceTrigger(trigger)
            }
            // 轻量会话：让镜腿触发在聊天页始终可用
            Task { await streamViewModel.acquireAgentTriggerSession() }
            // 恢复该 Agent 的最近一次会话历史
            if messages.isEmpty {
                let records = ConversationStorage.shared.loadAllConversations()
                if let initialRecordID {
                    messages = AgentConversationPersister.loadMessages(
                        from: records,
                        recordID: initialRecordID
                    )
                    if !messages.isEmpty {
                        persistedRecordID = initialRecordID
                    }
                } else if AgentMemorySettings.chatHistoryEnabled {
                    messages = AgentConversationPersister.loadMessages(
                        from: records,
                        agentName: agentName
                    )
                    persistedRecordID = AgentConversationPersister.latestRecord(
                        from: records,
                        agentName: agentName
                    )?.id
                }
                lastPersistedMessageCount = messages.count
                restoredFromHistory = !messages.isEmpty
            }

            // 任务结果「在聊天中追问」：载入结果上下文，首条消息自动携带
            if let initialTaskResult {
                armTaskFollowUp(with: initialTaskResult)
            }

            // 自定义 Agent 无需健康检查：配置有效即视为可用，连接错误在流式回调中呈现
            guard customConfig == nil else { return }
            switch kind {
            case .openclaw:
                setupChatEventHandler()
                if openClawService.connectionState != .connected,
                   openClawService.loadGatewayToken() != nil {
                    openClawService.connect()
                }
            case .hermes:
                if !healthChecked {
                    healthChecked = true
                    Task { await hermesService.checkHealth() }
                }
            }

            // 图库照片直达：进入聊天页即发送所选照片（视野上下文保留，可继续追问）
            if !AppIdentity.isRunningPreview, let pendingPhoto {
                self.pendingPhoto = nil
                sendGalleryPhoto(pendingPhoto)
            }
            // 图库 OCR 直达：进入聊天页即把识别文字作为用户消息发送（可继续追问翻译 / 总结）
            if !AppIdentity.isRunningPreview, let pendingUserText {
                self.pendingUserText = nil
                sendPendingUserText(pendingUserText)
            }
        }
        .onDisappear {
            guard !AppIdentity.isRunningPreview else { return }
            cancelThinkingHint()
            streamViewModel.onDeviceTrigger = nil
            AgentDisplayHub.shared.show(.idle)
            Task { await streamViewModel.releaseAgentTriggerSession() }
            bannerDismissTask?.cancel()
            stopListening()
            if let customConfig {
                if customConfig.transport == .websocket {
                    CustomWebSocketAgentService.shared.cancel()
                } else {
                    CustomAgentService.shared.cancel()
                }
            } else if kind == .openclaw {
                openClawService.onChatEvent = nil
            } else {
                hermesService.cancel()
            }
            flushPendingResponse()
            persistConversationIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentVisionDataCleared)) { _ in
            // 视觉数据清理：丢弃当前会话保留的视野上下文（帧仅内存持有）
            visionContext = nil
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AgentWearableTriggerCenter.repeatReplyNotification
        )) { _ in
            // 触发中心「重听回复」：与眼镜菜单 Repeat 共用同一实现
            handleMenuAction(.repeatLastReply)
        }
        .photosPicker(
            isPresented: $showFallbackPhotoPicker,
            selection: $fallbackPhotoItem,
            matching: .images
        )
        .onChange(of: fallbackPhotoItem) { _, item in
            guard let item else { return }
            Task {
                // 相册回退：加载所选图片后执行与眼镜帧相同的端侧视觉动作
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    showTriggerBanner("agent.vision.pick.failed".localized)
                    fallbackPhotoItem = nil
                    return
                }
                switch fallbackAction {
                case .sendPhoto:
                    sendGalleryPhoto(image)
                case .ocr:
                    isOCRing = true
                    defer { isOCRing = false }
                    await processOCR(image)
                case .scene:
                    isOCRing = true
                    defer { isOCRing = false }
                    await processScene(image)
                }
                fallbackPhotoItem = nil
            }
        }
        .onChange(of: voiceSession.acknowledgmentNotice) { _, notice in
            // 任务受理回执：任务创建时立即回一句「收到」（与语音页一致）
            guard let notice else { return }
            AgentTaskLensPresenter.handleAcknowledgmentChange(
                title: notice.title,
                announceByApp: true,
                isSpeaking: voiceSession.isSpeaking,
                isInputActive: voiceSession.isInputActive,
                ttsSpeaking: TTSService.shared.isSpeaking
            )
        }
        .onChange(of: voiceSession.completionNotice) { _, notice in
            // 后台任务终态：清过期进度 → TTS 播报 → 镜片结果卡 → 手机触觉（与语音页一致）
            guard let notice else { return }
            AgentTaskLensPresenter.handleCompletionChange(
                phase: turnMachine.phase,
                kind: notice.kind,
                text: notice.text,
                lastTaskResultText: voiceSession.lastTaskResultText,
                runningTaskCount: voiceSession.runningTaskCount,
                announceByApp: true,
                isSpeaking: voiceSession.isSpeaking,
                isInputActive: voiceSession.isInputActive,
                ttsSpeaking: TTSService.shared.isSpeaking
            )
        }
        .onChange(of: voiceSession.runningTaskCount) { _, count in
            // 任务进度变化：进行中显示进度卡；全部结束后清进度并恢复回合状态
            AgentTaskLensPresenter.handleProgressChange(
                phase: turnMachine.phase,
                runningTaskCount: count,
                taskMessage: voiceSession.taskMessage,
                hasCompletionNotice: voiceSession.completionNotice != nil
            )
        }
        .onChange(of: voiceSession.taskMessage) { _, message in
            // 任务分步进度：聆听/思考/空闲态实时把最新步骤透出到眼镜
            AgentTaskLensPresenter.handleStepMessageChange(
                phase: turnMachine.phase,
                runningTaskCount: voiceSession.runningTaskCount,
                taskMessage: message
            )
        }
        .onChange(of: openClawService.connectionState) { _, newState in
            // OpenClaw 断线时没有 FINAL 事件，需重置发送状态防止 UI 卡死
            guard isSending else { return }
            if case .connected = newState { return }
            cancelThinkingHint()
            AgentDisplayHub.shared.clearTaskProgress()
            isSending = false
            activeTool = nil
        }
    }

    // MARK: - Computed

    private var runtimeCapabilities: AssistantRuntimeCapabilities {
        AssistantRuntimePolicy.resolve(hasActiveGlasses: streamViewModel.hasActiveDevice)
    }

    private var connectionState: AgentConnectionState {
        if let customConfig {
            return customConfig.isValid
                ? .connected
                : .failed("custom.agent.error.invalidurl".localized)
        }
        switch kind {
        case .openclaw: return AgentConnectionState.map(openClawService.connectionState)
        case .hermes: return AgentConnectionState.map(hermesService.connectionState)
        }
    }

    private var isStreamingActive: Bool {
        if customConfig != nil { return isSending }
        return kind == .hermes && hermesService.isStreaming
    }

    /// 历史持久化使用的 Agent 标识（自定义 Agent 用配置 ID 区分多实例）
    private var agentName: String {
        if let customConfig { return "custom." + customConfig.id.uuidString }
        return kind.displayName
    }

    private var iconName: String {
        if isListening { return "stop.fill" }
        if isStreamingActive { return "stop.circle.fill" }
        return "mic.fill"
    }

    private var displayASRText: String {
        if asrText.isEmpty && asrPartial.isEmpty {
            return isListening ? "openclaw.chat.listening".localized : ""
        }
        return asrText + asrPartial
    }

    private var statusText: String {
        switch connectionState {
        case .connected: return "agents.status.connected".localized
        case .connecting: return "agents.status.connecting".localized
        case .waitingForPairing: return "agents.status.pairing".localized
        case .failed(let message): return message.isEmpty ? "agents.status.disconnected".localized : message
        case .unknown: return "agents.status.disconnected".localized
        }
    }

    // MARK: - Chat Events (OpenClaw streaming snapshots)

    private func setupChatEventHandler() {
        openClawService.onChatEvent = { (text: String) in
            if text.hasPrefix("[[FINAL]]") {
                cancelThinkingHint()
                AgentDisplayHub.shared.clearTaskProgress()
                turnMachine.outputEnded()
                if turnMachine.phase != .interrupted {
                    AgentDisplayHub.shared.show(.listening)
                }
                isSending = false
                activeTool = nil
                let fullText = String(text.dropFirst(9))
                pendingResponse = ""
                if !fullText.isEmpty {
                    messages.append(AgentChatMessage(role: "assistant", text: fullText, image: nil))
                    speakAssistantReply(fullText)
                }
            } else {
                cancelThinkingHint()
                turnMachine.outputStarted()
                AgentDisplayHub.shared.show(.speaking)
                pendingResponse = text
            }
        }
    }

    // MARK: - Text

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        // 任务指令（进度/取消）本地拦截：与语音页一致，不发给大脑（大脑没有任务上下文）
        if let command = AgentTaskCommandParser.parse(
            text,
            activeTaskCount: QwenVoiceSession.shared.runningTaskCount,
            failedTaskCount: QwenVoiceSession.shared.failedTasks.count
        ), handleTaskCommand(command, userText: text) {
            inputText = ""
            return
        }
        // 清单指令（添加/查询/序号点名/清空）本地拦截：与语音页一致，不发给大脑
        if let command = AgentListCommandParser.parse(text),
           handleListCommand(command, userText: text) {
            inputText = ""
            return
        }
        // 记忆指令（记住/查询/纠正删除）本地拦截：与语音页一致，不发给大脑
        if let command = AgentMemoryCommandParser.parse(text),
           handleProfileCommandReply(command.replyText(), userText: text) {
            inputText = ""
            return
        }
        // 助手画像指令（查询/改名）本地拦截：与语音页一致，不发给大脑
        if let command = AgentPersonaCommandParser.parse(text),
           handlePersonaCommand(command, userText: text) {
            inputText = ""
            return
        }
        // 个性化规则指令（添加/查询/删除/清空）本地拦截：与语音页一致，不发给大脑
        if let command = AgentRuleCommandParser.parse(text),
           handleProfileCommandReply(command.replyText(), userText: text) {
            inputText = ""
            return
        }

        // 健康数据指令（记录/查询）本地拦截：与语音页一致，不发给大脑
        if let command = AgentHealthCommandParser.parse(text),
           handleHealthCommand(command, userText: text) {
            inputText = ""
            return
        }
        // 智能家居指令（控制/查询 HomeKit）本地拦截：与语音页一致，不发给大脑
        if let command = AgentHomeKitCommandParser.parse(text),
           handleHomeKitCommand(command, userText: text) {
            inputText = ""
            return
        }
        // 日历删除歧义追问（序号 / 更具体名称 / 取消）：有待选且消息像是选择时拦截，
        // 与语音页一致——解析为选择则删除 / 取消 / 收窄追问，否则走常规流程（待选保留）
        if !AgentCalendarDeletePendingStore.candidates.isEmpty,
           AgentCalendarDeleteSelectionParser.isPotentialSelection(
               text,
               candidates: AgentCalendarDeletePendingStore.candidates
           ) {
            inputText = ""
            // 镜片按钮选择卡：选项来自当前待选快照，点击直接删除 / 取消（与语音并行）
            let snapshot = AgentCalendarDeletePendingStore.candidates
            AgentDisplayHub.shared.showChoice(
                options: snapshot.map(\.title),
                onSelect: { index in
                    let target = snapshot[index]
                    Task { @MainActor in
                        if let reply = await AgentCalendarDeleteSelectionCoordinator.select(
                            matching: target,
                            provider: AgentCalendar.provider
                        ) {
                            appendLocalReply(reply)
                        }
                    }
                },
                onCancel: {
                    Task { @MainActor in
                        appendLocalReply(AgentCalendarDeleteSelectionCoordinator.cancel())
                    }
                }
            )
            Task { @MainActor in
                if let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
                    text: text,
                    provider: AgentCalendar.provider
                ) {
                    handleProfileCommandReply(reply, userText: text)
                }
            }
            return
        }
        // 日历日程指令（创建/查询系统日历）本地拦截：与语音页一致，不发给大脑
        if let command = AgentCalendarCommandParser.parse(text),
           handleCalendarCommand(command, userText: text) {
            inputText = ""
            return
        }
        // 通知播报指令（未读汇总/清空）本地拦截：与语音页一致，不发给大脑
        if let command = AgentNotificationCommandParser.parse(text),
           handleNotificationCommand(command, userText: text) {
            inputText = ""
            return
        }

        let effectiveText = applyTaskFollowUpWrapIfNeeded(text)
        messages.append(AgentChatMessage(role: "user", text: effectiveText, image: nil))
        flushPendingResponse()
        inputText = ""
        send(text: effectiveText, image: nil)
    }



    /// 画像指令的本地处理：改名直接保存，查询播报身份。返回 true 表示已拦截。
    @discardableResult
    private func handlePersonaCommand(
        _ command: AgentPersonaCommand,
        userText: String
    ) -> Bool {
        let reply: String
        switch command {
        case .query:
            reply = AgentPersonaPromptBuilder.spokenIdentity()
        case .setName(let name):
            let persona = AgentPersonaStore.current
            AgentPersonaStore.save(
                name: name,
                role: persona.role,
                style: persona.style,
                enabled: persona.enabled
            )
            reply = AgentProfileCommandReply.personaSet(name: name)
        }
        return handleProfileCommandReply(reply, userText: userText)
    }

    /// 本地指令通用回复：作为 assistant 消息保留在对话记录、上镜片并播报。
    @discardableResult
    private func handleProfileCommandReply(
        _ reply: String,
        userText: String
    ) -> Bool {
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        messages.append(AgentChatMessage(role: "assistant", text: reply, image: nil))
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .completed),
            text: reply,
            fallback: .idle
        )
        speakAssistantReply(reply)
        showTriggerBanner(reply)
        return true
    }

    /// 处理任务指令（进度播报 / 请求取消），本地响应并保留对话记录。
    /// 返回 true 表示已拦截，不再发送给 Agent。
    @discardableResult
    private func handleTaskCommand(
        _ command: AgentTaskCommand,
        userText: String
    ) -> Bool {
        guard let reply = AgentTaskCommandResponseBuilder.reply(
            for: command,
            session: QwenVoiceSession.shared
        ) else { return false }
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        messages.append(AgentChatMessage(role: "assistant", text: reply, image: nil))
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .progress),
            text: reply,
            fallback: .idle
        )
        speakAssistantReply(reply)
        let bannerKey: String
        if command.isRetry {
            bannerKey = "agent.task.command.retry.banner"
        } else if command.isCancellation {
            bannerKey = "agent.task.command.cancel.banner"
        } else {
            bannerKey = "agent.task.command.progress.banner"
        }
        showTriggerBanner(bannerKey.localized)
        return true
    }

    /// 处理清单指令（添加 / 查询 / 序号点名 / 清空），本地响应并保留对话记录。
    /// 返回 true 表示已拦截，不再发送给 Agent。
    @discardableResult
    private func handleListCommand(
        _ command: AgentListCommand,
        userText: String
    ) -> Bool {
        let reply: String
        switch command {
        case .add(let item, let list):
            if let updated = AgentListStore.addItem(item, to: list) {
                reply = AgentListResponseText.added(item: item, to: updated.name)
            } else if AgentListStore.list(named: list)?.items.contains(item) == true {
                reply = AgentListResponseText.duplicate(item: item, in: list)
            } else {
                reply = AgentListResponseText.full(list: list)
            }
        case .remove(let item, let list):
            let existed = AgentListStore.list(named: list)?.items.contains(item) ?? false
            AgentListStore.removeItem(item, from: list)
            reply = existed
                ? AgentListResponseText.removed(item: item, from: list)
                : AgentListResponseText.missing(item: item, in: list)
        case .query(let list):
            reply = AgentListResponseText.query(
                list: list,
                items: AgentListStore.list(named: list)?.items ?? []
            )
        case .queryIndex(let index):
            reply = AgentListResponseText.queryIndex(
                index: index,
                lists: AgentListDisplayMapping.recentLists(limit: AgentListStore.maxListCount)
            )
        case .queryItem(let list, let index):
            reply = AgentListResponseText.queryItem(
                list: list,
                index: index,
                items: AgentListStore.list(named: list)?.items ?? []
            )
        case .queryItemByIndexes(let listIndex, let itemIndex):
            reply = AgentListResponseText.queryItemByIndexes(
                listIndex: listIndex,
                itemIndex: itemIndex,
                lists: AgentListDisplayMapping.recentLists(limit: AgentListStore.maxListCount)
            )
        case .rename(let list, let newName):
            if AgentListStore.renameList(named: list, to: newName) != nil {
                reply = AgentListResponseText.renamed(list: list, to: newName)
            } else if AgentListStore.list(named: newName) != nil {
                reply = AgentListResponseText.renameDuplicate(name: newName)
            } else {
                reply = AgentListResponseText.renameNotFound(list: list)
            }
        case .clear(let list):
            AgentListStore.clearItems(named: list)
            reply = AgentListResponseText.cleared(list: list)
        }
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        messages.append(AgentChatMessage(role: "assistant", text: reply, image: nil))
        AgentDisplayHub.shared.showResult(
            title: "List",
            text: reply,
            fallback: .idle
        )
        speakAssistantReply(reply)
        showTriggerBanner(reply)
        return true
    }

    // MARK: - 健康数据

    /// 健康指令本地处理：记录 / 查询健康数据（HealthKit）。返回 true 表示已拦截。
    @discardableResult
    private func handleHealthCommand(
        _ command: AgentHealthCommand,
        userText: String
    ) -> Bool {
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        Task { @MainActor in
            let reply = await AgentHealthExecutor.execute(
                command,
                provider: AgentHealth.provider
            )
            appendLocalReply(reply)
        }
        return true
    }

    // MARK: - 智能家居

    /// 家居指令本地处理：控制 / 查询 HomeKit 配件。返回 true 表示已拦截。
    @discardableResult
    private func handleHomeKitCommand(
        _ command: AgentHomeKitCommand,
        userText: String
    ) -> Bool {
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        Task { @MainActor in
            let reply = await AgentHomeKitExecutor.execute(
                command,
                provider: AgentHomeKit.provider
            )
            appendLocalReply(reply)
        }
        return true
    }

    // MARK: - 通知播报

    /// 通知指令本地处理：未读汇总 / 清空通知中心。返回 true 表示已拦截。
    @discardableResult
    private func handleNotificationCommand(
        _ command: AgentNotificationCommand,
        userText: String
    ) -> Bool {
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        Task { @MainActor in
            let reply: String
            switch command {
            case .catchUp:
                reply = await AgentNotificationButler.shared.catchUp()
            case .clear:
                reply = await AgentNotificationButler.shared.clearDelivered()
            }
            appendLocalReply(reply)
        }
        return true
    }

    // MARK: - 日历日程

    /// 日历指令本地处理：创建 / 查询系统日历（EventKit）。返回 true 表示已拦截。
    @discardableResult
    private func handleCalendarCommand(
        _ command: AgentCalendarCommand,
        userText: String
    ) -> Bool {
        messages.append(AgentChatMessage(role: "user", text: userText, image: nil))
        Task { @MainActor in
            let reply = await AgentCalendarExecutor.execute(
                command,
                provider: AgentCalendar.provider
            )
            appendLocalReply(reply)
        }
        return true
    }

    /// 日历等本地工具的标准回复：进对话流 + 镜片结果卡 + TTS + 顶部提示条
    private func appendLocalReply(_ text: String) {
        messages.append(AgentChatMessage(role: "assistant", text: text, image: nil))
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .completed),
            text: text,
            fallback: .idle
        )
        speakAssistantReply(text)
        showTriggerBanner(text)
    }

    // MARK: - Camera

    /// 抓取一帧眼镜当前画面（复用流会话与超时逻辑）
    private func captureCurrentFrame() async -> UIImage? {
        let streamReady = await streamViewModel.acquireStream(for: .agentChat)
        guard streamReady else { return nil }
        defer {
            Task { @MainActor in
                await streamViewModel.releaseStream(for: .agentChat)
            }
        }
        let deadline = Date().addingTimeInterval(2.0)
        while (!streamViewModel.cameraCaptureState.isStreaming ||
               streamViewModel.currentVideoFrame == nil) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard streamViewModel.cameraCaptureState.isStreaming,
              let frame = streamViewModel.currentVideoFrame else {
            return nil
        }
        return frame
    }

    private func snapAndSend() async {
        guard !isSending else { return }
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            messages.append(AgentChatMessage(
                role: "assistant",
                text: "agent.vision.revoked".localized,
                image: nil
            ))
            return
        }
        guard runtimeCapabilities.preferredVisualInput == .glassesCamera else {
            presentFallbackPicker(for: .sendPhoto)
            return
        }
        isSending = true
        guard let frame = await captureCurrentFrame() else {
            isSending = false
            presentFallbackPicker(for: .sendPhoto)
            return
        }
        // 捕获期占用结束，由 send() 接管发送期状态（同步交接，无并发窗口）
        isSending = false
        sendPhotoMessage(frame, defaultPrompt: "openclaw.chat.photoprompt".localized)
    }

    /// 图库照片直达：以所选照片作为视野上下文发送给当前 Agent（与拍照发送同一语义）
    private func sendGalleryPhoto(_ image: UIImage) {
        guard !isSending else { return }
        sendPhotoMessage(image, defaultPrompt: "agent.vision.gallery.prompt".localized)
    }

    /// 把直达文字作为用户消息发送（与聊天页取词「发给 Agent」同一语义）
    private func sendPendingUserText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        messages.append(AgentChatMessage(role: "user", text: trimmed, image: nil))
        flushPendingResponse()
        send(text: trimmed, image: nil)
    }

    /// 发送带图消息：设置视野上下文、输入为空用默认提示、入消息列表并发送
    private func sendPhotoMessage(_ image: UIImage, defaultPrompt: String) {
        visionContext = image
        let text = inputText.isEmpty ? defaultPrompt : inputText
        messages.append(AgentChatMessage(role: "user", text: text, image: image))
        flushPendingResponse()
        inputText = ""
        send(text: text, image: image)
    }

    /// Agent 请求拍照：获取一帧眼镜画面并展示到聊天记录（供自定义 Agent 工具执行）
    private func captureFrameForAgent() async -> UIImage? {
        guard let frame = await captureCurrentFrame() else { return nil }
        visionContext = frame
        messages.append(AgentChatMessage(
            role: "user",
            text: "agent.vision.captured".localized,
            image: frame
        ))
        return frame
    }

    // MARK: - 端侧场景识别与 OCR

    /// 抓帧 → 端侧场景识别 → 上镜片展示并朗读；识别结果作为用户消息发给当前 Agent
    private func runScene(autoplaySpeech: Bool = false) async {
        guard !isOCRing, !isSending else { return }
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            showTriggerBanner("agent.vision.revoked".localized)
            return
        }
        guard runtimeCapabilities.preferredVisualInput == .glassesCamera else {
            presentFallbackPicker(for: .scene)
            return
        }
        isOCRing = true
        defer { isOCRing = false }

        guard let frame = await captureCurrentFrame() else {
            presentFallbackPicker(for: .scene)
            return
        }
        await processScene(frame, autoplaySpeech: autoplaySpeech)
    }

    /// 相册选图回退：无眼镜画面帧时让用户从相册选一张，执行相同动作
    private func presentFallbackPicker(for action: FallbackVisionAction) {
        fallbackAction = action
        showFallbackPhotoPicker = true
    }

    /// 对给定帧执行场景识别（眼镜帧与相册回退共用）
    private func processScene(_ frame: UIImage, autoplaySpeech: Bool = false) async {
        let result = await VisionSceneService.analyze(frame)
        let summary = VisionSceneTextProcessor.summaryText(from: result)
        guard !summary.isEmpty else {
            showTriggerBanner("agent.vision.scene.empty".localized)
            return
        }
        AgentVisionSceneStore.set(summary)
        AgentDisplayHub.shared.showResult(
            title: "agent.vision.scene.title".localized,
            text: VisionSceneTextProcessor.displayText(from: result),
            fallback: .idle
        )
        if autoplaySpeech, AgentVoiceSettings.replyEnabled {
            TTSService.shared.stop()
            TTSService.shared.speak(summary)
        }
        // 识别结果作为用户消息发给当前 Agent，可继续追问
        messages.append(AgentChatMessage(role: "user", text: summary, image: nil))
        flushPendingResponse()
        send(text: summary, image: nil)
    }

    /// 抓帧 → 端侧 OCR → 展示识别结果（离线、免费、无网络）
    private func runOCR(autoplaySpeech: Bool = false) async {
        guard !isOCRing, !isSending else { return }
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            showTriggerBanner("agent.vision.revoked".localized)
            return
        }
        guard runtimeCapabilities.preferredVisualInput == .glassesCamera else {
            presentFallbackPicker(for: .ocr)
            return
        }
        isOCRing = true
        defer { isOCRing = false }

        guard let frame = await captureCurrentFrame() else {
            presentFallbackPicker(for: .ocr)
            return
        }
        await processOCR(frame, autoplaySpeech: autoplaySpeech)
    }

    /// 对给定帧执行取词（眼镜帧与相册回退共用）
    private func processOCR(_ frame: UIImage, autoplaySpeech: Bool = false) async {
        let lines = await VisionOCRService.recognizeText(in: frame)
        let text = VisionOCRTextProcessor.normalizedText(from: lines.map(\.text))
        guard !text.isEmpty else {
            showTriggerBanner("agent.vision.ocr.empty".localized)
            return
        }
        AgentVisionOCRStore.set(text)
        ocrResultText = text
        AgentDisplayHub.shared.showResult(
            title: "agent.vision.ocr.title".localized,
            text: VisionOCRTextProcessor.displayText(from: text),
            fallback: .idle
        )
        showOCRResult = true
        // 镜片触发的取词：直接朗读，无需掏手机
        if autoplaySpeech, AgentVoiceSettings.replyEnabled {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
    }

    /// 把识别文字作为用户消息发给 Agent（可继续追问翻译 / 总结）
    private func sendOCRText() {
        let text = ocrResultText
        showOCRResult = false
        guard !text.isEmpty, !isSending else { return }
        messages.append(AgentChatMessage(role: "user", text: text, image: nil))
        flushPendingResponse()
        send(text: text, image: nil)
    }

    private func copyOCRText() {
        UIPasteboard.general.string = ocrResultText
        showOCRResult = false
        showTriggerBanner("agent.vision.ocr.copied".localized)
    }

    /// 朗读识别文字（眼镜场景：看菜单 / 路牌时直接听）
    private func speakOCRText() {
        guard !ocrResultText.isEmpty else { return }
        showOCRResult = false
        TTSService.shared.stop()
        TTSService.shared.speak(ocrResultText)
    }

    /// 镜片「翻译」：把最近一次取词结果发给当前 Agent 翻译（回复 TTS 播报）
    private func requestTranslateFromMenu() {
        guard let text = AgentVisionOCRStore.lastText else {
            showTriggerBanner("agent.vision.translate.notext".localized)
            return
        }
        let instruction = VisionTranslationPlanner.translateInstruction(for: text)
        messages.append(AgentChatMessage(role: "user", text: instruction, image: nil))
        flushPendingResponse()
        send(text: instruction, image: nil)
    }

    // MARK: - Voice (ASR)

    private func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: .alibaba), !apiKey.isEmpty else {
            messages.append(AgentChatMessage(role: "assistant", text: "openclaw.chat.noapikey".localized, image: nil))
            return
        }

        asrText = ""
        asrPartial = ""
        let service = OpenClawASRService(apiKey: apiKey)
        self.asrService = service

        service.onPartialResult = { text in
            asrPartial = text
        }

        service.onFinalResult = { text in
            asrText += text
            asrPartial = ""
        }

        service.onError = { error in
            isListening = false
            print("[Agent ASR] Error: \(error)")
        }

        service.start()
        isListening = true
    }

    private func stopListening() {
        asrService?.stop()
        asrService = nil
        isListening = false
        asrPartial = ""
    }

    private func sendASRText() {
        let text = asrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let effectiveText = applyTaskFollowUpWrapIfNeeded(text)
        messages.append(AgentChatMessage(role: "user", text: effectiveText, image: nil))
        flushPendingResponse()
        send(text: effectiveText, image: nil)
        asrText = ""
    }

    // MARK: - Send to Agent

    private func send(text: String, image: UIImage?) {
        guard !isSending else { return }
        turnMachine.turnStarted()
        // 视野连续追问：显式图片优先；否则有视野上下文且开启时自动携带
        let attachVision = AgentVisionContextPolicy.shouldAttach(
            sendingImage: image != nil,
            hasActiveContext: visionContext != nil,
            followUpEnabled: AgentVisionSettings.followUpEnabled
        )
        let effectiveImage = attachVision ? (image ?? visionContext) : image
        // 发送后立即进入思考态，首个流式片段到达后再切播报
        AgentDisplayHub.shared.show(.thinking)
        isSending = true
        pendingResponse = ""
        activeTool = nil
        startThinkingHint()

        if let customConfig {
            // 多轮上下文：当前用户消息已入 messages，历史取之前的文本轮次（图片/空文本不入历史）
            let history = messages.dropLast().compactMap { message -> CustomChatTurn? in
                guard message.image == nil else { return nil }
                let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return CustomChatTurn(role: message.role, text: content)
            }
            let systemPrompt = AgentSystemPromptBuilder.build()
            let toolExecutor: (CustomToolCall) async -> String = { call in
                let result = await CustomAgentLocalTools.execute(
                    call,
                    context: CustomAgentToolContext(
                        captureVision: { await self.captureFrameForAgent() },
                        latestFrame: { self.visionContext }
                    )
                )
                // 工具执行结果上镜片（打断期间不打扰）
                if !result.isEmpty, turnMachine.phase != .interrupted {
                    AgentDisplayHub.shared.showResult(
                        title: "custom.agent.tool.result.title".localized,
                        text: result,
                        fallback: .thinking
                    )
                }
                return result
            }
            let onDelta: (String) -> Void = { delta in
                cancelThinkingHint()
                turnMachine.outputStarted()
                AgentDisplayHub.shared.show(.speaking)
                pendingResponse += delta
            }
            let onTool: (String) -> Void = { tool in
                activeTool = tool
                AgentDisplayHub.shared.showTaskProgress(count: 1, title: "agent.thinking.tool".localized(tool))
            }
            let onComplete: (String) -> Void = { finalText in
                cancelThinkingHint()
                AgentDisplayHub.shared.clearTaskProgress()
                turnMachine.outputEnded()
                if turnMachine.phase != .interrupted {
                    AgentDisplayHub.shared.show(.listening)
                }
                isSending = false
                activeTool = nil
                if !finalText.isEmpty {
                    pendingResponse = finalText
                }
                flushPendingResponse()
                speakAssistantReply(finalText)
            }
            let onError: (String) -> Void = { error in
                cancelThinkingHint()
                AgentDisplayHub.shared.clearTaskProgress()
                isSending = false
                activeTool = nil
                flushPendingResponse()
                messages.append(AgentChatMessage(role: "assistant", text: error, image: nil))
            }
            if customConfig.transport == .websocket {
                CustomWebSocketAgentService.shared.sendMessage(
                    config: customConfig,
                    text: text,
                    image: effectiveImage,
                    history: history,
                    systemPrompt: systemPrompt,
                    toolExecutor: toolExecutor,
                    onDelta: onDelta,
                    onTool: onTool,
                    onComplete: onComplete,
                    onError: onError
                )
            } else {
                CustomAgentService.shared.sendMessage(
                    config: customConfig,
                    text: text,
                    image: effectiveImage,
                    history: history,
                    systemPrompt: systemPrompt,
                    toolExecutor: toolExecutor,
                    onDelta: onDelta,
                    onTool: onTool,
                    onComplete: onComplete,
                    onError: onError
                )
            }
            return
        }

        switch kind {
        case .openclaw:
            openClawService.sendChatMessage(text, image: effectiveImage)

        case .hermes:
            hermesService.sendMessage(
                text,
                image: effectiveImage,
                instructions: AgentSystemPromptBuilder.build(),
                onDelta: { delta in
                    cancelThinkingHint()
                    turnMachine.outputStarted()
                    AgentDisplayHub.shared.show(.speaking)
                    pendingResponse += delta
                },
                onTool: { tool in
                    activeTool = tool
                    AgentDisplayHub.shared.showTaskProgress(count: 1, title: "agent.thinking.tool".localized(tool))
                },
                onToolResult: { callID, output in
                    // 服务端已执行的工具结果：上镜片展示（对齐自定义 Agent 分支）
                    if !output.isEmpty, turnMachine.phase != .interrupted {
                        AgentDisplayHub.shared.showResult(
                            title: "custom.agent.tool.result.title".localized,
                            text: String(output.prefix(200)),
                            fallback: .speaking
                        )
                    }
                },
                onComplete: { finalText in
                    cancelThinkingHint()
                    AgentDisplayHub.shared.clearTaskProgress()
                    turnMachine.outputEnded()
                    if turnMachine.phase != .interrupted {
                        AgentDisplayHub.shared.show(.listening)
                    }
                    isSending = false
                    activeTool = nil
                    if !finalText.isEmpty {
                        pendingResponse = finalText
                    }
                    flushPendingResponse()
                    speakAssistantReply(finalText)
                },
                onError: { error in
                    cancelThinkingHint()
                    AgentDisplayHub.shared.clearTaskProgress()
                    isSending = false
                    activeTool = nil
                    flushPendingResponse()
                    messages.append(AgentChatMessage(role: "assistant", text: error, image: nil))
                }
            )
        }
    }

    private func flushPendingResponse() {
        if !pendingResponse.isEmpty {
            messages.append(AgentChatMessage(role: "assistant", text: pendingResponse, image: nil))
            pendingResponse = ""
        }
    }

    // MARK: - 眼镜物理触发（镜腿单击/长按）

    private func handleDeviceTrigger(_ trigger: AgentDeviceTrigger) {
        AgentTriggerFeedback.play(for: trigger)
        switch turnMachine.handle(trigger: trigger) {
        case .wake:
            showTextInput = true
            AgentDisplayHub.shared.show(.listening)
            showTriggerBanner("agent.trigger.woke".localized)
        case .interrupt:
            interruptCurrentTurn()
            AgentDisplayHub.shared.show(.interrupted)
            showTriggerBanner("agent.trigger.interrupted".localized)
        case .resume:
            AgentDisplayHub.shared.show(.listening)
            showTriggerBanner("agent.trigger.resumed".localized)
        case .endTurn:
            interruptCurrentTurn()
            showIdleMenu()
            showTriggerBanner("agent.trigger.ended".localized)
        case .none:
            break
        }
    }

    // MARK: - 眼镜端动作菜单

    private func showIdleMenu() {
        Task { @MainActor in
            async let upcomingEventsTask = AgentCalendarDisplayMapping.upcomingEventsForMenu(
                provider: AgentCalendar.provider
            )
            async let upcomingTomorrowTask = AgentCalendarDisplayMapping.tomorrowEventsForMenu(
                provider: AgentCalendar.provider
            )
            let upcomingEvents = await upcomingEventsTask
            let upcomingTomorrowEvents = await upcomingTomorrowTask
            AgentDisplayHub.shared.showMenu(
                actions: AgentDisplayMenuMapping.actions(
                    for: .chat,
                    hasActiveTasks: QwenVoiceSession.shared.runningTaskCount > 0,
                    hasTodayOverview: !upcomingEvents.isEmpty
                        || AgentReminderDisplayMapping.hasActiveReminders(
                            AgentReminderStore.reminders
                        )
                        || QwenVoiceSession.shared.runningTaskCount > 0,
                    hasTomorrowOverview: !upcomingTomorrowEvents.isEmpty,
                    hasFollowUpContext: QwenVoiceSession.shared.hasFollowUpContext,
                    hasActiveReminders: AgentReminderDisplayMapping.hasActiveReminders(
                        AgentReminderStore.reminders
                    ),
                    hasUpcomingCalendarEvents: !upcomingEvents.isEmpty,
                    hasAgentPrefs: AgentPrefsDisplayMapping.hasPrefs(),
                    hasNamedLists: AgentListDisplayMapping.hasLists()
                ),
                onSelect: { [self] action in handleMenuAction(action) }
            )
        }
    }

    /// 镜片「Today」总览：下一场日程 + 提醒 + 进行中任务一键播报（JARVIS 状态汇报）
    private func showTodayOverview() {
        Task { @MainActor in
            let events = await AgentCalendarDisplayMapping.upcomingEventsForMenu(
                provider: AgentCalendar.provider
            )
            let content = AgentTodayOverviewBuilder.content(
                events: events,
                reminders: AgentReminderStore.reminders,
                taskTitles: QwenVoiceSession.shared.activeTasks
                    .filter { $0.status == .running || $0.status == .waiting }
                    .map(\.title),
                now: Date()
            )
            let text = content.fullText
            AgentDisplayHub.shared.showResult(
                title: AgentDisplayMenuMapping.title(for: .todayOverview),
                text: text,
                fallback: .idle
            )
            speakAssistantReply(text)
            showTriggerBanner(text)
        }
    }

    /// 镜片「Tomorrow」总览：明天下一场日程 + 场次数一键播报（JARVIS 明日汇报）
    private func showTomorrowOverview() {
        Task { @MainActor in
            let events = await AgentCalendarDisplayMapping.tomorrowEventsForMenu(
                provider: AgentCalendar.provider
            )
            let content = AgentTomorrowOverviewBuilder.content(
                events: events,
                now: Date()
            )
            let text = content.fullText
            AgentDisplayHub.shared.showResult(
                title: AgentDisplayMenuMapping.title(for: .tomorrowOverview),
                text: text,
                fallback: .idle
            )
            speakAssistantReply(text)
            showTriggerBanner(text)
        }
    }

    /// 任务中心子菜单：进度播报 / 取消 / 重试失败任务 / 返回主菜单
    private func showTaskMenu() {
        AgentDisplayHub.shared.showMenu(
            actions: AgentDisplayMenuMapping.actions(
                for: .taskCenter,
                hasFailedTasks: QwenVoiceSession.shared.failedTasks.count > 0
            ),
            onSelect: { [self] action in handleMenuAction(action) }
        )
    }

    private func handleMenuAction(_ action: AgentDisplayAction) {
        switch action {
        case .wake:
            showTextInput = true
            AgentDisplayHub.shared.show(.listening)
            showTriggerBanner("agent.trigger.woke".localized)
        case .repeatLastReply:
            if let last = messages.last(where: { $0.role == "assistant" }) {
                speakAssistantReply(last.text)
            } else {
                showTriggerBanner("agent.menu.repeat.empty".localized)
            }
            AgentDisplayHub.shared.show(.idle)
        case .followUp:
            requestLensFollowUp()
        case .reminders:
            showRemindersMenu()
        case .calendar:
            showCalendarMenu()
        case .prefs:
            showPrefsMenu()
        case .lists:
            showListsMenu()
        case .audit:
            showLatestAudit()
        case .newChat:
            startNewChat()
            showIdleMenu()
        case .shortcuts:
            showShortcutsMenu()
        case .todayOverview:
            showTodayOverview()
        case .tomorrowOverview:
            showTomorrowOverview()
        case .announceTasks:
            showTaskMenu()
        case .taskProgress:
            presentTaskProgressFromMenu()
        case .cancelLatestTask:
            presentTaskCancellationFromMenu()
        case .retryLatestTask:
            presentTaskRetryFromMenu()
        case .backToMainMenu:
            showIdleMenu()
        case .captureVision:
            Task { await snapAndSend() }
        case .ocr:
            Task { await runOCR(autoplaySpeech: true) }
        case .translate:
            requestTranslateFromMenu()
        case .scene:
            Task { await runScene(autoplaySpeech: true) }
        case .home:
            Task { @MainActor in
                let state = await AgentDisplayHomeLoader.state()
                AgentDisplayHub.shared.showHome(state: state) { [self] action in
                    handleMenuAction(action)
                }
            }
            showTriggerBanner("agent.display.hub.home.detail".localized)
        case .dismiss:
            AgentDisplayHub.shared.show(.idle)
        }
    }

    /// 眼镜菜单「Audit」：展示最近一条审计记录（4 秒后回退到空闲状态）
    private func showLatestAudit() {
        guard let entry = AgentAuditStore.entries.first else {
            AgentDisplayHub.shared.showResult(
                title: "Audit",
                text: "agent.audit.empty".localized,
                fallback: .idle
            )
            return
        }
        let content = AgentAuditDisplayMapping.resultContent(for: entry)
        AgentDisplayHub.shared.showResult(
            title: content.title,
            text: content.text,
            fallback: .idle
        )
    }

    /// 眼镜菜单「Ask」：对最新任务结果发起追问（结果上下文随追问文本一起发送）
    private func requestLensFollowUp() {
        guard QwenVoiceSession.shared.hasFollowUpContext else {
            AgentDisplayHub.shared.showResult(
                title: "Ask",
                text: "agent.menu.followup.empty".localized,
                fallback: .idle
            )
            return
        }
        inputText = QwenVoiceSession.shared.followUpMessage(
            "agent.menu.followup.prompt".localized
        )
        sendText()
        showTriggerBanner("agent.menu.followup.done".localized)
    }

    /// 任务卡长按「在聊天中追问」：就地载入该任务结果上下文（当前已是聊天页）
    private func startTaskFollowUpInChat(_ task: QwenAgentTask) {
        guard let result = task.resultText else { return }
        armTaskFollowUp(with: result)
    }

    /// 载入任务结果追问上下文：注入共享会话（语音/菜单追问共用）+ 武装一次性包装门 + 提示
    private func armTaskFollowUp(with result: String) {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        QwenVoiceSession.shared.restoreFollowUpContext(trimmed)
        followUpWrapGate = TaskFollowUpWrapGate(armed: true)
        showTriggerBanner("agent.task.followup.contextLoaded".localized)
    }

    /// 任务结果追问包装：打开聊天页后第一条用户消息自动携带结果上下文（一次性），随后透传
    private func applyTaskFollowUpWrapIfNeeded(_ text: String) -> String {
        guard followUpWrapGate.consumeIfArmed() else { return text }
        return QwenVoiceSession.shared.followUpMessage(text)
    }

    /// 眼镜菜单「Reminders」：列出即将触发的本地提醒，选中后播报
    private func showRemindersMenu() {
        let reminders = AgentReminderDisplayMapping.upcoming(AgentReminderStore.reminders)
        guard !reminders.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Reminders",
                text: "agent.reminder.lens.empty".localized,
                fallback: .idle
            )
            return
        }
        AgentDisplayHub.shared.showReminderListMenu(
            reminders: reminders,
            onSelect: { [self] reminder in speakReminder(reminder) },
            onBack: { [self] in showIdleMenu() }
        )
    }

    /// 播报一条提醒：镜片结果卡 + TTS + 手机横幅；
    /// 随后镜片显示「Done / Delete / Cancel」操作卡，点按直接完成 / 删除并追加本地回复
    private func speakReminder(_ reminder: AgentReminder) {
        let text = AgentReminderDisplayMapping.resultText(for: reminder)
        AgentDisplayHub.shared.showResult(
            title: "Reminder",
            text: text,
            fallback: .idle
        )
        speakAssistantReply(text)
        showTriggerBanner(text)
        AgentDisplayHub.shared.showChoice(
            options: [
                AgentDisplayChoiceMapping.completeLabel(),
                AgentDisplayChoiceMapping.deleteLabel(),
            ],
            iconName: "bell",
            onSelect: { [self] index in
                switch index {
                case 0:
                    guard let announcement = AgentReminderLensAction.complete(reminder) else { return }
                    appendLocalReply(announcement)
                case 1:
                    guard let announcement = AgentReminderLensAction.delete(reminder) else { return }
                    appendLocalReply(announcement)
                default:
                    break
                }
            },
            onCancel: { [self] in showIdleMenu() }
        )
    }

    /// 眼镜菜单「Calendar」：列出今天未结束的日程，选中后播报
    private func showCalendarMenu() {
        Task { @MainActor in
            guard let events = await AgentCalendarDisplayMapping.todayEvents(
                provider: AgentCalendar.provider
            ) else {
                AgentDisplayHub.shared.showResult(
                    title: "Calendar",
                    text: "agent.calendar.denied".localized,
                    fallback: .idle
                )
                return
            }
            guard !events.isEmpty else {
                AgentDisplayHub.shared.showResult(
                    title: "Calendar",
                    text: String(
                        format: "agent.calendar.query.empty".localized,
                        "agent.calendar.range.today".localized
                    ),
                    fallback: .idle
                )
                return
            }
            AgentDisplayHub.shared.showCalendarListMenu(
                events: events,
                onSelect: { [self] event in speakCalendarEvent(event) },
                onBack: { [self] in showIdleMenu() }
            )
        }
    }

    /// 播报一条日程：镜片结果卡 + TTS + 手机横幅（复用语音查询的单条日程行文案）；
    /// 随后镜片显示「Delete / Cancel」确认卡，点 Delete 直接删除并播报结果
    private func speakCalendarEvent(_ event: AgentCalendarEvent) {
        let text = AgentCalendarDisplayMapping.resultText(for: event)
        AgentDisplayHub.shared.showResult(
            title: "Calendar",
            text: text,
            fallback: .idle
        )
        speakAssistantReply(text)
        showTriggerBanner(text)
        AgentDisplayHub.shared.showChoice(
            options: [AgentDisplayChoiceMapping.deleteLabel()],
            onSelect: { [self] _ in
                Task { @MainActor in
                    let deleted = await AgentCalendarDetailDeleteAction.performDelete(
                        event: event,
                        provider: AgentCalendar.provider
                    )
                    let text = deleted
                        ? AgentCalendarDetailDeleteAction.deletedText(for: event, now: Date())
                        : AgentCalendarDetailDeleteAction.failureMessage()
                    appendLocalReply(text)
                }
            },
            onCancel: { [self] in showIdleMenu() }
        )
    }

    /// 眼镜菜单「Prefs」：列出长期记忆与个性化规则（混合，按最近更新排序），选中后播报
    private func showPrefsMenu() {
        let items = AgentPrefsDisplayMapping.recentItems()
        guard !items.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Prefs",
                text: "agent.prefs.lens.empty".localized,
                fallback: .idle
            )
            return
        }
        AgentDisplayHub.shared.showPrefsMenu(
            items: items,
            onSelect: { [self] item in speakPrefItem(item) },
            onBack: { [self] in showIdleMenu() }
        )
    }

    /// 播报一条记忆/规则：镜片结果卡 + TTS + 手机横幅
    private func speakPrefItem(_ item: AgentPrefsDisplayMapping.Item) {
        let text = AgentPrefsDisplayMapping.resultText(for: item)
        AgentDisplayHub.shared.showResult(
            title: item.kind == .memory ? "Memory" : "Rule",
            text: text,
            fallback: .idle
        )
        speakAssistantReply(text)
        showTriggerBanner(text)
    }

    /// 眼镜菜单「Lists」：列出用户命名清单（购物单 / 待办），选中后播报内容
    private func showListsMenu() {
        let lists = AgentListDisplayMapping.recentLists()
        guard !lists.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Lists",
                text: "agent.lists.lens.empty".localized,
                fallback: .idle
            )
            return
        }
        AgentDisplayHub.shared.showListMenu(
            lists: lists,
            onSelect: { [self] list in speakList(list) },
            onBack: { [self] in showIdleMenu() }
        )
    }

    /// 播报一个清单：镜片结果卡 + TTS + 手机横幅
    private func speakList(_ list: AgentNamedList) {
        if AgentListDisplayMapping.shouldShowItemMenu(for: list) {
            AgentDisplayHub.shared.showListItemsMenu(
                items: AgentListDisplayMapping.items(for: list),
                onSelect: { [self] index in speakListItem(list, index: index) },
                onBack: { [self] in showListsMenu() }
            )
            return
        }
        let text = AgentListDisplayMapping.resultText(for: list)
        AgentDisplayHub.shared.showResult(
            title: "List",
            text: text,
            fallback: .idle
        )
        speakAssistantReply(text)
        showTriggerBanner(text)
    }

    /// 播报清单单条：镜片结果卡 + TTS + 手机横幅（带序号）
    private func speakListItem(_ list: AgentNamedList, index: Int) {
        let items = AgentListDisplayMapping.items(for: list)
        guard index >= 0, index < items.count else { return }
        let text = AgentListDisplayMapping.itemResultText(for: items[index], index: index, in: list)
        AgentDisplayHub.shared.showResult(
            title: "List",
            text: text,
            fallback: .idle
        )
        speakAssistantReply(text)
        showTriggerBanner(text)
    }

    /// 快捷指令子菜单：列出用户配置的常用指令，一键触发
    private func showShortcutsMenu() {
        let shortcuts = AgentShortcutStore.shortcuts
        guard !shortcuts.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Shortcuts",
                text: "agent.shortcuts.empty".localized,
                fallback: .idle
            )
            return
        }
        AgentDisplayHub.shared.showShortcutsMenu(
            shortcuts: shortcuts,
            onSelect: { [self] shortcut in runShortcut(shortcut) },
            onBack: { [self] in showIdleMenu() }
        )
    }

    /// 执行快捷指令：把配置的指令文本作为用户消息发送
    private func runShortcut(_ shortcut: AgentShortcut) {
        let prompt = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        messages.append(AgentChatMessage(role: "user", text: prompt, image: nil))
        flushPendingResponse()
        send(text: prompt, image: nil)
        showTriggerBanner("agent.shortcuts.triggered".localized)
    }

    /// 任务中心「Cancel」：请求取消最近的活动任务并语音确认
    /// 镜片任务中心「Cancel」：单个活动任务直接取消；多个弹出编号选择卡（选择后按序号取消）。
    private func presentTaskCancellationFromMenu() {
        let tasks = QwenVoiceSession.shared.activeTasks
        switch AgentTaskChoiceFlow.presentation(taskCount: tasks.count) {
        case .none:
            showIdleMenu()
        case .direct:
            cancelTaskFromMenu(index: nil)
        case .choose:
            AgentDisplayHub.shared.showChoice(
                options: AgentTaskChoiceFlow.optionLabels(from: tasks),
                iconName: "x",
                onSelect: { [self] index in
                    cancelTaskFromMenu(index: index)
                },
                onCancel: { [self] in
                    showIdleMenu()
                }
            )
        }
    }

    private func cancelTaskFromMenu(index: Int? = nil) {
        let session = QwenVoiceSession.shared
        let name: String?
        if let index {
            name = session.requestTaskCancellation(index: index)
        } else {
            name = session.requestTaskCancellation()
        }
        guard let name else {
            showIdleMenu()
            return
        }
        let reply = "agent.task.command.cancel.reply".localized(name)
        TTSService.shared.stop()
        TTSService.shared.speak(reply)
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .progress),
            text: reply,
            fallback: .idle
        )
        showTriggerBanner("agent.task.command.cancel.banner".localized)
        showIdleMenu()
    }

    /// 眼镜菜单「Task」：播报后台任务进度（有活动任务时菜单项才出现）
    /// 镜片任务中心「Progress」：单个活动任务直接播报；多个弹出编号选择卡（选择后播报该任务进度）。
    private func presentTaskProgressFromMenu() {
        let tasks = QwenVoiceSession.shared.activeTasks
        switch AgentTaskChoiceFlow.presentation(taskCount: tasks.count) {
        case .none:
            showIdleMenu()
        case .direct:
            announceTaskProgress()
        case .choose:
            AgentDisplayHub.shared.showChoice(
                options: AgentTaskChoiceFlow.optionLabels(from: tasks),
                iconName: "gear",
                onSelect: { [self] index in
                    announceTaskProgress(index: index)
                },
                onCancel: { [self] in
                    showIdleMenu()
                }
            )
        }
    }

    private func announceTaskProgress(index: Int? = nil) {
        let session = QwenVoiceSession.shared
        let summary: String?
        if let index {
            summary = session.taskProgressSummary(for: index)
        } else {
            summary = session.taskProgressSummary
        }
        guard let summary else {
            showIdleMenu()
            return
        }
        TTSService.shared.stop()
        TTSService.shared.speak(summary)
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .progress),
            text: summary,
            fallback: .idle
        )
        showTriggerBanner("agent.task.command.progress.banner".localized)
        showIdleMenu()
    }

    /// 镜片任务中心「Retry」：单个失败任务直接重试；多个弹出编号选择卡（选择后按序号重试）。
    private func presentTaskRetryFromMenu() {
        let session = QwenVoiceSession.shared
        let tasks = session.failedTasks
        switch AgentTaskChoiceFlow.presentation(taskCount: tasks.count) {
        case .none:
            showIdleMenu()
        case .direct:
            retryTaskFromMenu(index: nil)
        case .choose:
            AgentDisplayHub.shared.showChoice(
                options: AgentTaskChoiceFlow.optionLabels(from: tasks),
                iconName: "two_arrows_clockwise",
                onSelect: { [self] index in
                    retryTaskFromMenu(index: index)
                },
                onCancel: { [self] in
                    showIdleMenu()
                }
            )
        }
    }

    private func retryTaskFromMenu(index: Int? = nil) {
        let session = QwenVoiceSession.shared
        let name: String?
        if let index {
            name = session.requestTaskRetry(index: index)
        } else {
            name = session.requestTaskRetry()
        }
        guard let name else {
            showIdleMenu()
            return
        }
        let reply = "agent.task.command.retry.reply".localized(name)
        TTSService.shared.stop()
        TTSService.shared.speak(reply)
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .progress),
            text: reply,
            fallback: .idle
        )
        showTriggerBanner("agent.task.command.retry.banner".localized)
        showIdleMenu()
    }

    private func interruptCurrentTurn() {
        cancelThinkingHint()
        AgentDisplayHub.shared.clearTaskProgress()
        stopListening()
        TTSService.shared.stop()
        if customConfig != nil {
            CustomAgentService.shared.cancel()
        } else if kind == .hermes {
            hermesService.cancel()
        }
        isSending = false
        activeTool = nil
        flushPendingResponse()
    }

    /// 思考超时安抚：发送后 X 秒仍无流式输出时语音/横幅提示（设置可调）
    private func startThinkingHint() {
        thinkingHintTask?.cancel()
        thinkingHintTask = Task { @MainActor in
            let delay = AgentTimingSettings.thinkingHintDelay
            guard delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard isSending, pendingResponse.isEmpty,
                  turnMachine.phase != .interrupted else { return }
            let hint: String
            if let tool = activeTool, !tool.isEmpty {
                hint = "agent.thinking.tool".localized(tool)
            } else {
                hint = "agent.thinking.hint".localized
            }
            if AgentVoiceSettings.replyEnabled {
                TTSService.shared.speak(hint)
            }
            showTriggerBanner(hint)
        }
    }

    private func cancelThinkingHint() {
        thinkingHintTask?.cancel()
        thinkingHintTask = nil
    }

    private func showTriggerBanner(_ text: String) {
        triggerBanner = text
        bannerDismissTask?.cancel()
        bannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            triggerBanner = nil
        }
    }

    private func speakAssistantReply(_ text: String) {
        guard voiceReplyEnabled, !text.isEmpty else { return }
        // TTS 服务对单次合成文本有长度上限，超长时截断播报
        let maxLength = 300
        let ttsText = text.count > maxLength
            ? String(text.prefix(maxLength)) + "…"
            : text
        TTSService.shared.speak(ttsText)
    }

    /// 点击任务卡片重听该任务的结果（优先详细结果，其次标题）
    private func replayChatTask(_ task: QwenAgentTask) {
        guard !task.isActive, !TTSService.shared.isSpeaking else { return }
        let text: String
        if let result = task.resultText, !result.isEmpty {
            text = result
        } else if !task.title.isEmpty {
            text = task.title
        } else {
            return
        }
        TTSService.shared.stop()
        TTSService.shared.speak(text)
        showTriggerBanner("agent.task.replay.done".localized)
    }

    /// 把语音会话期间的转写回填到聊天记录（两种模式共享上下文）
    private func importVoiceTranscripts() {
        let session = QwenVoiceSession.shared
        let importer = AgentTranscriptImport(
            transcriptLog: session.transcriptLog,
            taskFeed: session.taskFeed
        )
        guard importer.hasContent else { return }
        for item in importer.makeMessages() {
            messages.append(AgentChatMessage(role: item.role, text: item.text, image: nil))
        }
        session.clearTranscriptLog()
        session.clearTaskFeed()
        persistConversationIfNeeded()
    }

    /// 把本次聊天落盘到「记录」（有新增消息时保存，避免重复）
    private func persistConversationIfNeeded() {
        guard messages.count > lastPersistedMessageCount else { return }
        lastPersistedMessageCount = messages.count
        guard let record = AgentConversationPersister.makeRecord(
            messages: messages,
            agentName: agentName,
            recordID: persistedRecordID
        ) else { return }
        ConversationStorage.shared.saveConversation(record)
        persistedRecordID = record.id
    }

    /// 新建对话：清空本地聊天并切换服务端会话（历史保留在「记录」）
    private func startNewChat() {
        interruptCurrentTurn()
        messages = []
        visionContext = nil
        pendingResponse = ""
        lastPersistedMessageCount = 0
        persistedRecordID = nil
        restoredFromHistory = false
        // 自定义 Agent 无服务端会话，仅重置本地上下文
        guard customConfig == nil else { return }
        switch kind {
        case .openclaw:
            openClawService.startNewChat()
        case .hermes:
            hermesService.startNewConversation()
        }
    }

    /// 取消当前流式输出（自定义 Agent / Hermes 共用）
    private func cancelActiveStream() {
        if let customConfig {
            if customConfig.transport == .websocket {
                CustomWebSocketAgentService.shared.cancel()
            } else {
                CustomAgentService.shared.cancel()
            }
        } else if kind == .hermes {
            hermesService.cancel()
        }
    }

    /// 清除视野上下文（后续追问不再自动携带）
    private func clearVisionContext() {
        guard visionContext != nil else { return }
        visionContext = nil
        showTriggerBanner("agent.vision.context.cleared".localized)
    }
}
/// 记忆 / 规则指令的本地回复（纯构造，可测；与语音页共用话术）。
private extension AgentMemoryCommand {
    func replyText() -> String {
        switch self {
        case .remember(let text):
            let saved = AgentMemoryStore.add(text: text)
            return saved
                ? AgentProfileCommandReply.memoryRemembered(text: text)
                : AgentProfileCommandReply.memoryDuplicate()
        case .query:
            return AgentProfileCommandReply.memoryQuery(
                entries: AgentMemoryStore.entries.map(\.text)
            )
        case .forget(let text):
            let removed = AgentMemoryStore.remove(matching: text)
            return removed
                ? AgentProfileCommandReply.memoryForgot(text: text)
                : AgentProfileCommandReply.memoryForgetMissing()
        }
    }
}

private extension AgentRuleCommand {
    func replyText() -> String {
        switch self {
        case .add(let text):
            if AgentRuleStore.add(text: text) {
                return AgentProfileCommandReply.ruleAdded(text: text)
            } else if AgentRuleStore.entries.contains(where: { $0.text == text }) {
                return AgentProfileCommandReply.ruleDuplicate(text: text)
            }
            return AgentProfileCommandReply.ruleFull()
        case .query:
            return AgentProfileCommandReply.ruleQuery(
                entries: AgentRuleStore.entries.map(\.text)
            )
        case .remove(let text):
            let removed = AgentRuleStore.remove(text: text)
            return removed
                ? AgentProfileCommandReply.ruleRemoved(text: text)
                : AgentProfileCommandReply.ruleRemoveMissing()
        case .clear:
            AgentRuleStore.clear()
            return AgentProfileCommandReply.ruleCleared()
        }
    }
}



/// 端侧翻译（Apple Translation，iOS 18+，离线可用）：一键翻译 OCR 识别文字并朗读译文
@available(iOS 18.0, *)
struct OnDeviceTranslationView: View {
    let text: String

    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText: String?
    @State private var isTranslating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    isTranslating = true
                    errorMessage = nil
                    configuration = TranslationSession.Configuration(
                        source: nil,
                        target: VisionTranslationPlanner.targetLanguage(for: text)
                    )
                } label: {
                    Label(
                        isTranslating
                            ? "agent.vision.ocr.translating".localized
                            : "agent.vision.ocr.translate".localized,
                        systemImage: "character.bubble"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isTranslating || translatedText != nil || errorMessage != nil)
                Spacer()
                if translatedText != nil {
                    Text("agent.vision.ocr.translated".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.teal)
                }
            }
            if let translatedText {
                HStack(alignment: .top, spacing: 8) {
                    Text(translatedText)
                        .font(.system(size: 15))
                        .foregroundColor(.teal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        TTSService.shared.stop()
                        TTSService.shared.speak(translatedText)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 15))
                    }
                }
                .padding(10)
                .background(Color.teal.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .translationTask(configuration) { session in
            guard let configuration else { return }
            do {
                let response = try await session.translate(text)
                translatedText = response.targetText
            } catch {
                errorMessage = "agent.vision.ocr.translate.failed".localized(
                    error.localizedDescription
                )
            }
            isTranslating = false
        }
    }
}

#if DEBUG
@MainActor
private struct AgentChatPreview: View {
    @StateObject private var dependencies = PreviewDependencies()

    var body: some View {
        AgentChatView(kind: .hermes, streamViewModel: dependencies.streamViewModel)
    }
}

#Preview("Agent Chat") {
    AgentChatPreview()
}
#endif

// MARK: - Chat Bubble

private struct AgentChatBubble: View {
    let message: AgentChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: 200, maxHeight: 150)
                        .cornerRadius(12)
                        .clipped()
                }

                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundColor(message.role == "user" ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == "user"
                            ? AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color(.systemGray5))
                    )
                    .cornerRadius(18)
            }

            if message.role == "assistant" { Spacer(minLength: 60) }
        }
    }
}
