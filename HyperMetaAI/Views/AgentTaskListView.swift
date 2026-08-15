/*
 * Agent Task List View
 * 后台任务列表共享组件：语音页与聊天页共用，
 * 展示 等待中/进行中/已结束 状态徽标、相对时间与最新步骤，点击重听结果。
 */

import SwiftUI

/// 后台任务列表（状态徽标 + 相对时间 + 最新步骤，点击重听）
struct AgentTaskListView: View {
    let tasks: [QwenAgentTask]
    let onReplay: (QwenAgentTask) -> Void
    /// 任务卡长按「在聊天中追问」（仅已完成且有结果的任务）；nil 时不显示
    var onFollowUpInChat: ((QwenAgentTask) -> Void)?
    var maxTasks = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("qwen.voice.tasks.section".localized)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(Array(tasks.prefix(maxTasks))) { task in
                Button {
                    onReplay(task)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        if task.status == .running {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: Self.taskSymbol(for: task.status))
                                .font(.system(size: 11))
                                .foregroundColor(Self.taskColor(for: task.status))
                                .frame(width: 16)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(task.title.isEmpty ? task.statusLabel : task.title)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if !task.title.isEmpty {
                                    Text(task.statusLabel)
                                        .font(.system(size: 10))
                                        .foregroundColor(Self.taskColor(for: task.status))
                                }
                                Text(AgentTaskTimeFormatter.relativeTime(from: task.updatedAt))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            if let result = task.resultText, !result.isEmpty {
                                Text(result)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                .buttonStyle(.plain)
                .contextMenu {
                    if AgentTaskFollowUpOffer.isEligible(task) {
                        Button {
                            onFollowUpInChat?(task)
                        } label: {
                            Label("agent.task.followup.inChat".localized, systemImage: "text.bubble")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

    /// 任务状态图标
    private static func taskSymbol(for status: QwenAgentTask.Status) -> String {
        switch status {
        case .waiting: return "clock"
        case .running: return "ellipsis.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    /// 任务状态颜色
    private static func taskColor(for status: QwenAgentTask.Status) -> Color {
        switch status {
        case .waiting: return .orange
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

// MARK: - 任务卡「在聊天中追问」（纯逻辑，可测）

/// 任务是否可发起「在聊天中追问」：已完成且有非空结果文本
enum AgentTaskFollowUpOffer {
    static func isEligible(_ task: QwenAgentTask) -> Bool {
        guard task.status == .completed else { return false }
        guard let result = task.resultText else { return false }
        return !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 聊天页「在聊天中追问」的一次性包装门：打开聊天页后第一条用户消息
/// 自动携带任务结果上下文（`QwenVoiceSession.followUpMessage` 包装），随后透传。
struct TaskFollowUpWrapGate {
    private(set) var isArmed: Bool

    init(armed: Bool = false) {
        isArmed = armed
    }

    /// 消费一次性包装标记；返回 true 表示当前消息需要携带结果上下文。
    @discardableResult
    mutating func consumeIfArmed() -> Bool {
        guard isArmed else { return false }
        isArmed = false
        return true
    }
}
