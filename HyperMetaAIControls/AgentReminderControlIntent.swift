/*
 * 锁屏提醒倒计时卡交互 Intent
 * 运行在 Widget 扩展进程：只写入 App Group 请求标记（稍后提醒 / 完成），
 * 由 App 前台消费并应用到「当前展示的倒计时提醒」（与通知 Action 同一语义）。
 */

import AppIntents
import Foundation

/// 提醒倒计时卡的交互动作
enum AgentReminderActionOption: String, AppEnum {
    case snooze
    case complete

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "提醒操作"
    static var caseDisplayRepresentations: [AgentReminderActionOption: DisplayRepresentation] = [
        .snooze: "稍后提醒",
        .complete: "完成",
    ]
}

struct AgentReminderControlIntent: AppIntent {
    static var title: LocalizedStringResource = "提醒操作"
    static var description = IntentDescription("对锁屏提醒倒计时执行稍后提醒或完成")

    @Parameter(title: "操作")
    var action: AgentReminderActionOption

    init() {}

    init(action: AgentReminderActionOption) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        AgentReminderRequestStore.request(action == .snooze ? "snooze" : "complete")
        return .result()
    }
}

/// 提醒按钮请求标记（App Group 跨进程通道，与审批 / 查看任务同一模式）
enum AgentReminderRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.reminder.v1"

    static func request(_ raw: String) {
        (UserDefaults(suiteName: suiteName) ?? .standard).set(raw, forKey: requestKey)
    }
}
