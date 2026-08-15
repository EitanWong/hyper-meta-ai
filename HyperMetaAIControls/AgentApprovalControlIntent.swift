/*
 * 任务 Live Activity 审批「批准 / 拒绝」Intent
 * 运行在 Widget 扩展进程：只写入 App Group 请求标记（allow / deny），
 * 由 App 前台消费并提交当前审批决策（与「查看任务」同一通道模式）。
 */

import AppIntents
import Foundation

/// App 与 Live Activity 扩展共享的审批请求通道（App Group UserDefaults）
enum AgentApprovalRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.approval.v1"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func request(_ rawValue: String) {
        defaults.set(rawValue, forKey: requestKey)
    }

    static func clear() {
        defaults.removeObject(forKey: requestKey)
    }
}

/// 审批决策选项（Siri 参数化短语 / Live Activity 按钮共用）
enum AgentApprovalDecisionOption: String, AppEnum {
    case allow
    case deny

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "审批决策")

    static var caseDisplayRepresentations: [AgentApprovalDecisionOption: DisplayRepresentation] {
        [
            .allow: DisplayRepresentation(title: "允许"),
            .deny: DisplayRepresentation(title: "拒绝")
        ]
    }
}

/// Live Activity 审批卡「批准 / 拒绝」按钮：打开 App 并提交决策
struct AgentApprovalControlIntent: AppIntent {
    static var title: LocalizedStringResource = "审批"
    static var description = IntentDescription("提交当前 JARVIS 权限审批决策")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "决策")
    var decision: AgentApprovalDecisionOption

    func perform() async throws -> some IntentResult {
        AgentApprovalRequestStore.request(decision.rawValue)
        return .result()
    }
}
