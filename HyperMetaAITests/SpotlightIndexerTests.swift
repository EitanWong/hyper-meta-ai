import CoreSpotlight
import XCTest

@testable import HyperMetaAI

/// Spotlight 系统搜索索引：元数据构造 / identifier 解析 / 系统项组装
final class SpotlightIndexerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 元数据构造

    func testMetadataBuildsAllFourDomains() {
        let memory = AgentMemoryEntry(id: UUID(), text: "喜欢极简界面", date: now)
        let rule = AgentRuleEntry(id: UUID(), text: "汇报先说结论", date: now)
        let list = AgentNamedList(id: UUID(), name: "购物单", items: ["牛奶", "鸡蛋"], date: now)
        let reminder = AgentReminder(
            id: UUID(), text: "喝水", fireDate: now.addingTimeInterval(600), createdAt: now
        )

        let metadata = SpotlightIndexer.metadata(
            memories: [memory],
            rules: [rule],
            lists: [list],
            reminders: [reminder],
            now: now
        )

        XCTAssertEqual(metadata.count, 4)
        XCTAssertEqual(
            metadata.map(\.domain),
            [.memory, .rule, .list, .reminder]
        )

        let memoryItem = metadata[0]
        XCTAssertEqual(memoryItem.title, "喜欢极简界面")
        XCTAssertEqual(memoryItem.contentDescription, "喜欢极简界面")
        XCTAssertEqual(memoryItem.relatedIdentifier, memory.id)
        XCTAssertNil(memoryItem.expirationDate)

        let listItem = metadata[2]
        XCTAssertEqual(listItem.title, "购物单")
        XCTAssertEqual(listItem.contentDescription, "牛奶、鸡蛋")
        XCTAssertEqual(listItem.relatedIdentifier, list.id)

        let reminderItem = metadata[3]
        XCTAssertEqual(reminderItem.title, "喝水")
        XCTAssertTrue(reminderItem.contentDescription.contains("喝水"))
        XCTAssertEqual(reminderItem.relatedIdentifier, reminder.id)
    }

    func testSingleReminderExpiresOneDayAfterFireDate() {
        let fireDate = now.addingTimeInterval(3_600)
        let reminder = AgentReminder(id: UUID(), text: "吃药", fireDate: fireDate, createdAt: now)

        let metadata = SpotlightIndexer.metadata(
            memories: [], rules: [], lists: [], reminders: [reminder], now: now
        )

        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(
            metadata[0].expirationDate,
            fireDate.addingTimeInterval(86_400)
        )
    }

    func testRepeatingReminderNeverExpiresAndPassedSingleReminderIsExcluded() {
        let repeating = AgentReminder(
            id: UUID(),
            text: "每天吃维生素",
            fireDate: now.addingTimeInterval(-3_600),
            createdAt: now,
            repeatRule: .daily
        )
        let passed = AgentReminder(
            id: UUID(), text: "过期的单次提醒", fireDate: now.addingTimeInterval(-60), createdAt: now
        )

        let metadata = SpotlightIndexer.metadata(
            memories: [], rules: [], lists: [], reminders: [repeating, passed], now: now
        )

        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata[0].relatedIdentifier, repeating.id)
        XCTAssertNil(metadata[0].expirationDate)
    }

    func testEmptyDataProducesEmptyMetadata() {
        let metadata = SpotlightIndexer.metadata(
            memories: [], rules: [], lists: [], reminders: [], now: now
        )
        XCTAssertTrue(metadata.isEmpty)
    }

    // MARK: - identifier 解析

    func testIdentifierRoundTripMapsToDestinations() {
        let settingsCases: [(SpotlightDomain, AgentSettingsSection)] = [
            (.memory, .memory),
            (.rule, .rules),
            (.list, .lists),
            (.reminder, .reminders)
        ]
        for (domain, section) in settingsCases {
            let id = UUID()
            let identifier = SpotlightIndexer.identifier(for: domain, uuid: id)
            XCTAssertEqual(
                SpotlightIdentifierParser.destination(for: identifier),
                .settings(section)
            )
        }

        let photoID = UUID()
        let photoIdentifier = SpotlightIndexer.identifier(for: .photo, uuid: photoID)
        XCTAssertEqual(
            SpotlightIdentifierParser.destination(for: photoIdentifier),
            .galleryPhoto(photoID)
        )

        let conversationID = UUID()
        let conversationIdentifier = SpotlightIndexer.identifier(
            for: .conversation,
            uuid: conversationID
        )
        XCTAssertEqual(
            SpotlightIdentifierParser.destination(for: conversationIdentifier),
            .conversation(conversationID)
        )
    }

    func testDestinationMapsToNavigationDestination() {
        XCTAssertEqual(
            SpotlightDestination.settings(.reminders).navigationDestination,
            .agentSettings(.reminders)
        )
        let photoID = UUID()
        XCTAssertEqual(
            SpotlightDestination.galleryPhoto(photoID).navigationDestination,
            .gallery(photoID)
        )
        let conversationID = UUID()
        XCTAssertEqual(
            SpotlightDestination.conversation(conversationID).navigationDestination,
            .conversation(conversationID)
        )
    }

    // MARK: - 对话记录元数据

    func testConversationMetadataBuildsTitleAndSummary() {
        let record = ConversationRecord(
            id: UUID(),
            timestamp: now,
            messages: [
                ConversationMessage(role: .user, content: "明天天气怎么样", timestamp: now),
                ConversationMessage(role: .assistant, content: "明天多云转晴。", timestamp: now),
            ],
            aiModel: AgentAskArchiver.aiModel
        )
        let metadata = SpotlightIndexer.conversationMetadata([record])

        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata[0].domain, .conversation)
        XCTAssertEqual(metadata[0].title, "明天天气怎么样")
        XCTAssertEqual(metadata[0].contentDescription, "明天多云转晴。")
        XCTAssertEqual(metadata[0].relatedIdentifier, record.id)
        XCTAssertNil(metadata[0].expirationDate, "对话是持久档案不过期")
    }

    func testConversationMetadataFallsBackToTitleWhenSummaryEmpty() {
        let record = ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "你好", timestamp: now)],
            aiModel: "Hermes"
        )
        let metadata = SpotlightIndexer.conversationMetadata([record])
        XCTAssertEqual(metadata[0].contentDescription, "你好", "空回复回退标题")
    }

    func testConversationMetadataSortedNewestFirst() {
        let older = ConversationRecord(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 100),
            messages: [ConversationMessage(role: .user, content: "旧对话", timestamp: now)],
            aiModel: "Hermes"
        )
        let newer = ConversationRecord(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 200),
            messages: [ConversationMessage(role: .user, content: "新对话", timestamp: now)],
            aiModel: "Hermes"
        )
        let metadata = SpotlightIndexer.conversationMetadata([older, newer])
        XCTAssertEqual(metadata.map(\.title), ["新对话", "旧对话"])
    }

    func testPhotoMetadataUsesDescriptionWhenAvailable() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let record = CapturedPhotoRecord(
            id: UUID(),
            fileName: "IMG-20260812-213500.jpg",
            createdAt: now,
            aiDescription: "夕阳下的海边"
        )

        let metadata = SpotlightIndexer.photoMetadata([record], formatter: formatter)

        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata[0].domain, .photo)
        XCTAssertEqual(metadata[0].relatedIdentifier, record.id)
        XCTAssertEqual(metadata[0].title, "夕阳下的海边")
        XCTAssertTrue(metadata[0].contentDescription.contains(formatter.string(from: now)))
        XCTAssertNil(metadata[0].expirationDate)
        XCTAssertEqual(metadata[0].thumbnailFileName, record.fileName)
    }

    func testPhotoMetadataFallsBackToTimeTitleWithoutDescription() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let record = CapturedPhotoRecord(
            id: UUID(),
            fileName: "IMG-20260812-213501.jpg",
            createdAt: now,
            aiDescription: nil
        )

        let metadata = SpotlightIndexer.photoMetadata([record], formatter: formatter)

        XCTAssertEqual(metadata[0].title, formatter.string(from: now))
        XCTAssertEqual(metadata[0].contentDescription, "spotlight.photo.noDescription".localized)
    }

    func testPhotoMetadataIgnoresEmptyDescription() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let record = CapturedPhotoRecord(
            id: UUID(),
            fileName: "IMG-20260812-213502.jpg",
            createdAt: now,
            aiDescription: "   "
        )

        let metadata = SpotlightIndexer.photoMetadata([record], formatter: formatter)

        XCTAssertEqual(metadata[0].title, formatter.string(from: now))
    }

    func testEmptyPhotosProduceNoMetadata() {
        XCTAssertTrue(SpotlightIndexer.photoMetadata([]).isEmpty)
    }

    func testDomainIdentifiersCoversPhotoDomain() {
        XCTAssertEqual(SpotlightIndexer.domainIdentifiers.count, 6)
        XCTAssertTrue(SpotlightIndexer.domainIdentifiers.contains { $0.hasSuffix(".photo") })
        XCTAssertTrue(SpotlightIndexer.domainIdentifiers.contains { $0.hasSuffix(".conversation") })
    }

    func testPhotoItemThumbnailAppliedWhenFileMissingIsNoOp() {
        let metadata = SpotlightItemMetadata(
            identifier: SpotlightIndexer.identifier(for: .photo, uuid: UUID()),
            domain: .photo,
            relatedIdentifier: UUID(),
            title: "照片",
            contentDescription: "眼镜拍摄的照片",
            expirationDate: nil,
            thumbnailFileName: "IMG-does-not-exist.jpg"
        )
        let item = SpotlightIndexer.makeItem(metadata)
        SpotlightIndexer.applyThumbnailIfAvailable(to: item, fileName: metadata.thumbnailFileName)
        XCTAssertNil(item.attributeSet.thumbnailData, "文件缺失时缩略图应为 nil（幂等无副作用）")
    }

    func testNonPhotoItemIgnoresThumbnailFileName() {
        let metadata = SpotlightItemMetadata(
            identifier: SpotlightIndexer.identifier(for: .memory, uuid: UUID()),
            domain: .memory,
            relatedIdentifier: UUID(),
            title: "记忆",
            contentDescription: "内容"
        )
        let item = SpotlightIndexer.makeItem(metadata)
        SpotlightIndexer.applyThumbnailIfAvailable(to: item, fileName: nil)
        XCTAssertNil(item.attributeSet.thumbnailData)
    }

    func testMakeItemKeepsPhotoDomainIdentifier() {
        let metadata = SpotlightItemMetadata(
            identifier: SpotlightIndexer.identifier(for: .photo, uuid: UUID()),
            domain: .photo,
            relatedIdentifier: UUID(),
            title: "照片",
            contentDescription: "描述"
        )
        let item = SpotlightIndexer.makeItem(metadata)
        XCTAssertEqual(item.domainIdentifier, "\(SpotlightIndexer.identifierPrefix).photo")
    }

    func testParserRejectsMalformedIdentifiers() {
        let valid = SpotlightIndexer.identifier(for: .memory, uuid: UUID())
        XCTAssertNil(SpotlightIdentifierParser.destination(for: ""))
        XCTAssertNil(SpotlightIdentifierParser.destination(for: SpotlightIndexer.identifierPrefix))
        XCTAssertNil(SpotlightIdentifierParser.destination(for: valid + ".extra"))
        XCTAssertNil(SpotlightIdentifierParser.destination(for: valid.replacingOccurrences(of: "memory", with: "unknown")))
        let badUUID = valid.replacingOccurrences(
            of: valid.split(separator: ".").last!.description,
            with: "not-a-uuid"
        )
        XCTAssertNil(SpotlightIdentifierParser.destination(for: badUUID))
        XCTAssertNil(SpotlightIdentifierParser.destination(for: "com.other.app.spotlight.memory.\(UUID().uuidString)"))
    }

    // MARK: - 系统项组装

    func testMakeItemMapsMetadataToCSSearchableItem() {
        let metadata = SpotlightItemMetadata(
            identifier: SpotlightIndexer.identifier(for: .reminder, uuid: UUID()),
            domain: .reminder,
            relatedIdentifier: UUID(),
            title: "喝水",
            contentDescription: "10 分钟后：喝水",
            expirationDate: now.addingTimeInterval(86_400)
        )

        let item = SpotlightIndexer.makeItem(metadata)

        XCTAssertEqual(item.uniqueIdentifier, metadata.identifier)
        XCTAssertEqual(item.domainIdentifier, "\(SpotlightIndexer.identifierPrefix).reminder")
        XCTAssertEqual(item.attributeSet.title, "喝水")
        XCTAssertEqual(item.attributeSet.contentDescription, "10 分钟后：喝水")
        XCTAssertEqual(item.attributeSet.relatedUniqueIdentifier, metadata.relatedIdentifier.uuidString)
        XCTAssertEqual(item.expirationDate, metadata.expirationDate)
    }
}
