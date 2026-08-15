/*
 * Agent Calendar（日历日程）
 * 前端自有工具：经 EventKit 读写系统日历——「把明天下午3点的评审加入日历」创建日程、
 * 「今天有什么安排」查询日程；权限按需请求，与提醒 / 清单同属本地维护、不转发大脑。
 * EventKit 封装走 AgentCalendarProviding 协议（测试注入 Mock），解析 / 格式化纯逻辑可测。
 */

import EventKit
import Foundation
import UserNotifications

/// 一条日历日程（EventKit 实体转换为纯模型，便于测试与格式化）
struct AgentCalendarEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarName: String?

    init(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarName: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarName = calendarName
    }
}

/// 日历授权状态（映射 EKAuthorizationStatus，纯枚举可测）
enum AgentCalendarAuthorization: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// 日历能力提供者（可注入 Mock 测试）
protocol AgentCalendarProviding {
    var authorization: AgentCalendarAuthorization { get }
    func requestAuthorization() async -> AgentCalendarAuthorization
    func fetchEvents(from start: Date, to end: Date) async -> [AgentCalendarEvent]
    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws -> AgentCalendarEvent
    func deleteEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws
}

/// EventKit 真实实现（系统日历）
final class EventKitCalendarService: AgentCalendarProviding {
    private let store = EKEventStore()

    var authorization: AgentCalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess, .writeOnly:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> AgentCalendarAuthorization {
        if #available(iOS 17.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            _ = try? await store.requestAccess(to: .event)
        }
        return authorization
    }

    func fetchEvents(from start: Date, to end: Date) async -> [AgentCalendarEvent] {
        guard authorization == .authorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            AgentCalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                calendarName: event.calendar?.title
            )
        }
    }

    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool = false) async throws -> AgentCalendarEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return AgentCalendarEvent(
            title: event.title ?? title,
            start: event.startDate ?? start,
            end: event.endDate ?? end,
            isAllDay: event.isAllDay,
            calendarName: event.calendar?.title
        )
    }

    /// 删除精确匹配的日程（标题 / 起止 / 全天一致；重复实例按单次实例删除）
    func deleteEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws {
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-1),
            end: end.addingTimeInterval(1),
            calendars: nil
        )
        let matches = store.events(matching: predicate).filter {
            ($0.title ?? "") == title
                && $0.startDate == start
                && $0.endDate == end
                && $0.isAllDay == isAllDay
        }
        for event in matches {
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }
}

/// 应用侧日历能力入口（测试可替换 provider）
enum AgentCalendar {
    static var provider: AgentCalendarProviding = EventKitCalendarService()
}

// MARK: - Executor

/// 日历指令执行：统一授权 + EventKit 副作用，返回应答文案（可注入 provider 测试）
enum AgentCalendarExecutor {
    static func execute(
        _ command: AgentCalendarCommand,
        provider: AgentCalendarProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> String {
        switch command {
        case .create(let title, let start, let end):
            AgentCalendarDeletePendingStore.clear()
            let authorization = await provider.requestAuthorization()
            guard authorization == .authorized else {
                return "agent.calendar.denied".localized
            }
            do {
                let event = try await provider.createEvent(
                    title: title,
                    start: start,
                    end: end,
                    isAllDay: false
                )
                AgentHomeCardRefreshCenter.post()
                return AgentCalendarFormatter.createdConfirmation(
                    for: event,
                    now: now,
                    calendar: calendar
                )
            } catch {
                return "agent.calendar.create.failed".localized
            }
        case .query(let start, let end):
            AgentCalendarDeletePendingStore.clear()
            var authorization = provider.authorization
            if authorization == .notDetermined {
                authorization = await provider.requestAuthorization()
            }
            guard authorization == .authorized else {
                return "agent.calendar.denied".localized
            }
            let events = await provider.fetchEvents(from: start, to: end)
            if let summary = AgentCalendarFormatter.querySummary(
                events: events,
                now: now,
                calendar: calendar
            ) {
                return summary
            }
            let range = AgentCalendarFormatter.rangeTitle(
                start: start,
                end: end,
                now: now,
                calendar: calendar
            )
            return String(format: "agent.calendar.query.empty".localized, range)
        case .delete(let keyword, let start, let end):
            var authorization = provider.authorization
            if authorization == .notDetermined {
                authorization = await provider.requestAuthorization()
            }
            guard authorization == .authorized else {
                AgentCalendarDeletePendingStore.clear()
                return "agent.calendar.denied".localized
            }
            let events = await provider.fetchEvents(from: start, to: end)
            switch AgentCalendarDeleteMatcher.match(events: events, keyword: keyword) {
            case .delete(let event):
                AgentCalendarDeletePendingStore.clear()
                do {
                    try await provider.deleteEvent(
                        title: event.title,
                        start: event.start,
                        end: event.end,
                        isAllDay: event.isAllDay
                    )
                    AgentHomeCardRefreshCenter.post()
                    return String(
                        format: "agent.calendar.deleted".localized,
                        AgentCalendarFormatter.eventLine(event, now: now, calendar: calendar)
                    )
                } catch {
                    return "agent.calendar.delete.failed".localized
                }
            case .notFound:
                AgentCalendarDeletePendingStore.clear()
                return "agent.calendar.delete.notFound".localized
            case .ambiguous(let matches):
                // 进入追问闭环：候选暂存，回复编号列表引导用户选择
                AgentCalendarDeletePendingStore.store(matches)
                return AgentCalendarDeletePromptBuilder.prompt(
                    for: matches,
                    now: now,
                    calendar: calendar
                )
            }
        }
    }
}

// MARK: - Command

/// 日历语音 / 文字指令
enum AgentCalendarCommand: Equatable {
    /// 创建日程：标题 + 起止时间（默认时长 1 小时）
    case create(title: String, start: Date, end: Date)
    /// 查询时间范围内的日程
    case query(start: Date, end: Date)
    /// 删除日程：标题关键词 + 搜索窗口
    case delete(keyword: String, start: Date, end: Date)
}

/// 日历指令解析（保守匹配，避免误吞普通对话；时间短语复用提醒解析器）
enum AgentCalendarCommandParser {
    static let createSuffixes = [
        "加入日历", "加进日历", "加入日程", "加进日程",
        "添加到日历", "记到日历", "记入日程", "排进日程",
    ]
    static let leadingFillers = ["帮我把", "请把", "记得把", "把", "帮我", "请", "在"]
    static let queryMarkers = [
        "查一下日程", "查看日程", "查日程", "看看日程", "看一下日程", "日程列表",
        "有什么日程", "有什么安排", "什么日程", "什么安排", "看看安排", "看一下安排",
    ]
    /// 查询文本长度上限（防止普通对话命中 marker）
    static let queryMaxLength = 20
    /// 创建日程默认时长（1 小时）
    static let defaultDuration: TimeInterval = 3600

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AgentCalendarCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let query = parseQuery(trimmed, now: now, calendar: calendar) {
            return query
        }
        if let create = parseCreate(trimmed, now: now, calendar: calendar) {
            return create
        }
        if let delete = parseDelete(trimmed, now: now, calendar: calendar) {
            return delete
        }
        return nil
    }

    /// 删除动词（不含「取消」，避免与提醒取消指令冲突）
    static let deleteVerbs = ["删掉", "删除", "移除"]
    /// 日程语境词：无时间短语时仅当内容含这些词才拦截（避免误吞「删掉照片」等对话）
    static let deleteContextWords = ["日程", "安排", "会议", "约会", "行程", "事项", "预约", "会"]

    private static func parseDelete(_ text: String, now: Date, calendar: Calendar) -> AgentCalendarCommand? {
        // 后缀驱动：「把明天的评审删掉」「评审删除」
        let tail = text.trimmingCharacters(in: .punctuationCharacters)
        if let verb = deleteVerbs.first(where: { tail.hasSuffix($0) }),
           tail.count > verb.count {
            let content = stripLeadingFillers(String(tail.dropLast(verb.count)))
            return buildDelete(content: content, now: now, calendar: calendar)
        }
        // 前缀驱动：「删除明天的评审」「删掉下午3点的会」
        if let verb = deleteVerbs.first(where: { text.hasPrefix($0) }) {
            let content = String(text.dropFirst(verb.count))
            return buildDelete(content: content, now: now, calendar: calendar)
        }
        return nil
    }

    private static func buildDelete(content: String, now: Date, calendar: Calendar) -> AgentCalendarCommand? {
        var remainder = AgentReminderTimeParser.strip(content.dropFirst(0))
        var startDate: Date?
        if let time = AgentReminderTimeParser.parse(from: remainder, now: now, calendar: calendar) {
            startDate = time.date
            remainder = AgentReminderTimeParser.strip(remainder.dropFirst(time.consumedCount))
        }
        if remainder.hasPrefix("后的") {
            remainder = String(remainder.dropFirst(2))
        }
        remainder = String(remainder.drop(while: { "的、：，。!！?？ ".contains($0) }))
        var keyword = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return nil }
        let range: (start: Date, end: Date)
        if let startDate {
            range = (start: startDate, end: startDate.addingTimeInterval(86400))
        } else {
            range = AgentCalendarDayRange.resolve(in: content, now: now, calendar: calendar)
            // 无时间短语时需日期范围词或日程语境词保护（「删掉照片」不拦截）
            guard AgentCalendarDayRange.hasRangePhrase(content)
                || deleteContextWords.contains(where: { content.contains($0) }) else {
                return nil
            }
        }
        keyword = AgentCalendarDayRange.strippingRangeWords(keyword)
        guard !keyword.isEmpty else { return nil }
        return .delete(keyword: keyword, start: range.start, end: range.end)
    }

    private static func stripLeadingFillers(_ text: String) -> String {
        var rest = text
        for filler in leadingFillers where rest.hasPrefix(filler) {
            rest = String(rest.dropFirst(filler.count))
            break
        }
        return rest
    }

    private static func parseQuery(_ text: String, now: Date, calendar: Calendar) -> AgentCalendarCommand? {
        guard text.count <= queryMaxLength,
              queryMarkers.contains(where: { text.contains($0) }) else {
            return nil
        }
        let range = AgentCalendarDayRange.resolve(in: text, now: now, calendar: calendar)
        return .query(start: range.start, end: range.end)
    }

    private static func parseCreate(_ text: String, now: Date, calendar: Calendar) -> AgentCalendarCommand? {
        // 后缀驱动：「…加入日历」（后缀需在结尾，允许尾随标点）
        let tail = text.trimmingCharacters(in: .punctuationCharacters)
        if let suffix = createSuffixes.first(where: { tail.hasSuffix($0) }),
           tail.count > suffix.count,
           let match = buildCreate(
               content: String(tail.dropLast(suffix.count)),
               now: now,
               calendar: calendar
           ) {
            return match
        }
        // 时间在前：「明天下午3点把会议加入日历」
        if let time = AgentReminderTimeParser.parse(from: text, now: now, calendar: calendar) {
            let remainder = AgentReminderTimeParser.strip(text.dropFirst(time.consumedCount))
            let tail2 = remainder.trimmingCharacters(in: .punctuationCharacters)
            guard let suffix2 = createSuffixes.first(where: { tail2.hasSuffix($0) }),
                  tail2.count > suffix2.count else {
                return nil
            }
            return buildCreate(
                content: String(tail2.dropLast(suffix2.count)),
                now: now,
                calendar: calendar,
                start: time.date
            )
        }
        return nil
    }

    /// 从「内容（可能含开头时间短语）」构造 create；无时间短语 → nil（不拦截，交给大脑）
    private static func buildCreate(
        content: String,
        now: Date,
        calendar: Calendar,
        start: Date? = nil
    ) -> AgentCalendarCommand? {
        var remainder = content
        for filler in leadingFillers where remainder.hasPrefix(filler) {
            remainder = String(remainder.dropFirst(filler.count))
            break
        }
        var startDate = start
        if startDate == nil,
           let time = AgentReminderTimeParser.parse(from: remainder, now: now, calendar: calendar) {
            startDate = time.date
            remainder = AgentReminderTimeParser.strip(remainder.dropFirst(time.consumedCount))
        }
        // 时间短语在前的写法：「明天下午3点把会议加入日历」→ 时间后可能还有「把」
        for filler in leadingFillers where remainder.hasPrefix(filler) {
            remainder = String(remainder.dropFirst(filler.count))
            break
        }
        remainder = AgentReminderTimeParser.strip(remainder.dropFirst(0))
        // 「半小时后的健身」→ 时间短语后跟「后的」时一并剥掉
        if remainder.hasPrefix("后的") {
            remainder = String(remainder.dropFirst(2))
        }
        remainder = String(remainder.drop(while: { "的、：，。!！?？ ".contains($0) }))
        let title = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startDate, !title.isEmpty else { return nil }
        return .create(
            title: title,
            start: startDate,
            end: startDate.addingTimeInterval(defaultDuration)
        )
    }
}

// MARK: - Day Range

/// 查询日期范围解析（纯逻辑可测）
enum AgentCalendarDayRange {
    static let recentDuration: TimeInterval = 7 * 86400

    /// 从文本解析日期范围；无日期词 → 今天（半开区间 [start, end)）
    static func resolve(in text: String, now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        if text.contains("最近") {
            return (start: now, end: now.addingTimeInterval(recentDuration))
        }
        if text.contains("下周") {
            let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: now) ?? now
            let interval = calendar.dateInterval(of: .weekOfYear, for: nextWeek)
            return (start: interval?.start ?? now, end: interval?.end ?? now.addingTimeInterval(recentDuration))
        }
        if text.contains("后天") {
            let start = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? startOfToday
            return (start: start, end: nextDay(after: start, calendar: calendar))
        }
        if text.contains("明天") {
            let start = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return (start: start, end: nextDay(after: start, calendar: calendar))
        }
        if let weekday = weekdayToken(in: text) {
            let start = nextDate(forWeekday: weekday, after: now, calendar: calendar) ?? startOfToday
            return (start: start, end: nextDay(after: start, calendar: calendar))
        }
        if text.contains("这周") || text.contains("本周") || text.contains("这个星期") {
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return (start: interval?.start ?? startOfToday, end: interval?.end ?? nextDay(after: startOfToday, calendar: calendar))
        }
        if text.contains("今天") {
            return todayRange(now: now, calendar: calendar)
        }
        return todayRange(now: now, calendar: calendar)
    }

    /// 日期范围词（今天 / 明天 / 周X…），供删除指令语境保护与关键词剥离复用
    static var rangePhrases: [String] {
        ["今天", "明天", "后天", "最近", "下周", "这周", "本周", "这个星期"] + weekdayTokens.map(\.token)
    }

    /// 文本是否含日期范围词
    static func hasRangePhrase(_ text: String) -> Bool {
        rangePhrases.contains { text.contains($0) }
    }

    /// 剥离开头的日期范围词（「明天的」「周三的」），返回剩余文本
    static func strippingRangeWords(_ text: String) -> String {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for phrase in rangePhrases where rest.hasPrefix(phrase) {
            rest = String(rest.dropFirst(phrase.count))
            break
        }
        if rest.hasPrefix("的") {
            rest = String(rest.dropFirst(1))
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 今天（半开区间 [start, end)）
    static func todayRange(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        return (start: start, end: nextDay(after: start, calendar: calendar))
    }

    /// 明天（半开区间 [start, end)）
    static func tomorrowRange(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        return (start: start, end: nextDay(after: start, calendar: calendar))
    }

    private static let weekdayTokens: [(token: String, weekday: Int)] = [
        ("星期一", 2), ("礼拜一", 2), ("周一", 2),
        ("星期二", 3), ("礼拜二", 3), ("周二", 3),
        ("星期三", 4), ("礼拜三", 4), ("周三", 4),
        ("星期四", 5), ("礼拜四", 5), ("周四", 5),
        ("星期五", 6), ("礼拜五", 6), ("周五", 6),
        ("星期六", 7), ("礼拜六", 7), ("周六", 7),
        ("星期日", 1), ("星期天", 1), ("礼拜日", 1), ("礼拜天", 1),
        ("周日", 1), ("周天", 1),
    ]

    private static func weekdayToken(in text: String) -> Int? {
        weekdayTokens.first { text.contains($0.token) }?.weekday
    }

    /// 今天（若今天是该星期几）或下一个该星期几
    private static func nextDate(forWeekday weekday: Int, after now: Date, calendar: Calendar) -> Date? {
        var date = calendar.startOfDay(for: now)
        for _ in 0...7 {
            if calendar.component(.weekday, from: date) == weekday {
                return date
            }
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return nil
    }

    private static func nextDay(after date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }
}

// MARK: - 删除匹配

/// 删除日程的匹配决策（纯逻辑，可测）：
/// 归一化（去空白 + 小写）后双向包含匹配（标题含关键词或关键词含标题），
/// 唯一匹配才允许删除，多个则提示更具体，零个提示未找到。
enum AgentCalendarDeleteMatcher {
    enum Outcome: Equatable {
        case delete(AgentCalendarEvent)
        case notFound
        case ambiguous(events: [AgentCalendarEvent])
    }

    /// 归一化：小写 + 去空白
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    static func match(
        events: [AgentCalendarEvent],
        keyword: String
    ) -> Outcome {
        let key = normalized(keyword)
        guard !key.isEmpty else { return .notFound }
        let matches = events
            .filter { event in
                let title = normalized(event.title)
                return !title.isEmpty && (title.contains(key) || key.contains(title))
            }
            .sorted { $0.start < $1.start }
        switch matches.count {
        case 0:
            return .notFound
        case 1:
            return .delete(matches[0])
        default:
            return .ambiguous(events: matches)
        }
    }
}

// MARK: - Formatting

/// 日历应答文案（纯逻辑可测）
enum AgentCalendarFormatter {
    /// 时间范围标签：「明天 15:00-16:00」（跨天时两端都带日期）
    static func timeRangeLabel(
        start: Date,
        end: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let dayStart = dayLabel(start, now: now, calendar: calendar)
        let clockStart = clockFormatter.string(from: start)
        let clockEnd = clockFormatter.string(from: end)
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(dayStart) \(clockStart)-\(clockEnd)"
        }
        let dayEnd = dayLabel(end, now: now, calendar: calendar)
        return "\(dayStart) \(clockStart)-\(dayEnd) \(clockEnd)"
    }

    /// 单条日程行：「明天 15:00-16:00 产品评审」；全天：「全天 产品评审」
    static func eventLine(
        _ event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if event.isAllDay {
            return "\(allDayLabel) \(event.title)"
        }
        let when = timeRangeLabel(start: event.start, end: event.end, now: now, calendar: calendar)
        return "\(when) \(event.title)"
    }

    /// 查询汇总（按开始时间排序）；空返回 nil
    static func querySummary(
        events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let sorted = events.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return nil }
        return sorted.map { eventLine($0, now: now, calendar: calendar) }.joined(separator: "，")
    }

    /// 创建确认：「已加入日历：明天 15:00-16:00 产品评审」
    static func createdConfirmation(
        for event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let when = event.isAllDay
            ? allDayLabel
            : timeRangeLabel(start: event.start, end: event.end, now: now, calendar: calendar)
        return String(format: "agent.calendar.created".localized, when, event.title)
    }

    /// 查询空态 / 标题用的日期范围名
    static func rangeTitle(
        start: Date,
        end: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        if start == startOfToday, end == tomorrow {
            return "agent.calendar.range.today".localized
        }
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? tomorrow
        if start == tomorrow, end == dayAfter {
            return "agent.calendar.range.tomorrow".localized
        }
        let plusThree = calendar.date(byAdding: .day, value: 3, to: startOfToday) ?? dayAfter
        if start == dayAfter, end == plusThree {
            return "agent.calendar.range.after".localized
        }
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        if let weekInterval, start >= weekInterval.start, end <= weekInterval.end {
            return "agent.calendar.range.week".localized
        }
        if let weekInterval,
           let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: 1, to: weekInterval.start),
           start >= nextWeekStart, end <= calendar.dateInterval(of: .weekOfYear, for: nextWeekStart)?.end ?? end {
            return "agent.calendar.range.nextweek".localized
        }
        if end.timeIntervalSince(start) >= 6 * 86400 {
            return "agent.calendar.range.recent".localized
        }
        return dateFormatter.string(from: start)
    }

    /// 日期标签：今天 / 明天 / 后天 / 本周星期名 / 具体日期
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0
        switch offset {
        case 0:
            return "agent.calendar.day.today".localized
        case 1:
            return "agent.calendar.day.tomorrow".localized
        case 2:
            return "agent.calendar.day.after".localized
        default:
            if calendar.isDate(startOfDate, equalTo: startOfToday, toGranularity: .weekOfYear) {
                return weekdayLabel(date, calendar: calendar)
            }
            return dateFormatter.string(from: date)
        }
    }

    private static func weekdayLabel(_ date: Date, calendar: Calendar) -> String {
        let weekday = calendar.component(.weekday, from: date)
        let symbols = weekdayFormatter.weekdaySymbols ?? []
        return (1...7).contains(weekday) ? symbols[weekday - 1] : ""
    }

    private static var allDayLabel: String {
        "agent.calendar.allday".localized
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static var appLocale: Locale {
        LanguageManager.staticIsChinese
            ? Locale(identifier: "zh-Hans")
            : Locale(identifier: "en")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        return formatter
    }()
}

// MARK: - 日程倒计时 Live Activity

/// 日程倒计时同步入口：拉取近期日程 → 最近一个非全天日程 → 更新 Live Activity。
/// 幂等：无符合条件的日程时结束日程倒计时（回落提醒 / 任务进度或结束）。
/// events / provider 可注入（测试用），nil 时经真实 provider 拉取未来窗口内日程。
@MainActor
enum AgentCalendarCountdownCoordinator {
    private static var observer: NSObjectProtocol?

    /// 最近一次拉取到的日程列表（供小组件快照复用；未授权 / 未拉取为空）
    static private(set) var lastFetchedEvents: [AgentCalendarEvent] = []

    /// 注册 EventKit 变更监听（App 内新增 / 删除 / 修改日程即时重算；幂等）
    static func startObserving() {
        guard observer == nil else {
            Task { await sync() }
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await AgentCalendarCountdownCoordinator.sync()
            }
        }
        Task { await sync() }
    }

    /// 重算最近一个即将开始的日程并同步到 Live Activity
    static func sync(
        events: [AgentCalendarEvent]? = nil,
        now: Date = Date(),
        provider: AgentCalendarProviding? = nil
    ) async {
        let notifyLookahead = AgentCalendarNotificationSettings.enabled
            ? AgentCalendarEventNotifier.lookahead
            : 0
        let horizon = now.addingTimeInterval(
            max(AgentCalendarCountdownPolicy.defaultMaxAhead, notifyLookahead)
        )
        let fetched: [AgentCalendarEvent]
        if let events {
            fetched = events
        } else {
            fetched = await (provider ?? AgentCalendar.provider).fetchEvents(
                from: now,
                to: horizon
            )
        }
        lastFetchedEvents = fetched
        if !AgentLiveActivityManager.isRunningTests {
            AgentCalendarNotificationScheduler.sync(events: fetched, now: now)
        }
        guard let next = AgentCalendarCountdownPolicy.nextEvent(in: fetched, now: now) else {
            AgentLiveActivityManager.updateCalendarCountdown(event: nil)
            Self.refreshWidgetIfNeeded()
            return
        }
        AgentLiveActivityManager.updateCalendarCountdown(event: next)
        Self.refreshWidgetIfNeeded()
    }

    /// 小组件快照跟随日程变化刷新（XCTest 环境跳过，避免 App Group / WidgetKit 副作用）
    private static func refreshWidgetIfNeeded() {
        guard !AgentLiveActivityManager.isRunningTests else { return }
        AgentWidgetSnapshotCenter.refresh()
    }
}
// MARK: - 眼镜端展示映射

/// 眼镜端日历日程展示映射（纯逻辑，可测）：
/// 镜片主菜单「Calendar」动态出现（今天有未结束日程时），
/// 子菜单按钮为「时间 标题」短标签，选中后复用语音查询文案播报。
enum AgentCalendarDisplayMapping {
    /// 今天且尚未结束的日程（镜片主菜单「Calendar」动态出现的依据）
    static func hasUpcomingEvents(
        _ events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        !upcoming(events, now: now, calendar: calendar).isEmpty
    }

    /// 今天尚未结束的日程（按开始时间升序，最多 limit 条；全天日程全天有效）
    static func upcoming(
        _ events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 5
    ) -> [AgentCalendarEvent] {
        events
            .filter { event in
                guard calendar.isDate(event.start, inSameDayAs: now) else { return false }
                return event.isAllDay || event.end > now
            }
            .sorted { $0.start < $1.start }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 静默拉取今天未结束的日程（不请求权限；未授权返回空，供菜单动态显隐使用）
    static func upcomingEventsForMenu(
        provider: AgentCalendarProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> [AgentCalendarEvent] {
        guard provider.authorization == .authorized else { return [] }
        let range = AgentCalendarDayRange.todayRange(now: now, calendar: calendar)
        let events = await provider.fetchEvents(from: range.start, to: range.end)
        return upcoming(events, now: now, calendar: calendar)
    }

    /// 明天尚未开始的日程（按开始时间升序，最多 limit 条；全天日程全天有效）
    static func upcomingTomorrow(
        _ events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 5
    ) -> [AgentCalendarEvent] {
        let range = AgentCalendarDayRange.tomorrowRange(now: now, calendar: calendar)
        return events
            .filter { calendar.isDate($0.start, inSameDayAs: range.start) }
            .sorted { $0.start < $1.start }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 静默拉取明天尚未开始的日程（不请求权限；未授权返回空，供菜单动态显隐使用）
    static func tomorrowEventsForMenu(
        provider: AgentCalendarProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> [AgentCalendarEvent] {
        guard provider.authorization == .authorized else { return [] }
        let range = AgentCalendarDayRange.tomorrowRange(now: now, calendar: calendar)
        let events = await provider.fetchEvents(from: range.start, to: range.end)
        return upcomingTomorrow(events, now: now, calendar: calendar)
    }

    /// 拉取今天未结束的日程（必要时请求权限）；未授权返回 nil
    static func todayEvents(
        provider: AgentCalendarProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> [AgentCalendarEvent]? {
        var authorization = provider.authorization
        if authorization == .notDetermined {
            authorization = await provider.requestAuthorization()
        }
        guard authorization == .authorized else { return nil }
        let range = AgentCalendarDayRange.todayRange(now: now, calendar: calendar)
        let events = await provider.fetchEvents(from: range.start, to: range.end)
        return upcoming(events, now: now, calendar: calendar)
    }

    /// 镜片按钮短标签：「15:00 评审」/「all day 评审」；标题截断（超长加省略号），空标题回退 Event
    static func menuLabel(for event: AgentCalendarEvent, maxLength: Int = 8) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle: String
        if title.isEmpty {
            shortTitle = "Event"
        } else if title.count > maxLength {
            shortTitle = String(title.prefix(maxLength)) + "…"
        } else {
            shortTitle = title
        }
        let when = event.isAllDay ? "agent.calendar.allday".localized : clockLabel(event.start)
        return "\(when) \(shortTitle)"
    }

    /// 镜片结果卡 / TTS 播报文本：复用语音查询的单条日程行（「今天 15:00-16:00 产品评审」）
    static func resultText(
        for event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        AgentCalendarFormatter.eventLine(event, now: now, calendar: calendar)
    }

    private static func clockLabel(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 设置页日历分区

/// 设置页「日历」分区的动作决策
enum AgentCalendarSettingsAction: Equatable {
    /// 尚未请求 → 就地请求授权
    case request
    /// 已拒绝 / 受限 → 跳转系统设置
    case openSettings
    /// 已授权 → 无需动作
    case none
}

/// 设置页「日历」分区文案与动作（纯逻辑，可测）：
/// 授权状态明确反馈（已授权 / 未授权 / 受限 / 尚未请求），
/// 并按状态给出唯一合理动作（请求授权 / 前往系统设置 / 无）。
enum AgentCalendarSettings {
    static func statusText(for authorization: AgentCalendarAuthorization) -> String {
        switch authorization {
        case .authorized:
            return "agent.settings.calendar.status.authorized".localized
        case .denied:
            return "agent.settings.calendar.status.denied".localized
        case .restricted:
            return "agent.settings.calendar.status.restricted".localized
        case .notDetermined:
            return "agent.settings.calendar.status.notDetermined".localized
        }
    }

    static func action(for authorization: AgentCalendarAuthorization) -> AgentCalendarSettingsAction {
        switch authorization {
        case .authorized:
            return .none
        case .denied, .restricted:
            return .openSettings
        case .notDetermined:
            return .request
        }
    }
}

// MARK: - 设置页「近期日程」列表

/// 设置页日历分区的「近期日程」展示映射（纯逻辑，可测）：
/// 未来 7 天窗口内按天分组（今天 / 明天 / 之后），组内按开始时间升序，
/// 行格式「15:00 标题」（全天「全天 标题」），数量截断避免淹没设置页。
enum AgentCalendarOverviewMapping {
    /// 列表窗口：未来 7 天（与日程提醒通知预排窗口一致）
    static let lookahead: TimeInterval = 7 * 86400
    /// 单组最多行数
    static let maxPerGroup = 5
    /// 总行数上限
    static let maxRows = 10

    /// 分组（声明顺序即展示顺序）
    enum Group: Int, CaseIterable, Equatable {
        case today
        case tomorrow
        case later

        var titleKey: String {
            switch self {
            case .today: return "agent.settings.calendar.events.today"
            case .tomorrow: return "agent.settings.calendar.events.tomorrow"
            case .later: return "agent.settings.calendar.events.later"
            }
        }
    }

    /// 单行：时间文本 + 标题
    struct Row: Equatable {
        let timeText: String
        let title: String
    }

    /// 分组结果（持有事件本体，视图点按可拿到完整事件）
    struct GroupedEvents: Equatable {
        let group: Group
        let events: [AgentCalendarEvent]
    }

    /// 分组归属：今天 / 明天 / 之后；今天之前的日程（跨天已开始）不进入列表
    static func group(
        for event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Group? {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfEvent = calendar.startOfDay(for: event.start)
        guard startOfEvent >= startOfToday else { return nil }
        let offset = calendar.dateComponents([.day], from: startOfToday, to: startOfEvent).day ?? 0
        switch offset {
        case 0: return .today
        case 1: return .tomorrow
        default: return .later
        }
    }

    /// 行文案：非全天「15:00」+ 清理后的标题；全天「全天」+ 标题
    static func row(for event: AgentCalendarEvent) -> Row {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = event.isAllDay
            ? "agent.calendar.allday".localized
            : clockFormatter.string(from: event.start)
        return Row(timeText: time, title: title)
    }

    /// 分组列表：窗口过滤 → 按组顺序 → 组内时间升序 → 行数截断
    static func groupedEvents(
        _ events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        lookahead: TimeInterval = lookahead,
        maxPerGroup: Int = maxPerGroup,
        maxRows: Int = maxRows
    ) -> [GroupedEvents] {
        let deadline = now.addingTimeInterval(lookahead)
        var result: [GroupedEvents] = []
        var total = 0
        for group in Group.allCases {
            let limit = max(0, min(maxPerGroup, maxRows - total))
            let rows = events
                .filter { self.group(for: $0, now: now, calendar: calendar) == group }
                .filter { $0.start <= deadline }
                .sorted { $0.start < $1.start }
                .prefix(limit)
                .map { $0 }
            total += rows.count
            if !rows.isEmpty {
                result.append(GroupedEvents(group: group, events: rows))
            }
            if total >= maxRows { break }
        }
        return result
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 日程详情卡

/// 日程详情卡（近期日程行点按弹出）的展示映射（纯逻辑，可测）：
/// 标题清理、时间范围（复用语音查询文案）、日历来源与当前状态（即将开始 / 进行中 / 已结束）。
enum AgentCalendarDetailMapping {
    /// 状态：未开始（距开始秒数）/ 进行中（距结束秒数）/ 已结束；全天日程无状态
    enum Status: Equatable {
        case upcoming(TimeInterval)
        case inProgress(TimeInterval)
        case ended
    }

    struct Detail: Equatable {
        let title: String
        let timeText: String
        let calendarName: String?
        let status: Status?
    }

    static func detail(
        for event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Detail {
        Detail(
            title: event.title.trimmingCharacters(in: .whitespacesAndNewlines),
            timeText: event.isAllDay
                ? "agent.calendar.allday".localized
                : AgentCalendarFormatter.timeRangeLabel(
                    start: event.start,
                    end: event.end,
                    now: now,
                    calendar: calendar
                ),
            calendarName: event.calendarName,
            status: event.isAllDay ? nil : status(for: event, now: now)
        )
    }

    /// 状态判定：开始前 → upcoming；进行中 → inProgress；否则 ended
    static func status(
        for event: AgentCalendarEvent,
        now: Date = Date()
    ) -> Status {
        if event.start > now {
            return .upcoming(event.start.timeIntervalSince(now))
        }
        if event.end > now {
            return .inProgress(event.end.timeIntervalSince(now))
        }
        return .ended
    }

    /// 状态文案：分档相对时间（马上 / X 分钟 / X 小时）
    static func statusText(for status: Status) -> String {
        switch status {
        case .upcoming(let interval):
            if interval < 60 { return "agent.calendar.detail.imminent".localized }
            if interval < 3600 {
                return String(format: "agent.calendar.detail.starts.minutes".localized, Int(interval / 60))
            }
            return String(format: "agent.calendar.detail.starts.hours".localized, Int(interval / 3600))
        case .inProgress(let interval):
            if interval < 60 { return "agent.calendar.detail.ending.imminent".localized }
            if interval < 3600 {
                return String(format: "agent.calendar.detail.ending.minutes".localized, Int(interval / 60))
            }
            return String(format: "agent.calendar.detail.ending.hours".localized, Int(interval / 3600))
        case .ended:
            return "agent.calendar.detail.ended".localized
        }
    }

    /// 状态图标（SF Symbol）：进行中 hourglass / 即将开始 clock / 已结束 checkmark.circle
    static func statusSymbol(for status: Status) -> String {
        switch status {
        case .upcoming: return "clock"
        case .inProgress: return "hourglass"
        case .ended: return "checkmark.circle"
        }
    }
}

// MARK: - 详情卡「删除此日程」

/// 日程详情卡删除动作：确认文案与执行（纯逻辑，可测）。
/// 执行成功广播主页双卡刷新信号，失败返回 false 由 UI 明确反馈。
enum AgentCalendarDetailDeleteAction {
    static func buttonTitle() -> String {
        "agent.calendar.detail.delete.button".localized
    }

    static func confirmTitle() -> String {
        "agent.calendar.detail.delete.confirm.title".localized
    }

    static func confirmMessage(for event: AgentCalendarEvent) -> String {
        String(format: "agent.calendar.detail.delete.confirm.message".localized, event.title)
    }

    static func confirmActionTitle() -> String {
        "agent.calendar.detail.delete.confirm.action".localized
    }

    static func cancelTitle() -> String {
        "agent.calendar.detail.delete.cancel".localized
    }

    static func errorTitle() -> String {
        "agent.calendar.detail.delete.error.title".localized
    }

    static func failureMessage() -> String {
        "agent.calendar.delete.failed".localized
    }

    /// 删除成功播报文案：「已删除：今天 15:00-16:00 产品评审。」
    static func deletedText(
        for event: AgentCalendarEvent,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        String(
            format: "agent.calendar.deleted".localized,
            AgentCalendarFormatter.eventLine(event, now: now, calendar: calendar)
        )
    }

    /// 执行 EventKit 删除；成功广播双卡刷新信号
    static func performDelete(
        event: AgentCalendarEvent,
        provider: AgentCalendarProviding
    ) async -> Bool {
        do {
            try await provider.deleteEvent(
                title: event.title,
                start: event.start,
                end: event.end,
                isAllDay: event.isAllDay
            )
            AgentHomeCardRefreshCenter.post()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 删除歧义追问（语音 / 文字选择闭环）

/// 删除歧义待选存储：最近一次 `.ambiguous` 的候选日程（App 内共享，任一入口可消费）
enum AgentCalendarDeletePendingStore {
    static private(set) var candidates: [AgentCalendarEvent] = []

    static func store(_ events: [AgentCalendarEvent]) {
        candidates = events
    }

    static func clear() {
        candidates = []
    }
}

/// 追问提示文案（纯逻辑，可测）：编号列出候选 + 引导回复序号或更具体名称
enum AgentCalendarDeletePromptBuilder {
    static func prompt(
        for candidates: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let title = String(
            format: "agent.calendar.delete.choose.title".localized,
            candidates.count
        )
        let lines = candidates.enumerated().map { index, event in
            "\(index + 1). " + AgentCalendarFormatter.eventLine(
                event,
                now: now,
                calendar: calendar
            )
        }
        return ([title] + lines + ["agent.calendar.delete.choose.hint".localized])
            .joined(separator: "\n")
    }

    /// 序号越界应答：明确提示有效范围（待选保持不变，可继续回复）
    static func invalidReply(
        number: Int,
        count: Int
    ) -> String {
        String(format: "agent.calendar.delete.choose.invalid".localized, number, count)
    }
}

/// 追问回复解析（纯逻辑，可测）：
/// 取消词精确匹配；序号支持阿拉伯 / 中文数字与「第 X 个 / X 号 / X 个」形式（返回 0 起下标）
enum AgentCalendarDeleteSelectionParser {
    static let cancelTokens = ["取消", "算了", "不用了", "不删了", "别删"]

    static func isCancel(_ text: String) -> Bool {
        cancelTokens.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func numberIndex(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = digitValue(trimmed) {
            return value
        }
        // 第 X 个 / 第 X 号
        if trimmed.hasPrefix("第"),
           trimmed.hasSuffix("个") || trimmed.hasSuffix("号") {
            let body = String(trimmed.dropFirst().dropLast())
            if let value = digitValue(body) {
                return value
            }
        }
        // X 个 / X 号
        if trimmed.hasSuffix("个") || trimmed.hasSuffix("号") {
            let body = String(trimmed.dropLast())
            if let value = digitValue(body) {
                return value
            }
        }
        return nil
    }

    /// 同步预判：该消息是否可能是对追问的选择（取消 / 序号 / 名称包含任一候选）。
    /// 视图在进入异步解析前用它快速过滤无关消息，避免打断正常对话。
    static func isPotentialSelection(
        _ text: String,
        candidates: [AgentCalendarEvent]
    ) -> Bool {
        if isCancel(text) || numberIndex(text) != nil { return true }
        let key = AgentCalendarDeleteMatcher.normalized(text)
        guard !key.isEmpty else { return false }
        return candidates.contains { event in
            let title = AgentCalendarDeleteMatcher.normalized(event.title)
            return !title.isEmpty && (title.contains(key) || key.contains(title))
        }
    }

    /// 1 起数字 → 0 起下标：支持阿拉伯数字与中文数字（一~十）
    private static func digitValue(_ text: String) -> Int? {
        if let arabic = Int(text), arabic >= 1 {
            return arabic - 1
        }
        let chineseDigits: [String: Int] = [
            "一": 0, "二": 1, "三": 2, "四": 3, "五": 4,
            "六": 5, "七": 6, "八": 7, "九": 8, "十": 9,
        ]
        return chineseDigits[text]
    }
}

/// 删除歧义追问协调器：消费用户对追问提示的回复，返回应答文案；无关消息返回 nil（保留待选）。
enum AgentCalendarDeleteSelectionCoordinator {
    static func resolve(
        text: String,
        provider: AgentCalendarProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> String? {
        let candidates = AgentCalendarDeletePendingStore.candidates
        guard !candidates.isEmpty else { return nil }

        // 明确取消
        if AgentCalendarDeleteSelectionParser.isCancel(text) {
            AgentCalendarDeletePendingStore.clear()
            return "agent.calendar.delete.choose.cancelled".localized
        }

        // 序号选择
        if let index = AgentCalendarDeleteSelectionParser.numberIndex(text) {
            guard candidates.indices.contains(index) else {
                return AgentCalendarDeletePromptBuilder.invalidReply(
                    number: index + 1,
                    count: candidates.count
                )
            }
            AgentCalendarDeletePendingStore.clear()
            return await performDelete(
                candidates[index],
                provider: provider,
                now: now,
                calendar: calendar
            )
        }

        // 更具体的名称：与删除匹配同规则（归一化双向包含）
        let key = AgentCalendarDeleteMatcher.normalized(text)
        guard !key.isEmpty else { return nil }
        let indices = candidates.indices.filter { index in
            let title = AgentCalendarDeleteMatcher.normalized(candidates[index].title)
            return !title.isEmpty && (title.contains(key) || key.contains(title))
        }
        if indices.count == 1 {
            AgentCalendarDeletePendingStore.clear()
            return await performDelete(
                candidates[indices[0]],
                provider: provider,
                now: now,
                calendar: calendar
            )
        }
        if indices.count > 1 {
            // 仍然歧义：收窄候选后再次追问
            let subset = indices.map { candidates[$0] }
            AgentCalendarDeletePendingStore.store(subset)
            return AgentCalendarDeletePromptBuilder.prompt(
                for: subset,
                now: now,
                calendar: calendar
            )
        }
        return nil
    }

    /// 镜片按钮直接选择：按（标题 + 开始时间）在当前待选中定位并删除；
    /// 待选已被语音 / 其它入口消费时返回 nil（选择失效，静默忽略）。
    static func select(
        matching target: AgentCalendarEvent,
        provider: AgentCalendarProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> String? {
        let candidates = AgentCalendarDeletePendingStore.candidates
        guard let event = candidates.first(where: {
            $0.title == target.title && $0.start == target.start
        }) else {
            return nil
        }
        AgentCalendarDeletePendingStore.clear()
        return await performDelete(event, provider: provider, now: now, calendar: calendar)
    }

    /// 镜片按钮取消：放弃删除追问
    static func cancel() -> String {
        AgentCalendarDeletePendingStore.clear()
        return "agent.calendar.delete.choose.cancelled".localized
    }

    private static func performDelete(
        _ event: AgentCalendarEvent,
        provider: AgentCalendarProviding,
        now: Date,
        calendar: Calendar
    ) async -> String {
        do {
            try await provider.deleteEvent(
                title: event.title,
                start: event.start,
                end: event.end,
                isAllDay: event.isAllDay
            )
            AgentHomeCardRefreshCenter.post()
            return String(
                format: "agent.calendar.deleted".localized,
                AgentCalendarFormatter.eventLine(event, now: now, calendar: calendar)
            )
        } catch {
            return "agent.calendar.delete.failed".localized
        }
    }
}

// MARK: - 主页「今日日程」卡片

/// 主页今日日程卡的展示映射（纯逻辑，可测）：
/// 已授权且今天有未结束日程 → 最近一条的完整行（「今天 15:00-16:00 产品评审」）；
/// 已授权但无 → 空态；未授权 → 引导文案（静默拉取，不请求权限）。
enum AgentHomeCalendarCardMapping {
    struct Content: Equatable {
        /// 主行文本
        let line: String
        /// 是否为占位（空态 / 未授权，弱化显示）
        let isPlaceholder: Bool
        /// 今天未结束日程数量（主页徽标用；未授权 / 空为 0）
        let count: Int
    }

    static func content(
        events: [AgentCalendarEvent],
        authorized: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Content {
        guard authorized else {
            return Content(
                line: "home.calendar.unauthorized".localized,
                isPlaceholder: true,
                count: 0
            )
        }
        let upcoming = AgentCalendarDisplayMapping.upcoming(
            events,
            now: now,
            calendar: calendar,
            limit: Int.max
        )
        guard let next = upcoming.first else {
            return Content(
                line: "home.calendar.empty".localized,
                isPlaceholder: true,
                count: 0
            )
        }
        return Content(
            line: AgentCalendarFormatter.eventLine(next, now: now, calendar: calendar),
            isPlaceholder: false,
            count: upcoming.count
        )
    }
}

// MARK: - 日程 → 提醒桥接

/// 日程详情卡「设为提醒」的纯逻辑（可测）：
/// 提前量选项、同源去重（标题 + 开始时间）、提醒构建（触发时间 = 开始 - 提前量）。
enum AgentCalendarReminderBridge {
    /// 可选提前量（分钟）
    static let leadOptions = [5, 10, 15, 30]
    static let defaultLeadMinutes = 10

    /// 同源判定：标题相同且开始时间相同（同一日程重复设提醒视为已设置）
    static func hasReminder(
        for event: AgentCalendarEvent,
        in reminders: [AgentReminder]
    ) -> Bool {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return reminders.contains {
            $0.text == title && $0.fireDate == event.start
        }
    }

    /// 构建提醒：内容为日程标题，触发时间 = 开始 - 提前量；
    /// 提前量非法或触发时间已过返回 nil
    static func reminder(
        for event: AgentCalendarEvent,
        leadMinutes: Int = defaultLeadMinutes,
        now: Date = Date()
    ) -> AgentReminder? {
        guard leadOptions.contains(leadMinutes) else { return nil }
        let fireDate = event.start.addingTimeInterval(-TimeInterval(leadMinutes * 60))
        guard fireDate > now else { return nil }
        return AgentReminder(
            text: event.title.trimmingCharacters(in: .whitespacesAndNewlines),
            fireDate: fireDate
        )
    }
}

// MARK: - 日程提醒通知

/// 日程提醒设置（本地存储；默认关闭，避免与系统日历提醒重复）
enum AgentCalendarNotificationSettings {
    static let enabledKey = "agent.calendar.notify.enabled"
    static let leadMinutesKey = "agent.calendar.notify.leadMinutes"
    /// 可选提前量（分钟）
    static let leadOptions = [5, 10, 15, 30]
    static let defaultLeadMinutes = 10

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var leadTimeMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: leadMinutesKey)
            return leadOptions.contains(value) ? value : defaultLeadMinutes
        }
        set { UserDefaults.standard.set(newValue, forKey: leadMinutesKey) }
    }
}

/// 一条待排期的日程提醒通知（纯值，可测）
struct AgentCalendarEventNotificationSpec: Equatable {
    /// 稳定去重 ID（同日程跨刷新可识别）
    let id: String
    /// 通知正文（「今天 15:00-16:00 评审」，跟随 App 语言）
    let body: String
    /// 触发时间 = 日程开始 - 提前量
    let fireDate: Date
}

/// 日程提醒通知的选择策略（纯逻辑，可测）：
/// 未来 lookahead 内最近的非全天日程，触发时间晚于当前（已进入提前窗口的
/// 日程交给 Live Activity 倒计时，不再补通知），数量封顶避免占满系统配额。
enum AgentCalendarEventNotifier {
    /// 预排窗口：未来 7 天
    static let lookahead: TimeInterval = 7 * 86400
    /// 单次同步最多排期数（系统待触发通知上限 64）
    static let maxSpecs = 20

    static func specs(
        for events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        leadTime: TimeInterval,
        lookahead: TimeInterval = lookahead,
        maxCount: Int = maxSpecs
    ) -> [AgentCalendarEventNotificationSpec] {
        let deadline = now.addingTimeInterval(lookahead)
        return events
            .filter { !$0.isAllDay && $0.start > now && $0.start <= deadline }
            .sorted { $0.start < $1.start }
            .prefix(max(0, maxCount))
            .compactMap { event -> AgentCalendarEventNotificationSpec? in
                let fireDate = event.start.addingTimeInterval(-leadTime)
                guard fireDate > now else { return nil }
                return AgentCalendarEventNotificationSpec(
                    id: id(for: event),
                    body: AgentCalendarFormatter.eventLine(event, now: now, calendar: calendar),
                    fireDate: fireDate
                )
            }
    }

    /// 稳定 ID：开始时间戳 + 清理后的标题（跨启动可重复、可读）
    static func id(for event: AgentCalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = title.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return "\(Int(event.start.timeIntervalSince1970))-\(safeTitle)"
    }
}

/// 日程提醒通知的交互：身份标记 + 点按深链（锁屏 / 通知中心点按 → 设置页日历分区）。
/// 标识常量与深链决策为纯逻辑，便于测试；消费在 `AgentReminderNotificationDelegate`。
enum AgentCalendarNotificationAction {
    /// 通知分类标识（与提醒 / 任务 / 问答结果通知并列，按类别分流）
    static let categoryIdentifier = "agent.calendar.event.notify"
    /// 通知 userInfo 标记键：标记为本 App 的日程提醒通知
    static let userInfoKey = "agent.calendar"
    /// 事件 ID 键：点按后可用于定位（当前深链到设置页日历分区）
    static let eventIDKey = "agent.calendar.event.id"

    static func isCalendarEvent(_ userInfo: [AnyHashable: Any]?) -> Bool {
        userInfo?[userInfoKey] as? Bool == true
    }

    /// 通知 userInfo：身份标记 + 事件 ID
    static func userInfo(eventID: String) -> [String: Any] {
        [userInfoKey: true, eventIDKey: eventID]
    }

    static func eventID(from userInfo: [AnyHashable: Any]?) -> String? {
        userInfo?[eventIDKey] as? String
    }

    /// 点按深链决策：默认点按（通知本体）→ 设置页日历分区；其余 Action 无导航
    static func destination(for actionIdentifier: String) -> AppNavigationDestination? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        return .agentSettings(.calendar)
    }
}

/// 日程提醒通知调度（薄封装）：与已排期集合差量增删，关闭时清空。
/// XCTest 环境由调用方（coordinator）跳过；纯决策在 `AgentCalendarEventNotifier`。
enum AgentCalendarNotificationScheduler {
    static let storedKey = "agent.calendar.notify.scheduled"
    static let requestPrefix = "agent.calendar.event."

    static func sync(
        events: [AgentCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard AgentCalendarNotificationSettings.enabled else {
            cancelAll()
            return
        }
        let specs = AgentCalendarEventNotifier.specs(
            for: events,
            now: now,
            calendar: calendar,
            leadTime: TimeInterval(AgentCalendarNotificationSettings.leadTimeMinutes * 60)
        )
        let desired = Set(specs.map(\.id))
        var stored = Set(UserDefaults.standard.stringArray(forKey: storedKey) ?? [])
        let center = UNUserNotificationCenter.current()
        for id in stored.subtracting(desired) {
            center.removePendingNotificationRequests(withIdentifiers: [requestID(for: id)])
        }
        for spec in specs where !stored.contains(spec.id) {
            let content = UNMutableNotificationContent()
            content.title = "agent.calendar.notify.title".localized
            content.body = spec.body
            content.sound = .default
            content.categoryIdentifier = AgentCalendarNotificationAction.categoryIdentifier
            content.userInfo = AgentCalendarNotificationAction.userInfo(eventID: spec.id)
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: spec.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: requestID(for: spec.id),
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
        stored = desired
        UserDefaults.standard.set(Array(stored), forKey: storedKey)
    }

    static func cancelAll() {
        let stored = UserDefaults.standard.stringArray(forKey: storedKey) ?? []
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: stored.map { requestID(for: $0) }
        )
        UserDefaults.standard.removeObject(forKey: storedKey)
    }

    private static func requestID(for id: String) -> String {
        requestPrefix + id
    }
}
