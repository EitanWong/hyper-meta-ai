/*
 * Agent Background Task Inspector
 * JARVIS 后台任务巡检：App 侧在任务状态变化时把结构化任务持久化为快照，
 * 系统经 BGAppRefreshTask 在后台唤醒 App 时，对比「已通知任务」找出新进入
 * 终态（完成 / 失败）的任务，推送本地通知；同一任务同一终态只通知一次。
 * 决策（pendingNotifications）、快照存储与调度均纯逻辑 / 协议注入，可测。
 */

import BackgroundTasks
import Foundation
import UserNotifications

// MARK: - 持久化任务条目

/// 后台巡检用的任务快照（QwenAgentTask 的可持久化投影）
struct PersistedAgentTask: Codable, Equatable, Identifiable {
    var taskId: String
    var title: String
    var status: String
    var updatedAt: Date
    /// 详细结果文本（追问上下文来源；无详细结果时为 nil）
    var resultText: String?
    /// 触发任务的原始用户文本（通知「重试」跨进程重放来源；无口述时为 nil）
    var sourceText: String?

    var id: String { taskId }

    init(
        taskId: String,
        title: String,
        status: String,
        updatedAt: Date,
        resultText: String? = nil,
        sourceText: String? = nil
    ) {
        self.taskId = taskId
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.resultText = resultText
        self.sourceText = sourceText
    }

    init(task: QwenAgentTask) {
        self.init(
            taskId: task.taskId,
            title: task.title,
            status: task.status.notificationRaw,
            updatedAt: task.updatedAt,
            resultText: task.resultText,
            sourceText: task.sourceText
        )
    }

    /// 是否需要通知用户（完成 / 失败；取消与等待中 / 进行中不打扰）
    var needsNotification: Bool {
        status == QwenAgentTask.Status.completed.notificationRaw
            || status == QwenAgentTask.Status.failed.notificationRaw
    }
}

extension QwenAgentTask.Status {
    var notificationRaw: String {
        switch self {
        case .waiting: return "waiting"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: - 快照存储（UserDefaults JSON，可注入 defaults 便于测试）

enum AgentTaskNotificationStore {
    static let tasksKey = "agent.task.notify.tasks.v1"
    static let notifiedKey = "agent.task.notify.notified.v1"
    static let lastInspectionKey = "agent.task.notify.lastInspection.v1"
    /// 已通知任务 ID 记录上限（防无限增长）
    static let maxNotifiedIDs = 100

    static func save(_ tasks: [QwenAgentTask], defaults: UserDefaults = .standard) {
        let snapshot = tasks.map(PersistedAgentTask.init(task:))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: tasksKey)
    }

    static func load(defaults: UserDefaults = .standard) -> [PersistedAgentTask] {
        guard let data = defaults.data(forKey: tasksKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedAgentTask].self, from: data)) ?? []
    }

    static func notifiedTaskIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: notifiedKey) ?? [])
    }

    static func recordNotified(_ newIDs: [String], defaults: UserDefaults = .standard) {
        var stored = defaults.stringArray(forKey: notifiedKey) ?? []
        for id in newIDs {
            stored.removeAll { $0 == id }
            stored.insert(id, at: 0)
        }
        if stored.count > maxNotifiedIDs {
            stored = Array(stored.prefix(maxNotifiedIDs))
        }
        defaults.set(stored, forKey: notifiedKey)
    }

    static func lastInspectionDate(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastInspectionKey) as? Date
    }

    static func setLastInspectionDate(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastInspectionKey)
    }
}

// MARK: - 决策（纯逻辑，可测）

enum AgentBackgroundTaskInspector {
    /// 单次巡检最多通知条数（防后台唤醒一次性轰炸）
    static let maxNotificationsPerRun = 3

    /// 找出新进入终态且尚未通知过的任务（按更新时间倒序，封顶 3 条）
    static func pendingNotifications(
        tasks: [PersistedAgentTask],
        lastNotifiedTaskIDs: Set<String>
    ) -> [PersistedAgentTask] {
        tasks
            .filter { $0.needsNotification && !lastNotifiedTaskIDs.contains($0.taskId) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxNotificationsPerRun)
            .map { $0 }
    }

    /// 通知标题（完成 / 失败）
    static func notificationTitle(for task: PersistedAgentTask) -> String {
        task.status == QwenAgentTask.Status.completed.notificationRaw
            ? "agent.task.notify.done.title".localized
            : "agent.task.notify.failed.title".localized
    }

    /// 通知正文：任务标题（空标题回退通用文案）
    static func notificationBody(for task: PersistedAgentTask) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatKey = task.status == QwenAgentTask.Status.completed.notificationRaw
            ? "agent.task.notify.done.body"
            : "agent.task.notify.failed.body"
        let fallback = "agent.task.notify.unnamed".localized
        return String(format: formatKey.localized, title.isEmpty ? fallback : title)
    }

    /// 任务是否为失败终态
    static func isFailure(_ task: PersistedAgentTask) -> Bool {
        task.status == QwenAgentTask.Status.failed.notificationRaw
    }
}

// MARK: - 通知发送（协议注入，测试 Mock）

protocol AgentBackgroundNotifying {
    func send(
        title: String,
        body: String,
        level: UNNotificationInterruptionLevel,
        task: PersistedAgentTask
    ) async
}

/// 真实实现：通知权限已授权（或临时授权）时投递本地通知
final class SystemAgentTaskNotifier: AgentBackgroundNotifying {
    func send(
        title: String,
        body: String,
        level: UNNotificationInterruptionLevel,
        task: PersistedAgentTask
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let status = settings.authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = level
        content.userInfo = AgentTaskNotificationUserInfo.make(task: task)
        content.categoryIdentifier = AgentTaskNotificationCategory.categoryIdentifier(
            for: task.status
        )
        let request = UNNotificationRequest(
            identifier: "agent.task.notify.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

// MARK: - 巡检执行（快照 + 通知闭环）

enum AgentBackgroundTaskRunner {
    static func run(
        defaults: UserDefaults = .standard,
        notifier: AgentBackgroundNotifying = SystemAgentTaskNotifier()
    ) async -> Int {
        let tasks = AgentTaskNotificationStore.load(defaults: defaults)
        let lastNotified = AgentTaskNotificationStore.notifiedTaskIDs(defaults: defaults)
        let pending = AgentBackgroundTaskInspector.pendingNotifications(
            tasks: tasks,
            lastNotifiedTaskIDs: lastNotified
        )
        guard !pending.isEmpty else { return 0 }

        for task in pending {
            await notifier.send(
                title: AgentBackgroundTaskInspector.notificationTitle(for: task),
                body: AgentBackgroundTaskInspector.notificationBody(for: task),
                level: .active,
                task: task
            )
        }
        AgentTaskNotificationStore.recordNotified(
            pending.map(\.taskId),
            defaults: defaults
        )
        AgentTaskNotificationStore.setLastInspectionDate(Date(), defaults: defaults)
        return pending.count
    }
}

// MARK: - 后台任务调度（BGTaskScheduler）

/// 任务通知开关（UserDefaults 持久化）
enum AgentTaskNotificationSettings {
    static let enabledKey = "agent.task.notify.enabled"

    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledKey)
    }
}

/// 后台任务巡检（机会式）：注册 / 提交 / 处理
@MainActor
enum AgentTaskBackgroundTask {
    static let identifier = "com.lunflux.hyper-meta-ai.task-inspect"

    static func register() {
        // 任务通知的交互 Action（查看结果 / 稍后提醒）
        AgentTaskNotificationCategory.register()
        // 「问 JARVIS」结果通知的交互 Action（继续追问）
        AgentAskResultNotificationCategory.register()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            MainActor.assumeIsolated {
                handle(task)
            }
        }
    }

    /// App 进后台时提交（仅开关开启时）
    static func submitIfNeeded() {
        guard AgentTaskNotificationSettings.enabled() else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        Task {
            _ = await AgentBackgroundTaskRunner.run()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        submitIfNeeded()
    }
}
