/*
 * Hyper Meta AI Home View
 * 主页 - 功能入口
 */

import SwiftUI
import EventKit

struct HyperMetaAIHomeView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    let apiKey: String

    @State private var showLiveAI = false
    @State private var showLiveStream = false
    @State private var showRTMPStreaming = false
    @State private var showLeanEat = false
    @State private var showQuickVision = false
    @State private var showLiveTranslate = false
    @State private var showAgents = false
    @State private var showVoiceAssistant = false
    @ObservedObject private var navigationRouter = AppNavigationRouter.shared
    @State private var voiceAssistantRequest: VoiceAssistantRequest?
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @ObservedObject private var hermesService = HermesService.shared
    @ObservedObject private var liveAIManager = LiveAIManager.shared
    @ObservedObject private var voiceAssistantRouter = VoiceAssistantRouter.shared
    @State private var calendarLine = ""
    @State private var calendarPlaceholder = true
    @State private var calendarCount = 0
    @State private var reminderLine = ""
    @State private var reminderPlaceholder = true
    @State private var reminderCount = 0
    /// 提醒概览 Sheet（主页直达完成 / 删除，与镜片 / 锁屏同一语义）
    @State private var showRemindersOverview = false
    /// 今日日程概览 Sheet（主页直达查看 / 删除今日日程）
    @State private var showCalendarOverview = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        AppColors.primary.opacity(0.1),
                        AppColors.secondary.opacity(0.1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppSpacing.lg) {
                        // Header
                        VStack(spacing: AppSpacing.sm) {
                            Text("app.name".localized)
                                .font(AppTypography.largeTitle)
                                .foregroundColor(AppColors.textPrimary)

                            Text("app.subtitle".localized)
                                .font(AppTypography.callout)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding(.top, AppSpacing.xl)

                        // 今日安排双卡：日程 + 提醒（点按深链到对应设置分区）
                        HStack(spacing: AppSpacing.md) {
                            HomeInfoCard(
                                icon: "calendar",
                                tint: .red,
                                title: "home.calendar.title".localized,
                                line: calendarLine,
                                isPlaceholder: calendarPlaceholder,
                                badge: calendarCount
                            ) {
                                // 有日程时弹概览 Sheet 快速查看 / 删除；空态 / 未授权直接深链设置页
                                if calendarCount > 0 {
                                    showCalendarOverview = true
                                } else {
                                    AppNavigationRouter.shared.request(.agentSettings(.calendar))
                                }
                            }
                            HomeInfoCard(
                                icon: "alarm",
                                tint: .yellow,
                                title: "home.reminder.title".localized,
                                line: reminderLine,
                                isPlaceholder: reminderPlaceholder,
                                badge: reminderCount
                            ) {
                                // 有提醒时弹概览 Sheet 快速操作；空态直接深链设置页
                                if reminderCount > 0 {
                                    showRemindersOverview = true
                                } else {
                                    AppNavigationRouter.shared.request(.agentSettings(.reminders))
                                }
                            }
                        }
                        .padding(.horizontal, AppSpacing.lg)

                        // Feature Grid
                        VStack(spacing: AppSpacing.md) {
                            // Row 1
                            HStack(spacing: AppSpacing.md) {
                                FeatureCard(
                                    title: "home.liveai.title".localized,
                                    subtitle: "home.liveai.subtitle".localized,
                                    icon: "brain.head.profile",
                                    gradient: [AppColors.liveAI, AppColors.liveAI.opacity(0.7)]
                                ) {
                                    showLiveAI = true
                                }

                                FeatureCard(
                                    title: "home.quickvision.title".localized,
                                    subtitle: "home.quickvision.subtitle".localized,
                                    icon: "eye.circle.fill",
                                    gradient: [Color.purple, Color.purple.opacity(0.7)]
                                ) {
                                    showQuickVision = true
                                }
                            }

                            // Row 2
                            HStack(spacing: AppSpacing.md) {
                                FeatureCard(
                                    title: "home.translate.title".localized,
                                    subtitle: "home.translate.subtitle".localized,
                                    icon: "globe",
                                    gradient: [Color.teal, Color.teal.opacity(0.7)]
                                ) {
                                    showLiveTranslate = true
                                }

                                FeatureCard(
                                    title: "home.agents.title".localized,
                                    subtitle: agentsStatusSubtitle,
                                    icon: "square.stack.3d.up.fill",
                                    gradient: [Color.purple, Color.teal]
                                ) {
                                    showAgents = true
                                }
                            }

                            // Row 3 - RTMP Streaming (Experimental)
                            FeatureCardWide(
                                title: "home.rtmp.title".localized,
                                subtitle: "home.rtmp.subtitle".localized,
                                icon: "antenna.radiowaves.left.and.right",
                                gradient: [Color.red, Color.orange],
                                badge: "home.experimental".localized
                            ) {
                                showRTMPStreaming = true
                            }

                            // Row 4 - Screen Recording Stream
                            FeatureCardWide(
                                title: "home.livestream.title".localized,
                                subtitle: "home.livestream.subtitle".localized,
                                icon: "video.fill",
                                gradient: [AppColors.liveStream, AppColors.liveStream.opacity(0.7)]
                            ) {
                                showLiveStream = true
                            }

                            // Row 5 - LeanEat
                            FeatureCardWide(
                                title: "home.leaneat.title".localized,
                                subtitle: "home.leaneat.subtitle".localized,
                                icon: "chart.bar.fill",
                                gradient: [AppColors.leanEat, AppColors.leanEat.opacity(0.7)]
                            ) {
                                showLeanEat = true
                            }
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xl)
                    }
                }
                .safeAreaPadding(.bottom, 72)
            }
            .overlay(alignment: .bottom) {
                Color(uiColor: .systemBackground)
                    .frame(height: 110)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
            .refreshable {
                // 下拉刷新：重新拉取今日日程与提醒（Apple 原生手势反馈）
                await refreshHomeCards()
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showLiveAI) {
                LiveAIView(streamViewModel: streamViewModel, apiKey: apiKey)
            }
            .fullScreenCover(isPresented: $showLiveStream) {
                SimpleLiveStreamView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showRTMPStreaming) {
                RTMPStreamingView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showLeanEat) {
                StreamView(viewModel: streamViewModel, wearablesVM: wearablesViewModel)
            }
            .fullScreenCover(isPresented: $showQuickVision) {
                QuickVisionView(streamViewModel: streamViewModel, apiKey: apiKey)
            }
            .fullScreenCover(isPresented: $showLiveTranslate) {
                LiveTranslateView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showAgents) {
                AgentHubView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showVoiceAssistant) {
                QwenVoiceView(
                    streamViewModel: streamViewModel,
                    initialBrain: voiceAssistantRequest?.brain,
                    initialInstruction: voiceAssistantRequest?.instruction,
                    initialFollowUpContext: voiceAssistantRequest?.followUpContext
                )
            }
        }
        .sheet(isPresented: $showRemindersOverview) {
            HomeReminderOverviewSheet {
                Task { await refreshHomeCards() }
            }
        }
        .sheet(isPresented: $showCalendarOverview) {
            HomeCalendarOverviewSheet {
                Task { await refreshHomeCards() }
            }
        }
        .task {
            await loadCalendarCard()
            loadReminderCard()
        }
        .onAppear {
            presentLiveAIIfRequested()
            presentVoiceAssistantIfRequested()
        }
        .onChange(of: liveAIManager.isPresentationRequested) { _, _ in
            presentLiveAIIfRequested()
        }
        .onChange(of: voiceAssistantRouter.isVoiceSessionRequested) { _, _ in
            presentVoiceAssistantIfRequested()
        }
        .onChange(of: navigationRouter.pendingDestination) { _, _ in
            presentAgentHubIfRequested()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 回到前台：设置页授权 / 系统日历外部变更后立即刷新双卡
            guard newPhase == .active else { return }
            Task { await refreshHomeCards() }
        }
        .onReceive(AgentHomeCardRefreshCenter.publisher) { _ in
            // 提醒 / 日程数据在任何入口变更后即时刷新
            Task { await refreshHomeCards() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            // 外部日历变更（系统日历 App / 其它设备同步）后刷新日程卡
            Task { await refreshHomeCards() }
        }
    }

    /// 幂等刷新双卡：日历异步拉取，提醒同步读取；供下拉刷新 / 信号 / 回前台调用
    private func refreshHomeCards() async {
        await loadCalendarCard()
        loadReminderCard()
    }

    /// 静默拉取今日日程（不请求权限），映射为卡片内容
    private func loadCalendarCard() async {
        let events = await AgentCalendarDisplayMapping.upcomingEventsForMenu(
            provider: AgentCalendar.provider
        )
        let content = AgentHomeCalendarCardMapping.content(
            events: events,
            authorized: AgentCalendar.provider.authorization == .authorized
        )
        calendarLine = content.line
        calendarPlaceholder = content.isPlaceholder
        calendarCount = content.count
    }

    /// 取最近一条提醒映射为卡片内容（存储同步读取）
    private func loadReminderCard() {
        let content = AgentHomeReminderCardMapping.content(
            reminders: AgentReminderStore.reminders
        )
        reminderLine = content.line
        reminderPlaceholder = content.isPlaceholder
        reminderCount = content.count
    }

    private var agentsStatusSubtitle: String {
        let openClawOnline = openClawService.connectionState == .connected
        let hermesOnline = hermesService.connectionState.isOnline
        if openClawOnline || hermesOnline {
            return "agents.status.connected".localized
        }
        return "home.agents.subtitle".localized
    }

    private func presentAgentHubIfRequested() {
        guard let destination = navigationRouter.pendingDestination else { return }
        switch destination {
        case .agentHub:
            // 任务通知「查看结果」深链：弹出 Agent Hub
            navigationRouter.consume(where: { $0 == .agentHub })
            showAgents = true
        case .conversation:
            // 对话记录深链（结果通知 / Spotlight）：弹出 Agent Hub，记录详情由 Hub 消费
            showAgents = true
        default:
            break
        }
    }

    private func presentLiveAIIfRequested() {
        guard liveAIManager.isPresentationRequested else { return }
        liveAIManager.consumePresentationRequest()
        showLiveAI = true
    }

    private func presentVoiceAssistantIfRequested() {
        guard let request = voiceAssistantRouter.consumeVoiceSessionRequest() else { return }
        voiceAssistantRequest = request
        showVoiceAssistant = true
    }
}

// MARK: - Feature Card

struct FeatureCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    var isPlaceholder: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.md) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text
                VStack(spacing: AppSpacing.xs) {
                    Text(title)
                        .font(AppTypography.headline)
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                if isPlaceholder {
                    Text("home.comingsoon".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs)
                        .background(.white.opacity(0.2))
                        .cornerRadius(AppCornerRadius.sm)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        }
        .disabled(isPlaceholder)
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Feature Card Wide

struct FeatureCardWide: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.lg) {
                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(title)
                        .font(AppTypography.title2)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(subtitle)
                        .font(AppTypography.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let badge = badge {
                        Text(badge)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.25))
                            .cornerRadius(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize()
            }
            .padding(AppSpacing.lg)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
  }
}

#if DEBUG
@MainActor
private struct HyperMetaAIHomePreview: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    HyperMetaAIHomeView(
      streamViewModel: dependencies.streamViewModel,
      wearablesViewModel: dependencies.wearablesViewModel,
      apiKey: ""
    )
  }
}

#Preview("Feature Dashboard") {
  HyperMetaAIHomePreview()
}
#endif

// MARK: - Home Info Card

/// 主页信息卡（今日日程 / 下次提醒）：图标 + 标题 + 单行内容，占位态弱化显示
private struct HomeInfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let line: String
    let isPlaceholder: Bool
    /// 数量徽标（> 0 显示，如「今天 3 场」「3 条」）
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundColor(tint)
                    }
                    Spacer()
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(tint.opacity(0.15))
                            .clipShape(Capsule())
                            .accessibilityLabel(String(format: "home.card.badge".localized, badge))
                    }
                }
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                Text(line)
                    .font(AppTypography.subheadline)
                    .foregroundColor(isPlaceholder ? AppColors.textSecondary : AppColors.textPrimary)
                    .lineLimit(1)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.lg, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + "，" + line)
    }
}


// MARK: - 提醒概览 Sheet

/// 主页提醒概览：点提醒卡弹出，列表内一键完成 / 滑动删除（与镜片 / 锁屏同一语义）。
/// 完成 = 移除存储 + 取消通知调度；数据变更回调 onChanged 让主页双卡即时刷新。
private struct HomeReminderOverviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 数据变更后回调（主页刷新双卡）
    let onChanged: () -> Void

    @State private var reminders = AgentReminderStore.reminders
    @State private var completingIDs: Set<UUID> = []
    @State private var completionTasks: [UUID: Task<Void, Never>] = [:]
    @State private var completionTicks = 0

    var body: some View {
        NavigationStack {
            List {
                if reminders.isEmpty {
                    Text("agent.reminder.empty".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                ForEach(reminders) { reminder in
                    let isCompleting = completingIDs.contains(reminder.id)
                    HStack(spacing: 10) {
                        Button {
                            if isCompleting {
                                undoCompletion(reminder)
                            } else {
                                completeReminder(reminder)
                            }
                        } label: {
                            Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(isCompleting ? .green : Color(.tertiaryLabel))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            isCompleting
                                ? "agent.reminder.undo".localized
                                : "agent.reminder.action.complete".localized
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.text)
                                .font(.system(size: 15))
                                .strikethrough(isCompleting)
                            Text(AgentReminderTimeFormatter.announcementDescription(for: reminder))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .strikethrough(isCompleting)
                                .opacity(isCompleting ? 0.5 : 1)
                        }
                        .foregroundColor(isCompleting ? .secondary : .primary)
                        Spacer()
                        if isCompleting {
                            Button("agent.reminder.undo".localized) {
                                undoCompletion(reminder)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let reminder = reminders[index]
                        AgentReminderScheduler.cancel(id: reminder.id)
                        AgentReminderStore.remove(id: reminder.id)
                    }
                    reminders = AgentReminderStore.reminders
                    onChanged()
                }
            }
            .navigationTitle("home.reminder.overview.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("home.reminder.overview.manage".localized) {
                        dismiss()
                        AppNavigationRouter.shared.request(.agentSettings(.reminders))
                    }
                }
            }
            .sensoryFeedback(.success, trigger: completionTicks)
            .onAppear {
                reminders = AgentReminderStore.reminders
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 完成：划线过渡 + 短暂窗口撤销，到时移除存储并取消通知调度
    private func completeReminder(_ reminder: AgentReminder) {
        withAnimation(.snappy(duration: 0.25)) {
            completingIDs.insert(reminder.id)
        }
        completionTicks += 1
        completionTasks[reminder.id]?.cancel()
        completionTasks[reminder.id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            AgentReminderScheduler.cancel(id: reminder.id)
            AgentReminderStore.remove(id: reminder.id)
            withAnimation(.snappy(duration: 0.25)) {
                completingIDs.remove(reminder.id)
                completionTasks[reminder.id] = nil
            }
            reminders = AgentReminderStore.reminders
            onChanged()
        }
    }

    /// 撤销刚标记的完成（过渡窗口内）
    private func undoCompletion(_ reminder: AgentReminder) {
        completionTasks[reminder.id]?.cancel()
        completionTasks[reminder.id] = nil
        withAnimation(.snappy(duration: 0.25)) {
            completingIDs.remove(reminder.id)
        }
    }
}


// MARK: - 今日日程概览 Sheet

/// 主页今日日程概览：点日程卡弹出，列出今天未结束日程；
/// 左滑删除（确认对话框 → EventKit 删除 → 触觉反馈与主页双卡刷新），右上角「管理全部」深链设置页。
private struct HomeCalendarOverviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 数据变更后回调（主页刷新双卡）
    let onChanged: () -> Void

    @State private var events: [AgentCalendarEvent] = []
    @State private var loaded = false
    @State private var deleteCandidate: AgentCalendarEvent?
    @State private var detailEvent: AgentCalendarEvent?
    @State private var errorMessage: String?
    @State private var deletedTicks = 0

    var body: some View {
        NavigationStack {
            List {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                } else if events.isEmpty {
                    Text("home.calendar.empty".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                ForEach(events.indices, id: \.self) { index in
                    Button {
                        detailEvent = events[index]
                    } label: {
                        Text(AgentCalendarFormatter.eventLine(events[index], now: Date()))
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    if let first = offsets.first {
                        deleteCandidate = events[first]
                    }
                }
            }
            .navigationTitle("home.calendar.overview.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("home.calendar.overview.manage".localized) {
                        dismiss()
                        AppNavigationRouter.shared.request(.agentSettings(.calendar))
                    }
                }
            }
            .task {
                guard !loaded else { return }
                await loadEvents()
            }
            .confirmationDialog(
                AgentCalendarDetailDeleteAction.confirmTitle(),
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { event in
                Button(AgentCalendarDetailDeleteAction.confirmActionTitle(), role: .destructive) {
                    Task { await delete(event) }
                }
                Button(AgentCalendarDetailDeleteAction.cancelTitle(), role: .cancel) {
                    deleteCandidate = nil
                }
            } message: { event in
                Text(AgentCalendarDetailDeleteAction.confirmMessage(for: event))
            }
            .sheet(
                isPresented: Binding(
                    get: { detailEvent != nil },
                    set: { if !$0 { detailEvent = nil } }
                ),
                onDismiss: {
                    // 详情卡删除 / 设为提醒后刷新概览与主页双卡
                    Task { await loadEvents() }
                    onChanged()
                }
            ) {
                if let event = detailEvent {
                    CalendarEventDetailSheet(event: event, provider: AgentCalendar.provider) {
                        onChanged()
                    }
                }
            }
            .alert(
                AgentCalendarDetailDeleteAction.errorTitle(),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("agent.memory.ok".localized, role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sensoryFeedback(.success, trigger: deletedTicks)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 静默拉取今天未结束的日程（未授权为空 → 空态引导）
    @MainActor
    private func loadEvents() async {
        events = await AgentCalendarDisplayMapping.upcomingEventsForMenu(
            provider: AgentCalendar.provider
        )
        loaded = true
    }

    /// 执行删除：成功移除行 + 触觉 + 主页刷新；失败弹明确提示
    private func delete(_ event: AgentCalendarEvent) async {
        let deleted = await AgentCalendarDetailDeleteAction.performDelete(
            event: event,
            provider: AgentCalendar.provider
        )
        deleteCandidate = nil
        if deleted {
            deletedTicks += 1
            withAnimation(.snappy(duration: 0.25)) {
                events.removeAll {
                    $0.title == event.title && $0.start == event.start
                }
            }
            onChanged()
        } else {
            errorMessage = AgentCalendarDetailDeleteAction.failureMessage()
        }
    }
}
