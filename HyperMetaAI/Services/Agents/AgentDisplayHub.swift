/*
 * Agent Display Hub
 * 把 Agent 回合状态实时显示到眼镜镜片（MWDATDisplay）。
 * 状态 → (图标, 标题) 的映射是纯函数，便于单元测试；
 * SDK 调用全部容错：无设备/模拟器环境下静默降级。
 */

import Foundation
import MWDATCore
import MWDATDisplay
import UIKit

/// 眼镜端状态视图的纯映射（不依赖 SDK 运行时，可测）
enum AgentDisplayStatusMapping {
    /// 回合状态 → 眼镜图标名（MWDATDisplay.IconName 的 rawValue）
    static func iconName(for phase: AgentTurnPhase) -> String {
        switch phase {
        case .idle: return "meta_ai"
        case .listening: return "speech_bubble"
        case .thinking: return "three_dots_horizontal"
        case .speaking: return "speaker_with_three_arcs"
        case .interrupted: return "speaker_off"
        case .approval: return "padlock_closed"
        }
    }

    /// 回合状态 → 眼镜端短标题
    static func title(for phase: AgentTurnPhase) -> String {
        switch phase {
        case .idle: return ""
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .interrupted: return "Paused"
        case .approval: return "Approve?"
        }
    }

    /// 校验图标名是否为 SDK 支持的图标（供测试与容错使用）
    static func isValidIcon(_ name: String) -> Bool {
        IconName(rawValue: name) != nil
    }

    /// 构造眼镜端 FlexBox 视图
    static func makeView(phase: AgentTurnPhase) -> FlexBox? {
        let iconName = iconName(for: phase)
        let title = title(for: phase)
        guard let icon = IconName(rawValue: iconName) else { return nil }

        var children: [any ViewComponent] = [
            Icon(name: icon, style: .filled)
        ]
        if !title.isEmpty {
            children.append(Text(title, style: .body, color: .primary))
        }
        return FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
            for child in children {
                child
            }
        }
    }
}

/// 眼镜端可点动作菜单项（display 内容点击回调，独立于会话触发）
enum AgentDisplayAction: String, CaseIterable, Equatable {
    /// 唤醒新回合（语音页重新开始聆听；聊天页展开输入框）
    case wake
    /// 重听最后一条助手回复（语音页/聊天页通用）
    case repeatLastReply
    /// 对最新任务结果发起追问（有任务结果上下文时菜单动态出现，语音页/聊天页通用）
    case followUp
    /// 今日安排总览：下一场日程 + 提醒 + 进行中任务一键播报（任一有内容时菜单动态出现）
    case todayOverview
    /// 明日安排总览：明天下一场日程 + 场次数一键播报（明天有日程时菜单动态出现）
    case tomorrowOverview
    /// 查看即将触发的本地提醒（有活动提醒时菜单动态出现，语音页/聊天页通用）
    case reminders
    /// 查看今天未结束的日程（今天有日程时菜单动态出现，语音页/聊天页通用）
    case calendar
    /// 查看长期记忆与个性化规则（有任一内容时菜单动态出现，语音页/聊天页通用）
    case prefs
    /// 查看用户命名清单（购物单 / 待办；有清单时菜单动态出现，语音页/聊天页通用）
    case lists
    /// 查看最近一条审计记录（语音页/聊天页通用）
    case audit
    /// 拍照并把视野描述注入会话（仅语音页）
    case captureVision
    /// 端侧取词：识别眼镜画面文字并朗读（语音页 / 聊天页通用）
    case ocr
    /// 翻译最近一次取词结果（语音页 / 聊天页通用，发给当前 Agent）
    case translate
    /// 端侧场景识别：识别画面场景 / 动物并朗读（语音页 / 聊天页通用）
    case scene
    /// 新建会话（仅聊天页）
    case newChat
    /// 播报后台任务进度（有活动任务时菜单动态出现）
    case announceTasks
    /// 播报任务进度（任务中心子菜单）
    case taskProgress
    /// 取消最近的活动任务（任务中心子菜单）
    case cancelLatestTask
    /// 重试最近失败的任务（任务中心子菜单；有失败任务时动态出现）
    case retryLatestTask
    /// 返回上级菜单（任务中心子菜单）
    case backToMainMenu
    /// 镜片快捷指令子菜单（用户配置的常用指令）
    case shortcuts
    /// 关闭菜单，回到状态显示
    case dismiss
    /// 镜片主页 HUD（时间 / 未读 / HomeKit 摘要 + 快捷按钮）
    case home
}

/// 眼镜端动作菜单的纯映射（不依赖 SDK 运行时，可测）
enum AgentDisplayMenuMapping {
    /// 页面上下文决定菜单项
    enum Context {
        case voice
        case chat
        /// 任务中心子菜单（从主菜单「Task」进入）
        case taskCenter
    }

    /// 菜单项标题（眼镜端以英文短词为主，与状态行一致）
    static func title(for action: AgentDisplayAction) -> String {
        switch action {
        case .wake: return "Talk"
        case .repeatLastReply: return "Repeat"
        case .followUp: return "Ask"
        case .todayOverview: return "Today"
        case .tomorrowOverview: return "Tomorrow"
        case .reminders: return "Reminders"
        case .calendar: return "Calendar"
        case .prefs: return "Prefs"
        case .lists: return "Lists"
        case .audit: return "Audit"
        case .captureVision: return "Vision"
        case .ocr: return "OCR"
        case .translate: return "Translate"
        case .scene: return "Scene"
        case .newChat: return "New chat"
        case .announceTasks: return "Task"
        case .taskProgress: return "Progress"
        case .cancelLatestTask: return "Cancel"
        case .retryLatestTask: return "Retry"
        case .backToMainMenu: return "Back"
        case .shortcuts: return "Shortcuts"
        case .dismiss: return "Close"
        case .home: return "Home"
        }
    }

    /// 菜单项图标（MWDATDisplay.IconName 的 rawValue）
    static func iconName(for action: AgentDisplayAction) -> String {
        switch action {
        case .wake: return "speech_bubble"
        case .repeatLastReply: return "two_arrows_clockwise"
        case .followUp: return "three_dot_speech_bubble"
        case .todayOverview: return "clock"
        case .tomorrowOverview: return "arrow_right"
        case .reminders: return "bell"
        case .calendar: return "calendar"
        case .prefs: return "sliders_horizontal"
        case .lists: return "shopping_bag"
        case .audit: return "three_horizontal_lines"
        case .captureVision: return "video_camera"
        case .ocr: return "eye"
        case .translate: return "globe_western_hemisphere"
        case .scene: return "light_bulb"
        case .newChat: return "plus"
        case .announceTasks: return "gear"
        case .taskProgress: return "gear"
        case .cancelLatestTask: return "x"
        case .retryLatestTask: return "two_arrows_clockwise"
        case .backToMainMenu: return "arrow_left"
        case .shortcuts: return "star"
        case .dismiss: return "x"
        case .home: return "house"
        }
    }

    /// 校验图标是否为 SDK 支持的图标（供测试与容错使用）
    static func isValidIcon(for action: AgentDisplayAction) -> Bool {
        IconName(rawValue: iconName(for: action)) != nil
    }

    /// 指定上下文下的菜单项（顺序即眼镜端展示顺序）。
    /// 动态插入项（顺序固定）：有活动后台任务 →「Task」进度播报；
    /// 有任务结果追问上下文 →「Ask」追问；有活动提醒 →「Reminders」查看；
    /// 今天有未结束日程 →「Calendar」查看；
    /// 有记忆或规则 →「Prefs」查看；有命名清单 →「Lists」查看。
    static func actions(
        for context: Context,
        hasActiveTasks: Bool = false,
        hasTodayOverview: Bool = false,
        hasTomorrowOverview: Bool = false,
        hasFollowUpContext: Bool = false,
        hasActiveReminders: Bool = false,
        hasUpcomingCalendarEvents: Bool = false,
        hasAgentPrefs: Bool = false,
        hasNamedLists: Bool = false,
        hasFailedTasks: Bool = false
    ) -> [AgentDisplayAction] {
        let base: [AgentDisplayAction]
        switch context {
        case .voice: base = [.home, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        case .chat: base = [.home, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        case .taskCenter: base = [.taskProgress, .cancelLatestTask, .backToMainMenu]
        }
        var actions = base
        // 任务中心子菜单：有失败任务时在「Cancel」与「Back」之间插入「Retry」
        if hasFailedTasks, context == .taskCenter {
            actions.insert(.retryLatestTask, at: max(0, actions.count - 1))
        }
        var insertIndex = 1
        if hasActiveTasks {
            actions.insert(.announceTasks, at: insertIndex)
            insertIndex += 1
        }
        if hasTodayOverview {
            actions.insert(.todayOverview, at: insertIndex)
            insertIndex += 1
        }
        if hasTomorrowOverview {
            actions.insert(.tomorrowOverview, at: insertIndex)
            insertIndex += 1
        }
        if hasFollowUpContext {
            actions.insert(.followUp, at: insertIndex)
            insertIndex += 1
        }
        if hasActiveReminders {
            actions.insert(.reminders, at: insertIndex)
            insertIndex += 1
        }
        if hasUpcomingCalendarEvents {
            actions.insert(.calendar, at: insertIndex)
            insertIndex += 1
        }
        if hasAgentPrefs {
            actions.insert(.prefs, at: insertIndex)
            insertIndex += 1
        }
        if hasNamedLists {
            actions.insert(.lists, at: insertIndex)
        }
        return actions
    }

    /// 构造眼镜端菜单视图；无有效图标项时返回 nil（调用方回退清屏）
    static func makeView(
        actions: [AgentDisplayAction],
        onSelect: @escaping (AgentDisplayAction) -> Void
    ) -> FlexBox? {
        var buttons: [Button] = []
        for action in actions {
            guard let icon = IconName(rawValue: iconName(for: action)) else { continue }
            buttons.append(Button(
                label: title(for: action),
                style: .outline,
                iconName: icon,
                onClick: { onSelect(action) }
            ))
        }
        guard !buttons.isEmpty else { return nil }
        return FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
    }
}

// MARK: - 镜片今日总览文案

/// 镜片「Today」总览的文案构建（纯逻辑，可测）：
/// 下一场日程 + 下一条提醒 + 进行中任务（任一有内容即非空；全空回退「一切就绪」）。
enum AgentTodayOverviewBuilder {
    struct Content: Equatable {
        let scheduleLine: String?
        let reminderLine: String?
        let taskLine: String?

        var isEmpty: Bool {
            scheduleLine == nil && reminderLine == nil && taskLine == nil
        }

        /// 播报 / 结果卡全文（栏目间以「，」连接，适合 TTS）
        var fullText: String {
            if isEmpty { return "agent.today.empty".localized }
            var lines: [String] = []
            if let scheduleLine { lines.append(scheduleLine) }
            if let reminderLine { lines.append(reminderLine) }
            if let taskLine { lines.append(taskLine) }
            return lines.joined(separator: "，")
        }
    }

    static func content(
        events: [AgentCalendarEvent],
        reminders: [AgentReminder],
        taskTitles: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Content {
        var scheduleLine: String?
        if let next = events.sorted(by: { $0.start < $1.start }).first {
            scheduleLine = AgentCalendarFormatter.eventLine(next, now: now, calendar: calendar)
        }
        var reminderLine: String?
        if let next = reminders.sorted(by: { $0.fireDate < $1.fireDate }).first {
            reminderLine = AgentReminderDisplayMapping.resultText(for: next, now: now)
        }
        var taskLine: String?
        let titles = taskTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !titles.isEmpty {
            taskLine = String(format: "agent.today.tasks".localized, titles.count)
        }
        return Content(
            scheduleLine: scheduleLine,
            reminderLine: reminderLine,
            taskLine: taskLine
        )
    }
}


// MARK: - 镜片明日总览文案

/// 镜片「Tomorrow」总览的文案构建（纯逻辑，可测）：
/// 明天下一场日程 + 场次数（>1 场时补充总数；无日程回退「明天暂无安排」）。
enum AgentTomorrowOverviewBuilder {
    struct Content: Equatable {
        let scheduleLine: String?
        let countLine: String?

        var isEmpty: Bool {
            scheduleLine == nil && countLine == nil
        }

        /// 播报 / 结果卡全文（栏目间以「，」连接，适合 TTS）
        var fullText: String {
            if isEmpty { return "agent.tomorrow.empty".localized }
            var lines: [String] = []
            if let scheduleLine { lines.append(scheduleLine) }
            if let countLine { lines.append(countLine) }
            return lines.joined(separator: "，")
        }
    }

    static func content(
        events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Content {
        let sorted = events.sorted { $0.start < $1.start }
        var scheduleLine: String?
        if let next = sorted.first {
            scheduleLine = AgentCalendarFormatter.eventLine(next, now: now, calendar: calendar)
        }
        var countLine: String?
        if sorted.count > 1 {
            countLine = String(format: "agent.tomorrow.count".localized, sorted.count)
        }
        return Content(
            scheduleLine: scheduleLine,
            countLine: countLine
        )
    }
}

/// 眼镜端审批动作（纯映射，可测）
enum AgentDisplayPermissionAction: String, CaseIterable, Equatable {
    case allow
    case deny
    /// 稍后处理：收起审批卡但不发送决策（网关可能稍后再问）
    case later
}

/// 眼镜端权限审批卡的纯映射（不依赖 SDK 运行时，可测）
enum AgentDisplayPermissionMapping {
    /// 按钮标题（眼镜端以英文短词为主，与菜单一致）
    static func title(for action: AgentDisplayPermissionAction) -> String {
        switch action {
        case .allow: return "Allow"
        case .deny: return "Deny"
        case .later: return "Later"
        }
    }

    /// 按钮图标（MWDATDisplay.IconName 的 rawValue）
    static func iconName(for action: AgentDisplayPermissionAction) -> String {
        switch action {
        case .allow: return "checkmark"
        case .deny: return "x"
        case .later: return "clock"
        }
    }

    /// 校验图标是否为 SDK 支持的图标（供测试与容错使用）
    static func isValidIcon(for action: AgentDisplayPermissionAction) -> Bool {
        IconName(rawValue: iconName(for: action)) != nil
    }

    /// 构造眼镜端审批卡：padlock + 任务摘要 + Allow / Deny 按钮行 + Later 稍后处理
    static func makeView(
        summary: String,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void,
        onLater: @escaping () -> Void
    ) -> FlexBox? {
        guard let padlock = IconName(rawValue: "padlock_closed"),
              let allowIcon = IconName(rawValue: iconName(for: .allow)),
              let denyIcon = IconName(rawValue: iconName(for: .deny)),
              let laterIcon = IconName(rawValue: iconName(for: .later)) else { return nil }
        let buttons = FlexBox(direction: .row, spacing: 8, alignment: .start, crossAlignment: .start) {
            Button(label: title(for: .allow), style: .primary, iconName: allowIcon, onClick: onAllow)
            Button(label: title(for: .deny), style: .outline, iconName: denyIcon, onClick: onDeny)
        }
        var children: [any ViewComponent] = [
            Icon(name: padlock, style: .filled)
        ]
        if !summary.isEmpty {
            children.append(Text(summary, style: .meta, color: .secondary))
        }
        children.append(buttons)
        children.append(Button(
            label: title(for: .later),
            style: .outline,
            iconName: laterIcon,
            onClick: onLater
        ))
        return FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for child in children {
                child
            }
        }
    }
}

/// 审批决策的眼镜端即时反馈（纯映射，可测）
enum AgentApprovalFeedbackMapping {
    /// 决策 → (镜片短标题, 反馈文案)
    static func feedback(for decision: QwenPermissionDecision) -> (title: String, text: String) {
        switch decision {
        case .allow:
            return ("Done", "agent.permission.approved".localized)
        case .deny:
            return ("Denied", "agent.permission.denied".localized)
        }
    }
}

/// 眼镜端一次性结果摘要的纯映射（如任务完成/失败，可测）
// MARK: - 动态选择卡（镜片按钮选择）

/// 动态选择卡的纯映射（不依赖 SDK 运行时，可测）：
/// 编号选项按钮标题（镜片宽度有限，超长截断）+ 取消按钮标题（镜片端固定英文短词）。
enum AgentDisplayChoiceMapping {
    static let maxOptionLength = 12

    static func optionLabel(index: Int, title: String) -> String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(text.prefix(maxOptionLength))
        let body = text.count > maxOptionLength ? trimmed + "…" : trimmed
        return "\(index + 1). \(body)"
    }

    static func cancelLabel() -> String {
        "Cancel"
    }

    /// 确认删除按钮标签（镜片端固定英文短词）
    static func deleteLabel() -> String {
        "Delete"
    }

    /// 确认完成按钮标签（镜片端固定英文短词，与锁屏通知 Action 文案一致）
    static func completeLabel() -> String {
        "Done"
    }
}

/// 镜片任务子菜单「选择」流（纯逻辑，可测）：
/// 无目标任务不显示；单个直接操作；多个弹出编号选择卡（上限 5 个，保留原始任务序号）。
/// Cancel（取消）、Progress（进度）与 Retry（重试）选择共用同一决策与标签。
enum AgentTaskChoiceFlow {
    static let maxOptions = 5

    enum Presentation: Equatable {
        case none
        case direct
        case choose
    }

    static func presentation(taskCount: Int) -> Presentation {
        switch taskCount {
        case 0: return .none
        case 1: return .direct
        default: return .choose
        }
    }

    /// 选择卡选项标签（序号 = 活动任务原始下标，操作指令按序号直达）
    static func optionLabels(from tasks: [QwenAgentTask]) -> [String] {
        tasks.enumerated().prefix(maxOptions).map { index, task in
            AgentDisplayChoiceMapping.optionLabel(index: index, title: task.title)
        }
    }
}

enum AgentDisplayResultMapping {
    /// 结果标题 → 眼镜端短标题（英文短词，与状态行一致）
    static func title(for kind: QwenTaskFeedItem.Kind) -> String {
        switch kind {
        case .completed, .result: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .delegated, .progress, .permissionRequested: return "Task"
        }
    }

    /// 任务终态 → 手机触觉反馈类型（纯逻辑，可测；语音页与聊天页共用）
    static func haptic(for kind: QwenTaskFeedItem.Kind) -> UINotificationFeedbackGenerator.FeedbackType {
        switch kind {
        case .failed: return .error
        case .cancelled: return .warning
        case .completed, .result, .delegated, .progress, .permissionRequested: return .success
        }
    }

    /// 构造眼镜端结果视图：图标 + 标题 + 摘要
    static func makeView(title: String, text: String) -> FlexBox? {
        guard let icon = IconName(rawValue: "checkmark_circle") else { return nil }
        var children: [any ViewComponent] = [
            Icon(name: icon, style: .filled)
        ]
        if !title.isEmpty {
            children.append(Text(title, style: .body, color: .primary))
        }
        if !text.isEmpty {
            children.append(Text(text, style: .meta, color: .secondary))
        }
        return FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for child in children {
                child
            }
        }
    }
}

/// 任务生命周期 → 眼镜端呈现的统一 Presenter（语音页与聊天页共用）。
/// 纯决策部分（progressVisible / stepVisible / shouldAnnounceCompletion）可测；
/// 副作用（镜片显示 / TTS / 触觉）集中在执行方法内，避免两页行为漂移。
@MainActor
enum AgentTaskLensPresenter {
    /// 任务进度变化：进行中在聆听/空闲态显示进度卡；全部结束后恢复回合状态
    static func handleProgressChange(
        phase: AgentTurnPhase,
        runningTaskCount: Int,
        taskMessage: String?,
        hasCompletionNotice: Bool
    ) {
        if runningTaskCount > 0 {
            if progressVisible(phase: phase, hasCompletionNotice: hasCompletionNotice) {
                AgentDisplayHub.shared.showTaskProgress(count: runningTaskCount, title: taskMessage)
            }
        } else {
            AgentDisplayHub.shared.clearTaskProgress()
            if !hasCompletionNotice {
                AgentDisplayHub.shared.show(phase)
            }
        }
    }

    /// 任务分步消息：聆听/思考/空闲态实时把最新步骤透出到镜片
    static func handleStepMessageChange(
        phase: AgentTurnPhase,
        runningTaskCount: Int,
        taskMessage: String?
    ) {
        guard let taskMessage, !taskMessage.isEmpty, runningTaskCount > 0,
              stepVisible(phase: phase) else { return }
        AgentDisplayHub.shared.showTaskProgress(count: runningTaskCount, title: taskMessage)
    }

    /// 任务终态：清过期进度 → TTS 播报（静默模式 + 播报窗口约束）→ 镜片结果卡 → 手机触觉
    static func handleCompletionChange(
        phase: AgentTurnPhase,
        kind: QwenTaskFeedItem.Kind,
        text: String,
        lastTaskResultText: String,
        runningTaskCount: Int,
        announceByApp: Bool,
        isSpeaking: Bool,
        isInputActive: Bool,
        ttsSpeaking: Bool
    ) {
        if runningTaskCount == 0 {
            AgentDisplayHub.shared.clearTaskProgress()
            AgentLiveActivityManager.showResult(kind: kind, text: text)
        } else {
            AgentLiveActivityManager.updateTaskProgress(count: runningTaskCount, step: nil)
        }
        if announceByApp,
           shouldAnnounceCompletion(
               isSpeaking: isSpeaking,
               isInputActive: isInputActive,
               ttsSpeaking: ttsSpeaking
           ) {
            let announcement = lastTaskResultText.isEmpty ? text : lastTaskResultText
            TTSService.shared.speak(announcement)
        }
        AgentDisplayHub.shared.showResult(
            title: AgentDisplayResultMapping.title(for: kind),
            text: text,
            fallback: phase
        )
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(AgentDisplayResultMapping.haptic(for: kind))
    }

    /// 任务受理回执：任务创建时立即回一句「收到」（大脑转发模式由 App 播报）
    static func handleAcknowledgmentChange(
        title: String,
        announceByApp: Bool,
        isSpeaking: Bool,
        isInputActive: Bool,
        ttsSpeaking: Bool
    ) {
        guard announceByApp else { return }
        if AgentVoiceSettings.replyEnabled,
           AgentAnnouncementGate.shouldAnnounce(
               isSpeaking: isSpeaking,
               isInputActive: isInputActive,
               ttsSpeaking: ttsSpeaking
           ) {
            let text = title.isEmpty
                ? "agent.task.acknowledged.generic".localized
                : String(format: "agent.task.acknowledged".localized, title)
            TTSService.shared.speak(text)
        }
    }

    /// 长任务自动进度播报（对齐 qwen-audio-agent v1.8.2 的自动进度汇报）：
    /// 镜片进度卡 + TTS（大脑转发模式由 App 播报；原生模式由网关播报）。
    /// 静默模式与播报窗口约束与终态一致；不触发触觉（避免打扰）。
    static func handleProgressCheckInChange(
        text: String,
        runningTaskCount: Int,
        announceByApp: Bool,
        isSpeaking: Bool,
        isInputActive: Bool,
        ttsSpeaking: Bool
    ) {
        AgentDisplayHub.shared.showTaskProgress(
            count: runningTaskCount,
            title: text
        )
        guard announceByApp,
              AgentVoiceSettings.replyEnabled,
              AgentQuietAnnouncementPolicy.shouldSpeakProactive(),
              AgentAnnouncementGate.shouldAnnounce(
                  isSpeaking: isSpeaking,
                  isInputActive: isInputActive,
                  ttsSpeaking: ttsSpeaking
              ) else { return }
        TTSService.shared.speak(text)
    }

    // MARK: - 纯决策（可测）

    /// 进行中是否在镜片显示任务进度卡（聆听/空闲态，且无终态摘要待展示）
    static func progressVisible(phase: AgentTurnPhase, hasCompletionNotice: Bool) -> Bool {
        !hasCompletionNotice && (phase == .listening || phase == .idle)
    }

    /// 分步消息是否允许透出（聆听/思考/空闲态）
    static func stepVisible(phase: AgentTurnPhase) -> Bool {
        switch phase {
        case .listening, .thinking, .idle: return true
        default: return false
        }
    }

    /// 终态播报是否开口（尊重语音播报开关、静默模式与播报窗口）
    static func shouldAnnounceCompletion(
        isSpeaking: Bool,
        isInputActive: Bool,
        ttsSpeaking: Bool
    ) -> Bool {
        AgentVoiceSettings.replyEnabled &&
            AgentQuietAnnouncementPolicy.shouldSpeakProactive() &&
            AgentAnnouncementGate.shouldAnnounce(
                isSpeaking: isSpeaking,
                isInputActive: isInputActive,
                ttsSpeaking: ttsSpeaking
            )
    }
}

/// 审批卡弹出示意的延迟策略（纯逻辑，可测）：
/// 用户正在说话 / 网关或本地正在播报 / 回合处于忙碌态（speaking / interrupted）时，
/// 不立即弹出审批卡，等会话空闲再弹——避免卡片打断正在进行的回合（"不抢话"原则的视觉版）。
enum AgentApprovalDeferralPolicy {
    static func shouldDefer(
        phase: AgentTurnPhase,
        isInputActive: Bool,
        isSpeaking: Bool,
        ttsSpeaking: Bool
    ) -> Bool {
        if isInputActive || isSpeaking || ttsSpeaking { return true }
        switch phase {
        case .idle, .listening, .thinking: return false
        default: return true
        }
    }
}

/// 眼镜端后台任务进行中的纯映射（可测）
enum AgentDisplayTaskMapping {
    static let iconName = "gear"

    /// 任务数 → 眼镜端短标题（英文短词，与状态行一致）
    static func title(count: Int) -> String {
        count > 1 ? "Tasks \(count)" : "Task"
    }

    /// 构造眼镜端任务进度视图；title 为最新一步的进度文案（如"正在生成周报"）。
    /// 无 title 时用单行（图标 + 标题），有 title 时用双行（标题 + 步骤摘要）。
    static func makeView(count: Int, title: String? = nil) -> FlexBox? {
        guard let icon = IconName(rawValue: iconName) else { return nil }
        var children: [any ViewComponent] = [
            Icon(name: icon, style: .filled),
            Text(AgentDisplayTaskMapping.title(count: count), style: .body, color: .primary),
        ]
        let hasTitle = title.map { !$0.isEmpty } ?? false
        if hasTitle, let title {
            children.append(Text(title, style: .meta, color: .secondary))
        }
        return FlexBox(
            direction: hasTitle ? .column : .row,
            spacing: 8,
            alignment: .center,
            crossAlignment: hasTitle ? .start : .center
        ) {
            for child in children {
                child
            }
        }
    }
}

/// 管理 MWDATDisplay 生命周期：会话创建后挂载，状态变化时更新，会话释放时卸载。
@MainActor
final class AgentDisplayHub {
    static let shared = AgentDisplayHub()

    private var display: Display?
    private var lastShownPhase: AgentTurnPhase?
    private var menuHandler: ((AgentDisplayAction) -> Void)?
    private var permissionHandler: ((AgentDisplayPermissionAction) -> Void)?
    private var displayStateToken: (any AnyListenerToken)?
    /// 显示代次：任何新显示都会让旧结果摘要的自动清屏失效
    private var resultGeneration = 0
    /// 进行中的后台任务数（供结果摘要自动清屏后回退展示）
    private var taskProgressCount = 0
    /// 最新任务步骤文案（供结果摘要自动清屏后回退展示）
    private var taskProgressTitle: String?

    private init() {}

    /// 挂载到设备会话（同一会话只挂一次；无显示能力时静默降级）
    func attach(to session: DeviceSession) {
        guard display == nil else { return }
        guard let display = try? session.addDisplay() else { return }
        self.display = display
        display.start()
        lastShownPhase = nil
        displayStateToken = display.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.display != nil else { return }
                if state == .stopped {
                    // 系统中断（来电/双指轻点/断连）结束显示会话：重置内部状态，
                    // 下次 show 时惰性重启 display
                    self.lastShownPhase = nil
                    self.menuHandler = nil
                }
            }
        }
    }

    /// 更新眼镜端状态；状态未变化时跳过，idle 时清空显示
    func show(_ phase: AgentTurnPhase) {
        guard lastShownPhase != phase else { return }
        lastShownPhase = phase
        menuHandler = nil
        resultGeneration &+= 1
        guard let display else { return }

        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            if phase == .idle {
                try? await display.clearDisplay()
            } else if let view = AgentDisplayStatusMapping.makeView(phase: phase) {
                try? await display.send(view)
            }
        }
    }

    /// 显示可点动作菜单；无有效图标时回退清屏。
    /// 状态更新（show）会隐式关闭菜单。
    func showMenu(
        actions: [AgentDisplayAction],
        onSelect: @escaping (AgentDisplayAction) -> Void
    ) {
        menuHandler = onSelect
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display else { return }
        let view = AgentDisplayMenuMapping.makeView(actions: actions) { [weak self] action in
            self?.menuHandler?(action)
        }

        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            if let view {
                try? await display.send(view)
            } else {
                try? await display.clearDisplay()
            }
        }
    }

    /// 显示镜片主页 HUD（状态行 + 快捷按钮）；无有效按钮时回退清屏。
    func showHome(
        state: AgentDisplayHomeState,
        onSelect: @escaping (AgentDisplayAction) -> Void
    ) {
        menuHandler = onSelect
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display else { return }
        let view = AgentDisplayHomeMapping.makeView(state: state) { [weak self] action in
            self?.menuHandler?(action)
        }

        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            if let view {
                try? await display.send(view)
            } else {
                try? await display.clearDisplay()
            }
        }
    }

    /// 显示快捷指令子菜单（动态条目：标题来自用户配置，末尾固定 Back）。
    func showShortcutsMenu(
        shortcuts: [AgentShortcut],
        onSelect: @escaping (AgentShortcut) -> Void,
        onBack: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display, let star = IconName(rawValue: "star") else { return }
        var buttons: [Button] = []
        for shortcut in shortcuts {
            buttons.append(Button(
                label: shortcut.title,
                style: .outline,
                iconName: star,
                onClick: { onSelect(shortcut) }
            ))
        }
        buttons.append(Button(
            label: "Back",
            style: .outline,
            iconName: .arrowLeft,
            onClick: onBack
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }

    /// 显示本地提醒子菜单（动态条目：按钮标签来自提醒内容截断，末尾固定 Back）。
    func showReminderListMenu(
        reminders: [AgentReminder],
        onSelect: @escaping (AgentReminder) -> Void,
        onBack: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display, let bell = IconName(rawValue: "bell") else { return }
        var buttons: [Button] = []
        for reminder in reminders {
            buttons.append(Button(
                label: AgentReminderDisplayMapping.menuLabel(for: reminder),
                style: .outline,
                iconName: bell,
                onClick: { onSelect(reminder) }
            ))
        }
        buttons.append(Button(
            label: "Back",
            style: .outline,
            iconName: .arrowLeft,
            onClick: onBack
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }
    /// 显示动态选择卡（编号选项 + 末尾 Cancel）；按钮点击回调携带选项下标（0 起）。
    /// 无眼镜时静默降级（不影响 TTS / App 内提示）；任何后续 show / 状态更新会关闭选择卡。
    func showChoice(
        options: [String],
        iconName: String = "calendar",
        onSelect: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display, let choiceIcon = IconName(rawValue: iconName) else { return }
        var buttons: [Button] = []
        for (index, title) in options.enumerated() {
            buttons.append(Button(
                label: AgentDisplayChoiceMapping.optionLabel(index: index, title: title),
                style: .outline,
                iconName: choiceIcon,
                onClick: { onSelect(index) }
            ))
        }
        buttons.append(Button(
            label: AgentDisplayChoiceMapping.cancelLabel(),
            style: .outline,
            iconName: .arrowLeft,
            onClick: onCancel
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }


    /// 显示日历日程子菜单（动态条目：按钮标签来自「时间 标题」短标签，末尾固定 Back）。
    func showCalendarListMenu(
        events: [AgentCalendarEvent],
        onSelect: @escaping (AgentCalendarEvent) -> Void,
        onBack: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display, let calendarIcon = IconName(rawValue: "calendar") else { return }
        var buttons: [Button] = []
        for event in events {
            buttons.append(Button(
                label: AgentCalendarDisplayMapping.menuLabel(for: event),
                style: .outline,
                iconName: calendarIcon,
                onClick: { onSelect(event) }
            ))
        }
        buttons.append(Button(
            label: "Back",
            style: .outline,
            iconName: .arrowLeft,
            onClick: onBack
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }

    /// 显示记忆/规则子菜单（动态条目：按钮标签来自内容截断，图标区分记忆与规则，末尾 Back）。
    func showPrefsMenu(
        items: [AgentPrefsDisplayMapping.Item],
        onSelect: @escaping (AgentPrefsDisplayMapping.Item) -> Void,
        onBack: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display else { return }
        var buttons: [Button] = []
        for item in items {
            guard let icon = IconName(rawValue: AgentPrefsDisplayMapping.iconName(for: item)) else { continue }
            buttons.append(Button(
                label: AgentPrefsDisplayMapping.menuLabel(for: item),
                style: .outline,
                iconName: icon,
                onClick: { onSelect(item) }
            ))
        }
        buttons.append(Button(
            label: "Back",
            style: .outline,
            iconName: .arrowLeft,
            onClick: onBack
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }

    /// 显示命名清单子菜单（动态条目：按钮标签来自清单名截断，末尾固定 Back）。
    func showListMenu(
        lists: [AgentNamedList],
        onSelect: @escaping (AgentNamedList) -> Void,
        onBack: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display, let bag = IconName(rawValue: AgentListDisplayMapping.iconName()) else { return }
        var buttons: [Button] = []
        for list in lists {
            buttons.append(Button(
                label: AgentListDisplayMapping.menuLabel(for: list),
                style: .outline,
                iconName: bag,
                onClick: { onSelect(list) }
            ))
        }
        buttons.append(Button(
            label: "Back",
            style: .outline,
            iconName: .arrowLeft,
            onClick: onBack
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }

    /// 显示清单条目子菜单（逐条听：按钮标签 = 序号 + 条目截断，末尾固定 Back）。
    func showListItemsMenu(
        items: [String],
        onSelect: @escaping (Int) -> Void,
        onBack: @escaping () -> Void
    ) {
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display, let bag = IconName(rawValue: AgentListDisplayMapping.iconName()) else { return }
        var buttons: [Button] = []
        for (index, item) in items.enumerated() {
            buttons.append(Button(
                label: AgentListDisplayMapping.itemMenuLabel(for: item, index: index),
                style: .outline,
                iconName: bag,
                onClick: { onSelect(index) }
            ))
        }
        buttons.append(Button(
            label: "Back",
            style: .outline,
            iconName: .arrowLeft,
            onClick: onBack
        ))
        let view = FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for button in buttons {
                button
            }
        }
        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            try? await display.send(view)
        }
    }

    /// 显示权限审批卡（Allow / Deny / Later 按钮 + 任务摘要）。
    /// 审批完成后由调用方恢复状态显示；任何新显示会隐式关闭审批卡。
    func showPermission(
        summary: String,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void,
        onLater: @escaping () -> Void
    ) {
        permissionHandler = { action in
            switch action {
            case .allow: onAllow()
            case .deny: onDeny()
            case .later: onLater()
            }
        }
        menuHandler = nil
        lastShownPhase = nil
        resultGeneration &+= 1
        guard let display else { return }
        let view = AgentDisplayPermissionMapping.makeView(
            summary: summary,
            onAllow: { [weak self] in self?.permissionHandler?(.allow) },
            onDeny: { [weak self] in self?.permissionHandler?(.deny) },
            onLater: { [weak self] in self?.permissionHandler?(.later) }
        )

        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            if let view {
                try? await display.send(view)
            } else {
                try? await display.clearDisplay()
            }
        }
    }

    /// 显示一次性结果摘要（如任务完成）；4 秒后若无新显示则自动清屏。
    /// 清屏时优先回退到进行中的任务状态，其次回退到 fallback 回合状态。
    /// 期间任何新的状态/菜单/结果显示都会取消自动清屏，避免误清新内容。
    func showResult(title: String, text: String, fallback: AgentTurnPhase? = nil) {
        resultGeneration &+= 1
        let generation = resultGeneration
        lastShownPhase = nil
        menuHandler = nil
        guard let display else { return }

        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            if let view = AgentDisplayResultMapping.makeView(title: title, text: text) {
                try? await display.send(view)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard self.resultGeneration == generation else { return }
            if self.taskProgressCount > 0,
               let view = AgentDisplayTaskMapping.makeView(
                   count: self.taskProgressCount,
                   title: self.taskProgressTitle
               ) {
                try? await display.send(view)
            } else if let fallback,
                      let view = AgentDisplayStatusMapping.makeView(phase: fallback) {
                self.lastShownPhase = fallback
                try? await display.send(view)
            } else {
                try? await display.clearDisplay()
            }
        }
    }

    /// 显示后台任务进行中状态（图标 + 任务数 + 最新步骤文案）；
    /// 任务结束由调用方恢复回合状态。
    func showTaskProgress(count: Int, title: String? = nil) {
        taskProgressCount = count
        taskProgressTitle = title
        resultGeneration &+= 1
        lastShownPhase = nil
        menuHandler = nil
        guard let display else { return }

        Task { @MainActor [weak self, display] in
            guard let self else { return }
            guard let display = await self.ensureDisplayReady(display) else { return }
            if let view = AgentDisplayTaskMapping.makeView(count: count, title: title) {
                try? await display.send(view)
            } else {
                try? await display.clearDisplay()
            }
        }
    }

    /// 清空任务进度显示状态（无真实后台任务时调用，避免结果摘要回退到过期进度）
    func clearTaskProgress() {
        taskProgressCount = 0
        taskProgressTitle = nil
    }

    /// 惰性确保 display 处于 started：系统中断后允许重新拉起
    private func ensureDisplayReady(_ display: Display) async -> Display? {
        guard display.state != .started else { return display }
        display.start()
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if display.state == .started { return display }
        }
        return display.state == .started ? display : nil
    }

    /// 卸载显示（会话释放/页面退出时调用）
    func detach() {
        let display = self.display
        self.display = nil
        lastShownPhase = nil
        menuHandler = nil
        resultGeneration &+= 1
        let token = displayStateToken
        displayStateToken = nil
        Task { await token?.cancel() }
        display?.stop()
    }
}

// MARK: - 镜片端审计展示（纯映射，可测）

extension AgentAuditDisplayMapping {
    /// 审计动作 → 眼镜图标（MWDATDisplay.IconName 的 rawValue）
    static func glassesIconName(for action: AgentAuditAction) -> String {
        switch action {
        case .requested: return "bell"
        case .granted, .restored: return "checkmark"
        case .denied, .revoked: return "x"
        case .later, .skipped: return "clock"
        case .invoked: return "gear"
        }
    }

    /// 校验审计图标是否为 SDK 支持的图标（供测试与容错使用）
    static func isValidGlassesIcon(for action: AgentAuditAction) -> Bool {
        IconName(rawValue: glassesIconName(for: action)) != nil
    }

    /// 构造镜片端结果内容：标题 = 工具名 · 动作，正文 = 详情 · 相对时间
    static func resultContent(for entry: AgentAuditEntry, now: Date = Date()) -> (title: String, text: String) {
        let time = AgentTaskTimeFormatter.relativeTime(from: entry.date, now: now)
        let title = toolName(for: entry) + " · " + titleKey(for: entry.action).localized
        let text = entry.detail.isEmpty ? time : entry.detail + " · " + time
        return (title, text)
    }
}
