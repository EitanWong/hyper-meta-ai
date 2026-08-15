/*
 * Agent Live Activity（锁屏 / 灵动岛）
 * 展示后台 Agent 任务进度、审批待确认与任务终态。
 * 文案由 App 侧生成后传入 ContentState，扩展只负责渲染（与 App 语言一致）。
 */

import ActivityKit
import SwiftUI
import WidgetKit

/// 任务进度 / 审批 / 结果 的锁屏与灵动岛展示
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentLiveActivityAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    if let phase = Self.voicePhase(from: context.state) {
                        HStack(spacing: 8) {
                            VoiceWaveformView(phase: phase, animated: true, barHeight: 18)
                            Text(context.state.detail)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    } else {
                        Text(context.state.detail)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: Self.iconName(for: context.state.mode))
                    .foregroundStyle(Self.iconColor(for: context.state.mode))
            } compactTrailing: {
                if let fireDate = context.state.countdownFireDate {
                    Text(timerInterval: Date()...fireDate, countsDown: true)
                        .font(.caption2)
                        .monospacedDigit()
                } else {
                    Text(Self.shortText(for: context.state))
                        .font(.caption2)
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: Self.iconName(for: context.state.mode))
                    .foregroundStyle(Self.iconColor(for: context.state.mode))
            }
        }
    }

    // MARK: - 纯映射（扩展内复用，与 App 侧模式语义一致）

    static func iconName(for mode: AgentLiveActivityAttributes.Mode) -> String {
        switch mode {
        case .taskProgress: return "clock.fill"
        case .approval: return "checkmark.shield.fill"
        case .result: return "checkmark.circle.fill"
        case .reminderCountdown: return "timer"
        case .calendarCountdown: return "calendar"
        case .voiceSession: return "waveform"
        }
    }

    static func iconColor(for mode: AgentLiveActivityAttributes.Mode) -> Color {
        switch mode {
        case .taskProgress: return .blue
        case .approval: return .orange
        case .result: return .green
        case .reminderCountdown: return .yellow
        case .calendarCountdown: return .red
        case .voiceSession: return .green
        }
    }

    static func shortText(for state: AgentLiveActivityAttributes.ContentState) -> String {
        switch state.mode {
        case .taskProgress:
            return state.taskCount > 1 ? "\(state.taskCount)" : "..."
        case .approval:
            return "!"
        case .result:
            return "✓"
        case .reminderCountdown, .calendarCountdown, .voiceSession:
            return "…"
        }
    }

    /// 语音会话阶段（nil = 非语音卡 / 旧活动无阶段字段）
    static func voicePhase(
        from state: AgentLiveActivityAttributes.ContentState
    ) -> AgentLiveActivityAttributes.VoicePhase? {
        guard let raw = state.voicePhase else { return nil }
        return AgentLiveActivityAttributes.VoicePhase(rawValue: raw)
    }
}

/// 语音波形（phase 驱动；animated 用 TimelineView 持续波动，否则取 t=0 静态高度）
private struct VoiceWaveformView: View {
    let phase: AgentLiveActivityAttributes.VoicePhase?
    let animated: Bool
    var barHeight: CGFloat = 16

    private var resolvedPhase: AgentLiveActivityAttributes.VoicePhase {
        phase ?? .listening
    }

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                bars(heights: AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
                    phase: resolvedPhase,
                    t: timeline.date.timeIntervalSinceReferenceDate
                ))
            }
        } else {
            bars(heights: AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
                phase: resolvedPhase,
                t: 0
            ))
        }
    }

    private func bars(heights: [Double]) -> some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(AgentLiveActivityWidget.iconColor(for: .voiceSession))
                    .frame(width: 3, height: max(2, barHeight * height))
            }
        }
        .frame(height: barHeight, alignment: .center)
        .animation(.linear(duration: 0.12), value: heights)
        .accessibilityHidden(true)
    }
}

/// 锁屏视图
private struct LockScreenView: View {
    let state: AgentLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: AgentLiveActivityWidget.iconName(for: state.mode))
                    .foregroundStyle(AgentLiveActivityWidget.iconColor(for: state.mode))
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                if state.taskCount > 1 {
                    Text("\(state.taskCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let expiresAt = state.approvalExpiresAt {
                    Text(timerInterval: Date()...expiresAt, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(state.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // 任务进行中：取消 / 加速（锁屏快捷控制，App 前台消费后作用到网关任务）
            if state.mode == .taskProgress {
                HStack(spacing: 8) {
                    Button(intent: AgentTaskControlIntent(action: .cancel)) {
                        Label("取消", systemImage: "xmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button(intent: AgentTaskControlIntent(action: .accelerate)) {
                        Label("加速", systemImage: "bolt.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
            // 提醒 / 日程倒计时：系统计时器自动走秒（对齐系统计时器 App 的锁屏体验）
            if state.mode == .reminderCountdown || state.mode == .calendarCountdown,
               let fireDate = state.countdownFireDate {
                Text(timerInterval: Date()...fireDate, countsDown: true)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 提醒倒计时：稍后提醒 / 完成（与提醒通知 Action 同一语义）
            if state.mode == .reminderCountdown {
                HStack(spacing: 8) {
                    Button(intent: AgentReminderControlIntent(action: .snooze)) {
                        Label("稍后提醒", systemImage: "alarm")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                    Button(intent: AgentReminderControlIntent(action: .complete)) {
                        Label("完成", systemImage: "checkmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            // 任务终态：失败 → 重试 / 查看任务；成功或取消 → 追问 / 查看任务（iOS 17 锁屏交互）
            if state.mode == .result {
                HStack(spacing: 8) {
                    if state.resultKind == AgentLiveActivityAttributes.ResultKind.failed.rawValue {
                        Button(intent: AgentTaskRetryControlIntent()) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(intent: AgentTaskFollowUpControlIntent()) {
                            Label("追问", systemImage: "arrow.up.message.fill")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                    Button(intent: AgentTaskViewControlIntent()) {
                        Label("查看任务", systemImage: "checklist")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            // 语音会话进行中：状态行（聆听 / 思考 / 回复 / 休眠 / 连接）+ 停止；
            // 休眠态额外提供「唤醒」（与语音页唤醒词同一语义，经 App Group 通道）
            if state.mode == .voiceSession {
                HStack(spacing: 8) {
                    VoiceWaveformView(
                        phase: AgentLiveActivityWidget.voicePhase(from: state),
                        animated: false,
                        barHeight: 14
                    )
                    if state.voicePhase == AgentLiveActivityAttributes.VoicePhase.sleeping.rawValue {
                        Button(intent: WakeVoiceSessionControlIntent()) {
                            Label("唤醒", systemImage: "waveform.badge.mic")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                    Button(intent: StopVoiceSessionControlIntent()) {
                        Label("停止", systemImage: "stop.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            // 审批待确认：批准 / 拒绝直达（镜片审批的锁屏版）
            if state.mode == .approval {
                HStack(spacing: 8) {
                    Button(intent: AgentApprovalControlIntent(decision: .init(default: .deny))) {
                        Label("拒绝", systemImage: "xmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button(intent: AgentApprovalControlIntent(decision: .init(default: .allow))) {
                        Label("批准", systemImage: "checkmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.9))
        .activitySystemActionForegroundColor(.white)
    }
}

/// 灵动岛展开态 · 左侧（图标 + 标题）
private struct IslandLeading: View {
    let state: AgentLiveActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: AgentLiveActivityWidget.iconName(for: state.mode))
                .foregroundStyle(AgentLiveActivityWidget.iconColor(for: state.mode))
            Text(state.title)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

/// 灵动岛展开态 · 右侧（任务数 / 审批倒计时）
private struct IslandTrailing: View {
    let state: AgentLiveActivityAttributes.ContentState

    var body: some View {
        if let fireDate = state.countdownFireDate {
            Text(timerInterval: Date()...fireDate, countsDown: true)
                .font(.caption.monospacedDigit())
        } else if let expiresAt = state.approvalExpiresAt {
            Text(timerInterval: Date()...expiresAt, countsDown: true)
                .font(.caption.monospacedDigit())
        } else if state.taskCount > 1 {
            Text("×\(state.taskCount)")
                .font(.caption.weight(.bold))
        }
    }
}
