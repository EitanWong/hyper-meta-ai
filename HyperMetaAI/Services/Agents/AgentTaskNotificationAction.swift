/*
 * Agent Task Notification Actions
 * 任务完成 / 失败通知的交互 Action：查看结果（深链打开 Agent Hub）与
 * 稍后提醒（10 分钟后重发同一通知）。分类注册、动作解析、重发构造
 * 均为纯逻辑 / 协议注入，可测。
 */

import Foundation
import UserNotifications

// MARK: - 通知分类

enum AgentTaskNotificationCategory {
    /// 任务完成通知分类（查看结果 / 追问 / 稍后提醒）
    static let doneIdentifier = "agent.task.category.done"
    /// 任务失败通知分类（查看 / 重试 / 稍后提醒）
    static let failedIdentifier = "agent.task.category.failed"
    /// 旧分类标识（历史通知兼容路由；新通知按状态使用 done / failed）
    static let identifier = "agent.task.category"
    static let viewIdentifier = "AGENT_TASK_VIEW"
    static let snoozeIdentifier = "AGENT_TASK_SNOOZE"
    static let followUpIdentifier = "AGENT_TASK_FOLLOWUP"
    static let retryIdentifier = "AGENT_TASK_RETRY"
    /// 锁屏文本输入「回复 JARVIS」（文本作为指令交给 JARVIS，无需打开 App 打字）
    static let replyIdentifier = "AGENT_TASK_REPLY"
    /// 稍后提醒间隔
    static let snoozeInterval: TimeInterval = 10 * 60

    /// 锁屏「回复 JARVIS」文本输入 Action（iOS 通知文本输入，系统原生）
    static var replyAction: UNTextInputNotificationAction {
        UNTextInputNotificationAction(
            identifier: replyIdentifier,
            title: "agent.task.action.reply".localized,
            options: [.foreground],
            textInputButtonTitle: "agent.task.action.reply.send".localized,
            textInputPlaceholder: "agent.task.action.reply.placeholder".localized
        )
    }

    /// 完成类任务通知动作：查看结果 / 追问 / 稍后提醒
    static var doneActions: [UNNotificationAction] {
        [
            UNNotificationAction(
                identifier: viewIdentifier,
                title: "agent.task.action.view".localized,
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: followUpIdentifier,
                title: "agent.task.action.followup".localized,
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: snoozeIdentifier,
                title: "agent.task.action.snooze".localized,
                options: []
            ),
            replyAction
        ]
    }

    /// 失败类任务通知动作：查看结果 / 重试 / 稍后提醒（失败任务无结果可追问）
    static var failedActions: [UNNotificationAction] {
        [
            UNNotificationAction(
                identifier: viewIdentifier,
                title: "agent.task.action.view".localized,
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: retryIdentifier,
                title: "agent.task.action.retry".localized,
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: snoozeIdentifier,
                title: "agent.task.action.snooze".localized,
                options: []
            ),
            replyAction
        ]
    }

    /// 按任务状态选择动作集（失败 → 重试；其余 → 追问）
    static func actions(for status: String) -> [UNNotificationAction] {
        status == QwenAgentTask.Status.failed.notificationRaw ? failedActions : doneActions
    }

    /// 按任务状态选择通知分类标识
    static func categoryIdentifier(for status: String) -> String {
        status == QwenAgentTask.Status.failed.notificationRaw ? failedIdentifier : doneIdentifier
    }

    /// 是否任务通知分类（done / failed / 历史 identifier）
    static func isTaskCategory(_ identifier: String) -> Bool {
        identifier == doneIdentifier || identifier == failedIdentifier || identifier == Self.identifier
    }

    static func register() {
        let done = UNNotificationCategory(
            identifier: doneIdentifier,
            actions: doneActions,
            intentIdentifiers: [],
            options: []
        )
        let failed = UNNotificationCategory(
            identifier: failedIdentifier,
            actions: failedActions,
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([done, failed])
    }
}

// MARK: - 通知载荷（任务上下文跨进程携带）

/// 任务通知 userInfo 构造 / 解析（纯逻辑，可测）：
/// 通知 Action（如重试）需要知道目标任务，键与巡检投递一致。
enum AgentTaskNotificationUserInfo {
    static let taskIdKey = "agent.task.notify.taskId"
    static let sourceTextKey = "agent.task.notify.sourceText"

    static func make(task: PersistedAgentTask) -> [String: String] {
        var info = [taskIdKey: task.taskId]
        if let source = task.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            info[sourceTextKey] = source
        }
        return info
    }

    static func taskId(from userInfo: [AnyHashable: Any]?) -> String? {
        userInfo?[taskIdKey] as? String
    }

    static func sourceText(from userInfo: [AnyHashable: Any]?) -> String? {
        userInfo?[sourceTextKey] as? String
    }
}

// MARK: - 动作解析（纯逻辑）

/// 任务通知动作（纯值）
enum AgentTaskNotificationAction: Equatable {
    case view
    case snooze(after: TimeInterval)
    /// 一键追问：打开语音页并携带任务结果上下文，直接开口继续追问
    case followUp
    /// 一键重试失败任务：App 内会话持有任务时直接重试，否则带指令打开语音页
    case retry
    /// 锁屏文本输入回复：文本作为指令交给 JARVIS（语音页自动发送，本地指令同样拦截）
    case reply(text: String)
    case none
}

enum AgentTaskNotificationActionParser {
    /// text 为文本输入 Action 的用户输入（无输入 Action 时为 nil）
    static func parse(
        actionIdentifier: String,
        text: String? = nil
    ) -> AgentTaskNotificationAction {
        switch actionIdentifier {
        case AgentTaskNotificationCategory.viewIdentifier,
             UNNotificationDefaultActionIdentifier:
            // 直接点按通知与「查看结果」都打开 Agent Hub
            return .view
        case AgentTaskNotificationCategory.snoozeIdentifier:
            return .snooze(after: AgentTaskNotificationCategory.snoozeInterval)
        case AgentTaskNotificationCategory.followUpIdentifier:
            return .followUp
        case AgentTaskNotificationCategory.retryIdentifier:
            return .retry
        case AgentTaskNotificationCategory.replyIdentifier:
            return .reply(text: text ?? "")
        default:
            return .none
        }
    }
}

// MARK: - 稍后提醒重发构造（纯逻辑）

struct AgentTaskSnoozePayload: Equatable {
    var identifier: String
    var title: String
    var body: String
    var userInfo: [AnyHashable: Any]?
    var triggerDate: Date
    /// 沿用原通知分类（失败任务重发后仍带「重试」Action）
    var categoryIdentifier: String

    static func == (lhs: AgentTaskSnoozePayload, rhs: AgentTaskSnoozePayload) -> Bool {
        lhs.identifier == rhs.identifier
            && lhs.title == rhs.title
            && lhs.body == rhs.body
            && lhs.triggerDate == rhs.triggerDate
            && lhs.categoryIdentifier == rhs.categoryIdentifier
            && NSDictionary(dictionary: lhs.userInfo ?? [:]) == NSDictionary(dictionary: rhs.userInfo ?? [:])
    }
}

enum AgentTaskSnoozeBuilder {
    /// 构造重发载荷：复用原标题 / 正文 / userInfo，触发时间为 now + interval；
    /// 标识符带后缀避免与原始通知冲突（同任务可多次稍后提醒）。
    static func payload(
        from request: UNNotificationRequest,
        after interval: TimeInterval,
        now: Date = Date()
    ) -> AgentTaskSnoozePayload? {
        guard interval > 0 else { return nil }
        return AgentTaskSnoozePayload(
            identifier: "\(request.identifier).snoozed.\(Int(now.timeIntervalSince1970))",
            title: request.content.title,
            body: request.content.body,
            userInfo: request.content.userInfo,
            triggerDate: now.addingTimeInterval(interval),
            categoryIdentifier: request.content.categoryIdentifier
        )
    }
}

// MARK: - 动作执行（协议注入）

/// 任务通知动作路由（测试注入 Mock）
protocol AgentTaskNotificationActionRouting {
    func openAgentHub()
    func openFollowUp()
    func retryTask(taskId: String?, sourceText: String?)
    /// 锁屏文本回复：文本作为指令打开语音页（本地指令由语音页拦截）
    func replyToJARVIS(text: String)
}

/// 真实实现：查看结果经 AppNavigationRouter 深链到 Agent Hub；
/// 追问经 AgentTaskFollowUpCoordinator 恢复上下文并打开语音会话页；
/// 重试经 AgentTaskRetryCoordinator 按任务 ID 恢复重试闭环
@MainActor
final class AgentTaskNotificationActionRouter: AgentTaskNotificationActionRouting {
    static let shared = AgentTaskNotificationActionRouter()

    private init() {}

    func openAgentHub() {
        AppNavigationRouter.shared.request(.agentHub)
    }

    func openFollowUp() {
        AgentTaskFollowUpCoordinator.requestFollowUp()
    }

    func retryTask(taskId: String?, sourceText: String?) {
        AgentTaskRetryCoordinator.requestRetry(taskId: taskId, sourceText: sourceText)
    }

    func replyToJARVIS(text: String) {
        VoiceAssistantRouter.shared.requestVoiceSession(instruction: text)
    }
}

/// 通知投递（测试注入 Mock）
protocol AgentTaskNotificationScheduling {
    func add(_ request: UNNotificationRequest) async
}

/// 真实实现：投递到系统通知中心
final class SystemAgentTaskNotificationScheduler: AgentTaskNotificationScheduling {
    func add(_ request: UNNotificationRequest) async {
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// 动作执行器：查看结果 → 深链；稍后提醒 → 重发；未知 → 忽略
@MainActor
enum AgentTaskNotificationActionHandler {
    static func handle(
        action: AgentTaskNotificationAction,
        request: UNNotificationRequest,
        router: AgentTaskNotificationActionRouting = AgentTaskNotificationActionRouter.shared,
        scheduler: AgentTaskNotificationScheduling = SystemAgentTaskNotificationScheduler(),
        now: Date = Date()
    ) async {
        switch action {
        case .view:
            router.openAgentHub()
        case .snooze(let interval):
            guard let payload = AgentTaskSnoozeBuilder.payload(
                from: request,
                after: interval,
                now: now
            ) else { return }
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.userInfo = payload.userInfo ?? [:]
            content.sound = .default
            content.categoryIdentifier = payload.categoryIdentifier
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(payload.triggerDate.timeIntervalSince(now), 0.1),
                repeats: false
            )
            let newRequest = UNNotificationRequest(
                identifier: payload.identifier,
                content: content,
                trigger: trigger
            )
            await scheduler.add(newRequest)
        case .followUp:
            router.openFollowUp()
        case .retry:
            router.retryTask(
                taskId: AgentTaskNotificationUserInfo.taskId(from: request.content.userInfo),
                sourceText: AgentTaskNotificationUserInfo.sourceText(from: request.content.userInfo)
            )
        case .reply(let text):
            // 空输入忽略（用户可能误触发送）
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            router.replyToJARVIS(text: trimmed)
        case .none:
            break
        }
    }
}

// MARK: - 结果一键追问（通知 Action / 锁屏结果卡共用）

/// 追问上下文恢复（纯逻辑，可测）：
/// 优先用会话内存里已有的结果上下文（App 存活时任务完成即注入），
/// 否则从持久化任务快照取最近一条带详细结果的已完成任务。
enum AgentTaskFollowUpRestorer {
    static func restoreContext(
        sessionContext: String?,
        storedTasks: [PersistedAgentTask]
    ) -> String? {
        if let sessionContext,
           !sessionContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sessionContext
        }
        return storedTasks
            .filter { $0.status == QwenAgentTask.Status.completed.notificationRaw }
            .filter { task in
                guard let text = task.resultText else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .max { $0.updatedAt < $1.updatedAt }?
            .resultText
    }
}

/// Live Activity 结果卡「追问」按钮请求（App 侧消费）：扩展进程只写 App Group
/// 标记，App 读取并走与通知 Action 同一追问路径（一次性）。
enum AgentTaskFollowUpTapStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.followUp.v1"

    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> Bool {
        let store = defaults ?? .standard
        guard store.bool(forKey: requestKey) else { return false }
        store.removeObject(forKey: requestKey)
        return true
    }
}

/// 追问协调器（App 侧，@MainActor）：恢复结果上下文并请求打开语音会话页
/// （通知「追问」Action 与 Live Activity 结果卡按钮共用）。
@MainActor
enum AgentTaskFollowUpCoordinator {
    private static var observer: NSObjectProtocol?

    /// 注册 App Group 请求监听（幂等；跨进程 UserDefaults 变更）
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
                AgentTaskFollowUpCoordinator.consumeIfNeeded()
            }
        }
        consumeIfNeeded()
    }

    /// 恢复上下文并请求打开语音会话页；无上下文时也打开（用户可自由提问）。
    /// sessionContext / storedTasks 可注入（测试用）。
    static func requestFollowUp(
        sessionContext: String? = nil,
        storedTasks: [PersistedAgentTask]? = nil
    ) {
        let context = AgentTaskFollowUpRestorer.restoreContext(
            sessionContext: sessionContext ?? QwenVoiceSession.shared.resultFollowUpContext,
            storedTasks: storedTasks ?? AgentTaskNotificationStore.load()
        )
        VoiceAssistantRouter.shared.requestVoiceSession(
            brain: nil,
            instruction: nil,
            followUpContext: context
        )
    }

    /// 消费 Live Activity「追问」按钮标记并请求（defaults 可注入，测试用）
    @discardableResult
    static func consumeIfNeeded(defaults: UserDefaults? = nil) -> Bool {
        let store = defaults
            ?? UserDefaults(suiteName: AgentTaskFollowUpTapStore.suiteName)
            ?? .standard
        guard AgentTaskFollowUpTapStore.consume(defaults: store) else { return false }
        requestFollowUp()
        return true
    }
}

// MARK: - 失败任务重试（通知 Action / 深链共用）

/// 通知「重试」决策（纯逻辑，可测）：
/// 会话内已持有该失败任务 → 直接会话重试（保留系统提示与重放语义）；
/// 会话无任务（App 重启）→ 带指令打开语音页（指令优先重放原始口述，
/// 缺失时退化为自然语言重试指令）；
/// 既无会话任务也无持久化失败任务 → none（忽略）。
enum AgentTaskRetryPlanner {
    enum Plan: Equatable {
        case retryInSession(taskId: String?)
        case openVoiceSession(instruction: String)
        case none
    }

    static func plan(
        taskId: String?,
        sourceText: String?,
        sessionFailedTaskIDs: [String],
        storedTasks: [PersistedAgentTask]
    ) -> Plan {
        if let taskId, sessionFailedTaskIDs.contains(taskId) {
            return .retryInSession(taskId: taskId)
        }
        // 历史通知无 taskId：会话有失败任务时重试最近一个
        if taskId == nil, !sessionFailedTaskIDs.isEmpty {
            return .retryInSession(taskId: nil)
        }
        // 会话未持有该任务（App 重启）：从持久化快照定位并带指令打开语音页
        let stored = storedTask(taskId: taskId, storedTasks: storedTasks)
        guard let stored else { return .none }
        let instruction = instruction(
            sourceText: sourceText ?? stored.sourceText,
            title: stored.title
        )
        return .openVoiceSession(instruction: instruction)
    }

    /// 从持久化快照定位目标任务：优先按 ID；无 ID 时取最近失败任务
    static func storedTask(
        taskId: String?,
        storedTasks: [PersistedAgentTask]
    ) -> PersistedAgentTask? {
        if let taskId, let task = storedTasks.first(where: { $0.taskId == taskId }) {
            return task
        }
        return storedTasks
            .filter { $0.status == QwenAgentTask.Status.failed.notificationRaw }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// 重试指令文本：优先原样重放触发文本，缺失时退化为自然语言重试指令
    static func instruction(sourceText: String?, title: String) -> String {
        let source = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty { return source }
        let name = title.isEmpty ? "agent.task.untitled".localized : title
        return "agent.task.command.retry.instruction".localized(name)
    }
}

/// Live Activity 结果卡「重试」按钮请求（App 侧消费）：扩展进程只写
/// App Group 标记，App 读取后走与通知「重试」Action 同一重试闭环（一次性）。
enum AgentTaskRetryTapStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.taskRetry.v1"

    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> Bool {
        let store = defaults ?? .standard
        guard store.bool(forKey: requestKey) else { return false }
        store.removeObject(forKey: requestKey)
        return true
    }
}

/// 失败任务重试协调器（App 侧，@MainActor）：
/// 通知「重试」Action 与 Live Activity 结果卡「重试」按钮共用；
/// 会话内重试后 TTS + 镜片结果卡确认，否则带指令打开语音页。
@MainActor
enum AgentTaskRetryCoordinator {
    private static var observer: NSObjectProtocol?

    /// 注册 App Group 请求监听（幂等；跨进程 UserDefaults 变更）
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
                AgentTaskRetryCoordinator.consumeIfNeeded()
            }
        }
        consumeIfNeeded()
    }

    /// 消费一次 Live Activity「重试」按钮标记并执行（defaults / apply 可注入，测试用）。
    /// - Returns: 是否消费了请求标记。
    @discardableResult
    static func consumeIfNeeded(
        defaults: UserDefaults? = nil,
        apply: (() -> Bool)? = nil
    ) -> Bool {
        let store = defaults
            ?? UserDefaults(suiteName: AgentTaskRetryTapStore.suiteName)
            ?? .standard
        guard AgentTaskRetryTapStore.consume(defaults: store) else { return false }
        if let apply {
            _ = apply()
        } else {
            _ = requestRetry(taskId: nil, sourceText: nil)
        }
        return true
    }

    /// 执行一次重试（taskId / sourceText 来自通知载荷；均可注入便于测试）。
    /// - Returns: 是否发起了重试（会话内重试或语音页指令）。
    @discardableResult
    static func requestRetry(
        taskId: String?,
        sourceText: String?,
        session: QwenVoiceSession = QwenVoiceSession.shared,
        storedTasks: [PersistedAgentTask]? = nil
    ) -> Bool {
        let plan = AgentTaskRetryPlanner.plan(
            taskId: taskId,
            sourceText: sourceText,
            sessionFailedTaskIDs: session.failedTasks.map(\.taskId),
            storedTasks: storedTasks ?? AgentTaskNotificationStore.load()
        )
        switch plan {
        case .retryInSession(let targetID):
            let name: String?
            if let targetID {
                name = session.requestTaskRetry(taskId: targetID)
            } else {
                name = session.requestTaskRetry()
            }
            guard let name else { return false }
            announce("agent.task.command.retry.reply".localized(name))
            return true
        case .openVoiceSession(let instruction):
            VoiceAssistantRouter.shared.requestVoiceSession(
                brain: nil,
                instruction: instruction
            )
            return true
        case .none:
            return false
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
