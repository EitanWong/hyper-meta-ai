/*
 * Agent Connect Greeting
 * JARVIS 眼镜连接问候：戴上眼镜时在镜片播报语音摘要（日程 / 提醒 / 任务 / 未读通知）。
 * 策略（启用 / 会话中不打扰 / 最小间隔）与文案构建为纯逻辑可测；
 * AgentConnectGreetingAnnouncer 负责副作用（触觉 + 镜片卡片 + TTS）。
 */

import Foundation
import UIKit

// MARK: - 设置

/// 眼镜连接问候偏好（UserDefaults 持久化）
enum AgentConnectGreetingSettings {
    static let enabledKey = "agent.connect.greeting.enabled"
    static let scheduleKey = "agent.connect.greeting.schedule"
    static let remindersKey = "agent.connect.greeting.reminders"
    static let tasksKey = "agent.connect.greeting.tasks"
    static let unreadKey = "agent.connect.greeting.unread"
    static let minIntervalKey = "agent.connect.greeting.minInterval"

    /// 总开关（默认开；静默模式下语音被抑制，镜片卡片与触觉保留）
    static var enabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static var includeSchedule: Bool {
        get {
            UserDefaults.standard.object(forKey: scheduleKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: scheduleKey)
        }
    }

    static var includeReminders: Bool {
        get {
            UserDefaults.standard.object(forKey: remindersKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: remindersKey)
        }
    }

    static var includeTasks: Bool {
        get {
            UserDefaults.standard.object(forKey: tasksKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: tasksKey)
        }
    }

    static var includeUnread: Bool {
        get {
            UserDefaults.standard.object(forKey: unreadKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: unreadKey)
        }
    }

    /// 两次问候的最小间隔（秒），防断连重连风暴反复播报
    static var minInterval: TimeInterval {
        get {
            UserDefaults.standard.object(forKey: minIntervalKey) as? TimeInterval ?? 60
        }
        set {
            UserDefaults.standard.set(newValue, forKey: minIntervalKey)
        }
    }
}

// MARK: - 策略（纯逻辑，可测）

/// 连接问候策略：总开关、语音会话中不打扰、最小间隔去抖
enum AgentConnectGreetingPolicy {
    static func shouldGreet(
        enabled: Bool,
        isSessionActive: Bool,
        lastGreetedAt: Date?,
        now: Date = Date(),
        minInterval: TimeInterval
    ) -> Bool {
        guard enabled, !isSessionActive, minInterval >= 0 else { return false }
        guard let lastGreetedAt else { return true }
        return now.timeIntervalSince(lastGreetedAt) >= minInterval
    }
}

// MARK: - 文案构建（纯逻辑，可测）

/// 连接问候摘要构建：问候语 + 各栏目条数（0 项栏目省略，全空回退「一切正常」）
enum AgentConnectGreetingBuilder {
    static func summary(
        scheduleCount: Int,
        reminderCount: Int,
        taskCount: Int,
        unreadCount: Int,
        personaName: String = AgentPersonaStore.current.name
    ) -> String {
        let name = personaName.isEmpty
            ? "agent.briefing.greeting.fallback".localized
            : personaName
        let greeting = String(format: "agent.connect.greeting.head".localized, name)

        var sections: [String] = []
        if scheduleCount > 0 {
            sections.append(String(format: "agent.connect.greeting.schedule".localized, scheduleCount))
        }
        if reminderCount > 0 {
            sections.append(String(format: "agent.connect.greeting.reminders".localized, reminderCount))
        }
        if taskCount > 0 {
            sections.append(String(format: "agent.connect.greeting.tasks".localized, taskCount))
        }
        if unreadCount > 0 {
            sections.append(String(format: "agent.connect.greeting.unread".localized, unreadCount))
        }

        if sections.isEmpty {
            return greeting + " " + "agent.connect.greeting.allClear".localized
        }
        return greeting + " " + sections.joined(separator: "，")
    }
}

// MARK: - 数据组装（可注入 Mock 测试）

/// 连接问候数据组装：按设置收集各栏目条数并生成摘要
enum AgentConnectGreetingAssembler {
    @MainActor
    static func buildSummary(
        includeSchedule: Bool,
        includeReminders: Bool,
        includeTasks: Bool,
        includeUnread: Bool,
        briefingProvider: AgentBriefingDataProviding,
        notificationProvider: AgentNotificationProviding,
        personaName: String = AgentPersonaStore.current.name
    ) async -> String {
        var scheduleCount = 0
        var reminderCount = 0
        var taskCount = 0
        if includeSchedule {
            scheduleCount = await briefingProvider.todayEvents().count
        }
        if includeReminders {
            reminderCount = briefingProvider.reminders.count
        }
        if includeTasks {
            taskCount = briefingProvider.taskTitles.count
        }
        var unreadCount = 0
        if includeUnread,
           await notificationProvider.authorizationStatus() == .authorized {
            unreadCount = await notificationProvider.deliveredNotifications().count
        }
        return AgentConnectGreetingBuilder.summary(
            scheduleCount: scheduleCount,
            reminderCount: reminderCount,
            taskCount: taskCount,
            unreadCount: unreadCount,
            personaName: personaName
        )
    }
}

// MARK: - 播报执行器（副作用）

/// 眼镜连接问候执行器：策略门控 + 摘要播报（触觉 + 镜片卡片 + TTS）
@MainActor
final class AgentConnectGreetingAnnouncer {
    static let shared = AgentConnectGreetingAnnouncer()

    private var lastGreetedAt: Date?

    private init() {}

    /// 眼镜变为可用时调用（App 层经 StreamSessionViewModel.onDeviceAvailable 接入）
    func handleDeviceConnected(
        now: Date = Date(),
        isSessionActive: Bool? = nil,
        briefingProvider: AgentBriefingDataProviding? = nil,
        notificationProvider: AgentNotificationProviding? = nil
    ) async {
        let settings = AgentConnectGreetingSettings.self
        guard AgentConnectGreetingPolicy.shouldGreet(
            enabled: settings.enabled,
            isSessionActive: isSessionActive ?? QwenVoiceSession.shared.isActive,
            lastGreetedAt: lastGreetedAt,
            now: now,
            minInterval: settings.minInterval
        ) else { return }
        lastGreetedAt = now

        let summary = await AgentConnectGreetingAssembler.buildSummary(
            includeSchedule: settings.includeSchedule,
            includeReminders: settings.includeReminders,
            includeTasks: settings.includeTasks,
            includeUnread: settings.includeUnread,
            briefingProvider: briefingProvider ?? AgentBriefingScheduler.dataProvider,
            notificationProvider: notificationProvider ?? AgentNotification.provider
        )

        AgentTriggerFeedback.play()
        AgentDisplayHub.shared.showResult(
            title: "agent.connect.greeting.title".localized,
            text: summary,
            fallback: .idle
        )
        if AgentVoiceSettings.replyEnabled,
           AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
            TTSService.shared.stop()
            TTSService.shared.speak(summary)
        }
    }
}
