/*
 * Local Tools App Intent
 * Siri / 快捷指令直达本地工具：长期记忆、个人规则、命名清单、本地提醒。
 * 全部为本地 UserDefaults + 本地通知，可后台执行（openAppWhenRun = false）。
 * 结果判定与应答文案为纯逻辑（LocalToolIntentOutcome / Formatter），
 * 副作用集中在 LocalToolIntentHandler，便于单元测试。
 */

import AppIntents
import Foundation

// MARK: - Tool Option

enum AgentLocalTool: String, AppEnum {
    case memory
    case rule
    case list
    case reminder
    case calendar

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "本地工具")

    static var caseDisplayRepresentations: [AgentLocalTool: DisplayRepresentation] {
        [
            .memory: "记忆",
            .rule: "规则",
            .list: "清单",
            .reminder: "提醒",
            .calendar: "日历"
        ]
    }
}

// MARK: - Outcome & Formatter

/// Siri 本地工具直达的处理结果（纯值，可测）
enum LocalToolIntentOutcome: Equatable {
    case memoryAdded(text: String)
    case memoryDuplicate(text: String)
    case memoryFull(text: String)
    case ruleAdded(text: String)
    case ruleDuplicate(text: String)
    case ruleFull(text: String)
    case listItemAdded(item: String, list: String)
    case listItemDuplicate(item: String, list: String)
    case listItemFull(item: String, list: String)
    case reminderSet(text: String, fireDate: Date, repeatRule: AgentReminderRepeat)
    case reminderCancelled(count: Int)
    case reminderCompleted(count: Int, target: String?)
    case reminderQuery(text: String)
    case reminderUnparseable(text: String)
    case notificationsDenied
    case calendarReply(text: String)
    case calendarUnparseable(text: String)
    case invalid(text: String)
}

/// 结果 → Siri 应答文案（纯构造，可测；优先复用语音会话既有话术）
enum LocalToolIntentFormatter {
    static func dialog(for outcome: LocalToolIntentOutcome, now: Date = Date()) -> String {
        switch outcome {
        case .memoryAdded(let text):
            return String(format: "agent.memory.remembered".localized, text)
        case .memoryDuplicate:
            return "agent.memory.remember.dup".localized
        case .memoryFull:
            return "tools.intent.memory.full".localized
        case .ruleAdded(let text):
            return String(format: "agent.rules.added".localized, text)
        case .ruleDuplicate:
            return "tools.intent.rule.dup".localized
        case .ruleFull:
            return "agent.rules.full".localized
        case .listItemAdded(let item, let list):
            return AgentListResponseText.added(item: item, to: list)
        case .listItemDuplicate(let item, let list):
            return AgentListResponseText.duplicate(item: item, in: list)
        case .listItemFull(_, let list):
            return AgentListResponseText.full(list: list)
        case .reminderSet(let text, let fireDate, let repeatRule):
            let reminder = AgentReminder(text: text, fireDate: fireDate, repeatRule: repeatRule)
            let when = AgentReminderTimeFormatter.announcementDescription(for: reminder, now: now)
            return String(format: "agent.reminder.set".localized, when, text)
        case .reminderCancelled(let count):
            return String(format: "agent.reminder.cancelled".localized, count)
        case .reminderCompleted(let count, let target):
            if count == 1, let target, !target.isEmpty {
                return AgentReminderCompletion.completedText(for: target)
            }
            if count > 0 {
                return AgentReminderCompletion.completedAllText(count: count)
            }
            if let target, !target.isEmpty {
                return AgentReminderCompletion.noneText(for: target)
            }
            return AgentReminderCompletion.noneAnyText()
        case .reminderQuery(let text):
            return text
        case .reminderUnparseable:
            return "tools.intent.reminder.unparseable".localized
        case .notificationsDenied:
            return "agent.reminder.denied".localized
        case .calendarReply(let text):
            return text
        case .calendarUnparseable:
            return "tools.intent.calendar.unparseable".localized
        case .invalid:
            return "tools.intent.invalid".localized
        }
    }
}

// MARK: - Handler

/// 本地工具副作用执行器（@MainActor：提醒调度与授权走主线程）
@MainActor
enum LocalToolIntentHandler {
    /// 可注入的通知授权提供器（默认走系统授权；测试注入固定结果）
    static var authorizationProvider: () async -> Bool = {
        await AgentReminderScheduler.requestAuthorization()
    }

    static func handle(
        tool: AgentLocalTool,
        text: String,
        listName: String? = nil,
        minutes: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> LocalToolIntentOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case .memory:
            guard !trimmed.isEmpty else { return .invalid(text: text) }
            if AgentMemoryStore.add(text: trimmed) { return .memoryAdded(text: trimmed) }
            if AgentMemoryStore.entries.count >= AgentMemoryStore.maxCount {
                return .memoryFull(text: trimmed)
            }
            return .memoryDuplicate(text: trimmed)
        case .rule:
            guard !trimmed.isEmpty else { return .invalid(text: text) }
            if AgentRuleStore.add(text: trimmed) { return .ruleAdded(text: trimmed) }
            if AgentRuleStore.entries.contains(where: { $0.text == trimmed }) {
                return .ruleDuplicate(text: trimmed)
            }
            return .ruleFull(text: trimmed)
        case .list:
            let list = (listName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            let listName = list.isEmpty ? "tools.intent.list.default".localized : list
            guard !trimmed.isEmpty else { return .invalid(text: text) }
            if let updated = AgentListStore.addItem(trimmed, to: listName) {
                return .listItemAdded(item: trimmed, list: updated.name)
            }
            if let existing = AgentListStore.list(named: listName), existing.items.contains(trimmed) {
                return .listItemDuplicate(item: trimmed, list: existing.name)
            }
            return .listItemFull(item: trimmed, list: listName)
        case .reminder:
            if let minutes, minutes > 0 {
                guard await authorizationProvider() else { return .notificationsDenied }
                let fireDate = now.addingTimeInterval(TimeInterval(minutes * 60))
                guard let reminder = AgentReminderStore.add(text: trimmed, fireDate: fireDate) else {
                    return .invalid(text: trimmed)
                }
                AgentReminderScheduler.schedule(reminder)
                return .reminderSet(text: reminder.text, fireDate: reminder.fireDate, repeatRule: reminder.repeatRule)
            }
            guard let command = AgentReminderCommandParser.parse(trimmed, now: now, calendar: calendar) else {
                return .reminderUnparseable(text: trimmed)
            }
            switch command {
            case .set(let content, let fireDate, let rule):
                guard await authorizationProvider() else { return .notificationsDenied }
                guard let reminder = AgentReminderStore.add(text: content, fireDate: fireDate, repeatRule: rule) else {
                    return .invalid(text: content)
                }
                AgentReminderScheduler.schedule(reminder)
                return .reminderSet(text: reminder.text, fireDate: reminder.fireDate, repeatRule: reminder.repeatRule)
            case .cancel(let target):
                let matched = AgentReminderStore.reminders.filter {
                    target == nil || $0.text.contains(target ?? "")
                }
                for reminder in matched {
                    AgentReminderStore.remove(id: reminder.id)
                    AgentReminderScheduler.cancel(id: reminder.id)
                }
                return .reminderCancelled(count: matched.count)
            case .complete(let target):
                let matched = AgentReminderStore.reminders.filter {
                    target == nil || $0.text.contains(target ?? "")
                }
                for reminder in matched {
                    AgentReminderStore.remove(id: reminder.id)
                    AgentReminderScheduler.cancel(id: reminder.id)
                }
                return .reminderCompleted(
                    count: matched.count,
                    target: matched.first?.text ?? target
                )
            case .query:
                let upcoming = AgentReminderDisplayMapping.upcoming(AgentReminderStore.reminders, now: now, limit: 5)
                guard !upcoming.isEmpty else { return .reminderQuery(text: "agent.reminder.query.empty".localized) }
                let content = upcoming
                    .map { AgentReminderDisplayMapping.resultText(for: $0, now: now) }
                    .joined(separator: "；")
                return .reminderQuery(text: content)
            }
        case .calendar:
            // 日历删除歧义追问（序号 / 更具体名称 / 取消）：先于新指令解析消费待选
            if let reply = await AgentCalendarDeleteSelectionCoordinator.resolve(
                text: trimmed,
                provider: AgentCalendar.provider,
                now: now,
                calendar: calendar
            ) {
                return .calendarReply(text: reply)
            }
            guard let command = AgentCalendarCommandParser.parse(trimmed, now: now, calendar: calendar) else {
                return .calendarUnparseable(text: trimmed)
            }
            let reply = await AgentCalendarExecutor.execute(
                command,
                provider: AgentCalendar.provider,
                now: now,
                calendar: calendar
            )
            return .calendarReply(text: reply)
        }
    }
}

// MARK: - App Intent

struct LocalToolsAppIntent: AppIntent {
    static var title: LocalizedStringResource = "tools.intent.title"
    static var description = IntentDescription("直接调用本地工具：记忆 / 规则 / 清单 / 提醒 / 日历")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "工具")
    var tool: AgentLocalTool

    @Parameter(title: "内容")
    var text: String

    @Parameter(title: "清单名称")
    var listName: String?

    @Parameter(title: "分钟数")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await LocalToolIntentHandler.handle(
            tool: tool,
            text: text,
            listName: listName,
            minutes: minutes
        )
        return .result(dialog: IntentDialog(stringLiteral: LocalToolIntentFormatter.dialog(for: outcome)))
    }
}
