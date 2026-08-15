/*
 * Agent Reminder Store
 * 前端自有工具：语音设置的本地提醒（「十分钟后提醒我喝水」），
 * 通过 UNUserNotificationCenter 本地通知触发，不依赖 Agent 后台任务。
 * 纯逻辑（解析 / 存储 / 文案）与系统调度分离，便于测试。
 */

import Foundation
import UserNotifications

// MARK: - Model & Store

/// 提醒重复规则
enum AgentReminderRepeat: String, Codable, Equatable {
    /// 单次提醒
    case none
    /// 每天同一时刻
    case daily
    /// 每周同一天同一时刻（以 fireDate 的星期为准）
    case weekly
}

/// 一条本地提醒
struct AgentReminder: Codable, Equatable, Identifiable {
    var id: UUID
    /// 提醒内容（如「喝水」）
    var text: String
    /// 触发时间（本地时区绝对时间）
    var fireDate: Date
    var createdAt: Date
    /// 重复规则（默认单次）
    var repeatRule: AgentReminderRepeat
    /// 是否已标记（系统提醒 Schema isFlagged 的落盘字段；默认不标记）
    var isFlagged: Bool

    init(
        id: UUID = UUID(),
        text: String,
        fireDate: Date,
        createdAt: Date = Date(),
        repeatRule: AgentReminderRepeat = .none,
        isFlagged: Bool = false
    ) {
        self.id = id
        self.text = text
        self.fireDate = fireDate
        self.createdAt = createdAt
        self.repeatRule = repeatRule
        self.isFlagged = isFlagged
    }

    /// 兼容旧数据：历史存储没有 repeatRule 字段，解码为单次
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        fireDate = try container.decode(Date.self, forKey: .fireDate)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        repeatRule = try container.decodeIfPresent(AgentReminderRepeat.self, forKey: .repeatRule) ?? .none
        isFlagged = try container.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
    }
}

/// 提醒存储（UserDefaults JSON 持久化，最多 20 条，按触发时间升序）
enum AgentReminderStore {
    static let key = "agent.reminders.data"
    static let maxCount = 20

    static var reminders: [AgentReminder] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            let items = (try? JSONDecoder().decode([AgentReminder].self, from: data)) ?? []
            return items.sorted { $0.fireDate < $1.fireDate }
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
            AgentHomeCardRefreshCenter.post()
        }
    }

    /// 新增提醒；内容为空或已达上限返回 nil
    @discardableResult
    static func add(
        text: String,
        fireDate: Date,
        repeatRule: AgentReminderRepeat = .none
    ) -> AgentReminder? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard reminders.count < maxCount else { return nil }
        let reminder = AgentReminder(text: text, fireDate: fireDate, repeatRule: repeatRule)
        var items = reminders
        items.append(reminder)
        reminders = items
        return reminder
    }

    static func remove(id: UUID) {
        reminders = reminders.filter { $0.id != id }
    }

    /// 更新已存在的提醒（稍后提醒等）；找不到返回 nil
    @discardableResult
    static func update(_ reminder: AgentReminder) -> AgentReminder? {
        var items = reminders
        guard let index = items.firstIndex(where: { $0.id == reminder.id }) else { return nil }
        items[index] = reminder
        reminders = items
        return reminder
    }

    /// 按内容包含匹配移除；返回移除数量
    @discardableResult
    static func remove(matching text: String) -> Int {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = reminders
        let kept = text.isEmpty
            ? []
            : items.filter { !$0.text.contains(text) }
        reminders = kept
        return items.count - kept.count
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        AgentHomeCardRefreshCenter.post()
    }
}

// MARK: - 主页双卡刷新信号

/// 主页「今日安排」双卡（日程 / 提醒）刷新信号中心：
/// 任何入口（语音指令、设置页、通知 Action、外部日历变更）改动数据后广播，
/// 主页订阅后即时重新拉取，保证回到主页时信息始终最新（幂等）。
enum AgentHomeCardRefreshCenter {
    static let didChangeName = Notification.Name("AgentHomeCardRefreshCenter.didChange")

    /// 广播一次主页卡片刷新信号
    static func post() {
        NotificationCenter.default.post(name: didChangeName, object: nil)
    }

    /// 供 SwiftUI 视图以 onReceive 订阅
    static var publisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: didChangeName)
    }
}

// MARK: - Command

/// 语音提醒指令
enum AgentReminderCommand: Equatable {
    /// 设置提醒：内容 + 触发时间 + 重复规则
    case set(text: String, fireDate: Date, repeatRule: AgentReminderRepeat = .none)
    /// 取消提醒（nil = 全部取消）
    case cancel(text: String?)
    /// 完成（与锁屏通知 Action complete 语义一致：移除 + 取消调度）
    case complete(text: String?)
    /// 查询提醒列表
    case query
}

/// 语音提醒指令解析（保守匹配，避免误吞普通对话）
enum AgentReminderCommandParser {
    static let setPrefixes = ["提醒我", "定个提醒", "设置提醒", "定个闹钟", "闹钟"]
    static let cancelPrefixes = ["取消提醒", "删除提醒", "取消闹钟", "删除闹钟", "关掉提醒", "清空提醒"]
    static let completePrefixes = ["完成提醒", "提醒完成", "标记完成", "标为完成", "已完成"]
    static let queryPrefixes = ["有什么提醒", "查看提醒", "提醒列表", "提醒我什么", "查一下提醒", "有哪些提醒"]

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AgentReminderCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if queryPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .query
        }
        for prefix in cancelPrefixes where trimmed.hasPrefix(prefix) {
            let target = AgentReminderTimeParser.strip(trimmed.dropFirst(prefix.count))
            return .cancel(text: target.isEmpty ? nil : target)
        }
        for prefix in completePrefixes where trimmed.hasPrefix(prefix) {
            let target = AgentReminderTimeParser.strip(trimmed.dropFirst(prefix.count))
            return .complete(text: target.isEmpty ? nil : target)
        }
        for prefix in setPrefixes where trimmed.hasPrefix(prefix) {
            let remainder = AgentReminderTimeParser.strip(trimmed.dropFirst(prefix.count))
            guard !remainder.isEmpty,
                  let time = AgentReminderTimeParser.parse(from: remainder, now: now, calendar: calendar) else {
                continue
            }
            let content = AgentReminderTimeParser.strip(remainder.dropFirst(time.consumedCount))
            guard !content.isEmpty else { continue }
            return .set(text: content, fireDate: time.date, repeatRule: time.repeatRule)
        }
        // 时间在前：「十分钟后提醒我喝水」「明天早上八点提醒我开会」
        if let time = AgentReminderTimeParser.parse(from: trimmed, now: now, calendar: calendar) {
            let afterTime = AgentReminderTimeParser.strip(trimmed.dropFirst(time.consumedCount))
            guard afterTime.hasPrefix("提醒我") else { return nil }
            let content = AgentReminderTimeParser.strip(afterTime.dropFirst(3))
            guard !content.isEmpty else { return nil }
            return .set(text: content, fireDate: time.date, repeatRule: time.repeatRule)
        }
        return nil
    }
}

// MARK: - Time Parsing

/// 时间解析结果：绝对触发时间 + 消耗的字符数（时间短语前缀长度）
struct AgentReminderTimeMatch {
    let date: Date
    let consumedCount: Int
    var repeatRule: AgentReminderRepeat = .none
}

/// 中文自然语言时间解析（保守规则，可测试）
enum AgentReminderTimeParser {
    /// 数字 token（长 token 在前避免误吞）
    static let numberTokens: [(token: String, value: Int)] = [
        ("二十四", 24), ("二十三", 23), ("二十二", 22), ("二十一", 21),
        ("二十", 20), ("十九", 19), ("十八", 18), ("十七", 17), ("十六", 16),
        ("十五", 15), ("十四", 14), ("十三", 13), ("十二", 12), ("十一", 11),
        ("十", 10), ("九", 9), ("八", 8), ("七", 7), ("六", 6),
        ("五", 5), ("四", 4), ("三", 3), ("两", 2), ("二", 2), ("一", 1),
    ]
    /// 阿拉伯数字（支持 0~59 两位）
    static let arabicDigits = Array(0...59).map(String.init)

    /// 解析文本开头的相对或绝对时间短语；不支持返回 nil
    static func parse(from text: String, now: Date = Date(), calendar: Calendar = .current) -> AgentReminderTimeMatch? {
        if let match = parseRelative(text, now: now) { return match }
        return parseAbsolute(text, now: now, calendar: calendar)
    }

    /// 相对时间：半小时 / X分钟后 / X分钟以后 / X小时 / X天
    private static func parseRelative(_ text: String, now: Date) -> AgentReminderTimeMatch? {
        if text.hasPrefix("半个小时") {
            return AgentReminderTimeMatch(date: now.addingTimeInterval(1800), consumedCount: 4)
        }
        if text.hasPrefix("半小时") {
            return AgentReminderTimeMatch(date: now.addingTimeInterval(1800), consumedCount: 3)
        }
        for (token, value) in numberTokens {
            for suffix in ["分钟后", "分钟以后", "分钟"] {
                let phrase = token + suffix
                guard text.hasPrefix(phrase) else { continue }
                return AgentReminderTimeMatch(
                    date: now.addingTimeInterval(TimeInterval(value * 60)),
                    consumedCount: phrase.count
                )
            }
            for suffix in ["小时后", "小时"] {
                let phrase = token + suffix
                guard text.hasPrefix(phrase) else { continue }
                return AgentReminderTimeMatch(
                    date: now.addingTimeInterval(TimeInterval(value * 3600)),
                    consumedCount: phrase.count
                )
            }
            for suffix in ["天后", "天"] {
                let phrase = token + suffix
                guard text.hasPrefix(phrase) else { continue }
                return AgentReminderTimeMatch(
                    date: now.addingTimeInterval(TimeInterval(value * 86400)),
                    consumedCount: phrase.count
                )
            }
        }
        for digit in arabicDigits {
            for suffix in ["分钟后", "分钟以后", "分钟"] {
                let phrase = digit + suffix
                guard text.hasPrefix(phrase), let value = Int(digit) else { continue }
                return AgentReminderTimeMatch(
                    date: now.addingTimeInterval(TimeInterval(value * 60)),
                    consumedCount: phrase.count
                )
            }
            for suffix in ["小时后", "小时"] {
                let phrase = digit + suffix
                guard text.hasPrefix(phrase), let value = Int(digit) else { continue }
                return AgentReminderTimeMatch(
                    date: now.addingTimeInterval(TimeInterval(value * 3600)),
                    consumedCount: phrase.count
                )
            }
            for suffix in ["天后", "天"] {
                let phrase = digit + suffix
                guard text.hasPrefix(phrase), let value = Int(digit) else { continue }
                return AgentReminderTimeMatch(
                    date: now.addingTimeInterval(TimeInterval(value * 86400)),
                    consumedCount: phrase.count
                )
            }
        }
        return nil
    }

    /// 绝对时间：([每天|每周|周X]|[今天|明天|后天])([凌晨|早上|上午|中午|下午|晚上])X点(Y分|半)
    private static func parseAbsolute(_ text: String, now: Date, calendar: Calendar) -> AgentReminderTimeMatch? {
        var remainder = text
        var dayOffset = 0
        var defaultHour: Int?
        var explicitDay = false
        var afternoonOrEvening = false
        var repeatRule: AgentReminderRepeat = .none
        var consumed = 0

        // 重复规则：「每天」每天同一时刻；「每周」每周同一天（今天）；「周X / 礼拜X / 星期X」指定星期
        if remainder.hasPrefix("每天") {
            repeatRule = .daily
            remainder = String(remainder.dropFirst(2))
            consumed += 2
        } else if let weekday = parseWeekday(remainder, calendar: calendar, now: now) {
            repeatRule = .weekly
            dayOffset = weekday.daysUntil
            remainder = String(remainder.dropFirst(weekday.consumedCount))
            consumed += weekday.consumedCount
        } else if remainder.hasPrefix("每周") {
            repeatRule = .weekly
            remainder = String(remainder.dropFirst(2))
            consumed += 2
        }
        for (prefix, offset) in [("后天", 2), ("明天", 1), ("今天", 0)] where remainder.hasPrefix(prefix) {
            dayOffset = offset
            explicitDay = true
            remainder = String(remainder.dropFirst(prefix.count))
            consumed += prefix.count
            break
        }
        if remainder.hasPrefix("明晚") {
            dayOffset = 1
            explicitDay = true
            defaultHour = 20
            afternoonOrEvening = true
            remainder = String(remainder.dropFirst(2))
            consumed += 2
        } else if remainder.hasPrefix("今晚") {
            dayOffset = 0
            explicitDay = true
            defaultHour = 20
            afternoonOrEvening = true
            remainder = String(remainder.dropFirst(2))
            consumed += 2
        }
        for (prefix, hour) in [("凌晨", 3), ("早上", 7), ("上午", 9), ("中午", 12), ("下午", 15), ("晚上", 20)] where remainder.hasPrefix(prefix) {
            defaultHour = hour
            if prefix == "下午" || prefix == "晚上" {
                afternoonOrEvening = true
            }
            remainder = String(remainder.dropFirst(prefix.count))
            consumed += prefix.count
            break
        }
        guard let time = parseClock(remainder) else { return nil }
        var hour = time.hour ?? defaultHour
        // 十二小时制换算：下午/晚上 3 点 = 15 点
        if afternoonOrEvening, let parsedHour = time.hour, parsedHour < 12 {
            hour = parsedHour + 12
        }
        guard let hour, (0...23).contains(hour) else { return nil }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 1) + dayOffset
        components.hour = hour
        components.minute = time.minute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }

        // 时间已过 → 顺延到下一次触发：每天 +1 天、每周 +7 天、单次按「下一次八点」顺延一天
        if date <= now {
            switch repeatRule {
            case .daily:
                date = date.addingTimeInterval(86400)
            case .weekly:
                date = date.addingTimeInterval(7 * 86400)
            case .none:
                if !explicitDay || dayOffset == 0 {
                    date = date.addingTimeInterval(86400)
                }
            }
        }
        return AgentReminderTimeMatch(
            date: date,
            consumedCount: consumed + time.consumedCount,
            repeatRule: repeatRule
        )
    }

    /// 星期解析：「每周X / 周X / 礼拜X / 星期X」（X = 一~日/天）；返回目标星期与距今天数
    private static func parseWeekday(
        _ text: String,
        calendar: Calendar,
        now: Date
    ) -> (daysUntil: Int, consumedCount: Int)? {
        let weekdayNames: [(name: String, weekday: Int)] = [
            ("一", 2), ("二", 3), ("三", 4), ("四", 5), ("五", 6), ("六", 7), ("日", 1), ("天", 1),
        ]
        for prefix in ["礼拜", "星期", "每周", "周"] where text.hasPrefix(prefix) {
            let after = String(text.dropFirst(prefix.count))
            guard let first = after.first,
                  let match = weekdayNames.first(where: { $0.name == String(first) }) else { continue }
            let today = calendar.component(.weekday, from: now)
            let daysUntil = (match.weekday - today + 7) % 7
            return (daysUntil, prefix.count + 1)
        }
        return nil
    }

    /// 解析钟点：X点 / X点半 / X点Y分；返回小时（可空）、分钟与消耗长度
    private static func parseClock(_ text: String) -> (hour: Int?, minute: Int, consumedCount: Int)? {
        for (token, value) in numberTokens where value <= 24 {
            let phrase = token + "点"
            guard text.hasPrefix(phrase) else { continue }
            var minute = 0
            var consumed = phrase.count
            let after = String(text.dropFirst(phrase.count))
            if after.hasPrefix("半") {
                minute = 30
                consumed += 1
            } else {
                for (minuteToken, minuteValue) in numberTokens where minuteValue < 60 {
                    let minutePhrase = minuteToken + "分"
                    guard after.hasPrefix(minutePhrase) else { continue }
                    minute = minuteValue
                    consumed += minutePhrase.count
                    break
                }
            }
            return (value, minute, consumed)
        }
        for digit in arabicDigits {
            guard let value = Int(digit), value <= 24 else { continue }
            let phrase = digit + "点"
            guard text.hasPrefix(phrase) else { continue }
            var minute = 0
            var consumed = phrase.count
            let after = String(text.dropFirst(phrase.count))
            if after.hasPrefix("半") {
                minute = 30
                consumed += 1
            } else {
                for minuteDigit in arabicDigits {
                    let minutePhrase = minuteDigit + "分"
                    guard after.hasPrefix(minutePhrase), let minuteValue = Int(minuteDigit) else { continue }
                    minute = minuteValue
                    consumed += minutePhrase.count
                    break
                }
            }
            return (value, minute, consumed)
        }
        return nil
    }

    /// 剥离两侧空白与常见标点
    static func strip(_ text: Substring) -> String {
        String(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。！!？?、，"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Announcement Copy

/// 提醒确认文案（纯逻辑，可测试）
enum AgentReminderTimeFormatter {
    /// 相对触发描述：「马上」「X分钟后」「X小时后」；超过 24 小时用「明天/后天 HH:mm」或「M月d日 HH:mm」
    static func relativeDescription(from fireDate: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = max(0, fireDate.timeIntervalSince(now))
        if interval < 60 { return "agent.reminder.time.moment".localized }
        // 跨自然日的提醒优先显示相对日期（如「明天 08:00」），比「20小时后」更清晰
        let dayOffset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: fireDate)
        ).day ?? 0
        if dayOffset >= 1 {
            let clock = Self.clockFormatter.string(from: fireDate)
            switch dayOffset {
            case 1: return "agent.reminder.time.tomorrow".localized(clock)
            case 2: return "agent.reminder.time.aftertomorrow".localized(clock)
            default:
                return Self.dateFormatter.string(from: fireDate)
            }
        }
        if interval < 3600 {
            return String(format: "agent.reminder.time.minutes".localized, Int(interval / 60))
        }
        if interval < 86400 {
            return String(format: "agent.reminder.time.hours".localized, Int(interval / 3600))
        }
        return Self.dateFormatter.string(from: fireDate)
    }

    /// 播报 / 列表展示描述：单次用相对时间，周期提醒显示「每天 HH:mm」「每周 HH:mm」
    static func announcementDescription(
        for reminder: AgentReminder,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let clock = Self.clockFormatter.string(from: reminder.fireDate)
        switch reminder.repeatRule {
        case .none:
            return relativeDescription(from: reminder.fireDate, now: now, calendar: calendar)
        case .daily:
            return String(format: "agent.reminder.time.repeating.daily".localized, clock)
        case .weekly:
            return String(format: "agent.reminder.time.repeating.weekly".localized, clock)
        }
    }

    /// 周期徽标短文案（设置页列表用）
    static func repeatBadge(_ rule: AgentReminderRepeat) -> String {
        switch rule {
        case .none: return ""
        case .daily: return "agent.reminder.repeat.daily".localized
        case .weekly: return "agent.reminder.repeat.weekly".localized
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

/// 设置页「稍后提醒」滑动动作策略（纯逻辑，可测）：
/// 单次提醒已到点（fireDate <= now）可稍后；周期提醒无需（到点自动再触发）。
/// 重排计算复用 `AgentReminderNotificationAction.snoozed`（与锁屏通知 Action 行为一致）。
enum AgentReminderSnoozePolicy {
    static func canSnooze(_ reminder: AgentReminder, now: Date = Date()) -> Bool {
        reminder.repeatRule == .none && reminder.fireDate <= now
    }

    static func snoozed(
        _ reminder: AgentReminder,
        minutes: Int = AgentReminderNotificationAction.snoozeMinutes,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentReminder {
        AgentReminderNotificationAction.snoozed(
            reminder,
            minutes: minutes,
            now: now,
            calendar: calendar
        )
    }
}

/// 镜片 Reminders 子菜单的纯映射（不依赖 SDK 运行时，可测）。
/// 主菜单动态出现依据 + 按钮短标签 + 播报/展示文本。
enum AgentReminderDisplayMapping {
    /// 是否有即将触发的提醒（镜片主菜单「Reminders」动态出现的依据）；
    /// 周期提醒永远有效（下次仍会触发），单次提醒只看未来
    static func hasActiveReminders(_ reminders: [AgentReminder], now: Date = Date()) -> Bool {
        reminders.contains { $0.repeatRule != .none || $0.fireDate >= now }
    }

    /// 即将触发的提醒（升序，最多 limit 条；周期提醒保留最近一次触发）
    static func upcoming(
        _ reminders: [AgentReminder],
        now: Date = Date(),
        limit: Int = 5
    ) -> [AgentReminder] {
        reminders
            .filter { $0.repeatRule != .none || $0.fireDate >= now }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 镜片按钮短标签：提醒内容截断（超长加省略号），空内容回退「Reminder」
    static func menuLabel(for reminder: AgentReminder, maxLength: Int = 8) -> String {
        let text = reminder.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Reminder" }
        let trimmed = String(text.prefix(maxLength))
        return text.count > maxLength ? trimmed + "…" : trimmed
    }

    /// 镜片结果卡 / TTS 播报文本：相对时间：内容
    static func resultText(for reminder: AgentReminder, now: Date = Date()) -> String {
        let when = AgentReminderTimeFormatter.announcementDescription(for: reminder, now: now)
        return String(format: "agent.reminder.query.item".localized, when, reminder.text)
    }
}

// MARK: - 提醒「完成」反馈文案

/// 提醒「完成」的反馈文案（纯逻辑，可测）。
/// 完成与锁屏通知 Action complete 语义一致：移除 + 取消调度；话术区分「完成」与「取消」。
enum AgentReminderCompletion {
    /// 单条完成播报：如「已完成：喝水」
    static func completedText(for text: String) -> String {
        String(format: "agent.reminder.completed.text".localized, text)
    }

    /// 批量完成播报（完成全部 / 多条）
    static func completedAllText(count: Int) -> String {
        String(format: "agent.reminder.completed.all".localized, count)
    }

    /// 指定目标未匹配
    static func noneText(for target: String) -> String {
        String(format: "agent.reminder.complete.none".localized, target)
    }

    /// 无任何提醒可完成
    static func noneAnyText() -> String {
        "agent.reminder.complete.none.all".localized
    }
}

/// 镜片提醒操作执行器（App 侧 @MainActor）：
/// 完成 / 删除均移除存储并取消通知调度（与锁屏通知 Action 同一语义），
/// 返回播报文案；提醒已不存在返回 nil（防重复点按 / 已失效）。
enum AgentReminderLensAction {
    /// 完成：移除 + 取消调度，返回「已完成：xxx」
    @MainActor
    @discardableResult
    static func complete(_ reminder: AgentReminder) -> String? {
        guard AgentReminderStore.reminders.contains(where: { $0.id == reminder.id }) else { return nil }
        AgentReminderScheduler.cancel(id: reminder.id)
        AgentReminderStore.remove(id: reminder.id)
        return AgentReminderCompletion.completedText(for: reminder.text)
    }

    /// 删除：移除 + 取消调度，返回「已删除提醒：xxx」
    @MainActor
    @discardableResult
    static func delete(_ reminder: AgentReminder) -> String? {
        guard AgentReminderStore.reminders.contains(where: { $0.id == reminder.id }) else { return nil }
        AgentReminderScheduler.cancel(id: reminder.id)
        AgentReminderStore.remove(id: reminder.id)
        return String(format: "agent.reminder.deleted.text".localized, reminder.text)
    }
}

// MARK: - 主页「下次提醒」卡片

/// 主页下次提醒卡的展示映射（纯逻辑，可测）：
/// 取触发时间最近的一条——单次用相对时间（「25分钟后」），
/// 周期显示「每天 HH:mm」「每周 HH:mm」；无提醒显示空态占位。
enum AgentHomeReminderCardMapping {
    struct Content: Equatable {
        /// 主行文本
        let line: String
        /// 是否为占位（空态，弱化显示）
        let isPlaceholder: Bool
        /// 待触发提醒数量（周期提醒永远有效，单次只看未来；主页徽标用）
        let count: Int
    }

    static func content(
        reminders: [AgentReminder],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Content {
        let count = reminders
            .filter { $0.repeatRule != .none || $0.fireDate >= now }
            .count
        guard let next = reminders.sorted(by: { $0.fireDate < $1.fireDate }).first else {
            return Content(
                line: "home.reminder.empty".localized,
                isPlaceholder: true,
                count: 0
            )
        }
        return Content(
            line: AgentReminderTimeFormatter.announcementDescription(
                for: next,
                now: now,
                calendar: calendar
            ),
            isPlaceholder: false,
            count: count
        )
    }
}

// MARK: - System Scheduling

/// 提醒通知的前台播报判定与文案（纯逻辑，可测）
enum ReminderNotificationPresenter {
    /// 通知 userInfo 标记键：标记为本 App 的本地提醒通知
    static let userInfoKey = "agent.reminder"

    static func isReminder(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }
        return userInfo[userInfoKey] as? Bool == true
    }

    /// 前台播报文案：如「提醒：吃药」
    static func announcementText(for text: String) -> String {
        String(format: "agent.reminder.notification.body".localized, text)
    }
}

/// 提醒通知的交互 Action（锁屏 / 通知中心点按）：稍后提醒、完成。
/// 标识常量与重排计算为纯逻辑，便于测试；系统注册走 `register()`。
enum AgentReminderNotificationAction {
    static let categoryIdentifier = "agent.reminder.category"
    static let snoozeIdentifier = "agent.reminder.action.snooze"
    /// 锁屏「明天提醒」：把提醒重排到明天同一时刻
    static let tomorrowIdentifier = "agent.reminder.action.tomorrow"
    static let completeIdentifier = "agent.reminder.action.complete"
    /// 锁屏文本输入「回复 JARVIS」（与任务通知同一语义：文本作为指令交给 JARVIS）
    static let replyIdentifier = "agent.reminder.action.reply"
    /// 稍后提醒默认延后分钟数
    static let snoozeMinutes = 10

    /// 文本回复决策（纯逻辑，可测）：空白 / 空输入返回 nil（忽略），否则返回去空白文本
    static func replyText(from userText: String?) -> String? {
        guard let text = userText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// 锁屏「回复 JARVIS」文本输入 Action（文案键与任务通知分类共用）
    static var replyAction: UNTextInputNotificationAction {
        UNTextInputNotificationAction(
            identifier: replyIdentifier,
            title: "agent.task.action.reply".localized,
            options: [.foreground],
            textInputButtonTitle: "agent.task.action.reply.send".localized,
            textInputPlaceholder: "agent.task.action.reply.placeholder".localized
        )
    }

    /// 分类动作集（稍后提醒 / 明天提醒 / 完成 / 回复 JARVIS；register 与测试共用）
    static var actions: [UNNotificationAction] {
        [
            UNNotificationAction(
                identifier: snoozeIdentifier,
                title: "agent.reminder.action.snooze".localized,
                options: []
            ),
            UNNotificationAction(
                identifier: tomorrowIdentifier,
                title: "agent.reminder.action.tomorrow".localized,
                options: []
            ),
            UNNotificationAction(
                identifier: completeIdentifier,
                title: "agent.reminder.action.complete".localized,
                options: [.destructive]
            ),
            replyAction
        ]
    }

    /// 按通知 identifier（提醒 id 的 uuidString）在列表中定位提醒
    static func reminder(
        in reminders: [AgentReminder],
        notificationIdentifier: String
    ) -> AgentReminder? {
        reminders.first { $0.id.uuidString == notificationIdentifier }
    }

    /// 稍后提醒：单次提醒延后 minutes 分钟；周期提醒推算 minutes 之后的下一次触发（跳过本次）。
    static func snoozed(
        _ reminder: AgentReminder,
        minutes: Int = snoozeMinutes,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentReminder {
        var copy = reminder
        switch reminder.repeatRule {
        case .none:
            // 响应晚于触发时间时从当前时间起算，避免立即再次触发
            copy.fireDate = max(reminder.fireDate, now).addingTimeInterval(TimeInterval(minutes * 60))
        case .daily, .weekly:
            let spec = AgentReminderScheduleBuilder.spec(for: reminder, calendar: calendar)
            let earliest = now.addingTimeInterval(TimeInterval(minutes * 60))
            copy.fireDate = calendar.nextDate(
                after: earliest,
                matching: spec.components,
                matchingPolicy: .nextTime
            ) ?? earliest
        }
        return copy
    }

    /// 「明天提醒」：把提醒重排到明天同一时刻（保留 id / text / 重复规则；
    /// 日历日加法正确跨越月末 / 年末，fallback 为固定 24 小时）。
    static func tomorrow(
        _ reminder: AgentReminder,
        calendar: Calendar = .current
    ) -> AgentReminder {
        var copy = reminder
        copy.fireDate = calendar.date(byAdding: .day, value: 1, to: reminder.fireDate)
            ?? reminder.fireDate.addingTimeInterval(24 * 60 * 60)
        return copy
    }

    /// Action 处理结果（纯逻辑，可测）
    enum Outcome: Equatable {
        /// 已重排：携带更新后的提醒
        case snoozed(AgentReminder)
        /// 已重排到明天同一时刻：携带更新后的提醒
        case tomorrow(AgentReminder)
        /// 已完成：携带被移除的提醒
        case completed(AgentReminder)
        /// 无匹配（未知 Action / 提醒已不存在）
        case ignored
    }

    /// 根据 Action 与通知 identifier 计算处理结果
    static func outcome(
        actionIdentifier: String,
        notificationIdentifier: String,
        reminders: [AgentReminder],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Outcome {
        guard let reminder = reminder(in: reminders, notificationIdentifier: notificationIdentifier) else {
            return .ignored
        }
        switch actionIdentifier {
        case snoozeIdentifier:
            return .snoozed(snoozed(reminder, now: now, calendar: calendar))
        case tomorrowIdentifier:
            return .tomorrow(tomorrow(reminder, calendar: calendar))
        case completeIdentifier:
            return .completed(reminder)
        default:
            return .ignored
        }
    }

    /// 注册通知 Category（含「稍后提醒」「明天提醒」「完成」「回复 JARVIS」四个 Action）
    static func register() {
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// 提醒通知前台代理：App 在前台时把提醒同步到镜片并 TTS 播报（系统横幅保留作兜底）
final class AgentReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentReminderNotificationDelegate()

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        guard ReminderNotificationPresenter.isReminder(content.userInfo) else {
            // 非提醒通知：交给 JARVIS 通知播报管家（按策略 TTS 摘要播报），系统横幅保留
            Task { @MainActor in
                AgentNotificationButler.shared.handleForeground(notification: notification)
            }
            completionHandler([.banner, .sound])
            return
        }
        let announcement = ReminderNotificationPresenter.announcementText(for: content.body)
        Task { @MainActor in
            // 提醒已触发：结束对应倒计时 Live Activity（由本地通知接力）
            AgentLiveActivityManager.updateReminderCountdown(text: nil, fireDate: nil)
            AgentDisplayHub.shared.showResult(
                title: "agent.reminder.notification.title".localized,
                text: announcement,
                fallback: .idle
            )
            if AgentVoiceSettings.replyEnabled,
               AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                TTSService.shared.stop()
                TTSService.shared.speak(announcement)
            }
        }
        // 保留系统横幅：无眼镜连接时仍可见
        completionHandler([.banner, .sound])
    }

    /// 后台点按通知 Action：稍后提醒（重排）或完成（取消）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        // 任务完成 / 失败通知的 Action（查看结果 / 追问 / 重试 / 稍后提醒 / 回复 JARVIS）
        if AgentTaskNotificationCategory.isTaskCategory(request.content.categoryIdentifier) {
            let action = AgentTaskNotificationActionParser.parse(
                actionIdentifier: response.actionIdentifier,
                text: (response as? UNTextInputNotificationResponse)?.userText
            )
            Task { @MainActor in
                await AgentTaskNotificationActionHandler.handle(action: action, request: request)
            }
            completionHandler()
            return
        }
        // 日程提醒通知：点按深链到设置页日历分区（无动作按钮，纯跳转）
        if AgentCalendarNotificationAction.isCalendarEvent(request.content.userInfo) {
            if let destination = AgentCalendarNotificationAction.destination(
                for: response.actionIdentifier
            ) {
                Task { @MainActor in
                    AppNavigationRouter.shared.request(destination)
                }
            }
            completionHandler()
            return
        }
        // 「问 JARVIS」结果通知：查看详情（深链）/ 继续追问 / 重试同一问题 / 回复 JARVIS
        if AgentAskResultDeepLink.isAskResult(request.content.userInfo) {
            let action = AgentAskResultNotificationActionParser.parse(
                actionIdentifier: response.actionIdentifier,
                text: (response as? UNTextInputNotificationResponse)?.userText
            )
            let recordID = AgentAskResultDeepLink.recordID(from: request.content.userInfo)
            Task { @MainActor in
                await AgentAskResultNotificationActionHandler.handle(
                    action: action,
                    recordID: recordID,
                    message: AgentAskResultDeepLink.message(from: request.content.userInfo),
                    brain: AgentAskResultDeepLink.brain(from: request.content.userInfo)
                )
            }
            completionHandler()
            return
        }
        guard ReminderNotificationPresenter.isReminder(request.content.userInfo) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            // 锁屏文本输入「回复 JARVIS」：文本作为指令打开语音页（本地指令由语音页拦截）
            if response.actionIdentifier == AgentReminderNotificationAction.replyIdentifier,
               let text = AgentReminderNotificationAction.replyText(
                   from: (response as? UNTextInputNotificationResponse)?.userText
               ) {
                AgentTaskNotificationActionRouter.shared.replyToJARVIS(text: text)
                completionHandler()
                return
            }
            let outcome = AgentReminderNotificationAction.outcome(
                actionIdentifier: response.actionIdentifier,
                notificationIdentifier: request.identifier,
                reminders: AgentReminderStore.reminders
            )
            switch outcome {
            case .snoozed(let updated):
                if AgentReminderStore.update(updated) != nil {
                    AgentReminderScheduler.schedule(updated)
                    let announcement = String(
                        format: "agent.reminder.action.snoozed.text".localized,
                        AgentReminderTimeFormatter.relativeDescription(from: updated.fireDate)
                    )
                    AgentDisplayHub.shared.showResult(
                        title: "agent.reminder.notification.title".localized,
                        text: announcement,
                        fallback: .idle
                    )
                    if AgentVoiceSettings.replyEnabled,
                       AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                        TTSService.shared.stop()
                        TTSService.shared.speak(announcement)
                    }
                }
            case .tomorrow(let updated):
                if AgentReminderStore.update(updated) != nil {
                    AgentReminderScheduler.schedule(updated)
                    let announcement = "agent.reminder.action.tomorrow.text".localized
                    AgentDisplayHub.shared.showResult(
                        title: "agent.reminder.notification.title".localized,
                        text: announcement,
                        fallback: .idle
                    )
                    if AgentVoiceSettings.replyEnabled,
                       AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                        TTSService.shared.stop()
                        TTSService.shared.speak(announcement)
                    }
                }
            case .completed(let reminder):
                AgentReminderStore.remove(id: reminder.id)
                AgentReminderScheduler.cancel(id: reminder.id)
            let announcement = AgentReminderCompletion.completedText(for: reminder.text)
            AgentDisplayHub.shared.showResult(
                title: "agent.reminder.notification.title".localized,
                text: announcement,
                fallback: .idle
            )
            if AgentVoiceSettings.replyEnabled,
               AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                TTSService.shared.stop()
                TTSService.shared.speak(announcement)
            }
            case .ignored:
                // 点按横幅本体（默认 Action）：打开提醒管理页（深链）
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                    AppNavigationRouter.shared.request(.agentSettings(.reminders))
                }
            }
            completionHandler()
        }
    }
}

/// 提醒的本地通知触发描述（纯逻辑，可测）
struct AgentReminderScheduleSpec: Equatable {
    let components: DateComponents
    let repeats: Bool
}

enum AgentReminderScheduleBuilder {
    /// 单次：完整年月日时分，不重复；每天：仅时分，重复；每周：星期 + 时分，重复
    static func spec(for reminder: AgentReminder, calendar: Calendar = .current) -> AgentReminderScheduleSpec {
        let fire = reminder.fireDate
        switch reminder.repeatRule {
        case .none:
            return AgentReminderScheduleSpec(
                components: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                repeats: false
            )
        case .daily:
            return AgentReminderScheduleSpec(
                components: calendar.dateComponents([.hour, .minute], from: fire),
                repeats: true
            )
        case .weekly:
            return AgentReminderScheduleSpec(
                components: calendar.dateComponents([.weekday, .hour, .minute], from: fire),
                repeats: true
            )
        }
    }
}

/// 本地通知调度（UNUserNotificationCenter 封装）
@MainActor
enum AgentReminderScheduler {
    /// 请求通知权限；返回是否授权
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// 调度一条提醒（幂等：先移除同 id 的待触发请求）
    static func schedule(_ reminder: AgentReminder) {
        // 刷新 Action 标题，兼容 App 内切换语言
        AgentReminderNotificationAction.register()
        AgentWidgetSnapshotCenter.refresh()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminder.id.uuidString])
        let content = UNMutableNotificationContent()
        content.title = "agent.reminder.notification.title".localized
        content.body = reminder.text
        content.sound = .default
        content.userInfo = [ReminderNotificationPresenter.userInfoKey: true]
        content.categoryIdentifier = AgentReminderNotificationAction.categoryIdentifier
        let spec = AgentReminderScheduleBuilder.spec(for: reminder)
        let trigger = UNCalendarNotificationTrigger(dateMatching: spec.components, repeats: spec.repeats)
        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)
        center.add(request)
        // 最近一条一次性提醒 → 锁屏倒计时 Live Activity（幂等重算）
        AgentReminderCountdownCoordinator.sync()
    }

    static func cancel(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        AgentWidgetSnapshotCenter.refresh()
        AgentReminderCountdownCoordinator.sync()
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        AgentWidgetSnapshotCenter.refresh()
        AgentReminderCountdownCoordinator.sync()
    }
}

// MARK: - 锁屏提醒倒计时卡按钮（Live Activity Action）

/// 提醒倒计时卡按钮请求（App 侧消费）：扩展进程只写 App Group 标记
/// （"snooze" / "complete"），App 前台读取并应用到当前展示的提醒。
enum AgentReminderTapStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.liveactivity.tap.reminder.v1"

    /// 消费原始标记（读到即清除）；可注入 defaults 便于测试
    static func consume(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> String? {
        let store = defaults ?? .standard
        guard let raw = store.string(forKey: requestKey) else { return nil }
        store.removeObject(forKey: requestKey)
        return raw
    }
}

/// 锁屏按钮请求 → 提醒操作结果（纯逻辑，可测）。
/// 作用对象是「当前展示的倒计时提醒」：即策略选中的最近一条一次性提醒，
/// 与锁屏卡片内容保持一致；无符合条件的提醒时忽略（防串台 / 已失效）。
enum AgentReminderTapHandler {
    static func handle(
        raw: String,
        reminders: [AgentReminder],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentReminderNotificationAction.Outcome? {
        guard let target = AgentReminderCountdownPolicy.nextReminder(
            in: reminders,
            now: now
        ) else { return nil }
        switch raw {
        case "snooze":
            return .snoozed(
                AgentReminderNotificationAction.snoozed(
                    target,
                    now: now,
                    calendar: calendar
                )
            )
        case "complete":
            return .completed(target)
        default:
            return nil
        }
    }
}

/// 锁屏提醒按钮请求协调器（App 侧，@MainActor）：
/// 观察 App Group 变更并消费请求，把结果应用到提醒存储与调度。
@MainActor
enum AgentReminderTapCoordinator {
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
                AgentReminderTapCoordinator.consumeIfNeeded()
            }
        }
        consumeIfNeeded()
    }

    /// 消费一次按钮请求并应用（返回是否处理了请求）。
    /// defaults / apply 可注入（测试用），nil 时走真实 App Group 与默认副作用。
    @discardableResult
    static func consumeIfNeeded(
        reminders: [AgentReminder] = AgentReminderStore.reminders,
        defaults: UserDefaults? = nil,
        apply: ((AgentReminderNotificationAction.Outcome) -> Void)? = nil
    ) -> Bool {
        let store = defaults
            ?? UserDefaults(suiteName: AgentReminderTapStore.suiteName)
            ?? .standard
        guard let raw = AgentReminderTapStore.consume(defaults: store) else { return false }
        guard let outcome = AgentReminderTapHandler.handle(
            raw: raw,
            reminders: reminders
        ) else { return true }
        if let apply {
            apply(outcome)
        } else {
            Self.apply(outcome)
        }
        return true
    }

    /// 默认应用：更新提醒存储与调度，并给出反馈播报
    private static func apply(_ outcome: AgentReminderNotificationAction.Outcome) {
        switch outcome {
        case .snoozed(let updated):
            if AgentReminderStore.update(updated) != nil {
                AgentReminderScheduler.schedule(updated)
                let announcement = String(
                    format: "agent.reminder.action.snoozed.text".localized,
                    AgentReminderTimeFormatter.relativeDescription(from: updated.fireDate)
                )
                AgentDisplayHub.shared.showResult(
                    title: "agent.reminder.notification.title".localized,
                    text: announcement,
                    fallback: .idle
                )
                if AgentVoiceSettings.replyEnabled,
                   AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                    TTSService.shared.stop()
                    TTSService.shared.speak(announcement)
                }
            }
        case .tomorrow(let updated):
            if AgentReminderStore.update(updated) != nil {
                AgentReminderScheduler.schedule(updated)
                let announcement = "agent.reminder.action.tomorrow.text".localized
                AgentDisplayHub.shared.showResult(
                    title: "agent.reminder.notification.title".localized,
                    text: announcement,
                    fallback: .idle
                )
                if AgentVoiceSettings.replyEnabled,
                   AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                    TTSService.shared.stop()
                    TTSService.shared.speak(announcement)
                }
            }
        case .completed(let reminder):
            AgentReminderStore.remove(id: reminder.id)
            AgentReminderScheduler.cancel(id: reminder.id)
            let announcement = AgentReminderCompletion.completedText(for: reminder.text)
            AgentDisplayHub.shared.showResult(
                title: "agent.reminder.notification.title".localized,
                text: announcement,
                fallback: .idle
            )
            if AgentVoiceSettings.replyEnabled,
               AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
                TTSService.shared.stop()
                TTSService.shared.speak(announcement)
            }
        case .ignored:
            break
        }
    }
}
