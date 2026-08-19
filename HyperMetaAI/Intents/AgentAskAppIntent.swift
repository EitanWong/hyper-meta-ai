/*
 * Agent Ask App Intent
 * 「问 JARVIS」：Siri / 快捷指令 / 自动化把一句话交给当前 Agent（Hermes /
 * OpenClaw / 自定义），后台执行后经 Siri 对话直接朗读回复；眼镜连接且 App
 * 在前台时同步把完整回复渲染到镜片。openAppWhenRun = false，不需要打开 App。
 *
 * 结果判定与应答文案为纯逻辑（AgentAskIntentOutcome / Formatter），
 * 单轮调用经可注入的 send 闭包（AgentAskGateway 真实实现），便于单元测试。
 */

import AppIntents
import Foundation
import UIKit
import UserNotifications

// MARK: - 大脑选项

/// Siri 可选的 Agent 大脑（Qwen 原生实时语音不参与后台单轮问答）
enum AgentAskBrainOption: String, AppEnum {
    case auto
    case none
    case hermes
    case openclaw
    case custom

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "agent.ask.brain.title")

    static var caseDisplayRepresentations: [AgentAskBrainOption: DisplayRepresentation] {
        [
            .auto: "agent.ask.brain.auto",
            .none: "agent.ask.brain.none",
            .hermes: "agent.ask.brain.hermes",
            .openclaw: "agent.ask.brain.openclaw",
            .custom: "agent.ask.brain.custom"
        ]
    }

    var agentBrain: AgentBrain {
        switch self {
        case .auto: return .auto
        case .none: return .none
        case .hermes: return .hermes
        case .openclaw: return .openclaw
        case .custom: return .custom
        }
    }
}

// MARK: - 结果与文案

/// 单轮问答结果（纯值，可测）
enum AgentAskIntentOutcome: Equatable {
    case replied(text: String)
    case empty(text: String)
    case unavailable(text: String)
    case timedOut(text: String)
    case failed(text: String, reason: String)
}

/// 结果 → Siri 应答文案（纯构造，可测；回复过长时截断保护）
enum AgentAskIntentFormatter {
    /// 对话上限（Siri 朗读与展示的合理长度）
    static let maxDialogLength = 500

    static func dialog(for outcome: AgentAskIntentOutcome) -> String {
        switch outcome {
        case .replied(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > maxDialogLength else { return trimmed }
            return String(trimmed.prefix(maxDialogLength)) + "…"
        case .empty:
            return "agent.ask.intent.empty".localized
        case .unavailable:
            return "agent.ask.intent.unavailable".localized
        case .timedOut:
            return "agent.ask.intent.timeout".localized
        case .failed(_, let reason):
            return String(format: "agent.ask.intent.failed".localized, reason)
        }
    }
}

// MARK: - 真实网关

/// 把文本交给指定大脑的单轮调用（真实实现；可被测试注入替换）
@MainActor
enum AgentAskGateway {
    /// Hermes / OpenClaw / 自定义 的单轮发送。
    /// - Parameters:
    ///   - onFinal: 最终回复（完整文本）
    ///   - onError: 失败原因（本地化文案）
    static func send(
        _ text: String,
        brain: AgentBrain,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        switch brain {
        case .auto, .none, .qwen:
            onError("agent.ask.intent.unavailable".localized)
        case .hermes, .openclaw, .custom:
            // 内置网关协调语义：协调提示词 + 协议重试 + 最终语音（presentation.speech），
            // 与后台工作队列共用同一套 qwen_audio_agent_protocol（兼容 v1.10.1）。
            AgentGatewayService.shared.runSingleTurn(text, brain: brain) { result in
                switch result {
                case .success(let decision):
                    let speech = decision.presentation.speech.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    if speech.isEmpty {
                        onError("agent.ask.intent.unavailable".localized)
                    } else {
                        onFinal(speech)
                    }
                case .failure(let error):
                    onError(error.errorDescription ?? "agent.gateway.error.unknown".localized)
                }
            }
        }
    }
}

// MARK: - 单轮执行器（可注入 send，便于测试）

/// 「问 JARVIS」执行器：空输入拦截、Auto 路由、超时保护、结果归一。
@MainActor
enum AgentAskIntentHandler {
    static func ask(
        message: String,
        brain: AgentBrain = .auto,
        timeout: TimeInterval = 40,
        availability: AgentBackendAvailability? = nil,
        send: (
            @MainActor (String, AgentBrain, @escaping (String) -> Void, @escaping (String) -> Void) -> Void
        ) = { text, brain, onFinal, onError in
            AgentAskGateway.send(text, brain: brain, onFinal: onFinal, onError: onError)
        }
    ) async -> AgentAskIntentOutcome {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty(text: message) }

        let resolved = AgentBrainRouter.resolvedBrain(
            trimmed,
            selection: brain,
            availability: availability
        )
        guard resolved.isConcreteBackend else {
            return .unavailable(text: trimmed)
        }

        return await withCheckedContinuation { continuation in
            var didResume = false
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: .timedOut(text: trimmed))
            }

            func resumeOnce(_ outcome: AgentAskIntentOutcome) {
                guard !didResume else { return }
                didResume = true
                timeoutTask.cancel()
                continuation.resume(returning: outcome)
            }

            send(trimmed, resolved, { finalText in
                resumeOnce(.replied(text: finalText))
            }, { reason in
                resumeOnce(.failed(text: trimmed, reason: reason))
            })
        }
    }
}

// MARK: - App Intent

struct AgentAskAppIntent: AppIntent {
    static var title: LocalizedStringResource = "agent.ask.intent.title"
    static var description = IntentDescription("agent.ask.intent.description")
    // 后台单轮问答：不需要打开 App，Siri 直接朗读回复
    static var openAppWhenRun: Bool = false

    @Parameter(title: "agent.ask.intent.message")
    var message: String

    @Parameter(title: "agent.ask.intent.brain", default: .auto)
    var brain: AgentAskBrainOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // 短语触发但未带消息时，让 Siri 追问要做什么（ChatGPT 同款交互）
        guard !trimmed.isEmpty else {
            let spoken = try await $message.requestValue("agent.ask.intent.prompt")
            let run = await runAsk(spoken)
            await notifyResult(run, message: spoken)
            return .result(
                dialog: IntentDialog(
                    stringLiteral: AgentAskIntentFormatter.dialog(for: run.outcome)
                )
            )
        }
        let run = await runAsk(trimmed)
        await notifyResult(run, message: trimmed)
        return .result(dialog: IntentDialog(stringLiteral: AgentAskIntentFormatter.dialog(for: run.outcome)))
    }

    /// 单轮问答 + 结果归档 + 镜片渲染（成功回复才归档到 Hub 时间线）
    @MainActor
    private func runAsk(_ text: String) async -> (outcome: AgentAskIntentOutcome, recordID: UUID?) {
        let outcome = await AgentAskIntentHandler.ask(
            message: text,
            brain: brain.agentBrain
        )
        guard case .replied(let reply) = outcome else {
            return (outcome, nil)
        }
        let record = AgentAskArchiver.makeRecord(message: text, reply: reply)
        AgentAskArchiver.save(record)
        // 眼镜连接且 App 在前台时，把完整回复渲染到镜片
        AgentDisplayHub.shared.showResult(
            title: "agent.ask.lens.title".localized,
            text: reply,
            fallback: .idle
        )
        return (outcome, record.id)
    }

    /// 后台（Siri / 快捷指令 / 自动化）完成时：投递结果通知（开关可配置，
    /// 携带记录深链 + 原文 / 大脑，供锁屏「重试」同一问题）
    @MainActor
    private func notifyResult(
        _ run: (outcome: AgentAskIntentOutcome, recordID: UUID?),
        message: String
    ) async {
        let appActive = UIApplication.shared.applicationState == .active
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: run.outcome,
            appActive: appActive,
            enabled: AgentAskResultSettings.enabled(),
            recordID: run.recordID,
            message: message,
            brain: brain.agentBrain
        )
    }
}

// MARK: - 后台问答结果通知

/// 是否投递结果通知（纯策略，可测）：仅 App 不在前台且开关开启时投递
enum AgentAskResultPolicy {
    static func shouldNotify(appActive: Bool, enabled: Bool) -> Bool {
        !appActive && enabled
    }
}

/// 结果通知设置（UserDefaults，可注入测试）
enum AgentAskResultSettings {
    static let key = "agent.ask.notify.result"

    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// 结果通知内容（纯构建，可测）：回复截断到通知合理长度，失败 / 超时 / 不可用复用既有文案
enum AgentAskResultContent {
    /// 通知正文上限（系统通知展示的合理长度）
    static let maxBodyLength = 180

    struct Payload: Equatable {
        let title: String
        let body: String
    }

    static func content(for outcome: AgentAskIntentOutcome) -> Payload? {
        switch outcome {
        case .replied(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let body = trimmed.count > maxBodyLength
                ? String(trimmed.prefix(maxBodyLength)) + "…"
                : trimmed
            return Payload(
                title: "agent.ask.notify.result.title".localized,
                body: body
            )
        case .empty:
            return nil
        case .unavailable, .timedOut, .failed:
            let dialog = AgentAskIntentFormatter.dialog(for: outcome)
            return Payload(
                title: "agent.ask.notify.result.failed".localized,
                body: dialog
            )
        }
    }
}

/// 通知投递（协议隔离，测试注入 Mock；真实实现检查授权）
protocol AgentAskResultNotifying {
    func send(
        title: String,
        body: String,
        recordID: UUID?,
        message: String?,
        brain: AgentBrain?
    ) async
}

/// 真实实现：通知权限已授权（或临时授权）时投递本地通知
final class SystemAgentAskResultNotifier: AgentAskResultNotifying {
    func send(
        title: String,
        body: String,
        recordID: UUID?,
        message: String?,
        brain: AgentBrain?
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let status = settings.authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 交互 Action：点按默认查看详情，按钮「继续追问 / 重试」打开语音页
        content.categoryIdentifier = AgentAskResultNotificationCategory.identifier
        // 携带记录 ID（深链详情 / 追问上下文）与原文 / 大脑（锁屏一键重试同一问题）
        content.userInfo = AgentAskResultDeepLink.userInfo(
            recordID: recordID,
            message: message,
            brain: brain
        )
        let request = UNNotificationRequest(
            identifier: "agent.ask.result.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

/// 「问 JARVIS」结果通知的深链载荷（纯构建 / 解析，可测）
enum AgentAskResultDeepLink {
    /// 标记键：结果通知 userInfo 身份
    static let key = "agent.ask.result"
    /// 记录 ID 键：点按后定位到 Hub 时间线里的结果详情
    static let recordKey = "agent.ask.result.record"
    /// 原始问题键：锁屏「重试」同一问题
    static let messageKey = "agent.ask.result.message"
    /// 大脑键：重试沿用原大脑（Auto / Hermes / OpenClaw / 自定义）
    static let brainKey = "agent.ask.result.brain"

    static func isAskResult(_ userInfo: [AnyHashable: Any]?) -> Bool {
        userInfo?[key] as? Bool == true
    }

    static func userInfo(
        recordID: UUID?,
        message: String? = nil,
        brain: AgentBrain? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [key: true]
        if let recordID {
            info[recordKey] = recordID.uuidString
        }
        if let message {
            info[messageKey] = message
        }
        if let brain {
            info[brainKey] = brain.rawValue
        }
        return info
    }

    static func recordID(from userInfo: [AnyHashable: Any]?) -> UUID? {
        guard let raw = userInfo?[recordKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    static func message(from userInfo: [AnyHashable: Any]?) -> String? {
        userInfo?[messageKey] as? String
    }

    static func brain(from userInfo: [AnyHashable: Any]?) -> AgentBrain? {
        guard let raw = userInfo?[brainKey] as? String else { return nil }
        return AgentBrain(rawValue: raw)
    }
}

/// 后台问答结果通知协调器（App 侧，@MainActor）：
/// 满足「App 不在前台 + 开关开启」且结果可呈现时投递本地通知。
@MainActor
enum AgentAskResultCoordinator {
    static func notifyIfNeeded(
        outcome: AgentAskIntentOutcome,
        appActive: Bool,
        enabled: Bool,
        recordID: UUID? = nil,
        message: String? = nil,
        brain: AgentBrain? = nil,
        notifier: AgentAskResultNotifying? = nil
    ) async {
        guard AgentAskResultPolicy.shouldNotify(appActive: appActive, enabled: enabled),
              let content = AgentAskResultContent.content(for: outcome) else { return }
        await (notifier ?? SystemAgentAskResultNotifier()).send(
            title: content.title,
            body: content.body,
            recordID: recordID,
            message: message,
            brain: brain
        )
    }
}

// MARK: - 结果通知「重试」协调器

/// 「问 JARVIS」结果通知「重试」执行器（@MainActor，可注入 send / storage / notifier）：
/// 重新执行同一问题的单轮问答——成功归档 + 镜片结果卡（失败显示明确文案），
/// 再按「App 不在前台 + 开关开启」投递结果通知（与 Siri 触发同一策略）。
@MainActor
enum AgentAskRetryCoordinator {
    static func retry(
        message: String,
        brain: AgentBrain,
        timeout: TimeInterval = 40,
        appActive: Bool? = nil,
        storage: ConversationStorage = .shared,
        notifier: AgentAskResultNotifying? = nil,
        send: (
            @MainActor (String, AgentBrain, @escaping (String) -> Void, @escaping (String) -> Void) -> Void
        ) = { text, brain, onFinal, onError in
            AgentAskGateway.send(text, brain: brain, onFinal: onFinal, onError: onError)
        }
    ) async -> AgentAskIntentOutcome {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty(text: message) }

        let outcome = await AgentAskIntentHandler.ask(
            message: trimmed,
            brain: brain,
            timeout: timeout,
            send: send
        )

        var recordID: UUID?
        if case .replied(let reply) = outcome {
            let record = AgentAskArchiver.makeRecord(message: trimmed, reply: reply)
            AgentAskArchiver.save(record, storage: storage)
            recordID = record.id
            // 眼镜连接且 App 在前台时，把完整回复渲染到镜片
            AgentDisplayHub.shared.showResult(
                title: "agent.ask.lens.title".localized,
                text: reply,
                fallback: .idle
            )
        } else {
            // 重试失败：镜片给出明确反馈（与 Siri 应答同一文案）
            AgentDisplayHub.shared.showResult(
                title: "agent.ask.retry.title".localized,
                text: AgentAskIntentFormatter.dialog(for: outcome),
                fallback: .idle
            )
        }

        // appActive 可注入（测试用）；生产读取系统前台状态——用户点按「重试」后 App 在前台
        // 时结果经镜片卡反馈，切到后台后由结果通知送达（与 Siri 触发同一策略）
        let isAppActive = appActive ?? (UIApplication.shared.applicationState == .active)
        await AgentAskResultCoordinator.notifyIfNeeded(
            outcome: outcome,
            appActive: isAppActive,
            enabled: AgentAskResultSettings.enabled(),
            recordID: recordID,
            message: trimmed,
            brain: brain,
            notifier: notifier
        )
        return outcome
    }
}

// MARK: - 「问 JARVIS」结果归档

/// 「问 JARVIS」结果归档（纯逻辑，可测）：
/// 成功的单轮问答以独立 Agent 标识落盘到 Hub 时间线，便于回溯与通知深链。
enum AgentAskArchiver {
    /// 归档用的独立 Agent 标识（与语音 / 聊天历史区分，Hub 时间线单独归类）
    static let aiModel = "agent-ask"

    /// 构建结果记录：一条用户问题 + 一条 JARVIS 回复
    static func makeRecord(
        message: String,
        reply: String,
        id: UUID = UUID(),
        timestamp: Date = Date(),
        language: String = "zh-CN"
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            timestamp: timestamp,
            messages: [
                ConversationMessage(
                    role: .user,
                    content: message.trimmingCharacters(in: .whitespacesAndNewlines),
                    timestamp: timestamp
                ),
                ConversationMessage(
                    role: .assistant,
                    content: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                    timestamp: timestamp
                ),
            ],
            aiModel: aiModel,
            language: language
        )
    }

    /// 是否归档（纯策略）：仅成功回复落盘，失败 / 超时 / 空输入不产生记录
    static func shouldArchive(_ outcome: AgentAskIntentOutcome) -> Bool {
        if case .replied = outcome { return true }
        return false
    }

    /// 写入存储（storage 可注入，测试用隔离的 UserDefaults suite）
    static func save(_ record: ConversationRecord, storage: ConversationStorage = .shared) {
        storage.saveConversation(record)
    }
}

// MARK: - 结果通知交互 Action（继续追问 / 查看详情）

/// 「问 JARVIS」结果通知分类：点按默认打开详情（深链），按钮「继续追问」打开语音页
enum AgentAskResultNotificationCategory {
    static let identifier = "agent.ask.result.category"
    static let followUpIdentifier = "AGENT_ASK_RESULT_FOLLOWUP"
    /// 锁屏「重试」同一问题（重新执行单轮问答，结果再次归档 / 上镜片 / 通知）
    static let retryIdentifier = "AGENT_ASK_RESULT_RETRY"
    /// 锁屏文本输入「回复 JARVIS」（文本作为指令交给 JARVIS，无需打开 App 打字）
    static let replyIdentifier = "AGENT_ASK_RESULT_REPLY"

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

    static var actions: [UNNotificationAction] {
        [
            UNNotificationAction(
                identifier: followUpIdentifier,
                title: "agent.ask.notify.action.followup".localized,
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: retryIdentifier,
                title: "agent.task.action.retry".localized,
                options: [.foreground]
            ),
            replyAction
        ]
    }

    static func register() {
        let category = UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// 「问 JARVIS」结果通知 Action（纯值）
enum AgentAskResultNotificationAction: Equatable {
    /// 点按通知：打开 Hub 时间线里的结果详情
    case openDetail
    /// 「继续追问」：打开语音页并携带该结果上下文
    case followUp
    /// 锁屏文本输入回复：文本作为指令交给 JARVIS（语音页自动发送，本地指令同样拦截）
    case reply(text: String)
    /// 锁屏「重试」：重新执行同一问题（沿用通知携带的原文与大脑）
    case retry
    case none
}

/// Action 解析（纯逻辑，可测）
enum AgentAskResultNotificationActionParser {
    /// text 为文本输入 Action 的用户输入（无输入 Action 时为 nil）
    static func parse(
        actionIdentifier: String,
        text: String? = nil
    ) -> AgentAskResultNotificationAction {
        switch actionIdentifier {
        case AgentAskResultNotificationCategory.followUpIdentifier:
            return .followUp
        case AgentAskResultNotificationCategory.replyIdentifier:
            return .reply(text: text ?? "")
        case AgentAskResultNotificationCategory.retryIdentifier:
            return .retry
        case UNNotificationDefaultActionIdentifier:
            return .openDetail
        default:
            return .none
        }
    }
}

/// 追问上下文恢复（纯逻辑，可测）：从归档记录取最后一条助手回复
enum AgentAskFollowUpContextResolver {
    static func resolve(
        recordID: UUID?,
        records: [ConversationRecord] = ConversationStorage.shared.loadAllConversations()
    ) -> String? {
        guard let recordID,
              let record = records.first(where: { $0.id == recordID }) else { return nil }
        return record.followUpContext
    }
}

/// 结果通知 Action 路由（测试注入 Mock）
protocol AgentAskResultNotificationActionRouting {
    func openDetail(recordID: UUID)
    func openFollowUp(recordID: UUID?)
    /// 锁屏文本回复：文本作为指令打开语音页，并携带该条结果上下文（与「继续追问」同一语义）
    func replyToJARVIS(text: String, recordID: UUID?)
    /// 锁屏「重试」：重新执行同一问题的单轮问答
    func retryAsk(message: String, brain: AgentBrain) async
}

/// 真实实现：详情经 AppNavigationRouter 深链；追问 / 回复恢复上下文后打开语音会话页
@MainActor
final class AgentAskResultNotificationActionRouter: AgentAskResultNotificationActionRouting {
    static let shared = AgentAskResultNotificationActionRouter()

    /// 结果上下文解析（默认从归档记录恢复；测试注入避免真实存储副作用）
    var resolveContext: (UUID?) -> String? = { AgentAskFollowUpContextResolver.resolve(recordID: $0) }

    private init() {}

    func openDetail(recordID: UUID) {
        AppNavigationRouter.shared.request(.conversation(recordID))
    }

    func openFollowUp(recordID: UUID?) {
        let context = resolveContext(recordID)
        AgentTaskFollowUpCoordinator.requestFollowUp(sessionContext: context)
    }

    func replyToJARVIS(text: String, recordID: UUID?) {
        let context = resolveContext(recordID)
        VoiceAssistantRouter.shared.requestVoiceSession(
            instruction: text,
            followUpContext: context
        )
    }

    func retryAsk(message: String, brain: AgentBrain) async {
        await AgentAskRetryCoordinator.retry(message: message, brain: brain)
    }
}

/// Action 执行器：查看详情 → 深链；继续追问 / 回复 → 语音页；重试 → 重新问答；未知 → 忽略
@MainActor
enum AgentAskResultNotificationActionHandler {
    static func handle(
        action: AgentAskResultNotificationAction,
        recordID: UUID?,
        message: String? = nil,
        brain: AgentBrain? = nil,
        router: AgentAskResultNotificationActionRouting = AgentAskResultNotificationActionRouter.shared
    ) async {
        switch action {
        case .openDetail:
            if let recordID {
                router.openDetail(recordID: recordID)
            }
        case .followUp:
            router.openFollowUp(recordID: recordID)
        case .reply(let text):
            // 空输入忽略（用户可能误触发送）
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            router.replyToJARVIS(text: trimmed, recordID: recordID)
        case .retry:
            // 通知未携带原文时不重试（防御：旧通知无载荷）
            guard let message,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            await router.retryAsk(message: message, brain: brain ?? .auto)
        case .none:
            break
        }
    }
}


// MARK: - 今日安排 App Intent

/// 「今日安排」结果（纯值，可测）
struct AgentDayOverviewIntentOutcome: Equatable {
    let text: String
}

/// 「今日安排」本地组装（纯逻辑，可测）：复用镜片 Today 总览文案，
/// 日历未授权静默为空；全空回退「一切就绪，暂无安排」。
enum AgentTodayIntentBuilder {
    /// 活动任务标题（进行中 / 等待中；完成 / 失败 / 取消不参与总览）
    static func activeTaskTitles(from tasks: [QwenAgentTask]) -> [String] {
        tasks
            .filter { $0.status == .running || $0.status == .waiting }
            .map(\.title)
    }

    static func outcome(
        events: [AgentCalendarEvent],
        reminders: [AgentReminder],
        taskTitles: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentDayOverviewIntentOutcome {
        AgentDayOverviewIntentOutcome(
            text: AgentTodayOverviewBuilder.content(
                events: events,
                reminders: reminders,
                taskTitles: taskTitles,
                now: now,
                calendar: calendar
            ).fullText
        )
    }
}

/// Siri / 快捷指令 / 自动化「今日安排」直达：本地组装日程 + 提醒 + 进行中任务，
/// 无需网络与 Agent，Siri 直接朗读（openAppWhenRun = false）；
/// App 在前台且眼镜连接时，同步把总览渲染到镜片（与语音口令同一入口）。
struct TodayAppIntent: AppIntent {
    static var title: LocalizedStringResource = "agent.today.intent.title"
    static var description = IntentDescription("agent.today.intent.description")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let events = await AgentCalendarDisplayMapping.upcomingEventsForMenu(
            provider: AgentCalendar.provider
        )
        let outcome = AgentTodayIntentBuilder.outcome(
            events: events,
            reminders: AgentReminderStore.reminders,
            taskTitles: AgentTodayIntentBuilder.activeTaskTitles(
                from: QwenVoiceSession.shared.activeTasks
            )
        )
        // App 在前台时同步渲染镜片（JARVIS 汇报今日安排）
        if UIApplication.shared.applicationState == .active {
            AgentDisplayHub.shared.showResult(
                title: AgentDisplayMenuMapping.title(for: .todayOverview),
                text: outcome.text,
                fallback: .idle
            )
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.text))
    }
}


// MARK: - 明日安排 App Intent

/// 「明日安排」本地组装（纯逻辑，可测）：复用镜片 Tomorrow 总览文案。
enum AgentTomorrowIntentBuilder {
    static func outcome(
        events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentDayOverviewIntentOutcome {
        AgentDayOverviewIntentOutcome(
            text: AgentTomorrowOverviewBuilder.content(
                events: events,
                now: now,
                calendar: calendar
            ).fullText
        )
    }
}

/// Siri / 快捷指令 / 自动化「明天安排」直达：本地组装明天日程（下一场 + 场次数），
/// 无需网络与 Agent，Siri 直接朗读（openAppWhenRun = false）；
/// App 在前台且眼镜连接时，同步把总览渲染到镜片（与语音口令同一入口）。
struct TomorrowAppIntent: AppIntent {
    static var title: LocalizedStringResource = "agent.tomorrow.intent.title"
    static var description = IntentDescription("agent.tomorrow.intent.description")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let events = await AgentCalendarDisplayMapping.tomorrowEventsForMenu(
            provider: AgentCalendar.provider
        )
        let outcome = AgentTomorrowIntentBuilder.outcome(events: events)
        // App 在前台时同步渲染镜片（JARVIS 汇报明日安排）
        if UIApplication.shared.applicationState == .active {
            AgentDisplayHub.shared.showResult(
                title: AgentDisplayMenuMapping.title(for: .tomorrowOverview),
                text: outcome.text,
                fallback: .idle
            )
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.text))
    }
}
