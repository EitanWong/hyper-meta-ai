/*
 * Agent Live Activity Manager
 * 把任务进度 / 审批状态 / 提醒倒计时映射为锁屏与灵动岛的 Live Activity（iOS 16.1+）。
 * 纯映射逻辑 AgentLiveActivityStateMapper 可单测；ActivityKit 调用全部容错：
 * 系统未授权 / 模拟器 / 开关关闭时静默降级，不影响 App 内现有呈现。
 * 多内容共存时按优先级展示：审批 > 提醒倒计时 > 任务进度 > 结果卡（瞬时）。
 */

import ActivityKit
import Foundation

/// 任务 / 审批 / 提醒状态 → Live Activity 内容的纯映射（不依赖 ActivityKit 运行时，可测）
enum AgentLiveActivityStateMapper {
    /// 任务进度内容：count 为 0 返回 nil（不展示）；step 为空时详情显示进行中
    static func taskContent(
        count: Int,
        step: String?
    ) -> AgentLiveActivityAttributes.ContentState? {
        guard count > 0 else { return nil }
        let title = count == 1
            ? "agent.liveactivity.task.title.single".localized
            : "agent.liveactivity.task.title.plural".localized(count)
        return AgentLiveActivityAttributes.ContentState(
            mode: .taskProgress,
            title: title,
            detail: step?.isEmpty == false ? step! : "agent.liveactivity.task.detail.default".localized,
            taskCount: count,
            approvalExpiresAt: nil,
            countdownFireDate: nil,
            resultKind: nil
        )
    }

    /// 审批待确认内容（expiresAt 为 nil 时锁屏不显示倒计时）
    static func approvalContent(
        text: String,
        expiresAt: Date?
    ) -> AgentLiveActivityAttributes.ContentState {
        AgentLiveActivityAttributes.ContentState(
            mode: .approval,
            title: "agent.liveactivity.approval.title".localized,
            detail: text,
            taskCount: 0,
            approvalExpiresAt: expiresAt,
            countdownFireDate: nil,
            resultKind: nil
        )
    }

    /// 任务终态内容（短暂展示后由管理器自动结束）
    static func resultContent(
        kind: QwenTaskFeedItem.Kind,
        text: String
    ) -> AgentLiveActivityAttributes.ContentState {
        let title: String
        let resultKind: AgentLiveActivityAttributes.ResultKind
        switch kind {
        case .completed, .result, .delegated, .progress, .permissionRequested:
            title = "agent.liveactivity.result.done".localized
            resultKind = .completed
        case .failed:
            title = "agent.liveactivity.result.failed".localized
            resultKind = .failed
        case .cancelled:
            title = "agent.liveactivity.result.cancelled".localized
            resultKind = .cancelled
        }
        return AgentLiveActivityAttributes.ContentState(
            mode: .result,
            title: title,
            detail: text,
            taskCount: 0,
            approvalExpiresAt: nil,
            countdownFireDate: nil,
            resultKind: resultKind.rawValue
        )
    }

    /// 日程倒计时内容：标题为空或开始时间已过返回 nil（不展示）；全天日程由策略层过滤
    static func calendarContent(
        event: AgentCalendarEvent,
        now: Date = Date()
    ) -> AgentLiveActivityAttributes.ContentState? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, event.start > now else { return nil }
        return AgentLiveActivityAttributes.ContentState(
            mode: .calendarCountdown,
            title: "agent.liveactivity.calendar.title".localized,
            detail: title,
            taskCount: 0,
            approvalExpiresAt: nil,
            countdownFireDate: event.start,
            resultKind: nil
        )
    }

    /// 提醒倒计时内容：文本为空或触发时间已过返回 nil（不展示）
    static func reminderContent(
        text: String,
        fireDate: Date,
        now: Date = Date()
    ) -> AgentLiveActivityAttributes.ContentState? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, fireDate > now else { return nil }
        return AgentLiveActivityAttributes.ContentState(
            mode: .reminderCountdown,
            title: "agent.liveactivity.reminder.title".localized,
            detail: text,
            taskCount: 0,
            approvalExpiresAt: nil,
            countdownFireDate: fireDate,
            resultKind: nil
        )
    }

    /// 语音会话状态内容：会话活跃且状态文案非空时展示（voiceSession 模式）
    static func voiceContent(
        text: String?,
        phase: AgentLiveActivityAttributes.VoicePhase? = nil
    ) -> AgentLiveActivityAttributes.ContentState? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return AgentLiveActivityAttributes.ContentState(
            mode: .voiceSession,
            title: "agent.liveactivity.voice.title".localized,
            detail: text,
            taskCount: 0,
            approvalExpiresAt: nil,
            countdownFireDate: nil,
            resultKind: nil,
            voiceStatus: text,
            voicePhase: phase?.rawValue
        )
    }
}

/// 语音会话 Live Activity 阶段与状态文案（纯逻辑，可测）：
/// 按「休眠 > 未连接 > 播报 > 聆听 > 思考」优先级产出锁屏状态行与
/// 结构化阶段（扩展据此渲染「唤醒」按钮）；会话不活跃返回 nil。
enum AgentVoiceLiveActivityStatus {
    static func phase(
        isActive: Bool,
        isSleeping: Bool,
        isSpeaking: Bool,
        isInputActive: Bool,
        connectionState: QwenGatewayConnectionState
    ) -> AgentLiveActivityAttributes.VoicePhase? {
        guard isActive else { return nil }
        if isSleeping {
            return .sleeping
        }
        switch connectionState {
        case .disconnected, .connecting:
            return .connecting
        case .failed:
            return .failed
        case .connected:
            break
        }
        if isSpeaking {
            return .speaking
        }
        if isInputActive {
            return .listening
        }
        return .thinking
    }

    /// 阶段 → 锁屏状态行文案（与 phase 单一来源，避免两套逻辑漂移）
    static func text(for phase: AgentLiveActivityAttributes.VoicePhase) -> String {
        switch phase {
        case .sleeping: return "agent.liveactivity.voice.sleeping".localized
        case .connecting: return "agent.liveactivity.voice.connecting".localized
        case .failed: return "agent.liveactivity.voice.failed".localized
        case .speaking: return "agent.liveactivity.voice.speaking".localized
        case .listening: return "agent.liveactivity.voice.listening".localized
        case .thinking: return "agent.liveactivity.voice.thinking".localized
        }
    }

    static func text(
        isActive: Bool,
        isSleeping: Bool,
        isSpeaking: Bool,
        isInputActive: Bool,
        connectionState: QwenGatewayConnectionState
    ) -> String? {
        guard let phase = phase(
            isActive: isActive,
            isSleeping: isSleeping,
            isSpeaking: isSpeaking,
            isInputActive: isInputActive,
            connectionState: connectionState
        ) else { return nil }
        return text(for: phase)
    }
}

/// 提醒倒计时选择策略（纯逻辑，可测）：
/// 只选「未来 maxAhead 小时内」的最近一条一次性提醒（周期提醒由系统通知接力，不占倒计时）。
enum AgentReminderCountdownPolicy {
    /// 默认展示窗口：6 小时（Live Activity 系统时长上限内）
    static let defaultMaxAhead: TimeInterval = 6 * 3600

    static func nextReminder(
        in reminders: [AgentReminder],
        now: Date = Date(),
        maxAhead: TimeInterval = defaultMaxAhead
    ) -> AgentReminder? {
        let deadline = now.addingTimeInterval(maxAhead)
        return reminders
            .filter { $0.repeatRule == .none && $0.fireDate > now && $0.fireDate <= deadline }
            .min { $0.fireDate < $1.fireDate }
    }
}

/// 日程倒计时选择策略（纯逻辑，可测）：
/// 只选「未来 maxAhead 小时内」最近一个即将开始的非全天日程（全天日程不是时间点提醒）。
enum AgentCalendarCountdownPolicy {
    /// 默认展示窗口：6 小时（Live Activity 系统时长上限内）
    static let defaultMaxAhead: TimeInterval = 6 * 3600

    /// 小组件「下次日程」展示窗口：未来 24 小时内最近一个非全天日程
    static let widgetMaxAhead: TimeInterval = 24 * 3600

    static func nextEvent(
        in events: [AgentCalendarEvent],
        now: Date = Date(),
        maxAhead: TimeInterval = defaultMaxAhead
    ) -> AgentCalendarEvent? {
        let deadline = now.addingTimeInterval(maxAhead)
        return events
            .filter { !$0.isAllDay && $0.start > now && $0.start <= deadline }
            .min { $0.start < $1.start }
    }
}

/// 提醒倒计时同步入口：提醒新增 / 取消 / 稍后提醒 / 到点后重新计算并更新 Live Activity。
/// 幂等：无符合条件的提醒时结束倒计时（回落任务进度或结束）。
@MainActor
enum AgentReminderCountdownCoordinator {
    static func sync(
        reminders: [AgentReminder] = AgentReminderStore.reminders,
        now: Date = Date()
    ) {
        guard let next = AgentReminderCountdownPolicy.nextReminder(in: reminders, now: now) else {
            AgentLiveActivityManager.updateReminderCountdown(text: nil, fireDate: nil)
            return
        }
        AgentLiveActivityManager.updateReminderCountdown(text: next.text, fireDate: next.fireDate)
    }
}

/// Live Activity 单例管理器（App 侧，@MainActor）
@MainActor
enum AgentLiveActivityManager {
    static let enabledKey = "agent.liveactivity.enabled"

    /// 开关（设置页可配置，默认开启）
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 系统是否允许 Live Activity（开关 + 系统授权）
    static var isAvailable: Bool {
        !isRunningTests && ActivityAuthorizationInfo().areActivitiesEnabled && isEnabled
    }

    /// XCTest 运行时不触碰 ActivityKit（避免测试环境副作用）
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// 当前活动模式（供 UI / 测试观察）
    private(set) static var currentMode: AgentLiveActivityAttributes.Mode?

    /// 待展示内容缓存（不随当前活动结束清空，供优先级回落使用）
    private static var cachedApproval: AgentLiveActivityAttributes.ContentState?
    private static var cachedVoice: AgentLiveActivityAttributes.ContentState?
    private static var cachedTask: AgentLiveActivityAttributes.ContentState?
    private static var cachedReminder: AgentLiveActivityAttributes.ContentState?
    private static var cachedCalendar: AgentLiveActivityAttributes.ContentState?

    private static var activity: Activity<AgentLiveActivityAttributes>?

    /// 任务进度：count > 0 缓存并展示（若未被更高优先级内容占据）；count == 0 清缓存
    static func updateTaskProgress(count: Int, step: String?) {
        cachedTask = AgentLiveActivityStateMapper.taskContent(count: count, step: step)
        refresh()
    }

    /// 语音会话状态：会话活跃时缓存并展示（高于倒计时 / 任务进度）；nil 清除回落
    static func updateVoiceStatus(
        text: String?,
        phase: AgentLiveActivityAttributes.VoicePhase? = nil
    ) {
        cachedVoice = AgentLiveActivityStateMapper.voiceContent(text: text, phase: phase)
        refresh()
    }

    /// 审批待确认（优先级最高，覆盖倒计时 / 任务进度）
    static func showApproval(text: String, expiresAt: Date?) {
        cachedApproval = AgentLiveActivityStateMapper.approvalContent(text: text, expiresAt: expiresAt)
        refresh()
    }

    /// 审批已处理：清审批缓存并回到次优先级内容（倒计时 → 任务进度 → 结束）
    static func resolveApproval(runningTaskCount: Int, step: String?) {
        cachedApproval = nil
        cachedTask = AgentLiveActivityStateMapper.taskContent(count: runningTaskCount, step: step)
        refresh()
    }

    /// 提醒倒计时：最近一条一次性提醒的触发时间；nil 清除
    static func updateReminderCountdown(text: String?, fireDate: Date?) {
        if let text, let fireDate {
            cachedReminder = AgentLiveActivityStateMapper.reminderContent(
                text: text,
                fireDate: fireDate
            )
        } else {
            cachedReminder = nil
        }
        refresh()
    }

    /// 日程倒计时：下一个即将开始的日程；nil 清除
    static func updateCalendarCountdown(event: AgentCalendarEvent?) {
        if let event {
            cachedCalendar = AgentLiveActivityStateMapper.calendarContent(event: event)
        } else {
            cachedCalendar = nil
        }
        refresh()
    }

    /// 任务终态：短暂展示结果后自动结束并回落（6 秒）
    static func showResult(kind: QwenTaskFeedItem.Kind, text: String) {
        guard isEnabled else { end(); return }
        present(AgentLiveActivityStateMapper.resultContent(kind: kind, text: text))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard AgentLiveActivityManager.currentMode == .result else { return }
            AgentLiveActivityManager.end()
            AgentLiveActivityManager.refresh()
        }
    }

    /// 结束当前活动（幂等）
    static func end() {
        currentMode = nil
        guard !isRunningTests, let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: activity.contentState, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    /// 结束全部活动（App 启动 / 会话停止时兜底，清理上次运行的残留）
    static func endAll() {
        currentMode = nil
        cachedApproval = nil
        cachedVoice = nil
        cachedTask = nil
        cachedReminder = nil
        cachedCalendar = nil
        guard !isRunningTests else { return }
        for running in Activity<AgentLiveActivityAttributes>.activities {
            let content = ActivityContent(state: running.contentState, staleDate: nil)
            Task { await running.end(content, dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    /// 测试专用：清空展示状态（不触碰 ActivityKit）
    static func resetStateForTesting() {
        currentMode = nil
        cachedApproval = nil
        cachedVoice = nil
        cachedTask = nil
        cachedReminder = nil
        cachedCalendar = nil
    }

    /// 按优先级刷新：审批 > 提醒 / 日程倒计时（更早者展示）> 任务进度 > 结束
    private static func refresh() {
        guard isEnabled else { end(); return }
        if let cachedApproval {
            present(cachedApproval)
            return
        }
        // 语音会话进行中优先于倒计时 / 任务进度（用户正在与 JARVIS 交互）
        if let cachedVoice {
            present(cachedVoice)
            return
        }
        // 提醒与日程并存时展示更早触发的那个（「下一个安排」语义）
        let countdowns = [cachedReminder, cachedCalendar].compactMap { $0 }
        if let soonest = countdowns.min(by: {
            ($0.countdownFireDate ?? .distantFuture) < ($1.countdownFireDate ?? .distantFuture)
        }) {
            present(soonest)
            return
        }
        if let cachedTask {
            present(cachedTask)
            return
        }
        end()
    }

    /// 启动或更新单个活动
    private static func present(_ content: AgentLiveActivityAttributes.ContentState) {
        currentMode = content.mode
        guard !isRunningTests, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity {
            Task { await activity.update(using: content) }
        } else {
            do {
                let attributes = AgentLiveActivityAttributes()
                activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: content, staleDate: content.countdownFireDate)
                )
            } catch {
                activity = nil
            }
        }
    }
}

// MARK: - Live Activity「查看任务」请求消费

/// 任务 Live Activity 按钮请求（App 侧消费）：扩展进程只写 App Group 标记，
/// App 回前台读取并深链到 Agent Hub（与 Control Center 语音会话同一模式）。
enum AgentTaskViewRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.viewTask.v1"

    /// 消费「查看任务」请求（读到即清除）；可注入 defaults 便于测试
    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> Bool {
        let store = defaults ?? .standard
        guard store.bool(forKey: requestKey) else { return false }
        store.removeObject(forKey: requestKey)
        return true
    }
}

// MARK: - Live Activity 审批请求消费

/// Live Activity 审批卡按钮请求（App 侧消费）：扩展进程只写 App Group 标记
/// （allow / deny），App 回前台读取并提交当前审批决策（一次性）。
enum AgentApprovalTapStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.approval.v1"

    /// 消费原始标记（"allow" / "deny"），读到即清除
    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> String? {
        let store = defaults ?? .standard
        guard let raw = store.string(forKey: requestKey) else { return nil }
        store.removeObject(forKey: requestKey)
        return raw
    }

    /// 消费并映射为审批决策（标记使用扩展侧字面量，未知值忽略）
    static func consumeDecision(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> QwenPermissionDecision? {
        guard let raw = consume(defaults: defaults) else { return nil }
        switch raw {
        case "allow": return .allow
        case "deny": return .deny
        default: return nil
        }
    }
}

// MARK: - Live Activity 任务控制请求消费（取消 / 加速）

/// Live Activity 任务卡「取消 / 加速」按钮请求（App 侧消费）：扩展进程只写
/// App Group 标记（"cancel" / "accelerate"），App 读取并应用到最近的活动任务（一次性）。
enum AgentTaskControlTapStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.taskControl.v1"

    /// 消费原始标记，读到即清除
    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> String? {
        let store = defaults ?? .standard
        guard let raw = store.string(forKey: requestKey) else { return nil }
        store.removeObject(forKey: requestKey)
        return raw
    }
}

/// 任务控制动作（App 侧稳定枚举；扩展侧标记字面量映射）
enum AgentTaskControlAction: String, Equatable {
    case cancel
    case accelerate
}

/// 原始标记 → 动作（纯逻辑，可测）：未知 / 空值返回 nil（标记仍被消费，避免卡死）
enum AgentTaskControlActionParser {
    static func parse(_ raw: String?) -> AgentTaskControlAction? {
        guard let raw else { return nil }
        return AgentTaskControlAction(rawValue: raw)
    }
}

/// 任务 Live Activity 控制协调器（App 侧，@MainActor）：
/// 消费按钮请求并把动作应用到最近的活动任务；无活动任务或未知标记时静默忽略。
@MainActor
enum AgentTaskControlCoordinator {
    private static var observer: NSObjectProtocol?

    /// 注册 App Group 请求监听（幂等；跨进程 UserDefaults 变更，App 已在前台也能消费）
    static func startObserving() {
        guard observer == nil else {
            consumeIfNeeded()
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AgentTaskControlCoordinator.consumeIfNeeded()
            }
        }
        consumeIfNeeded()
    }

    /// 消费一次按钮请求并应用（返回是否处理了请求）。
    /// defaults / apply 可注入（测试用）；apply 返回任务显示名（nil = 无可作用任务）。
    @discardableResult
    static func consumeIfNeeded(
        defaults: UserDefaults? = nil,
        apply: ((AgentTaskControlAction) -> String?)? = nil
    ) -> Bool {
        let store = defaults
            ?? UserDefaults(suiteName: AgentTaskControlTapStore.suiteName)
            ?? .standard
        guard let raw = AgentTaskControlTapStore.consume(defaults: store) else { return false }
        guard let action = AgentTaskControlActionParser.parse(raw) else { return true }
        if let apply {
            _ = apply(action)
        } else {
            Self.apply(action)
        }
        return true
    }

    /// 默认应用：取消 / 加速最近的活动任务，并给出确认反馈（TTS + 镜片结果卡）
    private static func apply(_ action: AgentTaskControlAction) {
        switch action {
        case .cancel:
            guard let name = QwenVoiceSession.shared.requestTaskCancellation() else { return }
            announce(String(format: "agent.task.command.cancel.reply".localized, name))
        case .accelerate:
            guard let name = QwenVoiceSession.shared.requestTaskAcceleration() else { return }
            announce(String(format: "agent.task.command.accelerate.reply".localized, name))
        }
    }

    private static func announce(_ text: String) {
        TTSService.shared.stop()
        TTSService.shared.speak(text)
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: .progress),
            text: text,
            fallback: .idle
        )
    }
}
