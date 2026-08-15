/*
 * Voice Assistant App Intent
 * 统一输入入口：Siri 短语 / Spotlight / Action Button / 快捷指令
 * 一键进入实时语音会话（与眼镜 tap、App 内按钮共用同一套回合语义）。
 * 支持参数化：指定 Agent 大脑与直接指令，供快捷指令组合使用。
 */

import AppIntents

// MARK: - Agent Brain Option

enum AgentBrainOption: String, AppEnum {
    case auto
    case qwen
    case hermes
    case openclaw

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent 大脑")

    static var caseDisplayRepresentations: [AgentBrainOption: DisplayRepresentation] {
        [
            .auto: "Auto",
            .qwen: "Qwen",
            .hermes: "Hermes",
            .openclaw: "OpenClaw"
        ]
    }

    var agentBrain: AgentBrain {
        switch self {
        case .auto: return .auto
        case .qwen: return .qwen
        case .hermes: return .hermes
        case .openclaw: return .openclaw
        }
    }
}

// MARK: - Voice Assistant App Intent

struct VoiceAssistantAppIntent: AppIntent {
    static var title: LocalizedStringResource = "voice.intent.title"
    static var description = IntentDescription("进入实时语音会话，与所选 Agent 对话")
    // 语音会话需要前台 + 眼镜 / 麦克风，必须打开 App
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Agent 大脑")
    var brain: AgentBrainOption?

    @Parameter(title: "直接指令")
    var instruction: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        VoiceAssistantRouter.shared.requestVoiceSession(
            brain: brain?.agentBrain,
            instruction: instruction
        )
        return .result(dialog: IntentDialog(stringLiteral: "voice.intent.dialog".localized))
    }
}

// MARK: - Stop Voice Assistant Intent（可后台执行）

struct StopVoiceAssistantAppIntent: AppIntent {
    static var title: LocalizedStringResource = "voice.intent.stop.title"
    static var description = IntentDescription("停止正在运行的语音会话")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = QwenVoiceSession.shared
        guard session.isActive else {
            return .result(dialog: IntentDialog(stringLiteral: "voice.intent.stop.idle".localized))
        }
        session.stop()
        return .result(dialog: IntentDialog(stringLiteral: "voice.intent.stop.dialog".localized))
    }
}

// MARK: - Task Status Intent（后台查询）

/// 任务进度应答文案的纯函数（可测试）
enum VoiceTaskStatusFormatter {
    static func dialog(summary: String?, runningCount: Int) -> String {
        if let summary, !summary.isEmpty {
            return summary
        }
        if runningCount > 0 {
            return String(format: "voice.intent.task.active".localized, runningCount)
        }
        return "voice.intent.task.none".localized
    }
}

struct VoiceTaskStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "voice.intent.task.title"
    static var description = IntentDescription("查询后台 Agent 任务进度")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = QwenVoiceSession.shared
        return .result(
            dialog: IntentDialog(
                stringLiteral: VoiceTaskStatusFormatter.dialog(
                    summary: session.taskProgressSummary,
                    runningCount: session.runningTaskCount
                )
            )
        )
    }
}
