/*
 * Agent Display Home
 * 眼镜 Display 主界面 HUD（JARVIS 镜片主页）：时间 / 日期 / 未读通知数 /
 * 进行中任务 / 下一条提醒 / 今明日程摘要 / HomeKit 状态摘要 + 快捷动作按钮。
 * 状态组装与文案映射为纯逻辑可测；
 * AgentDisplayHub.showHome 负责渲染（无显示能力时静默降级）。
 */

import Foundation
import MWDATDisplay

// MARK: - HUD 状态

/// 镜片 HUD 的完整输入状态（纯值，可测）
struct AgentDisplayHomeState: Equatable {
    let now: Date
    let unreadCount: Int
    let taskLine: String?
    let reminderLine: String?
    let calendarLines: [String]
    let statusLines: [String]
    let actions: [AgentDisplayAction]
}

// MARK: - 纯映射

/// 镜片 HUD 文案与状态映射（不依赖 SDK 运行时，可测）
enum AgentDisplayHomeMapping {
    /// HUD 状态行上限（防止镜片列表过长）
    static let maxStatusLines = 3

    /// 24 小时制短时间（HH:mm）
    static func timeText(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 短日期（M/d 周X，随 locale）
    static func dateText(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "M/d EEE"
        return formatter.string(from: date)
    }

    /// 未读通知短文案
    static func unreadText(count: Int) -> String {
        count > 0
            ? String(format: "agent.display.home.unread.count".localized, count)
            : "agent.display.home.unread.none".localized
    }

    /// 进行中任务摘要行：1 个显示任务标题，多个显示「标题 等 N 项」；无进行中任务返回 nil
    static func taskLine(
        from tasks: [PersistedAgentTask]
    ) -> String? {
        let running = tasks.filter {
            $0.status == QwenAgentTask.Status.running.notificationRaw
                || $0.status == QwenAgentTask.Status.waiting.notificationRaw
        }
        guard let first = running.first else { return nil }
        let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if running.count == 1 {
            return String(format: "agent.display.home.task.running".localized, title)
        }
        return String(format: "agent.display.home.task.more".localized, title, running.count)
    }

    /// 下一条提醒摘要行：「提醒 25分钟后 吃药」；无即将触发的提醒返回 nil
    static func reminderLine(
        from reminders: [AgentReminder],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let next = AgentReminderDisplayMapping.upcoming(reminders, now: now, limit: 1).first else {
            return nil
        }
        let when = AgentReminderTimeFormatter.announcementDescription(
            for: next,
            now: now,
            calendar: calendar
        )
        let text = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(format: "agent.display.home.reminder".localized, "\(when) \(text)")
    }

    /// HomeKit 设备 → 短状态行（最多 limit 条，按传入顺序）
    static func statusLines(
        from devices: [AgentHomeKitDevice],
        limit: Int = maxStatusLines
    ) -> [String] {
        devices.prefix(max(0, limit)).map(shortStatus)
    }

    /// 今明两天日程摘要行（按开始时间升序，优先今天；最多 limit 条）
    static func calendarLines(
        from events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = maxStatusLines
    ) -> [String] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday) else {
            return []
        }
        let today = events
            .filter { $0.start >= startOfToday && $0.start < startOfTomorrow }
            .sorted { $0.start < $1.start }
        let tomorrow = events
            .filter { $0.start >= startOfTomorrow && $0.start < startOfDayAfter }
            .sorted { $0.start < $1.start }
        return (today + tomorrow)
            .prefix(max(0, limit))
            .map { calendarLine($0, now: now, calendar: calendar) }
    }

    /// 单条日程 HUD 行：「今天 15:00 评审」/「明天 全天 出游」
    static func calendarLine(
        _ event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let day = AgentCalendarFormatter.dayLabel(event.start, now: now, calendar: calendar)
        let when = event.isAllDay
            ? "agent.calendar.allday".localized
            : timeText(event.start, calendar: calendar)
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(day) \(when) \(title)"
    }

    /// 单台设备的 HUD 短状态
    static func shortStatus(_ device: AgentHomeKitDevice) -> String {
        switch device.kind {
        case .light, .outlet, .fan, .switch:
            let state = device.isOn == true
                ? "agent.display.home.status.on".localized
                : "agent.display.home.status.off".localized
            return "\(device.name) \(state)"
        case .thermostat:
            if let target = device.targetTemperature {
                return "\(device.name) \(Int(target.rounded()))°"
            }
            if let current = device.currentTemperature {
                return "\(device.name) \(Int(current.rounded()))°"
            }
            return "\(device.name) \("agent.display.home.status.unknown".localized)"
        case .lock:
            let state = device.isLocked == true
                ? "agent.display.home.status.locked".localized
                : "agent.display.home.status.unlocked".localized
            return "\(device.name) \(state)"
        case .unknown:
            return device.name
        }
    }

    /// HUD 快捷动作（顺序即镜片展示顺序）
    static func hudActions() -> [AgentDisplayAction] {
        [.wake, .captureVision, .repeatLastReply, .newChat, .dismiss]
    }

    /// 组装 HUD 状态
    static func state(
        now: Date,
        unreadCount: Int,
        devices: [AgentHomeKitDevice],
        tasks: [PersistedAgentTask] = [],
        reminders: [AgentReminder] = [],
        calendarEvents: [AgentCalendarEvent] = [],
        calendar: Calendar = .current,
        actions: [AgentDisplayAction] = hudActions()
    ) -> AgentDisplayHomeState {
        AgentDisplayHomeState(
            now: now,
            unreadCount: unreadCount,
            taskLine: taskLine(from: tasks),
            reminderLine: reminderLine(from: reminders, now: now, calendar: calendar),
            calendarLines: calendarLines(from: calendarEvents, now: now, calendar: calendar),
            statusLines: statusLines(from: devices),
            actions: actions
        )
    }

    /// 构造镜片 HUD 视图（状态行 + 动作按钮）；无有效按钮时返回 nil（调用方回退清屏）
    static func makeView(
        state: AgentDisplayHomeState,
        onSelect: @escaping (AgentDisplayAction) -> Void
    ) -> FlexBox? {
        var components: [any ViewComponent] = []
        components.append(Text(
            "\(timeText(state.now))  \(dateText(state.now))",
            style: .heading,
            color: .primary
        ))
        components.append(Text(
            unreadText(count: state.unreadCount),
            style: .body,
            color: .secondary
        ))
        if let taskLine = state.taskLine {
            components.append(Text(taskLine, style: .body, color: .primary))
        }
        if let reminderLine = state.reminderLine {
            components.append(Text(reminderLine, style: .body, color: .primary))
        }
        for line in state.calendarLines {
            components.append(Text(line, style: .body, color: .primary))
        }
        for line in state.statusLines {
            components.append(Text(line, style: .body, color: .primary))
        }
        var buttonCount = 0
        for action in state.actions {
            guard let icon = IconName(rawValue: AgentDisplayMenuMapping.iconName(for: action)) else {
                continue
            }
            buttonCount += 1
            components.append(Button(
                label: AgentDisplayMenuMapping.title(for: action),
                style: .outline,
                iconName: icon,
                onClick: { onSelect(action) }
            ))
        }
        guard buttonCount > 0 else { return nil }
        return FlexBox(direction: .column, spacing: 8, alignment: .start, crossAlignment: .start) {
            for component in components {
                component
            }
        }
    }
}

// MARK: - HUD 数据装载

/// 镜片 HUD 数据装载（通知数 + HomeKit 摘要；权限未授予时对应项为空）
enum AgentDisplayHomeLoader {
    @MainActor
    static func state(
        now: Date = Date(),
        calendar: Calendar = .current,
        notificationProvider: AgentNotificationProviding = AgentNotification.provider,
        homeKitProvider: AgentHomeKitProviding = AgentHomeKit.provider,
        calendarProvider: AgentCalendarProviding = AgentCalendar.provider,
        tasks: [PersistedAgentTask] = AgentTaskNotificationStore.load(),
        reminders: [AgentReminder] = AgentReminderStore.reminders
    ) async -> AgentDisplayHomeState {
        var unreadCount = 0
        let status = await notificationProvider.authorizationStatus()
        if status == .authorized {
            unreadCount = await notificationProvider.deliveredNotifications().count
        }
        let devices: [AgentHomeKitDevice] = homeKitProvider.authorization == .authorized
            ? await homeKitProvider.devices()
            : []
        var calendarEvents: [AgentCalendarEvent] = []
        if calendarProvider.authorization == .authorized {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start
            calendarEvents = await calendarProvider.fetchEvents(from: start, to: end)
        }
        return AgentDisplayHomeMapping.state(
            now: now,
            unreadCount: unreadCount,
            devices: devices,
            tasks: tasks,
            reminders: reminders,
            calendarEvents: calendarEvents,
            calendar: calendar
        )
    }
}
