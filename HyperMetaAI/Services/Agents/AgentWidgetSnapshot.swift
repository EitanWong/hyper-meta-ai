/*
 * Agent Home Widget Snapshot
 * 桌面小组件（下次提醒 + 语音会话快捷入口）的数据快照。
 * 文案由 App 侧生成（跟随 App 语言）写入 App Group UserDefaults，
 * Widget 扩展只读渲染；刷新点集中在提醒调度与语音会话状态变化。
 */

import Foundation
import WidgetKit

/// 桌面小组件快照（Codable，App Group 共享；扩展内定义同名结构解码）
struct AgentWidgetSnapshot: Codable, Equatable {
    /// 下次提醒内容（无提醒时为空态文案）
    var nextReminderText: String
    /// 下次提醒展示描述（如「10 分钟后」「明天 09:00」；无提醒为空）
    var nextReminderDetail: String
    /// 提醒总数（含周期提醒）
    var reminderCount: Int
    /// 语音会话是否活跃（决定按钮意图：开始 / 停止）
    var isVoiceSessionActive: Bool
    /// 语音按钮标题（已本地化）
    var voiceButtonTitle: String
    /// 后台任务摘要（无任务为空）
    var taskSummary: String
    /// 下次日程标题（无日程为空）
    var nextCalendarText: String
    /// 下次日程时间描述（「14:30」/「明天 09:00」；无日程为空）
    var nextCalendarDetail: String
    /// 锁屏矩形配件标题（「任务进行中」/「下次提醒」/「暂无提醒」）
    var accessoryTitle: String
    /// 锁屏矩形配件主内容（任务摘要优先，其次提醒内容）
    var accessoryBody: String
    /// 锁屏矩形配件副内容（提醒相对时间；任务进行中为空）
    var accessoryDetail: String
    /// 锁屏单行配件文本（任务摘要优先，其次「下次：内容」）
    var accessoryInlineText: String

    /// 无可用提醒时的空态文案
    static let noReminderText = "agent.widget.noReminder".localized

    /// 是否有可展示的提醒
    var hasReminder: Bool {
        !nextReminderDetail.isEmpty
    }

    /// 是否有可展示的日程
    var hasCalendar: Bool {
        !nextCalendarDetail.isEmpty
    }

    /// 从当前提醒列表构造快照（纯逻辑，可测）
    static func make(
        reminders: [AgentReminder],
        isVoiceSessionActive: Bool,
        taskSummary: String,
        calendarEvents: [AgentCalendarEvent] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentWidgetSnapshot {
        let next = AgentReminderDisplayMapping.upcoming(reminders, now: now, limit: 1).first
        let taskActive = !taskSummary.isEmpty
        let reminderDetail = next.map {
            AgentReminderTimeFormatter.announcementDescription(for: $0, now: now, calendar: calendar)
        } ?? ""
        let nextCalendar = AgentCalendarCountdownPolicy.nextEvent(
            in: calendarEvents,
            now: now,
            maxAhead: AgentCalendarCountdownPolicy.widgetMaxAhead
        )
        let calendarText = nextCalendar.map { event -> String in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "agent.widget.calendar.event".localized : title
        } ?? ""
        let calendarDetail = nextCalendar.map {
            AgentWidgetCalendarFormatter.detail(for: $0.start, now: now, calendar: calendar)
        } ?? ""
        let calendarLine = calendarDetail.isEmpty ? "" : "\(calendarDetail) \(calendarText)"
        return AgentWidgetSnapshot(
            nextReminderText: next?.text ?? noReminderText,
            nextReminderDetail: reminderDetail,
            reminderCount: reminders.count,
            isVoiceSessionActive: isVoiceSessionActive,
            voiceButtonTitle: isVoiceSessionActive
                ? "agent.widget.voice.stop".localized
                : "agent.widget.voice.start".localized,
            taskSummary: taskSummary,
            nextCalendarText: calendarText,
            nextCalendarDetail: calendarDetail,
            accessoryTitle: taskActive
                ? "agent.widget.accessory.task".localized
                : (next != nil
                    ? "agent.widget.accessory.nextReminder".localized
                    : (nextCalendar != nil
                        ? "agent.widget.calendar.next".localized
                        : "agent.widget.accessory.empty".localized)),
            accessoryBody: taskActive
                ? taskSummary
                : (next?.text ?? (nextCalendar != nil ? calendarLine : noReminderText)),
            accessoryDetail: taskActive ? "" : (next != nil ? reminderDetail : ""),
            accessoryInlineText: taskActive
                ? taskSummary
                : (next.map {
                    String(format: "agent.widget.accessory.inline.next".localized, $0.text)
                } ?? (nextCalendar != nil
                    ? String(format: "agent.widget.accessory.inline.next".localized, calendarLine)
                    : "agent.widget.accessory.empty".localized))
        )
    }
}

/// 小组件「下次日程」时间描述（纯逻辑，可测）：
/// 当天「14:30」、明天「明天 09:00」、更远「3月8日 14:30」
enum AgentWidgetCalendarFormatter {
    static func detail(for start: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let dayOffset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: start)
        ).day ?? 0
        let clock = makeClockFormatter(timeZone: calendar.timeZone).string(from: start)
        switch dayOffset {
        case 0:
            return clock
        case 1:
            return String(format: "agent.widget.calendar.tomorrow".localized, clock)
        default:
            let date = makeDateFormatter(timeZone: calendar.timeZone).string(from: start)
            return "\(date) \(clock)"
        }
    }

    private static var appLocale: Locale {
        LanguageManager.staticIsChinese
            ? Locale(identifier: "zh-Hans")
            : Locale(identifier: "en")
    }

    private static func makeClockFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }

    private static func makeDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }
}

/// 快照的 App Group 存储（App 与扩展共享）
enum AgentWidgetSnapshotStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let snapshotKey = "agent.widget.snapshot"
    /// 与扩展 `AgentHomeWidget.kind` 一致
    static let widgetKind = "agentHomeWidget"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func read() -> AgentWidgetSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(AgentWidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: AgentWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func clear() {
        defaults.removeObject(forKey: snapshotKey)
    }
}

/// 快照刷新中心：各状态变化点调用 `refresh()`，写共享存储并刷新小组件时间线
@MainActor
enum AgentWidgetSnapshotCenter {
    /// 从当前状态重建快照并刷新小组件（幂等，可安全多次调用）
    static func refresh(
        reminders: [AgentReminder]? = nil,
        isVoiceActive: Bool? = nil,
        taskSummary: String? = nil
    ) {
        // 默认实参在调用点求值（非隔离上下文），故在 @MainActor 函数体内读取
        let reminders = reminders ?? AgentReminderStore.reminders
        let isVoiceActive = isVoiceActive ?? QwenVoiceSession.shared.isActive
        let taskSummary = taskSummary ?? QwenVoiceSession.shared.taskProgressSummary ?? ""
        let snapshot = AgentWidgetSnapshot.make(
            reminders: reminders,
            isVoiceSessionActive: isVoiceActive,
            taskSummary: taskSummary,
            calendarEvents: AgentCalendarCountdownCoordinator.lastFetchedEvents
        )
        AgentWidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: AgentWidgetSnapshotStore.widgetKind)
    }
}
