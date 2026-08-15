/*
 * 任务 Live Activity「查看任务」Intent
 * 运行在 Widget 扩展进程：只写入 App Group 请求标记，由 App 前台消费并
 * 深链到 Agent Hub（与 Control Center 语音会话同一通道模式）。
 */

import AppIntents
import Foundation

/// App 与 Live Activity 扩展共享的「查看任务」请求通道（App Group UserDefaults）
enum AgentTaskViewRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.viewTask.v1"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func requestViewTask() {
        defaults.set(true, forKey: requestKey)
    }

    static func clear() {
        defaults.removeObject(forKey: requestKey)
    }
}

/// 任务 Live Activity「查看任务」按钮：打开 App 并请求进入 Agent Hub
struct AgentTaskViewControlIntent: AppIntent {
    static var title: LocalizedStringResource = "查看任务"
    static var description = IntentDescription("打开 App 查看 JARVIS 的任务进度与结果")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        AgentTaskViewRequestStore.requestViewTask()
        return .result()
    }
}

// MARK: - 任务控制（取消 / 加速）

/// 任务 Live Activity 锁屏卡的交互动作
enum AgentTaskControlOption: String, AppEnum {
    case cancel
    case accelerate

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "任务操作"
    static var caseDisplayRepresentations: [AgentTaskControlOption: DisplayRepresentation] = [
        .cancel: "取消",
        .accelerate: "加速",
    ]
}

/// 任务 Live Activity「取消 / 加速」Intent
/// 运行在 Widget 扩展进程：只写入 App Group 请求标记，由 App 前台消费并
/// 应用到最近的活动任务（与提醒倒计时卡按钮同一通道模式）。
struct AgentTaskControlIntent: AppIntent {
    static var title: LocalizedStringResource = "任务操作"
    static var description = IntentDescription("对正在进行的 JARVIS 任务执行取消或加速")

    @Parameter(title: "操作")
    var action: AgentTaskControlOption

    init() {}

    init(action: AgentTaskControlOption) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        AgentTaskControlRequestStore.request(action == .cancel ? "cancel" : "accelerate")
        return .result()
    }
}

/// 任务控制按钮请求标记（App Group 跨进程通道，与审批 / 查看任务同一模式）
enum AgentTaskControlRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.taskControl.v1"

    static func request(_ raw: String) {
        (UserDefaults(suiteName: suiteName) ?? .standard).set(raw, forKey: requestKey)
    }
}

// MARK: - 结果「重试」

/// 任务结果 Live Activity「重试」Intent（失败任务）
/// 运行在 Widget 扩展进程：只写 App Group 请求标记，App 前台消费后
/// 按最近失败任务恢复重试闭环（与通知「重试」Action 同一语义）。
struct AgentTaskRetryControlIntent: AppIntent {
    static var title: LocalizedStringResource = "重试"
    static var description = IntentDescription("重新执行失败的 JARVIS 任务")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        AgentTaskRetryRequestStore.request()
        return .result()
    }
}

/// 「重试」按钮请求标记（App Group 跨进程通道）
enum AgentTaskRetryRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.taskRetry.v1"

    static func request() {
        (UserDefaults(suiteName: suiteName) ?? .standard).set(true, forKey: requestKey)
    }
}

// MARK: - 结果「一键追问」

/// 任务结果 Live Activity「追问」Intent
/// 运行在 Widget 扩展进程：只写 App Group 请求标记，App 前台消费后
/// 恢复任务结果上下文并打开语音会话页（与任务控制按钮同一通道模式）。
struct AgentTaskFollowUpControlIntent: AppIntent {
    static var title: LocalizedStringResource = "追问"
    static var description = IntentDescription("带着任务结果继续追问 JARVIS")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        AgentTaskFollowUpRequestStore.request()
        return .result()
    }
}

/// 「追问」按钮请求标记（App Group 跨进程通道）
enum AgentTaskFollowUpRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.followUp.v1"

    static func request() {
        (UserDefaults(suiteName: suiteName) ?? .standard).set(true, forKey: requestKey)
    }
}
