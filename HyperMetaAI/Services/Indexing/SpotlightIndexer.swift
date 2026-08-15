/*
 * Spotlight System Search Indexer
 * 让长期记忆 / 规则 / 清单 / 提醒可被系统搜索（CoreSpotlight），
 * 点按搜索结果经 AppNavigationRouter 深链到 Agent 设置对应分区，
 * 让「大脑数据」像 JARVIS 档案一样随时可检索。
 * 纯逻辑（元数据构造 / identifier 解析）与系统副作用分离，便于测试。
 */

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Spotlight 索引域：对应 Agent 设置页可定位分区
enum SpotlightDomain: String, CaseIterable {
    case memory
    case rule
    case list
    case reminder
    /// 眼镜拍摄照片（图库）
    case photo
    /// 对话记录（「问 JARVIS」结果 / 语音 / 聊天历史）
    case conversation
}

/// 一条可索引元数据（纯逻辑构造，可测）
struct SpotlightItemMetadata: Equatable {
    /// 全局唯一标识（Spotlight 去重 / 深链依据）
    var identifier: String
    var domain: SpotlightDomain
    /// 关联数据 UUID（点按后定位 / 移除索引）
    var relatedIdentifier: UUID
    var title: String
    var contentDescription: String
    /// 过期时间（nil 表示不过期）
    var expirationDate: Date?
    /// 关联的照片文件名（照片域用于加载缩略图；其他域为 nil）
    var thumbnailFileName: String? = nil
}

/// Spotlight 索引器：元数据构造（纯逻辑）+ 系统索引副作用
enum SpotlightIndexer {
    static let identifierPrefix = "com.lunflux.hyper-meta-ai.spotlight"

    // MARK: - 纯逻辑：元数据构造

    /// 把四类大脑数据构造成可索引元数据（幂等，顺序稳定）
    static func metadata(
        memories: [AgentMemoryEntry],
        rules: [AgentRuleEntry],
        lists: [AgentNamedList],
        reminders: [AgentReminder],
        now: Date = Date()
    ) -> [SpotlightItemMetadata] {
        let memoryItems = memories.map { entry in
            SpotlightItemMetadata(
                identifier: identifier(for: .memory, uuid: entry.id),
                domain: .memory,
                relatedIdentifier: entry.id,
                title: entry.text,
                contentDescription: entry.text,
                expirationDate: nil
            )
        }
        let ruleItems = rules.map { entry in
            SpotlightItemMetadata(
                identifier: identifier(for: .rule, uuid: entry.id),
                domain: .rule,
                relatedIdentifier: entry.id,
                title: entry.text,
                contentDescription: entry.text,
                expirationDate: nil
            )
        }
        let listItems = lists.map { list in
            SpotlightItemMetadata(
                identifier: identifier(for: .list, uuid: list.id),
                domain: .list,
                relatedIdentifier: list.id,
                title: list.name,
                contentDescription: list.items.joined(separator: "、"),
                expirationDate: nil
            )
        }
        // 只索引仍有效的提醒：周期提醒永远有效，单次提醒只看未来
        let activeReminders = reminders.filter { $0.repeatRule != .none || $0.fireDate >= now }
        let reminderItems = activeReminders.map { reminder in
            SpotlightItemMetadata(
                identifier: identifier(for: .reminder, uuid: reminder.id),
                domain: .reminder,
                relatedIdentifier: reminder.id,
                title: reminder.text,
                contentDescription: AgentReminderDisplayMapping.resultText(for: reminder, now: now),
                // 单次提醒触发后次日过期，不再出现在搜索结果
                expirationDate: reminder.repeatRule == .none
                    ? reminder.fireDate.addingTimeInterval(86_400)
                    : nil
            )
        }
        return memoryItems + ruleItems + listItems + reminderItems
    }

    /// 生成稳定 identifier：`前缀.域.uuid`
    static func identifier(for domain: SpotlightDomain, uuid: UUID) -> String {
        "\(identifierPrefix).\(domain.rawValue).\(uuid.uuidString)"
    }

    /// 照片元数据：有 AI 描述时标题为描述、副标题为拍摄时间；
    /// 无描述时标题为拍摄时间、副标题为「眼镜拍摄的照片」。
    static func photoMetadata(
        _ photos: [CapturedPhotoRecord],
        formatter: DateFormatter = SpotlightIndexer.photoDateFormatter()
    ) -> [SpotlightItemMetadata] {
        photos.map { record in
            let timeText = formatter.string(from: record.createdAt)
            let trimmedDescription = record.aiDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasDescription = !trimmedDescription.isEmpty
            return SpotlightItemMetadata(
                identifier: identifier(for: .photo, uuid: record.id),
                domain: .photo,
                relatedIdentifier: record.id,
                title: hasDescription ? trimmedDescription : timeText,
                contentDescription: hasDescription
                    ? String(format: "spotlight.photo.title".localized, timeText)
                    : "spotlight.photo.noDescription".localized,
                expirationDate: nil,
                thumbnailFileName: record.fileName
            )
        }
    }

    /// 对话记录元数据：标题为首条用户消息，描述为最后一条回复（空回复回退标题）。
    /// 对话是持久档案，不过期；按时间倒序排列保证最新对话靠前。
    static func conversationMetadata(
        _ conversations: [ConversationRecord]
    ) -> [SpotlightItemMetadata] {
        conversations
            .sorted { $0.timestamp > $1.timestamp }
            .map { record in
                let summary = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return SpotlightItemMetadata(
                    identifier: identifier(for: .conversation, uuid: record.id),
                    domain: .conversation,
                    relatedIdentifier: record.id,
                    title: record.title,
                    contentDescription: summary.isEmpty ? record.title : summary,
                    expirationDate: nil
                )
            }
    }

    /// 照片搜索标题的时间文案格式（跟随 App 语言）
    static func photoDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    /// 各域的 domainIdentifier（删除索引时整域移除）
    static var domainIdentifiers: [String] {
        SpotlightDomain.allCases.map { "\(identifierPrefix).\($0.rawValue)" }
    }

    // MARK: - 系统副作用

    /// 重建全部索引（幂等：先整域删除再全量写入；数据量小，可安全多次调用）
    static func update(
        now: Date = Date()
    ) {
        let brainItems = metadata(
            memories: AgentMemoryStore.entries,
            rules: AgentRuleStore.entries,
            lists: AgentListStore.lists,
            reminders: AgentReminderStore.reminders,
            now: now
        )
        let photoItems = photoMetadata(CapturedPhotoStore.records)
        let conversationItems = conversationMetadata(
            ConversationStorage.shared.loadAllConversations()
        )
        let items = (brainItems + photoItems + conversationItems).map { metadata in
            let item = makeItem(metadata)
            applyThumbnailIfAvailable(to: item, fileName: metadata.thumbnailFileName)
            return item
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
            guard error == nil else { return }
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// 把纯元数据组装成系统可索引项
    static func makeItem(_ metadata: SpotlightItemMetadata) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
        attributeSet.title = metadata.title
        attributeSet.contentDescription = metadata.contentDescription
        attributeSet.relatedUniqueIdentifier = metadata.relatedIdentifier.uuidString
        let item = CSSearchableItem(
            uniqueIdentifier: metadata.identifier,
            domainIdentifier: "\(identifierPrefix).\(metadata.domain.rawValue)",
            attributeSet: attributeSet
        )
        if let expirationDate = metadata.expirationDate {
            item.expirationDate = expirationDate
        }
        return item
    }

    /// 照片域：加载本地缩略图写入搜索结果（文件缺失 / 非照片域跳过，幂等）
    static func applyThumbnailIfAvailable(to item: CSSearchableItem, fileName: String?) {
        guard let fileName,
              let image = CapturedPhotoStore.loadImage(fileName: fileName),
              let data = image.jpegData(compressionQuality: 0.5)
        else { return }
        item.attributeSet.thumbnailData = data
    }
}

/// Spotlight 点按目标：Agent 设置分区 / 图库照片
enum SpotlightDestination: Equatable {
    case settings(AgentSettingsSection)
    case galleryPhoto(UUID)
    case conversation(UUID)

    /// 映射为 App 内导航目标（路由只认 AppNavigationDestination）
    var navigationDestination: AppNavigationDestination {
        switch self {
        case .settings(let section): return .agentSettings(section)
        case .galleryPhoto(let uuid): return .gallery(uuid)
        case .conversation(let uuid): return .conversation(uuid)
        }
    }
}

/// Spotlight 点按 identifier → 深链目标解析（纯逻辑，可测）
enum SpotlightIdentifierParser {
    /// 解析为深链目标；非法 / 未知 / 非本 App 返回 nil
    static func destination(for identifier: String) -> SpotlightDestination? {
        let prefix = SpotlightIndexer.identifierPrefix + "."
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = String(identifier.dropFirst(prefix.count))
        let parts = suffix.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let domain = SpotlightDomain(rawValue: parts[0]),
              let uuid = UUID(uuidString: parts[1]) else { return nil }
        switch domain {
        case .memory: return .settings(.memory)
        case .rule: return .settings(.rules)
        case .list: return .settings(.lists)
        case .reminder: return .settings(.reminders)
        case .photo: return .galleryPhoto(uuid)
        case .conversation: return .conversation(uuid)
        }
    }
}
