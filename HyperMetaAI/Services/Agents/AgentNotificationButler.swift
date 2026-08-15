/*
 * Agent Notification Butler
 * JARVIS 通知播报管家：前台新通知 TTS 摘要播报 +「有什么通知」未读汇总。
 *
 * iOS 无公开 API 可获取通知来源 App 名（UNNotification.source 仅 macOS），
 * 因此汇总按「内容」呈现（标题 / 正文，隐私分级可只播报条数）。
 * 汇总 / 策略 / 解析 / 收件箱为纯逻辑可测；UNUserNotificationCenter 走
 * AgentNotificationProviding 协议注入（测试用 Mock）。
 */

import Foundation
import UIKit
import UserNotifications

// MARK: - 通知模型

/// 归一化后的通知（与系统 UNNotification 解耦，便于测试）
struct AgentNotificationItem: Equatable {
    let id: String
    let title: String
    let body: String
    let date: Date
}

// MARK: - 设置

/// 播报隐私分级
enum AgentNotificationPrivacy: String, CaseIterable, Equatable {
    /// 只播报条数
    case titlesOnly
    /// 条数 + 标题
    case titles
    /// 条数 + 标题 + 正文（截断）
    case full

    var displayName: String {
        "agent.notify.privacy.\(rawValue)".localized
    }
}

/// 主动播报时机
enum AgentNotificationMode: String, CaseIterable, Equatable {
    /// 关闭主动播报（「有什么通知」查询仍可用）
    case off
    /// 仅语音会话活跃时播报（JARVIS 在场）
    case activeSession
    /// App 前台时播报
    case foreground

    var displayName: String {
        "agent.notify.mode.\(rawValue)".localized
    }
}

/// 通知播报偏好（UserDefaults 持久化）
enum AgentNotificationSettings {
    private static let modeKey = "agent.notify.mode"
    private static let privacyKey = "agent.notify.privacy"
    private static let maxItemsKey = "agent.notify.max.items"
    private static let maxTextLengthKey = "agent.notify.max.text"

    static var mode: AgentNotificationMode {
        get {
            UserDefaults.standard
                .string(forKey: modeKey)
                .flatMap(AgentNotificationMode.init(rawValue:)) ?? .activeSession
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    static var privacy: AgentNotificationPrivacy {
        get {
            UserDefaults.standard
                .string(forKey: privacyKey)
                .flatMap(AgentNotificationPrivacy.init(rawValue:)) ?? .titles
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: privacyKey)
        }
    }

    /// 汇总最多播报条数
    static var maxItems: Int {
        get {
            UserDefaults.standard.object(forKey: maxItemsKey) as? Int ?? 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: maxItemsKey)
        }
    }

    /// 单条文本截断长度
    static var maxTextLength: Int {
        get {
            UserDefaults.standard.object(forKey: maxTextLengthKey) as? Int ?? 60
        }
        set {
            UserDefaults.standard.set(newValue, forKey: maxTextLengthKey)
        }
    }
}

// MARK: - 汇总（纯逻辑）

/// 通知文案汇总（纯函数，可测）
enum AgentNotificationSummarizer {
    /// 文本截断（超长加省略号）
    static func truncate(_ text: String, to maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    /// 单条通知的即时播报文本（新通知到达）
    static func announcementText(
        for item: AgentNotificationItem,
        privacy: AgentNotificationPrivacy,
        maxLength: Int
    ) -> String {
        switch privacy {
        case .titlesOnly:
            return "agent.notify.live.titlesOnly".localized
        case .titles:
            let content = item.title.isEmpty ? item.body : item.title
            return "agent.notify.live.prefix".localized + truncate(content, to: maxLength)
        case .full:
            let content: String
            if item.body.isEmpty {
                content = item.title
            } else if item.title.isEmpty {
                content = item.body
            } else {
                content = "\(item.title)：\(item.body)"
            }
            return "agent.notify.live.prefix".localized + truncate(content, to: maxLength)
        }
    }

    /// 未读汇总播报文本（内部按时间倒序，最新在前；按隐私分级与条数上限呈现）
    static func catchUpText(
        items: [AgentNotificationItem],
        privacy: AgentNotificationPrivacy,
        maxItems: Int,
        maxLength: Int
    ) -> String {
        let sorted = sortedNewestFirst(items)
        guard !sorted.isEmpty else {
            return "agent.notify.summary.empty".localized
        }
        let prefix = String(format: "agent.notify.summary.prefix".localized, sorted.count)
        guard privacy != .titlesOnly else {
            return prefix
        }
        let shown = sorted.prefix(max(0, maxItems))
        switch privacy {
        case .titlesOnly:
            return prefix
        case .titles:
            let titles = shown.map { item -> String in
                let content = item.title.isEmpty ? item.body : item.title
                return truncate(content, to: maxLength)
            }
            return prefix + "：" + titles.joined(separator: "，")
        case .full:
            let details = shown.map { item -> String in
                if item.body.isEmpty {
                    return truncate(item.title, to: maxLength)
                }
                let title = truncate(item.title, to: maxLength)
                let body = truncate(item.body, to: maxLength)
                return title.isEmpty ? body : "\(title)：\(body)"
            }
            return prefix + "：" + details.joined(separator: "；")
        }
    }

    /// 按时间倒序（最新在前）
    static func sortedNewestFirst(_ items: [AgentNotificationItem]) -> [AgentNotificationItem] {
        items.sorted { $0.date > $1.date }
    }
}

// MARK: - 播报策略（纯逻辑）

/// 是否主动播报新通知
enum AgentNotificationPolicy {
    static func shouldAnnounce(
        mode: AgentNotificationMode,
        isSessionActive: Bool
    ) -> Bool {
        switch mode {
        case .off:
            return false
        case .activeSession:
            return isSessionActive
        case .foreground:
            return true
        }
    }
}

// MARK: - 收件箱（已播报去重）

/// 已播报通知 ID 记录（UserDefaults，上限 50，防重复播报）
enum AgentNotificationInbox {
    static let maxEntries = 50
    private static let storageKey = "agent.notify.inbox.ids.v1"

    static func load(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    static func contains(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults).contains(id)
    }

    @discardableResult
    static func record(_ id: String, defaults: UserDefaults = .standard) -> [String] {
        var ids = load(defaults: defaults)
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > maxEntries {
            ids = Array(ids.prefix(maxEntries))
        }
        defaults.set(ids, forKey: storageKey)
        return ids
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

// MARK: - 指令解析（纯逻辑）

/// 通知播报指令
enum AgentNotificationCommand: Equatable {
    /// 播报未读通知汇总
    case catchUp
    /// 清空通知中心
    case clear
}

/// 指令解析（保守匹配：整句包含关键词才命中，避免误吞普通对话）
enum AgentNotificationCommandParser {
    static let catchUpKeywords = [
        "有什么通知", "未读消息", "未读通知", "播报通知", "通知播报",
        "看看通知", "查看通知", "读一下通知", "念一下通知", "读通知",
    ]
    static let clearKeywords = [
        "清空通知", "清除通知", "清空所有通知", "清除所有通知",
        "把通知清掉", "通知清空",
    ]
    /// 文本长度上限（防止长文本偶然包含关键词）
    static let maxTextLength = 20

    static func parse(_ text: String) -> AgentNotificationCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTextLength else { return nil }
        for keyword in clearKeywords where trimmed.contains(keyword) {
            return .clear
        }
        for keyword in catchUpKeywords where trimmed.contains(keyword) {
            return .catchUp
        }
        return nil
    }
}

// MARK: - 通知中心协议

/// 系统通知中心封装（测试注入 Mock）
protocol AgentNotificationProviding {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func deliveredNotifications() async -> [AgentNotificationItem]
    func removeAllDeliveredNotifications() async
}

/// UNUserNotificationCenter 真实实现
final class SystemNotificationService: AgentNotificationProviding {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func deliveredNotifications() async -> [AgentNotificationItem] {
        let notifications = await center.deliveredNotifications()
        return notifications.map { notification in
            let content = notification.request.content
            return AgentNotificationItem(
                id: notification.request.identifier,
                title: content.title,
                body: content.body,
                date: notification.date
            )
        }
    }

    func removeAllDeliveredNotifications() async {
        center.removeAllDeliveredNotifications()
    }
}

// MARK: - 执行器

/// 通知指令执行（统一权限 + 副作用，返回播报文案）
enum AgentNotificationExecutor {
    static func execute(
        _ command: AgentNotificationCommand,
        provider: AgentNotificationProviding,
        privacy: AgentNotificationPrivacy = AgentNotificationSettings.privacy,
        maxItems: Int = AgentNotificationSettings.maxItems,
        maxLength: Int = AgentNotificationSettings.maxTextLength
    ) async -> String {
        var status = await provider.authorizationStatus()
        if status == .notDetermined {
            _ = await provider.requestAuthorization()
            status = await provider.authorizationStatus()
        }
        guard status == .authorized else {
            return "agent.notify.denied".localized
        }

        switch command {
        case .catchUp:
            let items = AgentNotificationSummarizer.sortedNewestFirst(
                await provider.deliveredNotifications()
            )
            return AgentNotificationSummarizer.catchUpText(
                items: items,
                privacy: privacy,
                maxItems: maxItems,
                maxLength: maxLength
            )
        case .clear:
            let items = await provider.deliveredNotifications()
            await provider.removeAllDeliveredNotifications()
            return String(format: "agent.notify.cleared".localized, items.count)
        }
    }
}

// MARK: - 播报管家（副作用）

/// JARVIS 通知播报管家：前台新通知摘要播报 + 未读汇总。
@MainActor
final class AgentNotificationButler: ObservableObject {
    static let shared = AgentNotificationButler()

    /// 最近一次播报/汇总文案（设置页与诊断展示）
    @Published private(set) var lastAnnouncement: String?

    private init() {}

    /// 前台新通知到达（由 UNUserNotificationCenter 代理调用；非提醒通知）
    func handleForeground(notification: UNNotification) {
        let content = notification.request.content
        let item = AgentNotificationItem(
            id: notification.request.identifier,
            title: content.title,
            body: content.body,
            date: notification.date
        )
        let mode = AgentNotificationSettings.mode
        guard AgentNotificationPolicy.shouldAnnounce(
            mode: mode,
            isSessionActive: QwenVoiceSession.shared.isActive
        ) else { return }
        // 专注模式避让：整体暂停播报（含镜片卡 / 触觉），且不写入已播报去重，
        // 专注结束后仍可被「有什么通知」汇总到
        guard !AgentFocusPolicy.pauseNotifications else { return }
        guard !AgentNotificationInbox.contains(item.id) else { return }
        AgentNotificationInbox.record(item.id)

        let text = AgentNotificationSummarizer.announcementText(
            for: item,
            privacy: AgentNotificationSettings.privacy,
            maxLength: AgentNotificationSettings.maxTextLength
        )
        lastAnnouncement = text
        AgentTriggerFeedback.play()
        AgentDisplayHub.shared.showResult(
            title: "agent.notify.live.title".localized,
            text: text,
            fallback: .idle
        )
        if AgentVoiceSettings.replyEnabled,
           AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
    }

    /// 「有什么通知」：汇总未读并记录已播报 ID（防与新到达重复播报）
    func catchUp(provider: AgentNotificationProviding = AgentNotification.provider) async -> String {
        let reply = await AgentNotificationExecutor.execute(.catchUp, provider: provider)
        lastAnnouncement = reply
        let items = await provider.deliveredNotifications()
        for item in items {
            AgentNotificationInbox.record(item.id)
        }
        return reply
    }

    /// 「清空通知」：清空通知中心
    func clearDelivered(
        provider: AgentNotificationProviding = AgentNotification.provider
    ) async -> String {
        let reply = await AgentNotificationExecutor.execute(.clear, provider: provider)
        lastAnnouncement = reply
        return reply
    }
}

/// 通知中心实现注入点（测试替换 Mock）
enum AgentNotification {
    static var provider: AgentNotificationProviding = SystemNotificationService()
}
