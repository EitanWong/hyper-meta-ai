/*
 * 每日晨报（Morning Briefing）
 * JARVIS 式「早安汇报」：本地通知每天定时送达，内容融合今日日程（EventKit）、
 * 待触发提醒与进行中任务；数据在 App 回前台 / 后台任务 / 设置变更时刷新。
 * 设置持久化、内容构建、调度决策均为纯逻辑可测（通知中心与数据源可注入）。
 */

import BackgroundTasks
import Foundation
import UserNotifications

// MARK: - 设置存储

/// 每日晨报设置（UserDefaults JSON 持久化）
struct AgentBriefingSettings: Codable, Equatable {
    var enabled: Bool
    /// 送达时间（24 小时制）
    var hour: Int
    var minute: Int
    var includeSchedule: Bool
    var includeReminders: Bool
    var includeTasks: Bool

    init(
        enabled: Bool = false,
        hour: Int = 8,
        minute: Int = 0,
        includeSchedule: Bool = true,
        includeReminders: Bool = true,
        includeTasks: Bool = true
    ) {
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.includeSchedule = includeSchedule
        self.includeReminders = includeReminders
        self.includeTasks = includeTasks
    }
}

/// 晨报设置存储（纯逻辑可测）
enum AgentBriefingStore {
    static let key = "agent.briefing.settings"

    static var current: AgentBriefingSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else {
                return AgentBriefingSettings()
            }
            return (try? JSONDecoder().decode(AgentBriefingSettings.self, from: data))
                ?? AgentBriefingSettings()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func update(_ transform: (inout AgentBriefingSettings) -> Void) {
        var settings = current
        transform(&settings)
        // 时间钳制到合法范围
        settings.hour = min(max(settings.hour, 0), 23)
        settings.minute = min(max(settings.minute, 0), 59)
        current = settings
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - 内容构建

/// 一条晨报内容（纯模型）
struct AgentBriefingContent: Equatable {
    var greeting: String
    var dateLine: String
    /// 下一场日程倒计时（「下一场日程 45 分钟后开始。」，仅未来 24 小时内）
    var nextEventLine: String?
    var scheduleLine: String?
    var reminderLine: String?
    var taskLine: String?

    /// 各栏目是否有内容
    var isEmpty: Bool {
        scheduleLine == nil && reminderLine == nil && taskLine == nil
    }

    /// 完整通知正文（含问候与日期；空栏目回退温馨一句）
    var fullText: String {
        var lines = [greeting, dateLine]
        if isEmpty {
            lines.append("agent.briefing.empty".localized)
        } else {
            if let nextEventLine { lines.append(nextEventLine) }
            if let scheduleLine { lines.append(scheduleLine) }
            if let reminderLine { lines.append(reminderLine) }
            if let taskLine { lines.append(taskLine) }
        }
        return lines.joined(separator: "\n")
    }
}

/// 晨报问候时段（纯逻辑，可测）：按小时分段给出自然问候
enum AgentBriefingGreetingPeriod: Equatable {
    case morning, afternoon, evening, night

    static func period(hour: Int) -> AgentBriefingGreetingPeriod {
        switch hour {
        case 5..<12: return .morning
        case 12..<18: return .afternoon
        case 18..<23: return .evening
        default: return .night
        }
    }
}

/// 晨报内容构建（纯逻辑可测；中英文案随 App 语言）
enum AgentBriefingBuilder {
    static func build(
        date: Date = Date(),
        calendar: Calendar = .current,
        events: [AgentCalendarEvent],
        reminders: [AgentReminder],
        taskTitles: [String],
        settings: AgentBriefingSettings,
        personaName: String
    ) -> AgentBriefingContent {
        let greeting = Self.greeting(personaName: personaName, date: date, calendar: calendar)
        let dateLine = String(
            format: "agent.briefing.date".localized,
            Self.dateFormatter.string(from: date)
        )

        var nextEventLine: String?
        var scheduleLine: String?
        if settings.includeSchedule {
            let sorted = events.sorted { $0.start < $1.start }
            if let first = sorted.first {
                let interval = first.start.timeIntervalSince(date)
                if interval > 0, interval < 86400 {
                    nextEventLine = interval < 3600
                        ? String(format: "agent.briefing.next.minutes".localized, Int(interval / 60))
                        : String(format: "agent.briefing.next.hours".localized, Int(interval / 3600))
                }
            }
            let lines = sorted.map { AgentCalendarFormatter.eventLine($0, now: date, calendar: calendar) }
            if !lines.isEmpty {
                scheduleLine = String(format: "agent.briefing.section.schedule".localized, lines.joined(separator: "，"))
            }
        }

        var reminderLine: String?
        if settings.includeReminders {
            let lines = reminders
                .sorted { $0.fireDate < $1.fireDate }
                .map { reminder in
                    let when = AgentReminderTimeFormatter.announcementDescription(
                        for: reminder,
                        now: date,
                        calendar: calendar
                    )
                    return String(format: "agent.reminder.query.item".localized, when, reminder.text)
                }
            if !lines.isEmpty {
                reminderLine = String(format: "agent.briefing.section.reminders".localized, lines.joined(separator: "，"))
            }
        }

        var taskLine: String?
        if settings.includeTasks {
            let titles = taskTitles
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !titles.isEmpty {
                taskLine = String(format: "agent.briefing.section.tasks".localized, titles.joined(separator: "，"))
            }
        }

        return AgentBriefingContent(
            greeting: greeting,
            dateLine: dateLine,
            nextEventLine: nextEventLine,
            scheduleLine: scheduleLine,
            reminderLine: reminderLine,
            taskLine: taskLine
        )
    }

    /// 按当前时段选择问候语：「早上好 / 下午好 / 晚上好 / 夜深了」
    static func greeting(
        personaName: String,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        let key: String
        switch AgentBriefingGreetingPeriod.period(hour: hour) {
        case .morning: key = "agent.briefing.greeting"
        case .afternoon: key = "agent.briefing.greeting.afternoon"
        case .evening: key = "agent.briefing.greeting.evening"
        case .night: key = "agent.briefing.greeting.night"
        }
        return String(
            format: key.localized,
            personaName.isEmpty ? "agent.briefing.greeting.fallback".localized : personaName
        )
    }

    /// 日期行格式随语言：中文「8月13日 星期四」/ 英文「Thursday, Aug 13」
    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        if LanguageManager.staticIsChinese {
            formatter.locale = Locale(identifier: "zh-Hans")
            formatter.dateFormat = "M月d日 EEEE"
        } else {
            formatter.locale = Locale(identifier: "en")
            formatter.dateFormat = "EEEE, MMM d"
        }
        return formatter
    }
}

// MARK: - 数据源

/// 晨报数据源（可注入 Mock 测试）
@MainActor
protocol AgentBriefingDataProviding {
    func todayEvents() async -> [AgentCalendarEvent]
    var reminders: [AgentReminder] { get }
    /// 进行中 / 等待中的任务标题（按创建顺序）
    var taskTitles: [String] { get }
}

/// 真实数据源：日历走 AgentCalendar.provider，提醒 / 任务读本地存储
@MainActor
struct LiveAgentBriefingDataProvider: AgentBriefingDataProviding {
    func todayEvents() async -> [AgentCalendarEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return await AgentCalendar.provider.fetchEvents(from: start, to: end)
    }

    var reminders: [AgentReminder] {
        AgentReminderStore.reminders
    }

    var taskTitles: [String] {
        QwenVoiceSession.shared.activeTasks
            .filter { $0.status == .running || $0.status == .waiting }
            .map(\.title)
    }
}

// MARK: - 通知中心（可注入 Mock）

/// 晨报使用的通知中心薄封装（真实实现包 UNUserNotificationCenter）
protocol AgentBriefingNotificationCentering {
    func add(_ request: UNNotificationRequest)
    func removePending(withIdentifiers identifiers: [String])
}

/// 真实实现
struct SystemBriefingNotificationCenter: AgentBriefingNotificationCentering {
    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

// MARK: - 调度器

/// 每日晨报调度器：开关 / 时间 / 栏目变更时刷新内容（通知中心与数据源可注入）
@MainActor
enum AgentBriefingScheduler {
    static let identifier = "agent.briefing.daily"
    static let userInfoKey = "agent.briefing"

    static var center: AgentBriefingNotificationCentering = SystemBriefingNotificationCenter()
    static var dataProvider: AgentBriefingDataProviding = LiveAgentBriefingDataProvider()

    /// 依当前设置同步通知：启用 → 计算内容并调度（幂等）；关闭 → 移除
    static func sync(settings: AgentBriefingSettings = AgentBriefingStore.current) async {
        guard settings.enabled else {
            center.removePending(withIdentifiers: [identifier])
            return
        }
        let content = await buildContent(settings: settings)
        center.removePending(withIdentifiers: [identifier])
        let notification = UNMutableNotificationContent()
        notification.title = "agent.briefing.notification.title".localized
        notification.body = content.fullText
        notification.sound = .default
        notification.userInfo = [userInfoKey: true]
        var components = DateComponents()
        components.hour = settings.hour
        components.minute = settings.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: notification, trigger: trigger)
        center.add(request)
    }

    /// 计算当前晨报内容（可独立用于「预览」）
    static func buildContent(
        settings: AgentBriefingSettings,
        now: Date = Date(),
        calendar: Calendar = .current,
        provider: AgentBriefingDataProviding? = nil
    ) async -> AgentBriefingContent {
        let provider = provider ?? dataProvider
        let events = await provider.todayEvents()
        return AgentBriefingBuilder.build(
            date: now,
            calendar: calendar,
            events: events,
            reminders: provider.reminders,
            taskTitles: provider.taskTitles,
            settings: settings,
            personaName: AgentPersonaStore.current.name
        )
    }
}

// MARK: - 后台刷新（BGTaskScheduler）

/// 晨报后台刷新（机会式）：注册 / 提交 / 处理，内容刷新后重排次日
@MainActor
enum AgentBriefingBackgroundTask {
    static let identifier = "com.lunflux.hyper-meta-ai.briefing-refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            MainActor.assumeIsolated {
                handle(task)
            }
        }
    }

    /// App 进后台时提交（仅启用时）
    static func submitIfNeeded() {
        guard AgentBriefingStore.current.enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        Task {
            await AgentBriefingScheduler.sync()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        submitIfNeeded()
    }
}

// MARK: - Control Center 晨报请求消费

/// 晨报控制按钮请求（App 侧消费）：扩展进程只写 App Group 标记，
/// App 消费后走既有 URL 命令晨报播报路径（TTS + 镜片结果卡）。
enum AgentBriefingRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.briefing.request"

    /// 消费「播报晨报」请求（读到即清除）；可注入 defaults 便于测试
    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> Bool {
        let store = defaults ?? .standard
        guard store.bool(forKey: requestKey) else { return false }
        store.removeObject(forKey: requestKey)
        return true
    }
}

/// 晨报控制请求协调器（App 侧，@MainActor）：
/// 观察 App Group 变更并消费请求，分发到晨报播报路径。
@MainActor
enum AgentBriefingControlCoordinator {
    private static var observer: NSObjectProtocol?

    /// 注册 App Group 请求监听（幂等）
    static func startObserving() {
        guard observer == nil else {
            Task { await consumeIfNeeded() }
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await AgentBriefingControlCoordinator.consumeIfNeeded()
            }
        }
        Task { await consumeIfNeeded() }
    }

    /// 消费一次晨报请求并播报（execute 可注入测试，nil 时走真实播报路径）
    @discardableResult
    static func consumeIfNeeded(
        defaults: UserDefaults? = nil,
        execute: (() async -> Void)? = nil
    ) async -> Bool {
        let store = defaults
            ?? UserDefaults(suiteName: AgentBriefingRequestStore.suiteName)
            ?? .standard
        guard AgentBriefingRequestStore.consume(defaults: store) else { return false }
        if let execute {
            await execute()
        } else {
            _ = await SystemAgentURLCommandExecutor.shared.dispatchBriefing()
        }
        return true
    }
}
