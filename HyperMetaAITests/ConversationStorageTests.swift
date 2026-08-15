import XCTest
@testable import HyperMetaAI

final class ConversationStorageTests: XCTestCase {
    private let suiteName = "HyperMetaAI.ConversationStorageTests"
    private var defaults: UserDefaults!
    private var storage: ConversationStorage!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        storage = ConversationStorage(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        storage = nil
        super.tearDown()
    }

    private func makeRecord(agent: String = "Hermes") -> ConversationRecord {
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "你好")],
            aiModel: agent
        )
    }

    func testSaveThenLoadReturnsNewestFirst() {
        let first = makeRecord()
        let second = makeRecord(agent: "OpenClaw")
        storage.saveConversation(first)
        storage.saveConversation(second)

        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.id, second.id, "新记录应排在最前")
        XCTAssertEqual(loaded.last?.id, first.id)
    }

    func testSaveSameIDUpdatesInPlace() {
        let id = UUID()
        let first = ConversationRecord(
            id: id,
            messages: [ConversationMessage(role: .user, content: "你好")],
            aiModel: "Hermes"
        )
        storage.saveConversation(first)
        let second = ConversationRecord(
            id: id,
            messages: [
                ConversationMessage(role: .user, content: "你好"),
                ConversationMessage(role: .assistant, content: "在的"),
            ],
            aiModel: "Hermes"
        )
        storage.saveConversation(second)

        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 1, "同 ID 保存应覆盖更新而不是新增")
        XCTAssertEqual(loaded.first?.id, id)
        XCTAssertEqual(loaded.first?.messageCount, 2)
    }

    func testSameIDSaveMovesRecordToFront() {
        let first = makeRecord()
        let second = makeRecord(agent: "OpenClaw")
        storage.saveConversation(first)
        storage.saveConversation(second)
        storage.saveConversation(first)

        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.id, first.id, "覆盖更新后应排在最前")
        XCTAssertEqual(loaded.last?.id, second.id)
    }

    func testDeleteConversationRemovesOnlyTarget() {
        let first = makeRecord()
        let second = makeRecord(agent: "OpenClaw")
        storage.saveConversation(first)
        storage.saveConversation(second)

        storage.deleteConversation(first.id)

        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, second.id)
    }

    func testDeleteAllConversationsClears() {
        storage.saveConversation(makeRecord())
        storage.saveConversation(makeRecord(agent: "OpenClaw"))
        storage.deleteAllConversations()
        XCTAssertTrue(storage.loadAllConversations().isEmpty)
    }

    func testDeleteConversationsForAgentRemovesOnlyMatching() {
        storage.saveConversation(makeRecord(agent: "qwen-audio-agent"))
        storage.saveConversation(makeRecord(agent: "qwen-audio-agent"))
        storage.saveConversation(makeRecord(agent: "Hermes"))

        let removed = storage.deleteConversations(for: "qwen-audio-agent")

        XCTAssertEqual(removed, 2)
        let loaded = storage.loadAllConversations()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.aiModel, "Hermes")
    }

    func testDeleteConversationsForAgentIsIdempotent() {
        storage.saveConversation(makeRecord(agent: "qwen-audio-agent"))
        XCTAssertEqual(storage.deleteConversations(for: "qwen-audio-agent"), 1)
        XCTAssertEqual(storage.deleteConversations(for: "qwen-audio-agent"), 0)
        XCTAssertTrue(storage.loadAllConversations().isEmpty)
    }

    func testGetConversationByID() {
        let record = makeRecord()
        storage.saveConversation(record)
        XCTAssertEqual(storage.getConversation(by: record.id)?.id, record.id)
        XCTAssertNil(storage.getConversation(by: UUID()))
    }

    func testMaxConversationsCap() {
        for index in 0..<110 {
            storage.saveConversation(makeRecord(agent: "Agent\(index)"))
        }
        XCTAssertEqual(storage.loadAllConversations().count, 100)
    }
}
