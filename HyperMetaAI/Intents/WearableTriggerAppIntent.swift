/*
 * Wearable Trigger App Intent
 * 「JARVIS 触发」系统入口：背部轻点 / 操作按钮 / Siri / 快捷指令
 * 统一分发到 AgentWearableTriggerCenter，与眼镜触发共用同一路由与触发日志。
 * 配置方式：设置 → 辅助功能 → 触控 → 背部轻点（或操作按钮）→ 快捷指令 →
 * 选择「触发 JARVIS」并指定动作（默认唤醒）。
 */

import AppIntents
import Foundation

// MARK: - 触发动作选项

enum AgentWearableTriggerOption: String, AppEnum {
    case wake
    case interrupt
    case resume
    case endTurn
    case captureVision
    case repeatLastReply

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "JARVIS 动作")

    static var caseDisplayRepresentations: [AgentWearableTriggerOption: DisplayRepresentation] {
        [
            .wake: "唤醒 JARVIS",
            .interrupt: "打断播报",
            .resume: "恢复聆听",
            .endTurn: "结束回合",
            .captureVision: "拍照识图",
            .repeatLastReply: "重听回复"
        ]
    }

    var gesture: AgentWearableGesture {
        switch self {
        case .wake: return .wake
        case .interrupt: return .interrupt
        case .resume: return .resume
        case .endTurn: return .endTurn
        case .captureVision: return .captureVision
        case .repeatLastReply: return .repeatLastReply
        }
    }
}

// MARK: - Trigger App Intent

struct WearableTriggerAppIntent: AppIntent {
    static var title: LocalizedStringResource = "agent.wearable.intent.title"
    static var description = IntentDescription("从背部轻点 / 操作按钮 / Siri / 快捷指令触发 JARVIS 动作")
    // 语音会话与拍照需要前台运行
    static var openAppWhenRun: Bool = true

    @Parameter(title: "动作", default: .wake)
    var trigger: AgentWearableTriggerOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = AgentWearableTriggerCenter.shared.dispatch(
            source: .backTap,
            gesture: trigger.gesture
        )
        return .result(dialog: IntentDialog(stringLiteral: "agent.wearable.intent.dialog".localized))
    }
}
