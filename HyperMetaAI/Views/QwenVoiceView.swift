/*
 * Qwen Voice View
 * 实时语音会话页：连接 qwen-audio-agent 网关，全双工语音对话，
 * 支持镜腿单击打断 / 长按结束。
 */

import SwiftUI
import PhotosUI
import AVFoundation

struct QwenVoiceView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    private let wearablesViewModel: WearablesViewModel?
    @ObservedObject private var session = QwenVoiceSession.shared
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @ObservedObject private var ttsService = TTSService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// 从 AgentChat 聊天页进入时为 true：转写由聊天页回填并持久化，本页不重复保存
    let isEmbeddedInChat: Bool
    /// 从 Hub Recent 进入时指定的历史会话 ID（优先恢复该会话）
    private let initialHistoryRecordID: UUID?
    /// Siri / 快捷指令指定的大脑（仅本次会话生效，不覆盖用户保存的选择）
    private let initialBrain: AgentBrain?
    /// Siri / 快捷指令携带的直接指令，会话就绪后立即发送
    private let initialInstruction: String?
    /// 任务结果「追问」上下文（通知 / 锁屏结果卡深链带入，会话启动后注入）
    private let initialFollowUpContext: String?
    /// 主启动路径使用单一 Metal 光球；旧的 Hub/聊天入口仍可复用详细会话界面。
    private let isPrimaryExperience: Bool
    /// 系统快捷入口可要求光球页出现后立即进入全双工会话。
    private let startImmediately: Bool

    init(
        streamViewModel: StreamSessionViewModel,
        wearablesViewModel: WearablesViewModel? = nil,
        isEmbeddedInChat: Bool = false,
        initialHistoryRecordID: UUID? = nil,
        initialBrain: AgentBrain? = nil,
        initialInstruction: String? = nil,
        initialFollowUpContext: String? = nil,
        isPrimaryExperience: Bool = false,
        startImmediately: Bool = false
    ) {
        self.streamViewModel = streamViewModel
        self.wearablesViewModel = wearablesViewModel
        self.isEmbeddedInChat = isEmbeddedInChat
        self.initialHistoryRecordID = initialHistoryRecordID
        self.initialBrain = initialBrain
        self.initialInstruction = initialInstruction
        self.initialFollowUpContext = initialFollowUpContext
        self.isPrimaryExperience = isPrimaryExperience
        self.startImmediately = startImmediately
        _brain = State(initialValue: initialBrain ?? AgentBrainSettings.selected)
    }

    @State private var triggerBanner: String?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var showGatewayConfig = false
    @State private var isCapturingVision = false
    @State private var isOCRing = false
    @State private var isAnalyzingScene = false
    @State private var lastVisionImage: UIImage?
    /// 无眼镜画面帧时回退到相册选图（模拟器 / 无眼镜场景的稳定路径）
    @State private var showVoiceFallbackPhotoPicker = false
    @State private var voiceFallbackPhotoItem: PhotosPickerItem?
    @State private var voiceFallbackAction: VoiceFallbackVisionAction = .ocr

    /// 任务卡「在聊天中追问」：打开聊天页并载入该任务结果上下文
    @State private var showTaskChatFollowUp = false
    @State private var taskChatFollowUpResult = ""

    /// 回退选图后要执行的端侧视觉动作
    private enum VoiceFallbackVisionAction {
        case ocr
        case scene
    }
    /// 新手引导（首次进入语音页提示镜腿手势，看过一次后不再显示）
    @State private var showVoiceOnboarding = !AgentOnboardingSettings.voiceHintSeen
    /// thinking 超时提示任务（8 秒无回复时语音/横幅提示）
    @State private var thinkingHintTask: Task<Void, Never>?
    /// 打断期间大脑回复迟到到达：只入历史不播报，恢复时提示可重听
    @State private var droppedReplyWhileInterrupted = false
    /// Hermes 正在执行的工具名（用于眼镜任务显示与超时提示）
    @State private var hermesTool: String?
    /// 恢复的上次语音会话（仅显示层，不混入本次转写）
    @State private var restoredHistory: [QwenTranscriptItem] = []
    /// 可选的历史会话记录（qwen-audio-agent，最新在前）
    @State private var historyRecords: [ConversationRecord] = []
    /// 选中的历史会话 ID；nil 表示最新一条
    @State private var selectedHistoryRecordID: UUID?
    /// 统一回合状态机：镜腿触发语义 + 眼镜端状态显示
    @State private var turnMachine = AgentTurnStateMachine()
    /// 大脑模式：Qwen 原生实时语音 / 听写转发给 Hermes / OpenClaw
    @State private var brain = AgentBrainSettings.selected
    /// 大脑回复流式文本（live 预览）
    @State private var brainLiveText = ""
    /// 已转发的最后一条用户文本（防重复转发）
    @State private var lastForwardedUserText = ""
    /// 审批决策成功后的镜片反馈（在 pendingPermission 清空时展示一次）
    @State private var pendingApprovalFeedback: (title: String, text: String)?
    /// 会话忙碌时暂缓弹出的审批请求（空闲后由 reevaluateDeferredApproval 弹出）
    @State private var deferredApproval: QwenPermissionRequest?
    @State private var showSimplifiedSettings = false
    @State private var showTaskDetails = false
    @State private var primaryFeedback: String?

    @ViewBuilder
    var body: some View {
        if isPrimaryExperience {
            voiceTaskObservations(
                voiceTurnObservations(
                    voiceDeviceObservations(
                        voiceLifecycle(
                            voicePresentation(primaryOrbExperience)
                        )
                    )
                )
            )
        } else {
            voiceTaskObservations(
                voiceTurnObservations(
                    voiceDeviceObservations(
                        voiceLifecycle(
                            voicePresentation(
                            NavigationView {
                                VStack(spacing: 16) {
                // 新手引导：镜腿手势映射
                if showVoiceOnboarding {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("agent.onboarding.voice.title".localized)
                                .font(.system(size: 13, weight: .semibold))
                            Text("agent.onboarding.voice.body".localized)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            AgentOnboardingSettings.voiceHintSeen = true
                            withAnimation { showVoiceOnboarding = false }
                        } label: {
                            Text("agent.onboarding.voice.dismiss".localized)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(10)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 连接状态
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(connectionStateText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if turnMachine.phase == .thinking {
                        Text("qwen.voice.thinking".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    } else if ttsService.isSpeaking {
                        Text("qwen.voice.speaking".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                    if let attempt = session.reconnectAttempt {
                        Text(String(
                            format: "qwen.voice.reconnecting".localized,
                            attempt,
                            session.reconnectMaxAttempts
                        ))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    }
                    if session.runningTaskCount > 0 {
                        Text(String(format: "qwen.voice.tasks.running".localized, session.runningTaskCount))
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                    Button {
                        showGatewayConfig = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)

                // 大脑选择（Qwen 原生 / 听写转发），菜单样式避免窄屏拥挤
                HStack(spacing: 10) {
                    Text("qwen.voice.brain".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Menu {
                        ForEach(AgentBrain.allCases) { option in
                            Button {
                                brain = option
                            } label: {
                                if option == brain {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: brain.symbolName)
                            Text(brain.displayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    if AgentBrainRouter.isForwarding(to: brain) {
                        Text("qwen.voice.brain.forward".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    }
                    if brain == .custom {
                        Menu {
                            ForEach(CustomAgentStore.configs) { config in
                                Button {
                                    AgentBrainSettings.selectedCustomAgentID = config.id
                                } label: {
                                    if isSelectedCustomConfig(config.id) {
                                        Label(config.name, systemImage: "checkmark")
                                    } else {
                                        Text(config.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                Text(currentCustomAgentName)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.indigo)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                        if CustomAgentStore.configs.isEmpty {
                            Text("custom.agent.brain.noconfig.hint".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(.horizontal, 16)

                // 持续在场（Presence）：回合结束不退出，Agent 保持聆听
                Toggle(isOn: Binding(
                    get: { AgentPresenceSettings.presenceEnabled },
                    set: { isOn in
                        AgentPresenceSettings.presenceEnabled = isOn
                        session.refreshIdleWatchdog()
                        if isOn {
                            showTriggerBanner("agent.presence.on".localized)
                        } else {
                            showTriggerBanner("agent.presence.off".localized)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("agent.presence.title".localized)
                            .font(.system(size: 13, weight: .medium))
                        Text("agent.presence.subtitle".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)

                // 语音休眠与唤醒词（JARVIS 常驻模式）：休眠时等待「你好千问」或镜腿唤醒
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { QwenVoiceSession.wakeWordEnabled },
                        set: { isOn in
                            QwenVoiceSession.wakeWordEnabled = isOn
                            if isOn {
                                session.restartWakeWordListening()
                            } else {
                                session.stopWakeWordMonitoring()
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("qwen.wakeword.title".localized)
                                .font(.system(size: 13, weight: .medium))
                            Text("qwen.wakeword.subtitle".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    if session.isSleeping {
                        HStack(spacing: 10) {
                            Image(systemName: wakeWordListeningIcon)
                                .font(.system(size: 14))
                                .foregroundColor(wakeWordListening ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(wakeWordListening
                                    ? "qwen.wakeword.listening".localized
                                    : "qwen.wakeword.sleeping".localized)
                                    .font(.system(size: 13, weight: .medium))
                                if wakeWordListening, !session.wakeWordTranscript.isEmpty {
                                    Text(session.wakeWordTranscript)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                if let error = session.wakeWordMonitorError {
                                    Text(error)
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            Button {
                                session.wake()
                            } label: {
                                Text("qwen.wakeword.wake".localized)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(10)
                        .background(Color.green.opacity(wakeWordListening ? 0.10 : 0.05))
                        .cornerRadius(10)
                    } else if session.isActive {
                        HStack(spacing: 10) {
                            Image(systemName: "moon.zzz")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text("qwen.wakeword.sleep.hint".localized)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                session.requestSleep()
                            } label: {
                                Text("qwen.wakeword.sleep".localized)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 16)

                // 连接失败引导（按错误分类降级展示 + 兜底恢复提示）
                if let error = AgentTurnErrorClassifier.classify(connectionState: session.connectionState) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error.messageKey.localized)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                            if let recoveryKey = error.recoveryKey {
                                Text(recoveryKey.localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if error.kind == .gatewayUnreachable {
                            Button {
                                showGatewayConfig = true
                            } label: {
                                Text("qwen.voice.config".localized)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // 眼镜未连接提示（语音仍可用，镜腿触发不可用）
                if !streamViewModel.hasActiveDevice {
                    HStack(spacing: 8) {
                        Image(systemName: "smartglasses")
                            .font(.system(size: 12))
                        Text("qwen.voice.glasses.offline".localized)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                }

                // 镜腿触发提示
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

                Spacer()

                // 会话内容
                VStack(spacing: 20) {
                    if let errorMessage = session.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    if let taskMessage = session.taskMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 12))
                            Text(taskMessage)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }

                    // 任务权限审批卡片（等待用户在手机端确认）
                    if let permission = session.pendingPermission {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.orange)
                                Text("qwen.permission.title".localized)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if !permission.isSubmitting {
                                    Button {
                                        session.dismissPermission()
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Text(permission.permission.summary)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.leading)
                            // 超时倒计时：每秒刷新，剩余 ≤10 秒变红提示
                            if let expiresAt = session.permissionExpiresAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let seconds = AgentPermissionCountdown.remainingSeconds(
                                        expiresAt: expiresAt,
                                        now: context.date
                                    )
                                    HStack(spacing: 4) {
                                        Image(systemName: "timer")
                                            .font(.system(size: 10))
                                        Text("qwen.permission.timeout.remaining".localized(seconds))
                                            .font(.system(size: 11, weight: .medium))
                                            .monospacedDigit()
                                    }
                                    .foregroundColor(seconds <= 10 ? .red : .secondary)
                                }
                            }
                            HStack(spacing: 10) {
                                Button {
                                    Task { await session.respondToPermission(.deny) }
                                } label: {
                                    Text("qwen.permission.deny".localized)
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(8)
                                }
                                .disabled(permission.isSubmitting)

                                Button {
                                    Task { await session.respondToPermission(.allow) }
                                } label: {
                                    Group {
                                        if permission.isSubmitting {
                                            ProgressView()
                                        } else {
                                            Text("qwen.permission.allow".localized)
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .disabled(permission.isSubmitting)
                            }
                            if let error = session.permissionError {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // 任务完成播报横幅（完成/失败/取消，4 秒自动消失）
                    if let notice = session.completionNotice {
                        HStack(spacing: 8) {
                            Image(systemName: Self.feedSymbol(for: notice.kind))
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.completionTitle(for: notice.kind))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(notice.text)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Self.feedColor(for: notice.kind))
                        .cornerRadius(10)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            session.clearCompletionNotice()
                        }
                    }

                    // 后台任务列表（进行中 + 最近历史）
                    if !session.sortedAgentTasks.isEmpty {
                        AgentTaskListView(
                            tasks: session.sortedAgentTasks,
                            onReplay: replayTaskResult,
                            onFollowUpInChat: { task in
                                taskChatFollowUpResult = task.resultText ?? ""
                                showTaskChatFollowUp = true
                            }
                        )
                        .padding(.horizontal, 20)
                    }

                    // 对话流（本次会话转写 + 实时预览）
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                if !restoredHistory.isEmpty {
                                    if historyRecords.count > 1 {
                                        Menu {
                                            ForEach(historyRecords) { record in
                                                Button {
                                                    selectedHistoryRecordID = record.id
                                                    restorePreviousHistory(force: true)
                                                } label: {
                                                    if selectedHistoryRecordID == record.id {
                                                        Label(record.title, systemImage: "checkmark")
                                                    } else {
                                                        Text(record.title)
                                                    }
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text("qwen.voice.history.header".localized)
                                                Text(selectedHistoryTitle)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                Image(systemName: "chevron.up.chevron.down")
                                                    .font(.system(size: 9))
                                            }
                                            .font(.system(size: 11))
                                            .foregroundColor(.blue)
                                            .padding(.top, 4)
                                        }
                                    } else {
                                        Text("qwen.voice.history.header".localized)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .padding(.top, 4)
                                    }
                                    ForEach(restoredHistory) { item in
                                        transcriptBubble(item)
                                    }
                                }
                                ForEach(session.transcriptLog) { item in
                                    transcriptBubble(item)
                                }
                                if let live = livePreview {
                                    transcriptBubble(live, isLive: true)
                                }
                                if !brainLiveText.isEmpty {
                                    transcriptBubble(
                                        QwenTranscriptItem(role: .assistant, text: brainLiveText),
                                        isLive: true
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: session.transcriptLog.count) { _, _ in
                            if let last = session.transcriptLog.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }

                Spacer()

                // 主按钮区：视野注入 + 开始/停止
                HStack(spacing: 40) {
                    // 眼镜视野注入（会话进行中可用）
                    if AgentVisionSettings.injectionEnabled {
                        Button {
                            Task { await captureAndSendVision() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(session.isActive ? Color.blue.opacity(0.85) : Color(.systemGray5))
                                    .frame(width: 64, height: 64)
                                if isCapturingVision {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(session.isActive ? .white : .secondary)
                                }
                            }
                        }
                        .disabled(!session.isActive || isCapturingVision)
                    }

                    // 端侧取词 OCR（离线免费：朗读识别文字，并可转发给会话 Agent）
                    Button {
                        Task { await runVoiceOCR() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(session.isActive ? Color.teal.opacity(0.85) : Color(.systemGray5))
                                .frame(width: 64, height: 64)
                            if isOCRing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 24))
                                    .foregroundColor(session.isActive ? .white : .secondary)
                            }
                        }
                    }
                    .disabled(!session.isActive || isOCRing || isCapturingVision)

                    // 端侧场景识别（离线免费：识别画面场景 / 动物并朗读）
                    Button {
                        Task { await runVoiceScene() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(session.isActive ? Color.orange.opacity(0.85) : Color(.systemGray5))
                                .frame(width: 64, height: 64)
                            if isAnalyzingScene {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "lightbulb.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(session.isActive ? .white : .secondary)
                            }
                        }
                    }
                    .disabled(!session.isActive || isAnalyzingScene || isOCRing || isCapturingVision)

                    Button {
                        if session.isActive {
                            turnMachine.turnEnded()
                            AgentDisplayHub.shared.show(.idle)
                            session.endSession()
                        } else {
                            session.start()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(session.isActive ? Color.red.opacity(0.85) : Color.purple)
                                .frame(width: 84, height: 84)
                                .shadow(radius: 8)
                            Image(systemName: session.isActive ? "stop.fill" : "mic.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                        }
                    }
                }

                // 最近发送的视野缩略图
                if let lastVisionImage {
                    Image(uiImage: lastVisionImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.blue.opacity(0.4), lineWidth: 1)
                        )
                        .padding(.top, 2)
                }

                Text(session.isActive
                     ? (isCapturingVision ? "qwen.voice.vision.capture".localized : "qwen.voice.tapstop".localized)
                     : "qwen.voice.tapstart".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 20)
                                .navigationTitle("qwen.voice.title".localized)
                            }
                        )
                    )
                )
            )
            )
        }
    }

    // MARK: - Primary Orb Experience

    private var primaryOrbExperience: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.025, blue: 0.055),
                    Color.black,
                    Color(red: 0.02, green: 0.01, blue: 0.045),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                primaryTopBar

                Spacer(minLength: 12)

                Button {
                    handlePrimaryOrbTap()
                } label: {
                    MetalOrbView(
                        state: primaryOrbState,
                        intensity: primaryOrbIntensity,
                        audioLevel: session.inputLevel
                    )
                        .frame(maxWidth: 430, maxHeight: 430)
                        .aspectRatio(1, contentMode: .fit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(primaryControlTitle)
                .accessibilityHint(session.isActive ? "点按暂停或继续聆听" : "点按开始全双工语音会话")
                .accessibilityIdentifier("assistant.orb.primary")

                VStack(spacing: 8) {
                    Text(primaryStatusTitle)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())

                    Text(primaryStatusDetail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(minHeight: 34)
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 12)

                if let permission = session.pendingPermission {
                    primaryPermissionPanel(permission)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let task = primaryVisibleTask {
                    primaryTaskPanel(task)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let feedback = primaryFeedback ?? triggerBanner {
                    Text(feedback)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .frame(maxWidth: 340)
                        .primaryGlass(cornerRadius: 18)
                }

                Spacer(minLength: 20)

                primaryBottomControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSimplifiedSettings) {
            if let wearablesViewModel {
                SimplifiedSettingsView(
                    streamViewModel: streamViewModel,
                    wearablesViewModel: wearablesViewModel
                )
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showTaskDetails) {
            NavigationStack {
                ScrollView {
                    if session.sortedAgentTasks.isEmpty {
                        ContentUnavailableView(
                            "暂无任务",
                            systemImage: "checkmark.circle",
                            description: Text("后台 Agent 的进度与结果会显示在这里。")
                        )
                        .padding(.top, 80)
                    } else {
                        AgentTaskListView(
                            tasks: session.sortedAgentTasks,
                            onReplay: replayTaskResult,
                            onFollowUpInChat: { task in
                                taskChatFollowUpResult = task.resultText ?? ""
                                showTaskChatFollowUp = true
                            },
                            maxTasks: 20
                        )
                        .padding(20)
                    }
                }
                .navigationTitle("任务")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showTaskDetails = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var primaryTopBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(primaryStatusColor)
                    .frame(width: 7, height: 7)
                Text("HYPER")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }

            Spacer()

            HStack(spacing: 12) {
                if streamViewModel.hasActiveDevice {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .accessibilityLabel("眼镜已连接")
                }

                Button {
                    showSimplifiedSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .frame(width: 38, height: 38)
                        .primaryGlass(cornerRadius: 19, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
                .accessibilityIdentifier("assistant.settings")
            }
        }
        .frame(height: 44)
    }

    private var primaryBottomControls: some View {
        HStack(spacing: 14) {
            Button {
                if session.isActive {
                    session.toggleInterrupt()
                } else {
                    startPrimarySession()
                }
            } label: {
                Image(systemName: primaryControlSymbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .primaryGlass(cornerRadius: 25, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(primaryControlTitle)

            if AgentVisionSettings.injectionEnabled {
                Button {
                    Task { await captureAndSendVision() }
                } label: {
                    Group {
                        if isCapturingVision {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 19, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .primaryGlass(cornerRadius: 25, interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(!session.isActive || isCapturingVision)
                .opacity(session.isActive ? 1 : 0.42)
                .accessibilityLabel("读取眼镜视野")
            }

            if !session.sortedAgentTasks.isEmpty {
                Button {
                    showTaskDetails = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .primaryGlass(cornerRadius: 25, interactive: true)
                        if session.runningTaskCount > 0 {
                            Text("\(session.runningTaskCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(.white, in: Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("任务")
            }

            if session.isActive {
                Button {
                    endVoiceSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .primaryGlass(cornerRadius: 25, interactive: true, tint: .red.opacity(0.22))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("结束会话")
            }
        }
        .frame(minHeight: 58)
    }

    private func primaryTaskPanel(_ task: QwenAgentTask) -> some View {
        Button {
            showTaskDetails = true
        } label: {
            HStack(spacing: 12) {
                if task.isActive {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else {
                    Image(systemName: primaryTaskSymbol(task.status))
                        .foregroundStyle(primaryTaskColor(task.status))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title.isEmpty ? task.statusLabel : task.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(task.resultText?.isEmpty == false ? task.resultText! : task.statusLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: 340)
            .primaryGlass(cornerRadius: 18, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func primaryPermissionPanel(_ request: QwenPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("需要确认", systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(request.permission.summary)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(2)

            HStack(spacing: 10) {
                Button("拒绝") {
                    Task { await session.respondToPermission(.deny) }
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.8))
                .frame(maxWidth: .infinity)

                Button("允许") {
                    Task { await session.respondToPermission(.allow) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
            }
            .disabled(request.isSubmitting)
        }
        .padding(15)
        .frame(maxWidth: 340)
        .primaryGlass(cornerRadius: 18)
    }

    private var primaryVisibleTask: QwenAgentTask? {
        session.sortedAgentTasks.first
    }

    private var primaryOrbState: AssistantOrbState {
        if case .failed = session.connectionState { return .error }
        if session.runningTaskCount > 0 { return .working }
        if session.isSpeaking || ttsService.isSpeaking { return .speaking }
        if turnMachine.phase == .thinking { return .thinking }
        if session.isActive && !session.isInputPaused { return .listening }
        if case .connecting = session.connectionState { return .connecting }
        return .idle
    }

    private var primaryOrbIntensity: Float {
        if session.isSpeaking || ttsService.isSpeaking { return 1 }
        if session.runningTaskCount > 0 || turnMachine.phase == .thinking { return 0.88 }
        if session.isActive { return 0.76 }
        return 0.5
    }

    private var primaryStatusTitle: String {
        if let feedback = primaryFeedback { return feedback }
        if session.isSleeping { return "待命中" }
        if session.isInputPaused { return "已暂停" }
        if session.runningTaskCount > 0 { return "正在执行任务" }
        if session.isSpeaking || ttsService.isSpeaking { return "正在回应" }
        if turnMachine.phase == .thinking { return "正在思考" }
        switch session.connectionState {
        case .connecting: return "正在连接"
        case .failed: return "连接异常"
        case .connected where session.isActive: return "正在聆听"
        case .connected: return "准备就绪"
        case .disconnected: return "点按开始"
        }
    }

    private var primaryStatusDetail: String {
        if let task = primaryVisibleTask, task.isActive {
            return task.resultText?.isEmpty == false ? task.resultText! : task.statusLabel
        }
        if session.isSpeaking, !session.lastAssistantText.isEmpty {
            return session.lastAssistantText
        }
        if session.isActive, !session.lastUserText.isEmpty {
            return session.lastUserText
        }
        if streamViewModel.hasActiveDevice {
            return "语音与眼镜视觉已就绪"
        }
        return "全双工语音 · Agent 调度"
    }

    private var primaryStatusColor: Color {
        switch primaryOrbState {
        case .error: return .red
        case .connecting: return .orange
        case .idle: return .white.opacity(0.35)
        default: return .green
        }
    }

    private var primaryControlSymbol: String {
        if !session.isActive { return "waveform" }
        return session.isInputPaused ? "mic.fill" : "pause.fill"
    }

    private var primaryControlTitle: String {
        if !session.isActive { return "开始会话" }
        return session.isInputPaused ? "继续聆听" : "暂停聆听"
    }

    private func handlePrimaryOrbTap() {
        if !session.isActive {
            startPrimarySession()
        } else if session.isInputPaused {
            session.resume()
            primaryFeedback = "继续聆听"
        } else if session.isSpeaking || ttsService.isSpeaking {
            session.bargeIn()
            TTSService.shared.stop()
            primaryFeedback = "已打断"
        } else {
            session.interrupt()
            primaryFeedback = "已暂停"
        }
        clearPrimaryFeedbackLater()
    }

    private func startPrimarySession() {
        AgentPresenceSettings.presenceEnabled = true
        turnMachine.turnStarted()
        primaryFeedback = "正在连接"
        clearPrimaryFeedbackLater()
        Task { @MainActor in
            let permission: AVAudioSession.RecordPermission
            if #available(iOS 17.0, *) {
                permission = AVAudioApplication.shared.recordPermission == .granted
                    ? .granted
                    : (AVAudioApplication.shared.recordPermission == .denied ? .denied : .undetermined)
            } else {
                permission = AVAudioSession.sharedInstance().recordPermission
            }

            let granted: Bool
            switch permission {
            case .granted:
                granted = true
            case .denied:
                granted = false
            case .undetermined:
                granted = await withCheckedContinuation { continuation in
                    if #available(iOS 17.0, *) {
                        AVAudioApplication.requestRecordPermission { value in
                            continuation.resume(returning: value)
                        }
                    } else {
                        AVAudioSession.sharedInstance().requestRecordPermission { value in
                            continuation.resume(returning: value)
                        }
                    }
                }
            @unknown default:
                granted = false
            }

            guard granted else {
                turnMachine.turnEnded()
                primaryFeedback = "需要麦克风权限"
                clearPrimaryFeedbackLater()
                return
            }
            session.start()
        }
    }

    private func clearPrimaryFeedbackLater() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            primaryFeedback = nil
        }
    }

    private func primaryTaskSymbol(_ status: QwenAgentTask.Status) -> String {
        switch status {
        case .waiting: return "clock"
        case .running: return "ellipsis.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func primaryTaskColor(_ status: QwenAgentTask.Status) -> Color {
        switch status {
        case .waiting: return .orange
        case .running: return .cyan
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    // MARK: - Body 分段（拆分巨型修饰符链，避免 Swift type-check 超时）

    /// 导航栏与配置弹层
    private func voicePresentation<V: View>(_ content: V) -> some View {
        content
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isPrimaryExperience {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showTaskChatFollowUp) {
            AgentChatView(
                kind: brain == .openclaw ? .openclaw : .hermes,
                streamViewModel: streamViewModel,
                initialTaskResult: taskChatFollowUpResult.isEmpty ? nil : taskChatFollowUpResult
            )
        }
        .sheet(isPresented: $showGatewayConfig) {
            QwenGatewayConfigSheetView {
                // 配置变更后重连
                session.stop()
                session.start()
            }
        }
    }

    /// 生命周期（onAppear / onDisappear）
    private func voiceLifecycle<V: View>(_ content: V) -> some View {
        content
        .onAppear {
            guard !AppIdentity.isRunningPreview else { return }
            streamViewModel.onDeviceTrigger = { [self] trigger in
                handleDeviceTrigger(trigger)
            }
            streamViewModel.onDeviceReconnected = { [self] in
                handleDeviceReconnected()
            }
            // 清除残留的断开标志（避免下次长按误报）
            streamViewModel.consumeUnexpectedDeviceEndFlag()
            // 轻量会话：让镜腿触发在语音页始终可用
            Task { await streamViewModel.acquireAgentTriggerSession() }
            // 大脑模式：听写转发时关闭 Qwen 语音回复；OpenClaw 接管聊天事件
            session.outputEnabled = !AgentBrainRouter.isForwarding(to: brain)
            if brain == .openclaw || brain == .auto {
                openClawService.onChatEvent = { [self] snapshot in
                    handleOpenClawChatEvent(snapshot)
                }
            }
            session.onIdleTimeout = { [self] in
                turnMachine.turnEnded()
                showIdleMenu()
                let error = AgentTurnErrorClassifier.idleTimeout()
                let hint = error.recoveryKey.map { $0.localized } ?? ""
                self.showTriggerBanner(error.messageKey.localized + (hint.isEmpty ? "" : "（" + hint + "）"))
            }
            if let initialHistoryRecordID {
                selectedHistoryRecordID = initialHistoryRecordID
            }
            restorePreviousHistory()
            if isPrimaryExperience {
                if startImmediately {
                    startPrimarySession()
                } else {
                    AgentDisplayHub.shared.show(.idle)
                }
            } else {
                turnMachine.turnStarted()
                AgentDisplayHub.shared.show(.listening)
                session.start()
                if let initialFollowUpContext, !initialFollowUpContext.isEmpty {
                    // 结果追问：先注入结果上下文——锁屏「回复 JARVIS」携带的初始指令
                    // 与后续开口（如「展开第三条」）都带上该条结果
                    session.restoreFollowUpContext(initialFollowUpContext)
                }
                if let initialInstruction, !initialInstruction.isEmpty {
                    sendInitialInstruction(initialInstruction)
                }
            }
        }
        .onDisappear {
            guard !AppIdentity.isRunningPreview else { return }
            streamViewModel.onDeviceTrigger = nil
            streamViewModel.onDeviceReconnected = nil
            AgentDisplayHub.shared.show(.idle)
            Task { await streamViewModel.releaseAgentTriggerSession() }
            bannerDismissTask?.cancel()
            session.onIdleTimeout = nil
            openClawService.onChatEvent = nil
            AgentBrainRouter.shared.cancel(to: brain)
            TTSService.shared.stop()
            session.stop()
            extractMemoryCandidates()
            persistVoiceConversation()
        }
    }

    /// 视觉数据清理 / 相册回退 / 回退选图
    private func voiceDeviceObservations<V: View>(_ content: V) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .agentVisionDataCleared)) { _ in
            // 视觉数据清理：丢弃语音页保留的最近画面帧（帧仅内存持有）
            lastVisionImage = nil
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AgentWearableTriggerCenter.repeatReplyNotification
        )) { _ in
            // 触发中心「重听回复」：与眼镜菜单 Repeat 共用同一实现
            repeatLastReply()
        }
        .photosPicker(
            isPresented: $showVoiceFallbackPhotoPicker,
            selection: $voiceFallbackPhotoItem,
            matching: .images
        )
        .onChange(of: voiceFallbackPhotoItem) { _, item in
            guard let item else { return }
            Task {
                // 相册回退：加载所选图片后执行与眼镜帧相同的端侧视觉动作
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    showTriggerBanner("agent.vision.pick.failed".localized)
                    voiceFallbackPhotoItem = nil
                    return
                }
                defer { voiceFallbackPhotoItem = nil }
                switch voiceFallbackAction {
                case .ocr:
                    isOCRing = true
                    defer { isOCRing = false }
                    await processVoiceOCR(image)
                case .scene:
                    isAnalyzingScene = true
                    defer { isAnalyzingScene = false }
                    await processVoiceScene(image)
                }
            }
        }
    }

    /// 回合状态观察（说话 / 思考 / 审批）
    private func voiceTurnObservations<V: View>(_ content: V) -> some View {
        content
        .onChange(of: session.isSpeaking) { _, isSpeaking in
            if isSpeaking {
                turnMachine.outputStarted()
                if turnMachine.phase != .approval {
                    AgentDisplayHub.shared.show(.speaking)
                }
            } else {
                turnMachine.outputEnded()
                if turnMachine.phase != .interrupted,
                   turnMachine.phase != .approval,
                   turnMachine.phase != .idle {
                    restoreIdleDisplay()
                }
                reevaluateDeferredApproval()
            }
        }
        .onChange(of: ttsService.isSpeaking) { _, isSpeaking in
            // 听写转发模式的 TTS 播报结束：回到聆听（speaking 状态保持到播完）
            if !isSpeaking, turnMachine.phase == .speaking {
                turnMachine.outputEnded()
                restoreIdleDisplay()
            }
            reevaluateDeferredApproval()
        }
        .onChange(of: turnMachine.phase) { _, _ in
            // 回合状态变化：会话空闲（聆听/思考）时补弹被延迟的审批卡
            reevaluateDeferredApproval()
        }
        .onChange(of: session.isInputActive) { _, isActive in
            // 用户说完话（VAD 断句）后补弹被延迟的审批卡
            if !isActive {
                reevaluateDeferredApproval()
            }
        }
        .onChange(of: session.pendingPermission) { _, pending in
            // 权限请求到达/处理完成：会话空闲直接弹审批卡；忙碌（说话/播报）先延迟，空闲补弹
            if let pending {
                if AgentApprovalDeferralPolicy.shouldDefer(
                    phase: turnMachine.phase,
                    isInputActive: session.isInputActive,
                    isSpeaking: session.isSpeaking,
                    ttsSpeaking: TTSService.shared.isSpeaking
                ) {
                    // 忙碌：暂停超时计时，等会话空闲再弹（不打断正在进行的回合）
                    session.pausePermissionTimeout()
                    deferredApproval = pending
                } else {
                    session.resumePermissionTimeout()
                    deferredApproval = nil
                    presentApproval(pending)
                }
            } else {
                deferredApproval = nil
                turnMachine.permissionResolved()
                if let feedback = pendingApprovalFeedback {
                    // 决策成功：镜片展示一次即时反馈，随后自动回退到回合状态
                    pendingApprovalFeedback = nil
                    AgentDisplayHub.shared.showResult(
                        title: feedback.title,
                        text: feedback.text,
                        fallback: turnMachine.phase
                    )
                } else {
                    AgentDisplayHub.shared.show(turnMachine.phase)
                }
            }
        }
        .onChange(of: session.permissionTimedOut) { _, timedOut in
            guard timedOut else { return }
            showTriggerBanner("agent.permission.timeout".localized)
            session.clearPermissionTimeout()
        }
    }

    /// 任务 / 大脑 / 转写观察
    private func voiceTaskObservations<V: View>(_ content: V) -> some View {
        content
        .onChange(of: session.acknowledgmentNotice) { _, notice in
            // 任务受理回执：大脑转发模式网关不播报输出，用 TTS 立即回一句「收到」
            guard let notice else { return }
            AgentTaskLensPresenter.handleAcknowledgmentChange(
                title: notice.title,
                announceByApp: AgentBrainRouter.isForwarding(to: brain),
                isSpeaking: session.isSpeaking,
                isInputActive: session.isInputActive,
                ttsSpeaking: TTSService.shared.isSpeaking
            )
        }
        .onChange(of: session.progressCheckInNotice) { _, notice in
            handleProgressCheckIn(notice)
        }
        .onChange(of: session.completionNotice) { _, notice in
            // 后台任务终态：清过期进度 → TTS 播报（大脑转发模式由 App 补播）→ 镜片结果卡 → 触觉
            guard let notice else { return }
            AgentTaskLensPresenter.handleCompletionChange(
                phase: turnMachine.phase,
                kind: notice.kind,
                text: notice.text,
                lastTaskResultText: session.lastTaskResultText,
                runningTaskCount: session.runningTaskCount,
                announceByApp: AgentBrainRouter.isForwarding(to: brain),
                isSpeaking: session.isSpeaking,
                isInputActive: session.isInputActive,
                ttsSpeaking: TTSService.shared.isSpeaking
            )
        }
        .onChange(of: session.runningTaskCount) { _, count in
            // 任务进度变化：进行中显示进度卡；全部结束后清进度并恢复回合状态
            AgentTaskLensPresenter.handleProgressChange(
                phase: turnMachine.phase,
                runningTaskCount: count,
                taskMessage: session.taskMessage,
                hasCompletionNotice: session.completionNotice != nil
            )
        }
        .onChange(of: session.taskMessage) { _, message in
            // 任务分步进度：聆听/思考/空闲态实时把最新步骤透出到眼镜
            AgentTaskLensPresenter.handleStepMessageChange(
                phase: turnMachine.phase,
                runningTaskCount: session.runningTaskCount,
                taskMessage: message
            )
        }
        .onChange(of: scenePhase) { _, phase in
            // 退后台立即停止录音与连接（隐私与资源）
            if phase == .background {
                session.stop()
            }
        }
        .onChange(of: brain) { _, newBrain in
            AgentBrainSettings.selected = newBrain
            applyBrain(newBrain)
        }
        .onChange(of: session.transcriptLog.count) { _, _ in
            // 听写模式：用户每段最终转写转发给大脑
            guard AgentBrainRouter.isForwarding(to: brain),
                  let last = session.transcriptLog.last,
                  last.role == .user,
                  last.text != lastForwardedUserText else { return }
            // 任务语音指令（进度/取消）：大脑没有任务上下文，本地拦截处理
            if let command = AgentTaskCommandParser.parse(
                last.text,
                activeTaskCount: session.runningTaskCount,
                failedTaskCount: session.failedTasks.count
            ), handleTaskCommand(command) {
                lastForwardedUserText = last.text
                return
            }
            // 语音本地指令（重听/新会话）：大脑模式本地拦截
            if let local = AgentLocalCommandParser.parse(last.text),
               handleLocalCommand(local) {
                lastForwardedUserText = last.text
                return
            }
            // 记忆指令：显式「帮我记住 X」存入；「我记住了什么」查询播报，不转发
            if let memory = AgentMemoryCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleMemoryCommand(memory)
                return
            }
            // 助手画像指令：查询 / 改名（「你叫什么名字 / 以后你叫小舟」）本地维护，不转发。
            // 必须在规则解析之前拦截——「以后你叫 X」以「以后」开头，否则会被当成规则。
            if let personaCommand = AgentPersonaCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handlePersonaCommand(personaCommand)
                return
            }
            // 个性化规则指令「以后汇报先说结论」：本地维护并注入所有 Agent，不转发
            if let ruleCommand = AgentRuleCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleRuleCommand(ruleCommand)
                return
            }
            // 前端自有工具：命名清单指令（购物单 / 待办）本地维护，不转发
            if let listCommand = AgentListCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleListCommand(listCommand)
                return
            }
            // 前端自有工具：本地提醒（「十分钟后提醒我喝水」）本地调度，不转发
            if let reminderCommand = AgentReminderCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleReminderCommand(reminderCommand)
                return
            }
            // 前端自有工具：健康数据（「记录体重65公斤 / 今天走了多少步」）本地维护，不转发
            if let healthCommand = AgentHealthCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleHealthCommand(healthCommand)
                return
            }
            // 前端自有工具：智能家居（「打开客厅灯 / 把空调调到26度」）本地控制，不转发
            if let homeKitCommand = AgentHomeKitCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleHomeKitCommand(homeKitCommand)
                return
            }
            // 日历删除歧义追问（序号 / 更具体名称 / 取消）：有待选且消息像是选择时拦截，
            // 解析为选择则删除 / 取消 / 收窄追问，否则走常规流程（待选保留）
            if !AgentCalendarDeletePendingStore.candidates.isEmpty,
               AgentCalendarDeleteSelectionParser.isPotentialSelection(
                   last.text,
                   candidates: AgentCalendarDeletePendingStore.candidates
               ) {
                lastForwardedUserText = last.text
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
                                announceVoiceFeedback(reply)
                            }
                        }
                    },
                    onCancel: {
                        Task { @MainActor in
                            announceVoiceFeedback(AgentCalendarDeleteSelectionCoordinator.cancel())
                        }
                    }
                )
                Task {
                    if let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
                        text: last.text,
                        provider: AgentCalendar.provider
                    ) {
                        announceVoiceFeedback(reply)
                    }
                }
                return
            }
            // 前端自有工具：日历日程（「明天下午3点把会议加入日历 / 今天有什么安排」）本地维护，不转发
            if let calendarCommand = AgentCalendarCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleCalendarCommand(calendarCommand)
                return
            }
            // 前端自有工具：通知播报（「有什么通知 / 清空通知」）本地汇总，不转发
            if let notificationCommand = AgentNotificationCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                handleNotificationCommand(notificationCommand)
                return
            }
            // 端侧场景识别：「看看这是什么 / 识别场景」本地抓帧识别并播报，不转发
            if AgentVisionSceneCommandParser.parse(last.text) {
                lastForwardedUserText = last.text
                Task { await runVoiceScene() }
                return
            }
            lastForwardedUserText = last.text
            // 任务完成后的追问：把最新任务结果前置给大脑（如「展开第三条」）
            forwardToBrain(session.followUpMessage(last.text))
        }
    }

    // MARK: - Computed

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch session.connectionState {
        case .connected: return "qwen.voice.connected".localized
        case .connecting: return "qwen.voice.connecting".localized
        case .failed(let message): return message
        case .disconnected: return "qwen.voice.disconnected".localized
        }
    }

    private var wakeWordListening: Bool {
        session.wakeWordPhase == .listening
    }

    private var wakeWordListeningIcon: String {
        wakeWordListening ? "waveform" : "moon.zzz.fill"
    }

    private var connectionStateText: String {
        if session.isSpeaking { return "qwen.voice.speaking".localized }
        if session.isInputActive { return "qwen.voice.listening".localized }
        return "qwen.voice.idle".localized
    }

    /// 进行中的转写（delta 与已完成的 final 不一致时显示为预览）
    private var livePreview: QwenTranscriptItem? {
        if !session.lastUserText.isEmpty,
           session.transcriptLog.last(where: { $0.role == .user })?.text != session.lastUserText {
            return QwenTranscriptItem(role: .user, text: session.lastUserText)
        }
        if !session.lastAssistantText.isEmpty,
           session.transcriptLog.last(where: { $0.role == .assistant })?.text != session.lastAssistantText {
            return QwenTranscriptItem(role: .assistant, text: session.lastAssistantText)
        }
        return nil
    }

    private func transcriptBubble(_ item: QwenTranscriptItem, isLive: Bool = false) -> some View {
        if item.role == .system {
            return AnyView(
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            )
        }
        let isUser = item.role == .user
        return AnyView(
            HStack {
                if isUser { Spacer(minLength: 60) }
                Text(item.text)
                    .font(.system(size: 15))
                    .foregroundColor(isUser ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                            ? Color.purple.opacity(isLive ? 0.55 : 0.85)
                            : Color(.systemGray6)
                    )
                    .cornerRadius(16)
                    .overlay(
                        isLive
                            ? RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                            : nil
                    )
                if !isUser { Spacer(minLength: 60) }
            }
        )
    }

    private static func feedSymbol(for kind: QwenTaskFeedItem.Kind) -> String {
        switch kind {
        case .delegated: return "hammer.fill"
        case .progress: return "ellipsis.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .permissionRequested: return "hand.raised.fill"
        case .result: return "text.bubble.fill"
        }
    }

    private static func feedColor(for kind: QwenTaskFeedItem.Kind) -> Color {
        switch kind {
        case .delegated, .progress: return .blue
        case .completed, .result: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .permissionRequested: return .orange
        }
    }

    /// 任务终态横幅标题
    private static func completionTitle(for kind: QwenTaskFeedItem.Kind) -> String {
        switch kind {
        case .completed, .result: return "qwen.voice.task.completed".localized
        case .failed: return "qwen.voice.task.failed".localized
        case .cancelled: return "qwen.voice.task.cancelled".localized
        default: return "qwen.voice.task.completed".localized
        }
    }

    // MARK: - 眼镜视野注入

    /// 抓取眼镜当前画面 → 视觉模型生成描述 → 以文本消息发给语音 Agent。
    private func captureAndSendVision() async {
        guard AgentVisionPolicy.canCapture(
                  injectionEnabled: AgentVisionSettings.injectionEnabled,
                  revoked: AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id)
              ),
              session.isActive,
              !isCapturingVision else { return }
        guard !VisionAPIConfig.apiKey.isEmpty else {
            showTriggerBanner("qwen.voice.vision.noapikey".localized)
            return
        }

        isCapturingVision = true
        defer { isCapturingVision = false }

        guard let frame = await captureVoiceFrame() else {
            showTriggerBanner("qwen.voice.vision.noframe".localized)
            return
        }
        lastVisionImage = frame
        session.latestVisionFrame = frame

        do {
            let description = try await VisionAPIService().analyzeImage(
                frame,
                prompt: "qwen.voice.vision.prompt".localized
            )
            let context = "qwen.voice.vision.context".localized + description
            if AgentBrainRouter.isForwarding(to: brain) {
                // 大脑模式：视野描述作为上下文直接转发给大脑
                session.appendUserText(
                    context,
                    label: "qwen.voice.vision.sent".localized,
                    kind: .vision
                )
                lastForwardedUserText = context
                forwardToBrain(context)
            } else {
                session.sendText(
                    context,
                    label: "qwen.voice.vision.sent".localized,
                    kind: .vision
                )
            }
        } catch {
            showTriggerBanner("qwen.voice.vision.failed".localized)
        }
    }

    // MARK: - 健康数据

    /// 健康指令：记录 / 查询健康数据（HealthKit），播报确认，不转发给大脑
    private func handleHealthCommand(_ command: AgentHealthCommand) {
        Task { @MainActor in
            let reply = await AgentHealthExecutor.execute(
                command,
                provider: AgentHealth.provider
            )
            announceVoiceFeedback(reply)
        }
    }

    // MARK: - 智能家居

    /// 家居指令：控制 / 查询 HomeKit 配件（HomeKit），播报确认，不转发给大脑
    private func handleHomeKitCommand(_ command: AgentHomeKitCommand) {
        Task { @MainActor in
            let reply = await AgentHomeKitExecutor.execute(
                command,
                provider: AgentHomeKit.provider
            )
            announceVoiceFeedback(reply)
        }
    }

    // MARK: - 通知播报

    /// 通知指令：未读汇总 / 清空通知中心，播报确认，不转发给大脑
    private func handleNotificationCommand(_ command: AgentNotificationCommand) {
        Task { @MainActor in
            let reply: String
            switch command {
            case .catchUp:
                reply = await AgentNotificationButler.shared.catchUp()
            case .clear:
                reply = await AgentNotificationButler.shared.clearDelivered()
            }
            announceVoiceFeedback(reply)
        }
    }

    // MARK: - 日历日程

    /// 日历指令：创建 / 查询系统日程（EventKit），播报确认，不转发给大脑
    private func handleCalendarCommand(_ command: AgentCalendarCommand) {
        Task { @MainActor in
            let reply = await AgentCalendarExecutor.execute(
                command,
                provider: AgentCalendar.provider
            )
            announceVoiceFeedback(reply)
        }
    }

    // MARK: - 端侧取词 OCR

    /// 抓帧 → 场景识别 → 朗读（大脑模式）/ 转发给会话 Agent，并上镜片展示
    private func runVoiceScene() async {
        guard session.isActive, !isAnalyzingScene, !isOCRing, !isCapturingVision else { return }
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            showTriggerBanner("agent.vision.revoked".localized)
            return
        }
        isAnalyzingScene = true
        defer { isAnalyzingScene = false }

        guard let frame = await captureVoiceFrame() else {
            presentVoiceFallbackPicker(for: .scene)
            return
        }
        lastVisionImage = frame
        session.latestVisionFrame = frame
        await processVoiceScene(frame)
    }

    /// 相册选图回退：无眼镜画面帧时让用户从相册选一张，执行相同动作
    private func presentVoiceFallbackPicker(for action: VoiceFallbackVisionAction) {
        voiceFallbackAction = action
        showVoiceFallbackPhotoPicker = true
    }

    /// 对给定帧执行场景识别（眼镜帧与相册回退共用）
    private func processVoiceScene(_ frame: UIImage) async {
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
        if AgentBrainRouter.isForwarding(to: brain) {
            // 大脑模式：先朗读识别结果，再作为上下文转发给大脑（可追问）
            if AgentVoiceSettings.replyEnabled {
                TTSService.shared.stop()
                TTSService.shared.speak(summary)
            }
            session.appendUserText(summary, label: "agent.vision.scene.sent".localized, kind: .vision)
            lastForwardedUserText = summary
            forwardToBrain(summary)
        } else {
            session.sendText(summary, label: "agent.vision.scene.sent".localized, kind: .vision)
        }
    }

    /// 抓帧 → OCR → 朗读（大脑模式）/ 转发给会话 Agent，并上镜片展示
    private func runVoiceOCR() async {
        guard session.isActive, !isOCRing, !isCapturingVision else { return }
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            showTriggerBanner("agent.vision.revoked".localized)
            return
        }
        isOCRing = true
        defer { isOCRing = false }

        guard let frame = await captureVoiceFrame() else {
            presentVoiceFallbackPicker(for: .ocr)
            return
        }
        lastVisionImage = frame
        session.latestVisionFrame = frame
        await processVoiceOCR(frame)
    }

    /// 对给定帧执行取词（眼镜帧与相册回退共用）
    private func processVoiceOCR(_ frame: UIImage) async {
        let lines = await VisionOCRService.recognizeText(in: frame)
        let text = VisionOCRTextProcessor.normalizedText(from: lines.map(\.text))
        guard !text.isEmpty else {
            showTriggerBanner("agent.vision.ocr.empty".localized)
            return
        }
        AgentVisionOCRStore.set(text)

        AgentDisplayHub.shared.showResult(
            title: "agent.vision.ocr.title".localized,
            text: VisionOCRTextProcessor.displayText(from: text),
            fallback: .idle
        )
        if AgentBrainRouter.isForwarding(to: brain) {
            // 大脑模式：先朗读识别文字，再作为上下文转发给大脑（可追问翻译/总结）
            if AgentVoiceSettings.replyEnabled {
                TTSService.shared.stop()
                TTSService.shared.speak(text)
            }
            session.appendUserText(text, label: "agent.vision.ocr.sent".localized, kind: .vision)
            lastForwardedUserText = text
            forwardToBrain(text)
        } else {
            session.sendText(text, label: "agent.vision.ocr.sent".localized, kind: .vision)
        }
    }

    /// 镜片「翻译」：把最近一次取词结果发给当前大脑翻译（回复 TTS 播报）
    private func requestTranslateFromMenu() {
        guard let text = AgentVisionOCRStore.lastText else {
            showTriggerBanner("agent.vision.translate.notext".localized)
            return
        }
        let instruction = VisionTranslationPlanner.translateInstruction(for: text)
        if AgentBrainRouter.isForwarding(to: brain) {
            session.appendUserText(
                instruction,
                label: "agent.vision.translate.sent".localized,
                kind: .vision
            )
            lastForwardedUserText = instruction
            forwardToBrain(instruction)
        } else {
            session.sendText(
                instruction,
                label: "agent.vision.translate.sent".localized,
                kind: .vision
            )
        }
        showTriggerBanner("agent.vision.translate.sent".localized)
    }

    /// 抓取一帧眼镜当前画面（复用轻量摄像头流，拍完即释放）
    private func captureVoiceFrame() async -> UIImage? {
        let streamReady = await streamViewModel.acquireStream(for: .agentChat)
        guard streamReady else { return nil }
        defer {
            Task { @MainActor in
                await streamViewModel.releaseStream(for: .agentChat)
            }
        }
        let deadline = Date().addingTimeInterval(2.0)
        while (!streamViewModel.cameraCaptureState.isStreaming
               || streamViewModel.currentVideoFrame == nil) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return streamViewModel.currentVideoFrame
    }

    // MARK: - 镜腿触发

    private func handleDeviceTrigger(_ trigger: AgentDeviceTrigger) {
        AgentTriggerFeedback.play(for: trigger)
        switch turnMachine.handle(trigger: trigger) {
        case .wake:
            droppedReplyWhileInterrupted = false
            session.wake()
            AgentDisplayHub.shared.show(.listening)
            showTriggerBanner("agent.trigger.woke".localized)
        case .interrupt:
            session.interrupt()
            cancelBrainReply()
            AgentDisplayHub.shared.show(.interrupted)
            showTriggerBanner("agent.trigger.interrupted".localized)
        case .resume:
            session.resume()
            AgentDisplayHub.shared.show(.listening)
            if droppedReplyWhileInterrupted {
                droppedReplyWhileInterrupted = false
                showTriggerBanner("agent.trigger.reply.dropped".localized)
            } else {
                showTriggerBanner("agent.trigger.resumed".localized)
            }
        case .endTurn:
            cancelBrainReply()
            session.endSession()
            showIdleMenu()
            if streamViewModel.consumeUnexpectedDeviceEndFlag() {
                let error = AgentTurnErrorClassifier.deviceDisconnected()
                let hint = error.recoveryKey.map { $0.localized } ?? ""
                showTriggerBanner(error.messageKey.localized + (hint.isEmpty ? "" : "（" + hint + "）"))
            } else {
                showTriggerBanner("agent.trigger.ended".localized)
            }
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
                    for: .voice,
                    hasActiveTasks: session.runningTaskCount > 0,
                    hasTodayOverview: !upcomingEvents.isEmpty
                        || AgentReminderDisplayMapping.hasActiveReminders(
                            AgentReminderStore.reminders
                        )
                        || session.runningTaskCount > 0,
                    hasTomorrowOverview: !upcomingTomorrowEvents.isEmpty,
                    hasFollowUpContext: session.hasFollowUpContext,
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

    /// 快捷指令子菜单：列出用户配置的常用指令，一键触发
    private func showShortcutsMenu() {
        let shortcuts = AgentShortcutStore.shortcuts
        guard !shortcuts.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Shortcuts",
                text: "agent.shortcuts.empty".localized,
                fallback: turnMachine.phase
            )
            return
        }
        AgentDisplayHub.shared.showShortcutsMenu(
            shortcuts: shortcuts,
            onSelect: { [self] shortcut in runShortcut(shortcut) },
            onBack: { [self] in showIdleMenu() }
        )
    }

    /// 执行快捷指令：把配置的指令文本作为用户输入发送（大脑模式转发 / 原生模式直接发送）
    private func runShortcut(_ shortcut: AgentShortcut) {
        let prompt = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if AgentBrainRouter.isForwarding(to: brain) {
            lastForwardedUserText = prompt
            forwardToBrain(prompt)
        } else {
            session.sendText(prompt, label: "agent.shortcuts.sent".localized)
        }
        AgentDisplayHub.shared.show(.listening)
        showTriggerBanner("agent.shortcuts.triggered".localized)
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
                taskTitles: session.activeTasks
                    .filter { $0.status == .running || $0.status == .waiting }
                    .map(\.title),
                now: Date()
            )
            let text = content.fullText
            AgentDisplayHub.shared.showResult(
                title: AgentDisplayMenuMapping.title(for: .todayOverview),
                text: text,
                fallback: turnMachine.phase
            )
            showTriggerBanner(text)
            if AgentVoiceSettings.replyEnabled {
                TTSService.shared.stop()
                TTSService.shared.speak(text)
            }
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
                fallback: turnMachine.phase
            )
            showTriggerBanner(text)
            if AgentVoiceSettings.replyEnabled {
                TTSService.shared.stop()
                TTSService.shared.speak(text)
            }
        }
    }

    /// 任务中心子菜单：进度播报 / 取消 / 重试失败任务 / 返回主菜单
    private func showTaskMenu() {
        AgentDisplayHub.shared.showMenu(
            actions: AgentDisplayMenuMapping.actions(
                for: .taskCenter,
                hasFailedTasks: session.failedTasks.count > 0
            ),
            onSelect: { [self] action in handleMenuAction(action) }
        )
    }

    /// 镜片任务中心「Cancel」：单个活动任务直接取消；多个弹出编号选择卡（选择后按序号取消）。
    private func presentTaskCancellationFromMenu() {
        let tasks = session.activeTasks
        switch AgentTaskChoiceFlow.presentation(taskCount: tasks.count) {
        case .none:
            showIdleMenu()
        case .direct:
            handleTaskCommand(.cancelLatest)
            showIdleMenu()
        case .choose:
            AgentDisplayHub.shared.showChoice(
                options: AgentTaskChoiceFlow.optionLabels(from: tasks),
                iconName: "x",
                onSelect: { [self] index in
                    handleTaskCommand(.cancelTask(index))
                    showIdleMenu()
                },
                onCancel: { [self] in
                    showIdleMenu()
                }
            )
        }
    }

    /// 镜片任务中心「Progress」：单个活动任务直接播报；多个弹出编号选择卡（选择后播报该任务进度）。
    private func presentTaskProgressFromMenu() {
        let tasks = session.activeTasks
        switch AgentTaskChoiceFlow.presentation(taskCount: tasks.count) {
        case .none:
            showIdleMenu()
        case .direct:
            handleTaskCommand(.queryProgress)
            showIdleMenu()
        case .choose:
            AgentDisplayHub.shared.showChoice(
                options: AgentTaskChoiceFlow.optionLabels(from: tasks),
                iconName: "gear",
                onSelect: { [self] index in
                    handleTaskCommand(.queryProgressTask(index))
                    showIdleMenu()
                },
                onCancel: { [self] in
                    showIdleMenu()
                }
            )
        }
    }

    /// 镜片任务中心「Retry」：单个失败任务直接重试；多个弹出编号选择卡（选择后按序号重试）。
    private func presentTaskRetryFromMenu() {
        let tasks = session.failedTasks
        switch AgentTaskChoiceFlow.presentation(taskCount: tasks.count) {
        case .none:
            showIdleMenu()
        case .direct:
            handleTaskCommand(.retryLatest)
            showIdleMenu()
        case .choose:
            AgentDisplayHub.shared.showChoice(
                options: AgentTaskChoiceFlow.optionLabels(from: tasks),
                iconName: "two_arrows_clockwise",
                onSelect: { [self] index in
                    handleTaskCommand(.retryTask(index))
                    showIdleMenu()
                },
                onCancel: { [self] in
                    showIdleMenu()
                }
            )
        }
    }

    private func handleMenuAction(_ action: AgentDisplayAction) {
        switch action {
        case .wake:
            session.wake()
            AgentDisplayHub.shared.show(.listening)
            showTriggerBanner("agent.trigger.woke".localized)
        case .repeatLastReply:
            repeatLastReply()
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
        case .captureVision:
            Task { await captureAndSendVision() }
        case .ocr:
            Task { await runVoiceOCR() }
        case .translate:
            requestTranslateFromMenu()
        case .scene:
            Task { await runVoiceScene() }
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
        case .newChat:
            startNewVoiceChat()
            showIdleMenu()
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

    /// 眼镜菜单「Audit」：展示最近一条审计记录（4 秒后回退到回合状态）
    private func showLatestAudit() {
        guard let entry = AgentAuditStore.entries.first else {
            AgentDisplayHub.shared.showResult(
                title: "Audit",
                text: "agent.audit.empty".localized,
                fallback: turnMachine.phase
            )
            return
        }
        let content = AgentAuditDisplayMapping.resultContent(for: entry)
        AgentDisplayHub.shared.showResult(
            title: content.title,
            text: content.text,
            fallback: turnMachine.phase
        )
    }

    /// 重听最近一次内容（眼镜菜单 Repeat）：优先任务结果，其次助手回复
    private func repeatLastReply() {
        guard !session.isSpeaking else { return }
        let lastReply = latestReplayableText()
        guard !lastReply.isEmpty else {
            showTriggerBanner("agent.menu.repeat.empty".localized)
            AgentDisplayHub.shared.show(.idle)
            return
        }
        TTSService.shared.stop()
        TTSService.shared.speak(lastReply)
        AgentDisplayHub.shared.show(.idle)
        showTriggerBanner("agent.menu.repeat.done".localized)
    }

    /// 眼镜菜单「Ask」：对最新任务结果发起追问（结果上下文随追问消息前置给大脑）
    private func requestLensFollowUp() {
        guard session.hasFollowUpContext else {
            AgentDisplayHub.shared.showResult(
                title: "Ask",
                text: "agent.menu.followup.empty".localized,
                fallback: turnMachine.phase
            )
            return
        }
        forwardToBrain(session.followUpMessage("agent.menu.followup.prompt".localized))
        showTriggerBanner("agent.menu.followup.done".localized)
    }

    /// 眼镜菜单「Reminders」：列出即将触发的本地提醒，选中后播报
    private func showRemindersMenu() {
        let reminders = AgentReminderDisplayMapping.upcoming(AgentReminderStore.reminders)
        guard !reminders.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Reminders",
                text: "agent.reminder.lens.empty".localized,
                fallback: turnMachine.phase
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
    /// 随后镜片显示「Done / Delete / Cancel」操作卡，点按直接完成 / 删除并播报结果
    private func speakReminder(_ reminder: AgentReminder) {
        let text = AgentReminderDisplayMapping.resultText(for: reminder)
        AgentDisplayHub.shared.showResult(
            title: "Reminder",
            text: text,
            fallback: turnMachine.phase
        )
        if !session.isSpeaking {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
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
                    presentLensReminderResult(announcement)
                case 1:
                    guard let announcement = AgentReminderLensAction.delete(reminder) else { return }
                    presentLensReminderResult(announcement)
                default:
                    break
                }
            },
            onCancel: { [self] in showIdleMenu() }
        )
    }

    /// 镜片提醒操作结果：镜片结果卡 + 手机横幅 + TTS 确认（尊重语音播报开关）
    private func presentLensReminderResult(_ announcement: String) {
        AgentDisplayHub.shared.showResult(
            title: "Reminder",
            text: announcement,
            fallback: turnMachine.phase
        )
        showTriggerBanner(announcement)
        if AgentVoiceSettings.replyEnabled {
            TTSService.shared.stop()
            TTSService.shared.speak(announcement)
        }
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
                    fallback: turnMachine.phase
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
                    fallback: turnMachine.phase
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
            fallback: turnMachine.phase
        )
        if !session.isSpeaking {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
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
                    AgentDisplayHub.shared.showResult(
                        title: "Calendar",
                        text: text,
                        fallback: turnMachine.phase
                    )
                    showTriggerBanner(text)
                    if AgentVoiceSettings.replyEnabled {
                        TTSService.shared.stop()
                        TTSService.shared.speak(text)
                    }
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
                fallback: turnMachine.phase
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
            fallback: turnMachine.phase
        )
        if !session.isSpeaking {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
        showTriggerBanner(text)
    }

    /// 眼镜菜单「Lists」：列出用户命名清单（购物单 / 待办），选中后播报内容
    private func showListsMenu() {
        let lists = AgentListDisplayMapping.recentLists()
        guard !lists.isEmpty else {
            AgentDisplayHub.shared.showResult(
                title: "Lists",
                text: "agent.lists.lens.empty".localized,
                fallback: turnMachine.phase
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
            fallback: turnMachine.phase
        )
        if !session.isSpeaking {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
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
            fallback: turnMachine.phase
        )
        if !session.isSpeaking {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
        showTriggerBanner(text)
    }

    /// 点击任务卡片重听该任务的结果（优先详细结果，其次标题）
    private func replayTaskResult(_ task: QwenAgentTask) {
        guard !task.isActive, !session.isSpeaking, !TTSService.shared.isSpeaking else { return }
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

    /// 比较任务结果与助手回复的新旧，返回较新的可重听文本
    private func latestReplayableText() -> String {
        switch (session.lastTaskResultAt, session.lastAssistantReplyAt) {
        case let (taskResult?, assistantReply?):
            if taskResult > assistantReply, !session.lastTaskResultText.isEmpty {
                return session.lastTaskResultText
            }
            return session.lastAssistantText
        case (_?, nil):
            return session.lastTaskResultText
        case (nil, _):
            return session.lastAssistantText
        }
    }

    // MARK: - 大脑（听写转发）

    /// 当前选中的自定义 Agent 配置名（未选择时取列表首个）
    private var currentCustomAgentName: String {
        let configs = CustomAgentStore.configs
        if let id = AgentBrainSettings.selectedCustomAgentID,
           let config = configs.first(where: { $0.id == id }) {
            return config.name
        }
        return configs.first?.name ?? "custom.agent.brain.noconfig".localized
    }

    private func isSelectedCustomConfig(_ id: UUID) -> Bool {
        if let selected = AgentBrainSettings.selectedCustomAgentID {
            return selected == id
        }
        return CustomAgentStore.configs.first?.id == id
    }

    /// 应用大脑模式：调整网关输出、接管 OpenClaw 事件，必要时重启会话
    private func applyBrain(_ newBrain: AgentBrain) {
        let forwarding = AgentBrainRouter.isForwarding(to: newBrain)
        session.outputEnabled = !forwarding
        if newBrain == .openclaw || newBrain == .auto {
            openClawService.onChatEvent = { [self] snapshot in
                handleOpenClawChatEvent(snapshot)
            }
        } else {
            openClawService.onChatEvent = nil
        }
        if newBrain != .openclaw, newBrain != .auto {
            AgentBrainRouter.shared.cancel(to: newBrain)
        }
        guard session.isActive else { return }
        session.restart()
        if forwarding {
            turnMachine.turnStarted()
            AgentDisplayHub.shared.show(.listening)
        }
    }

    /// 发送 Siri / 快捷指令携带的直接指令：
    /// 转发大脑立即发送；Qwen 原生等网关连接就绪后发送（未连接时发送会被丢弃）。
    private func sendInitialInstruction(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if AgentBrainRouter.isForwarding(to: brain) {
            lastForwardedUserText = trimmed
            session.appendUserText(
                trimmed,
                label: "voice.intent.instruction.sent".localized,
                kind: .normal
            )
            // 结果追问上下文存在时，初始指令按「继续追问」包装（如锁屏回复 JARVIS）
            forwardToBrain(session.followUpMessage(trimmed))
            return
        }
        let instruction = trimmed
        let activeSession = session
        Task { @MainActor in
            // 最多等待 8 秒（每 200ms 探测一次），网关就绪后发送
            for _ in 0..<40 {
                if !activeSession.isActive { return }
                if activeSession.connectionState.isOnline { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard activeSession.isActive, activeSession.connectionState.isOnline else { return }
            activeSession.sendText(
                instruction,
                label: "voice.intent.instruction.sent".localized,
                kind: .normal
            )
        }
    }

    /// 转发用户文本给大脑（Hermes 流式 / OpenClaw 快照由事件回调驱动）。
    /// Auto 模式下按意图路由到具体大脑；target 可用于显式指定（如视野上下文）。
    private func forwardToBrain(_ text: String, target: AgentBrain? = nil) {
        let destination = target ?? AgentBrainRouter.resolvedBrain(text, selection: brain)
        guard destination != .qwen else { return }
        brainLiveText = ""
        hermesTool = nil
        if destination != .openclaw {
            enterThinking()
        }
        // 个性化规则：恒定行为约束，随每条转发消息携带（「我的规则」前缀，短、不占上下文）
        let message = AgentRulePromptBuilder.voicePrefix()
            .map { $0 + "\n" + text } ?? text
        // 视野连续追问：开关开启且本会话有最近画面帧时，转发自动携带（对齐聊天页）
        let attachVision = AgentVisionContextPolicy.shouldAttach(
            sendingImage: false,
            hasActiveContext: session.latestVisionFrame != nil,
            followUpEnabled: AgentVisionSettings.followUpEnabled
        )
        AgentBrainRouter.shared.forward(
            message,
            to: destination,
            image: attachVision ? session.latestVisionFrame : nil,
            onDelta: { [self] delta in
                brainLiveText += delta
            },
            onFinal: { [self] fullText in
                finishBrainReply(fullText)
            },
            onError: { [self] message in
                brainLiveText = ""
                hermesTool = nil
                if session.runningTaskCount == 0 {
                    AgentDisplayHub.shared.clearTaskProgress()
                }
                turnMachine.outputEnded()
                restoreIdleDisplay()
                showTriggerBanner(message)
            },
            onTool: { [self] tool in
                hermesTool = tool
                if turnMachine.phase == .thinking || turnMachine.phase == .listening {
                    AgentDisplayHub.shared.showTaskProgress(
                        count: 1,
                        title: thinkingToolHint(tool)
                    )
                }
            },
            onToolResult: { [self] _, output in
                // 服务端已执行的工具结果：thinking/聆听态上镜片（对齐聊天页）
                if !output.isEmpty,
                   turnMachine.phase == .thinking || turnMachine.phase == .listening {
                    AgentDisplayHub.shared.showResult(
                        title: "custom.agent.tool.result.title".localized,
                        text: String(output.prefix(200)),
                        fallback: turnMachine.phase
                    )
                }
            }
        )
    }

    /// 处理任务语音指令（进度播报 / 请求取消）。
    /// 返回 true 表示已拦截，不再转发给大脑。
    @discardableResult
    private func handleTaskCommand(_ command: AgentTaskCommand) -> Bool {
        guard let reply = AgentTaskCommandResponseBuilder.reply(
            for: command,
            session: session
        ) else { return false }
        session.appendAssistantText(reply)
        // 打断期间到达的指令回复：只入历史不播报（Repeat 菜单可重听）
        guard turnMachine.phase != .interrupted else {
            droppedReplyWhileInterrupted = true
            return true
        }
        turnMachine.outputStarted()
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .progress),
            text: reply,
            fallback: turnMachine.phase
        )
        if AgentVoiceSettings.replyEnabled {
            TTSService.shared.stop()
            TTSService.shared.speak(reply)
            // 播报结束（isSpeaking=false）时由 onChange 回到聆听
        } else {
            turnMachine.outputEnded()
            restoreIdleDisplay()
        }
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

    /// 处理语音本地指令（重听 / 新会话）。
    /// 返回 true 表示已拦截，不再转发给大脑。
    @discardableResult
    private func handleLocalCommand(_ command: AgentLocalCommand) -> Bool {
        switch command {
        case .repeatLastReply:
            // 打断期间到达的指令：不播报，恢复后可重听
            guard turnMachine.phase != .interrupted else {
                droppedReplyWhileInterrupted = true
                return true
            }
            repeatLastReply()
            return true
        case .newChat:
            startNewVoiceChat()
            return true
        case .endSession:
            // 持续在场模式下的显式退出；未开启时不拦截，正常转发给大脑
            guard AgentPresenceSettings.presenceEnabled else { return false }
            endVoiceSession()
            return true
        case .todayOverview:
            // 今日安排口令：本地组装播报（镜片 Today 同一实现）
            showTodayOverview()
            return true
        case .tomorrowOverview:
            // 明日安排口令：本地组装播报（镜片 Tomorrow 同一实现）
            showTomorrowOverview()
            return true
        }
    }

    /// 结束当前会话（持续在场模式的显式退出）：结束回合、停止会话、展示菜单
    private func endVoiceSession() {
        extractMemoryCandidates()
        cancelBrainReply()
        // 隐私生命周期：会话显式结束时丢弃本次保留的画面帧（取词/场景结果仍可跨页复用）
        lastVisionImage = nil
        session.latestVisionFrame = nil
        turnMachine.turnEnded()
        session.endSession()
        AgentDisplayHub.shared.clearTaskProgress()
        showIdleMenu()
        showTriggerBanner("agent.voice.end.done".localized)
    }

    /// 长任务自动进度播报（对齐 qwen-audio-agent v1.8.2）：
    /// 任务持续运行超阈值后主动汇报一次；镜片进度卡 + TTS（转发模式由 App 播报）
    private func handleProgressCheckIn(_ notice: QwenTaskProgressNotice?) {
        guard let notice else { return }
        AgentTaskLensPresenter.handleProgressCheckInChange(
            text: notice.text,
            runningTaskCount: session.runningTaskCount,
            announceByApp: AgentBrainRouter.isForwarding(to: brain),
            isSpeaking: session.isSpeaking,
            isInputActive: session.isInputActive,
            ttsSpeaking: TTSService.shared.isSpeaking
        )
        session.clearProgressCheckInNotice()
    }

    /// 显式记忆指令：存入长期记忆并播报确认
    /// 记忆语音指令：本地维护并播报确认，不转发给大脑
    private func handleMemoryCommand(_ command: AgentMemoryCommand) {
        switch command {
        case .remember(let memory):
            let saved = AgentMemoryStore.add(text: memory)
            let message = saved
                ? AgentProfileCommandReply.memoryRemembered(text: memory)
                : AgentProfileCommandReply.memoryDuplicate()
            showTriggerBanner(message)
            if saved, AgentVoiceSettings.replyEnabled {
                TTSService.shared.stop()
                TTSService.shared.speak("agent.memory.remembered.tts".localized)
            }
        case .query:
            announceVoiceFeedback(AgentProfileCommandReply.memoryQuery(
                entries: AgentMemoryStore.entries.map(\.text)
            ))
        case .forget(let text):
            let removed = AgentMemoryStore.remove(matching: text)
            let message = removed
                ? AgentProfileCommandReply.memoryForgot(text: text)
                : AgentProfileCommandReply.memoryForgetMissing()
            announceVoiceFeedback(message)
        }
    }

    /// 助手画像语音指令：查询播报身份；改名保存并确认。不转发大脑。
    private func handlePersonaCommand(_ command: AgentPersonaCommand) {
        switch command {
        case .query:
            announceVoiceFeedback(AgentPersonaPromptBuilder.spokenIdentity())
        case .setName(let name):
            let persona = AgentPersonaStore.current
            AgentPersonaStore.save(
                name: name,
                role: persona.role,
                style: persona.style,
                enabled: persona.enabled
            )
            announceVoiceFeedback(AgentProfileCommandReply.personaSet(name: name))
        }
    }

    /// 个性化规则语音指令：本地维护并播报确认，不转发给大脑
    private func handleRuleCommand(_ command: AgentRuleCommand) {
        switch command {
        case .add(let text):
            if AgentRuleStore.add(text: text) {
                announceVoiceFeedback(AgentProfileCommandReply.ruleAdded(text: text))
            } else if AgentRuleStore.entries.contains(where: { $0.text == text }) {
                announceVoiceFeedback(AgentProfileCommandReply.ruleDuplicate(text: text))
            } else {
                announceVoiceFeedback(AgentProfileCommandReply.ruleFull())
            }
        case .query:
            announceVoiceFeedback(AgentProfileCommandReply.ruleQuery(
                entries: AgentRuleStore.entries.map(\.text)
            ))
        case .remove(let text):
            let removed = AgentRuleStore.remove(text: text)
            announceVoiceFeedback(removed
                ? AgentProfileCommandReply.ruleRemoved(text: text)
                : AgentProfileCommandReply.ruleRemoveMissing())
        case .clear:
            AgentRuleStore.clear()
            announceVoiceFeedback(AgentProfileCommandReply.ruleCleared())
        }
    }

    /// 命名清单语音指令：本地维护并播报确认，不转发给大脑
    private func handleListCommand(_ command: AgentListCommand) {
        switch command {
        case .add(let item, let list):
            if let updated = AgentListStore.addItem(item, to: list) {
                announceVoiceFeedback(AgentListResponseText.added(item: item, to: updated.name))
            } else if AgentListStore.list(named: list)?.items.contains(item) == true {
                announceVoiceFeedback(AgentListResponseText.duplicate(item: item, in: list))
            } else {
                announceVoiceFeedback(AgentListResponseText.full(list: list))
            }
        case .remove(let item, let list):
            let existed = AgentListStore.list(named: list)?.items.contains(item) ?? false
            AgentListStore.removeItem(item, from: list)
            announceVoiceFeedback(
                existed
                    ? AgentListResponseText.removed(item: item, from: list)
                    : AgentListResponseText.missing(item: item, in: list)
            )
        case .query(let list):
            let items = AgentListStore.list(named: list)?.items ?? []
            announceVoiceFeedback(AgentListResponseText.query(list: list, items: items))
        case .queryIndex(let index):
            // 与镜片 Lists 子菜单同一排序基准（最近更新优先）
            let lists = AgentListDisplayMapping.recentLists(limit: AgentListStore.maxListCount)
            announceVoiceFeedback(AgentListResponseText.queryIndex(index: index, lists: lists))
        case .queryItem(let list, let index):
            let items = AgentListStore.list(named: list)?.items ?? []
            announceVoiceFeedback(AgentListResponseText.queryItem(list: list, index: index, items: items))
        case .queryItemByIndexes(let listIndex, let itemIndex):
            let lists = AgentListDisplayMapping.recentLists(limit: AgentListStore.maxListCount)
            announceVoiceFeedback(
                AgentListResponseText.queryItemByIndexes(
                    listIndex: listIndex,
                    itemIndex: itemIndex,
                    lists: lists
                )
            )
        case .rename(let list, let newName):
            if AgentListStore.renameList(named: list, to: newName) != nil {
                announceVoiceFeedback(AgentListResponseText.renamed(list: list, to: newName))
            } else if AgentListStore.list(named: newName) != nil {
                announceVoiceFeedback(AgentListResponseText.renameDuplicate(name: newName))
            } else {
                announceVoiceFeedback(AgentListResponseText.renameNotFound(list: list))
            }
        case .clear(let list):
            AgentListStore.clearItems(named: list)
            announceVoiceFeedback(AgentListResponseText.cleared(list: list))
        }
    }

    /// 本地指令即时反馈：横幅 + TTS 播报（用户刚说完话，立即确认）
    private func announceVoiceFeedback(_ message: String) {
        showTriggerBanner(message)
        if AgentVoiceSettings.replyEnabled {
            TTSService.shared.stop()
            TTSService.shared.speak(message)
        }
    }

    /// 本地提醒指令：调度系统通知并播报确认，不转发给大脑
    private func handleReminderCommand(_ command: AgentReminderCommand) {
        switch command {
        case .set(let text, let fireDate, let repeatRule):
            Task { @MainActor in
                guard await AgentReminderScheduler.requestAuthorization() else {
                    announceVoiceFeedback("agent.reminder.denied".localized)
                    return
                }
                guard let reminder = AgentReminderStore.add(
                    text: text,
                    fireDate: fireDate,
                    repeatRule: repeatRule
                ) else {
                    announceVoiceFeedback("agent.reminder.full".localized)
                    return
                }
                AgentReminderScheduler.schedule(reminder)
                let when = AgentReminderTimeFormatter.announcementDescription(for: reminder)
                announceVoiceFeedback(String(format: "agent.reminder.set".localized, when, text))
            }
        case .cancel(let text):
            if let text {
                let matched = AgentReminderStore.reminders.filter { $0.text.contains(text) }
                guard !matched.isEmpty else {
                    announceVoiceFeedback(String(format: "agent.reminder.cancel.none".localized, text))
                    return
                }
                for reminder in matched {
                    AgentReminderScheduler.cancel(id: reminder.id)
                }
                AgentReminderStore.remove(matching: text)
                announceVoiceFeedback(String(format: "agent.reminder.cancelled".localized, matched.count))
            } else {
                AgentReminderScheduler.cancelAll()
                AgentReminderStore.clear()
                announceVoiceFeedback("agent.reminder.cancelled.all".localized)
            }
        case .complete(let text):
            if let text {
                let matched = AgentReminderStore.reminders.filter { $0.text.contains(text) }
                guard !matched.isEmpty else {
                    announceVoiceFeedback(AgentReminderCompletion.noneText(for: text))
                    return
                }
                for reminder in matched {
                    AgentReminderScheduler.cancel(id: reminder.id)
                    AgentReminderStore.remove(id: reminder.id)
                }
                announceVoiceFeedback(matched.count == 1
                    ? AgentReminderCompletion.completedText(for: matched[0].text)
                    : AgentReminderCompletion.completedAllText(count: matched.count))
            } else {
                let count = AgentReminderStore.reminders.count
                guard count > 0 else {
                    announceVoiceFeedback(AgentReminderCompletion.noneAnyText())
                    return
                }
                AgentReminderScheduler.cancelAll()
                AgentReminderStore.clear()
                announceVoiceFeedback(AgentReminderCompletion.completedAllText(count: count))
            }
        case .query:
            let reminders = AgentReminderStore.reminders
            if reminders.isEmpty {
                announceVoiceFeedback("agent.reminder.query.empty".localized)
            } else {
                let now = Date()
                let lines = reminders.map { reminder in
                    let when = AgentReminderTimeFormatter.announcementDescription(for: reminder, now: now)
                    return String(format: "agent.reminder.query.item".localized, when, reminder.text)
                }
                announceVoiceFeedback(lines.joined(separator: "，"))
            }
        }
    }

    /// 会话结束时从转写提炼记忆候选（自动去重；有新增时提示去设置页审阅）
    private func extractMemoryCandidates() {
        guard AgentMemorySettings.enabled else { return }
        let texts = session.transcriptLog
            .filter { $0.role == .user }
            .map(\.text)
        let extracted = AgentMemoryExtractor.extractCandidates(from: texts)
        guard !extracted.isEmpty else { return }
        let before = AgentMemoryCandidateStore.candidates.count
        AgentMemoryCandidateStore.append(extracted.map { text in
            let source = texts.first(where: { $0.contains(text) }) ?? text
            return AgentMemoryCandidate(text: text, source: source)
        })
        if AgentMemoryCandidateStore.candidates.count > before {
            showTriggerBanner("agent.memory.candidates.new".localized)
        }
    }

    /// 眼镜断连后重新可用：提示「单击恢复交互」，会话已结束时在镜片给出恢复入口
    private func handleDeviceReconnected() {
        AgentTriggerFeedback.play(for: .tapResume)
        showTriggerBanner("agent.trigger.reconnected".localized)
        guard !session.isActive || turnMachine.phase == .idle else { return }
        AgentDisplayHub.shared.showMenu(
            actions: [.wake, .dismiss],
            onSelect: { [self] action in handleMenuAction(action) }
        )
    }

    /// 开始新会话：当前会话先落盘到「记录」，再清空转写与任务状态
    private func startNewVoiceChat() {
        extractMemoryCandidates()
        cancelBrainReply()
        persistVoiceConversation()
        session.clearTranscriptLog()
        session.clearTaskFeed()
        lastForwardedUserText = ""
        AgentDisplayHub.shared.clearTaskProgress()
        showTriggerBanner("agent.voice.newchat.done".localized)
    }

    /// 大脑回复完成：写入转写、播报、回到聆听
    private func finishBrainReply(_ fullText: String) {
        cancelThinkingHint()
        brainLiveText = ""
        hermesTool = nil
        if session.runningTaskCount == 0 {
            AgentDisplayHub.shared.clearTaskProgress()
        }
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            session.appendAssistantText(trimmed)
            // 打断期间到达的迟到回复：只入历史不播报（Repeat 菜单可重听）
            guard turnMachine.phase != .interrupted else {
                droppedReplyWhileInterrupted = true
                return
            }
            turnMachine.outputStarted()
            AgentDisplayHub.shared.show(.speaking)
            if AgentVoiceSettings.replyEnabled {
                TTSService.shared.speak(trimmed)
                // 播报结束（isSpeaking=false）时由 onChange 回到聆听
            } else {
                turnMachine.outputEnded()
                restoreIdleDisplay()
            }
        } else {
            guard turnMachine.phase != .interrupted else { return }
            turnMachine.outputEnded()
            restoreIdleDisplay()
        }
    }

    /// 回到聆听态：若仍有后台任务，优先展示任务进度而不是 Listening
    /// 会话空闲时把待弹审批卡补弹出来：恢复超时计时 → 切 approval 态 → 语音提醒 → 镜片卡
    private func reevaluateDeferredApproval() {
        guard let deferred = deferredApproval,
              deferred.id == session.pendingPermission?.id else {
            deferredApproval = nil
            return
        }
        guard !AgentApprovalDeferralPolicy.shouldDefer(
            phase: turnMachine.phase,
            isInputActive: session.isInputActive,
            isSpeaking: session.isSpeaking,
            ttsSpeaking: TTSService.shared.isSpeaking
        ) else { return }
        session.resumePermissionTimeout()
        deferredApproval = nil
        presentApproval(deferred)
    }

    /// 立即弹出审批卡：切 approval 态 → 语音提醒（大脑转发模式，走播报窗口）→ 镜片卡
    private func presentApproval(_ pending: QwenPermissionRequest) {
        turnMachine.permissionRequested()
        // 审批到达语音提示（大脑转发模式网关不播报输出，用 TTS 提醒用户看镜片）
        if AgentBrainRouter.isForwarding(to: brain),
           AgentVoiceSettings.replyEnabled,
           AgentVoiceSettings.approvalPromptEnabled,
           AgentQuietAnnouncementPolicy.shouldSpeakProactive(),
           !TTSService.shared.isSpeaking,
           !session.isSpeaking,
           !session.isInputActive {
            TTSService.shared.speak("qwen.permission.title".localized)
        }
        // 眼镜端审批卡：Allow/Deny 需显式导航点击（非镜腿单击），直接提交决策
        AgentDisplayHub.shared.showPermission(
            summary: pending.permission.summary,
            onAllow: { [self] in
                Task {
                    // 决策成功才展示反馈，避免失败/超时场景残留过期反馈
                    if await session.respondToPermission(.allow) {
                        pendingApprovalFeedback = AgentApprovalFeedbackMapping.feedback(for: .allow)
                    }
                }
            },
            onDeny: { [self] in
                Task {
                    if await session.respondToPermission(.deny) {
                        pendingApprovalFeedback = AgentApprovalFeedbackMapping.feedback(for: .deny)
                    }
                }
            },
            onLater: { [self] in
                // 稍后处理：收起审批卡不发送决策，网关可能稍后再问
                session.dismissPermission()
            }
        )
    }

    private func restoreIdleDisplay() {
        // 结果摘要展示期间不覆盖（其 4 秒后会自动回退）
        guard session.completionNotice == nil else { return }
        if session.runningTaskCount > 0 {
            AgentDisplayHub.shared.showTaskProgress(
                count: session.runningTaskCount,
                title: session.taskMessage
            )
        } else {
            AgentDisplayHub.shared.show(turnMachine.phase)
        }
    }

    /// OpenClaw 聊天事件快照（流式增量 / [[FINAL]] 结束）
    private func handleOpenClawChatEvent(_ snapshot: String) {
        let parsed = AgentBrainEventParser.parseOpenClawEvent(snapshot)
        if parsed.isFinal {
            finishBrainReply(parsed.text)
        } else {
            if brainLiveText.isEmpty {
                enterThinking()
            }
            brainLiveText += parsed.text
        }
    }

    /// 进入思考阶段：眼镜显示 thinking，8 秒无回复时语音/横幅提示"还在处理"
    private func enterThinking() {
        turnMachine.outputStarted()
        // 任务/工具进行中：优先展示任务进度，避免 Thinking 与进度显示来回切换
        if session.runningTaskCount > 0, let message = session.taskMessage, !message.isEmpty {
            AgentDisplayHub.shared.showTaskProgress(
                count: session.runningTaskCount,
                title: message
            )
        } else {
            AgentDisplayHub.shared.show(.thinking)
        }
        thinkingHintTask?.cancel()
        thinkingHintTask = Task { @MainActor in
            let delay = AgentTimingSettings.thinkingHintDelay
            guard delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard turnMachine.phase == .thinking, session.isActive else { return }
            let hint = latestThinkingHint()
            if AgentVoiceSettings.replyEnabled,
               AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                TTSService.shared.speak(hint)
            }
            showTriggerBanner(hint)
        }
    }

    /// 思考超时提示文案：后台任务进行中时播报最新任务状态，否则用通用文案
    private func latestThinkingHint() -> String {
        if session.runningTaskCount > 0,
           let message = session.taskMessage,
           !message.isEmpty {
            return message
        }
        if let tool = hermesTool, !tool.isEmpty {
            return thinkingToolHint(tool)
        }
        return "agent.thinking.hint".localized
    }

    /// Hermes 工具执行的提示文案（眼镜显示与超时播报共用）
    private func thinkingToolHint(_ tool: String) -> String {
        "agent.thinking.tool".localized(tool)
    }

    /// 取消 thinking 超时提示（回复到达/打断/结束时调用）
    private func cancelThinkingHint() {
        thinkingHintTask?.cancel()
        thinkingHintTask = nil
    }

    /// 取消进行中的大脑回复（打断/结束时调用）
    private func cancelBrainReply() {
        cancelThinkingHint()
        brainLiveText = ""
        hermesTool = nil
        if session.runningTaskCount == 0 {
            AgentDisplayHub.shared.clearTaskProgress()
        }
        TTSService.shared.stop()
        AgentBrainRouter.shared.cancel(to: brain)
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

    /// 历史落盘/恢复使用的 Agent 标识（Custom Agent 大脑按配置 ID 归类）
    private var historyAgentName: String {
        AgentVoiceHistoryNaming.agentName(
            brain: brain,
            customConfig: AgentBrainRouter.customAgentConfig()
        )
    }

    /// 从 Hub 直接进入的语音会话，结束时把转写落盘到「记录」。
    /// 从 AgentChat 进入的会话已在返回时回填聊天（并清空日志），不会重复保存。
    private func persistVoiceConversation() {
        guard !isEmbeddedInChat else { return }
        let importer = AgentTranscriptImport(
            transcriptLog: session.transcriptLog,
            taskFeed: session.taskFeed
        )
        guard importer.hasContent else { return }
        let messages = importer.makeMessages().map { (role: $0.role, text: $0.text) }
        guard let record = AgentConversationPersister.makeRecord(
            transcriptMessages: messages,
            agentName: historyAgentName
        ) else { return }
        ConversationStorage.shared.saveConversation(record)
        session.clearTranscriptLog()
        session.clearTaskFeed()
    }

    /// 恢复历史语音会话记录（仅显示层，开始新会话时不清空）。
    /// force 用于用户切换历史会话时强制重载。
    private func restorePreviousHistory(force: Bool = false) {
        if !force, !restoredHistory.isEmpty { return }
        // 会话记忆关闭时不再自动恢复历史；从 Hub 明确点开的会话仍恢复
        guard force || AgentMemorySettings.voiceHistoryEnabled || initialHistoryRecordID != nil else {
            historyRecords = []
            restoredHistory = []
            return
        }
        historyRecords = Array(
            ConversationStorage.shared.loadAllConversations()
                .filter { $0.aiModel == historyAgentName }
                .prefix(10)
        )
        guard let record = historyRecords.first(where: { $0.id == selectedHistoryRecordID }) ?? historyRecords.first else {
            return
        }
        let messages = AgentConversationPersister.loadMessages(
            from: [record],
            agentName: historyAgentName
        )
        restoredHistory = messages.map { message in
            QwenTranscriptItem(
                role: message.role == "user" ? .user : .assistant,
                text: message.text
            )
        }
    }

    /// 当前选中历史会话的标题（未选中时为最新一条）
    private var selectedHistoryTitle: String {
        if let id = selectedHistoryRecordID,
           let record = historyRecords.first(where: { $0.id == id }) {
            return record.title
        }
        return historyRecords.first?.title ?? ""
    }
}

#if DEBUG
@MainActor
private struct QwenVoicePreview: View {
    @StateObject private var dependencies = PreviewDependencies()

    var body: some View {
        QwenVoiceView(streamViewModel: dependencies.streamViewModel)
    }
}

#Preview("Qwen Voice") {
    QwenVoicePreview()
}
#endif
