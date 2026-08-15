/*
 * System Schema Intents
 * 通过 App Schema 把 App 的语音助手与提醒能力接入 Apple Intelligence / Siri AI：
 *   - assistant.activate（iOS 26.2+）：激活语音会话（iPhone 侧键 / Siri 系统级入口）
 *   - reminders.createReminder / createList（iOS 27.0+）：以系统提醒语义创建提醒与清单
 * 与 qwen-audio-agent 无关的纯 App 侧能力；业务逻辑下沉到可注入、可测的 Schema 服务，
 * 意图类型只做系统协议适配与反馈文案。
 */

import AppIntents
import CoreLocation
import Foundation
import MapKit

// MARK: - Assistant 域：激活语音会话（iOS 26.2+）

@available(iOS 26.2, *)
@AppIntent(schema: .assistant.activate)
struct ActivateVoiceAssistantSceneIntent {
    static let title: LocalizedStringResource = "voice.schema.activate.title"
    static let description = IntentDescription("voice.schema.activate.description")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        VoiceAssistantRouter.shared.wakeExecutor()
        VoiceAssistantRouter.shared.requestVoiceSession()
        return .result(dialog: IntentDialog(stringLiteral: "voice.schema.activate.dialog".localized))
    }
}

// MARK: - Reminders 域枚举 / 实体（iOS 27.0+）

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum AgentReminderListType: String, AppEnum {
    case standard
    case smart

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder List Type")

    static var caseDisplayRepresentations: [AgentReminderListType: DisplayRepresentation] {
        [
            .standard: DisplayRepresentation(title: "Standard"),
            .smart: DisplayRepresentation(title: "Smart List")
        ]
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum AgentReminderLocationTriggerEvent: String, AppEnum {
    case arrive
    case depart

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Location Trigger Event")

    static var caseDisplayRepresentations: [AgentReminderLocationTriggerEvent: DisplayRepresentation] {
        [
            .arrive: DisplayRepresentation(title: "Arrive"),
            .depart: DisplayRepresentation(title: "Depart")
        ]
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct AgentReminderListEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder List")

    var id: UUID
    var name: String
    var type: AgentReminderListType

    /// AppEntity 宏把属性包装为 EntityProperty，等价性以实体身份 id 为准。
    static func == (lhs: AgentReminderListEntity, rhs: AgentReminderListEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "\(name)"))
    }

    static var defaultQuery = DefaultQuery()

    struct DefaultQuery: EntityStringQuery {
        static var persistentIdentifier: String { "AgentReminderListEntity.DefaultQuery" }

        func entities(for identifiers: [AgentReminderListEntity.ID]) async throws -> [AgentReminderListEntity] {
            AgentListStore.lists
                .filter { identifiers.contains($0.id) }
                .map(AgentReminderListEntity.init(list:))
        }

        func entities(matching string: String) async throws -> [AgentReminderListEntity] {
            AgentListStore.lists
                .filter { $0.name.localizedCaseInsensitiveContains(string) }
                .map(AgentReminderListEntity.init(list:))
        }

        func suggestedEntities() async throws -> [AgentReminderListEntity] {
            AgentListStore.lists.map(AgentReminderListEntity.init(list:))
        }
    }

    init(id: UUID = UUID(), name: String, type: AgentReminderListType = .standard) {
        self.id = id
        self.name = name
        self.type = type
    }

    init(list: AgentNamedList) {
        self.init(id: list.id, name: list.name, type: .standard)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct AgentReminderSectionEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder Section")

    var id: UUID
    var name: String
    var list: AgentReminderListEntity

    /// AppEntity 宏把属性包装为 EntityProperty，等价性以实体身份 id 为准。
    static func == (lhs: AgentReminderSectionEntity, rhs: AgentReminderSectionEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "\(name)"))
    }

    static var defaultQuery = DefaultQuery()

    struct DefaultQuery: EntityStringQuery {
        static var persistentIdentifier: String { "AgentReminderSectionEntity.DefaultQuery" }

        func entities(for identifiers: [AgentReminderSectionEntity.ID]) async throws -> [AgentReminderSectionEntity] {
            []
        }

        func entities(matching string: String) async throws -> [AgentReminderSectionEntity] {
            []
        }

        func suggestedEntities() async throws -> [AgentReminderSectionEntity] {
            []
        }
    }

    init(id: UUID = UUID(), name: String, list: AgentReminderListEntity) {
        self.id = id
        self.name = name
        self.list = list
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct AgentReminderLocationTriggerEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Location Trigger")

    var id: UUID
    var event: AgentReminderLocationTriggerEvent
    var location: CLPlacemark?
    var place: CLPlacemark

    /// AppEntity 宏把属性包装为 EntityProperty，等价性以实体身份 id 为准。
    static func == (lhs: AgentReminderLocationTriggerEntity, rhs: AgentReminderLocationTriggerEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "\(event)"))
    }

    static var defaultQuery = DefaultQuery()

    struct DefaultQuery: EntityStringQuery {
        static var persistentIdentifier: String { "AgentReminderLocationTriggerEntity.DefaultQuery" }

        func entities(for identifiers: [AgentReminderLocationTriggerEntity.ID]) async throws -> [AgentReminderLocationTriggerEntity] {
            []
        }

        func entities(matching string: String) async throws -> [AgentReminderLocationTriggerEntity] {
            []
        }

        func suggestedEntities() async throws -> [AgentReminderLocationTriggerEntity] {
            []
        }
    }

    init(
        id: UUID = UUID(),
        event: AgentReminderLocationTriggerEvent,
        location: CLPlacemark? = nil,
        place: CLPlacemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
    ) {
        self.id = id
        self.event = event
        self.location = location
        self.place = place
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct AgentReminderEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reminder")

    var id: UUID
    var title: String
    var note: String?
    var isCompleted: Bool
    var isFlagged: Bool?
    var completionDate: Date?
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var creationDate: Date?
    var list: AgentReminderListEntity
    var locationTrigger: AgentReminderLocationTriggerEntity?
    var tags: Set<String>
    var urls: [URL]

    /// AppEntity 宏把属性包装为 EntityProperty，等价性以实体身份 id 为准。
    static func == (lhs: AgentReminderEntity, rhs: AgentReminderEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "\(title)"))
    }

    static var defaultQuery = DefaultQuery()

    struct DefaultQuery: EntityStringQuery {
        static var persistentIdentifier: String { "AgentReminderEntity.DefaultQuery" }

        func entities(for identifiers: [AgentReminderEntity.ID]) async throws -> [AgentReminderEntity] {
            AgentReminderStore.reminders
                .filter { identifiers.contains($0.id) }
                .map { AgentReminderEntity(reminder: $0) }
        }

        func entities(matching string: String) async throws -> [AgentReminderEntity] {
            AgentReminderStore.reminders
                .filter { $0.text.localizedCaseInsensitiveContains(string) }
                .map { AgentReminderEntity(reminder: $0) }
        }

        func suggestedEntities() async throws -> [AgentReminderEntity] {
            AgentReminderStore.reminders.map { AgentReminderEntity(reminder: $0) }
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        note: String? = nil,
        isCompleted: Bool = false,
        isFlagged: Bool? = nil,
        completionDate: Date? = nil,
        dueDate: DateComponents? = nil,
        recurrence: Calendar.RecurrenceRule? = nil,
        creationDate: Date? = Date(),
        list: AgentReminderListEntity = AgentReminderListEntity.defaultList,
        locationTrigger: AgentReminderLocationTriggerEntity? = nil,
        tags: Set<String> = [],
        urls: [URL] = []
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.isCompleted = isCompleted
        self.isFlagged = isFlagged
        self.completionDate = completionDate
        self.dueDate = dueDate
        self.recurrence = recurrence
        self.creationDate = creationDate
        self.list = list
        self.locationTrigger = locationTrigger
        self.tags = tags
        self.urls = urls
    }

    init(reminder: AgentReminder, list: AgentReminderListEntity? = nil) {
        self.init(
            id: reminder.id,
            title: reminder.text,
            dueDate: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate),
            creationDate: reminder.createdAt,
            list: list ?? AgentReminderListEntity.defaultList
        )
    }

    init(created: ReminderSchemaCreated, list: AgentReminderListEntity? = nil) {
        self.init(
            id: created.reminder.id,
            title: created.title,
            note: created.note,
            dueDate: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: created.reminder.fireDate),
            creationDate: created.reminder.createdAt,
            list: list ?? AgentReminderListEntity.defaultList,
            tags: created.tags,
            urls: created.urls
        )
    }
}

@available(iOS 27.0, *)
extension AgentReminderListEntity {
    /// App 内提醒不区分清单时的稳定默认清单（Siri Schema 要求 reminder 必带 list）。
    static let defaultList = AgentReminderListEntity(
        id: UUID(uuidString: "6F0A9C5E-0000-4000-8000-0000000000A1")!,
        name: "Reminders",
        type: .standard
    )
}

// MARK: - Reminders 域业务服务（可注入、可测）

/// 创建提醒的业务结果
struct ReminderSchemaCreated: Equatable {
    let reminder: AgentReminder
    let title: String
    let note: String?
    let tags: Set<String>
    let urls: [URL]
}

enum ReminderSchemaCreateOutcome: Equatable {
    case created(ReminderSchemaCreated)
    case failed(ReminderSchemaFailure)

    enum ReminderSchemaFailure: Equatable {
        case emptyTitle
        case limitReached
    }
}

/// 创建清单的业务结果
enum ReminderListSchemaCreateOutcome: Equatable {
    case created(AgentNamedList)
    case failed(ReminderListSchemaFailure)

    enum ReminderListSchemaFailure: Equatable {
        case emptyName
        case duplicate
        case limitReached
    }
}

/// 系统提醒 Schema 的纯业务实现：标题拼接、默认触发时间与存储/调度注入。
@MainActor
enum ReminderSchemaService {
    /// 未给出时间时的默认触发时间（一小时后）
    static let defaultLeadTime: TimeInterval = 3600

    /// 调度副作用覆盖（测试 / 调试用；nil 走真实系统通知调度）
    static var scheduleOverride: ((AgentReminder) -> Void)?

    /// 创建提醒：标题为空 / 存储拒绝（达上限）时返回失败。
    /// store 注入 AgentReminder（text 已拼好备注、fireDate 已确定），
    /// schedule 注入创建成功后的调度副作用。
    static func createReminder(
        title: String,
        dueDate: DateComponents? = nil,
        note: String? = nil,
        isFlagged: Bool? = nil,
        repeatRule: AgentReminderRepeat = .none,
        tags: Set<String> = [],
        urls: [URL] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        store: (AgentReminder) -> AgentReminder? = { reminder in
            AgentReminderStore.add(text: reminder.text, fireDate: reminder.fireDate, repeatRule: reminder.repeatRule)
        },
        schedule: ((AgentReminder) -> Void)? = nil
    ) -> ReminderSchemaCreateOutcome {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return .failed(.emptyTitle) }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var lines = [trimmedTitle]
        if !trimmedNote.isEmpty { lines.append(trimmedNote) }
        let normalizedTags = Set(tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let tagText = normalizedTags.sorted().map { "#\($0)" }.joined(separator: " ")
        if !tagText.isEmpty { lines.append(tagText) }
        lines.append(contentsOf: urls.map(\.absoluteString))
        let text = lines.joined(separator: "\n")
        let fireDate = dueDate.flatMap { calendar.date(from: $0) }
            ?? now.addingTimeInterval(defaultLeadTime)
        guard let reminder = store(AgentReminder(text: text, fireDate: fireDate, repeatRule: repeatRule)) else {
            return .failed(.limitReached)
        }
        (schedule ?? scheduleOverride ?? { AgentReminderScheduler.schedule($0) })(reminder)
        return .created(ReminderSchemaCreated(
            reminder: reminder,
            title: trimmedTitle,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            tags: normalizedTags,
            urls: urls
        ))
    }
}

/// Calendar.RecurrenceRule → App 重复规则映射（App 支持单次 / 每天 / 每周）。
@available(iOS 27.0, *)
enum ReminderRecurrenceMapper {
    static func repeatRule(_ rule: Calendar.RecurrenceRule?) -> AgentReminderRepeat {
        guard let rule, rule.interval == 1 else { return .none }
        switch rule.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        default: return .none
        }
    }
}

/// 系统清单 Schema 的纯业务实现：名称校验与存储注入。
@MainActor
enum ReminderListSchemaService {
    /// 创建清单：空名 / 重名 / 达上限分别返回对应失败。
    static func createList(
        name: String,
        store: (String) -> AgentNamedList? = { AgentListStore.createList(named: $0) }
    ) -> ReminderListSchemaCreateOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(.emptyName) }
        if AgentListStore.list(named: trimmed) != nil {
            return .failed(.duplicate)
        }
        guard let list = store(trimmed) else { return .failed(.limitReached) }
        return .created(list)
    }
}

// MARK: - Reminders 域意图（iOS 27.0+）

@available(iOS 27.0, *)
enum ReminderSchemaIntentError: LocalizedError {
    case emptyTitle
    case limitReached
    case emptyName
    case duplicateList

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "reminder.schema.error.empty.title".localized
        case .limitReached: return "reminder.schema.error.limit".localized
        case .emptyName: return "reminder.schema.error.empty.name".localized
        case .duplicateList: return "reminder.schema.error.duplicate".localized
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct CreateAgentReminderAppIntent {
    static var title: LocalizedStringResource = "reminder.schema.create.title"
    static var description = IntentDescription("reminder.schema.create.description")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "reminder.schema.param.title")
    var title: String

    @Parameter(title: "reminder.schema.param.list")
    var list: AgentReminderListEntity?

    @Parameter(title: "reminder.schema.param.note")
    var note: String?

    @Parameter(title: "reminder.schema.param.isflagged")
    var isFlagged: Bool?

    @Parameter(title: "reminder.schema.param.duedate")
    var dueDate: DateComponents?

    @Parameter(title: "reminder.schema.param.recurrence")
    var recurrence: Calendar.RecurrenceRule?

    @Parameter(title: "reminder.schema.param.locationtrigger")
    var locationTrigger: AgentReminderLocationTriggerEntity?

    @Parameter(title: "reminder.schema.param.section")
    var section: AgentReminderSectionEntity?

    @Parameter(title: "reminder.schema.param.tags", default: [])
    var tags: Set<String>

    @Parameter(title: "reminder.schema.param.urls", default: [])
    var urls: [URL]

    @Parameter(title: "reminder.schema.param.images", default: [], supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]

    @MainActor
    func perform() async throws -> some ReturnsValue<AgentReminderEntity> & ProvidesDialog {
        let outcome = ReminderSchemaService.createReminder(
            title: title,
            dueDate: dueDate,
            note: note,
            isFlagged: isFlagged,
            repeatRule: ReminderRecurrenceMapper.repeatRule(recurrence),
            tags: tags,
            urls: urls
        )
        switch outcome {
        case .created(let created):
            let entity = AgentReminderEntity(created: created, list: list)
            return .result(
                value: entity,
                dialog: IntentDialog(stringLiteral: "reminder.schema.created.dialog".localized)
            )
        case .failed(let failure):
            switch failure {
            case .emptyTitle: throw ReminderSchemaIntentError.emptyTitle
            case .limitReached: throw ReminderSchemaIntentError.limitReached
            }
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createList)
struct CreateAgentReminderListAppIntent {
    static var title: LocalizedStringResource = "reminder.schema.createlist.title"
    static var description = IntentDescription("reminder.schema.createlist.description")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "reminder.schema.param.name")
    var name: String

    @Parameter(title: "reminder.schema.param.type", default: .standard)
    var type: AgentReminderListType

    @MainActor
    func perform() async throws -> some ReturnsValue<AgentReminderListEntity> & ProvidesDialog {
        switch ReminderListSchemaService.createList(name: name) {
        case .created(let list):
            let entity = AgentReminderListEntity(list: list)
            return .result(
                value: entity,
                dialog: IntentDialog(stringLiteral: "reminder.schema.createlist.created.dialog".localized)
            )
        case .failed(let failure):
            switch failure {
            case .emptyName: throw ReminderSchemaIntentError.emptyName
            case .duplicate: throw ReminderSchemaIntentError.duplicateList
            case .limitReached: throw ReminderSchemaIntentError.limitReached
            }
        }
    }
}
