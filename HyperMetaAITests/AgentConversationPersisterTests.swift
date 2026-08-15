import XCTest
@testable import HyperMetaAI

final class AgentConversationPersisterTests: XCTestCase {

    func testMakesRecordFromChatMessages() {
        let messages = [
            AgentChatMessage(role: "user", text: "你好", image: nil),
            AgentChatMessage(role: "assistant", text: "你好！有什么可以帮你？", image: nil),
        ]
        let record = AgentConversationPersister.makeRecord(messages: messages, agentName: "Hermes")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.messages.count, 2)
        XCTAssertEqual(record?.messages[0].role, .user)
        XCTAssertEqual(record?.messages[0].content, "你好")
        XCTAssertEqual(record?.messages[1].role, .assistant)
        XCTAssertEqual(record?.aiModel, "Hermes")
    }

    func testSkipsImageMessages() {
        let messages = [
            AgentChatMessage(role: "user", text: "看看这个", image: UIImage()),
            AgentChatMessage(role: "assistant", text: "我看到了一张图片", image: nil),
        ]
        let record = AgentConversationPersister.makeRecord(messages: messages, agentName: "OpenClaw")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.messages.count, 1)
        XCTAssertEqual(record?.messages[0].content, "我看到了一张图片")
    }

    func testSkipsEmptyAndWhitespaceMessages() {
        let messages = [
            AgentChatMessage(role: "user", text: "   ", image: nil),
            AgentChatMessage(role: "assistant", text: "", image: nil),
        ]
        XCTAssertNil(AgentConversationPersister.makeRecord(messages: messages, agentName: "Hermes"))
    }

    func testNilWhenNoMessages() {
        XCTAssertNil(AgentConversationPersister.makeRecord(messages: [], agentName: "Hermes"))
    }

    func testMakeRecordReusesRecordID() {
        let id = UUID()
        let messages = [AgentChatMessage(role: "user", text: "你好", image: nil)]
        let record = AgentConversationPersister.makeRecord(
            messages: messages,
            agentName: "Hermes",
            recordID: id
        )
        XCTAssertEqual(record?.id, id)
    }

    func testMakeRecordWithoutRecordIDGeneratesNewID() {
        let messages = [AgentChatMessage(role: "user", text: "你好", image: nil)]
        let first = AgentConversationPersister.makeRecord(messages: messages, agentName: "Hermes")
        let second = AgentConversationPersister.makeRecord(messages: messages, agentName: "Hermes")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testLatestRecordPicksNewestForAgent() {
        let older = ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "第一段")],
            aiModel: "Hermes"
        )
        let newer = ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "第二段")],
            aiModel: "Hermes"
        )
        let other = ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "别的")],
            aiModel: "OpenClaw"
        )
        // 记录列表按时间倒序（最新在前）
        let records = [newer, older, other]
        XCTAssertEqual(
            AgentConversationPersister.latestRecord(from: records, agentName: "Hermes")?.id,
            newer.id
        )
        XCTAssertNil(AgentConversationPersister.latestRecord(from: records, agentName: "Qwen"))
    }

    func testMakesRecordFromTranscriptMessages() {
        let transcript: [(role: String, text: String)] = [
            ("user", "帮我查一下今天的天气"),
            ("assistant", "今天上海多云，25 度。"),
        ]
        let record = AgentConversationPersister.makeRecord(
            transcriptMessages: transcript,
            agentName: "qwen-audio-agent"
        )
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.messages.count, 2)
        XCTAssertEqual(record?.aiModel, "qwen-audio-agent")
    }

    func testTranscriptRecordReusesRecordID() {
        let id = UUID()
        let transcript: [(role: String, text: String)] = [("user", "查天气")]
        let record = AgentConversationPersister.makeRecord(
            transcriptMessages: transcript,
            agentName: "Hermes",
            recordID: id
        )
        XCTAssertEqual(record?.id, id)
    }

  func testTranscriptWithOnlyEmptyTextReturnsNil() {
    let transcript: [(role: String, text: String)] = [("user", "")]
    XCTAssertNil(AgentConversationPersister.makeRecord(transcriptMessages: transcript, agentName: "qwen-audio-agent"))
  }

  func testLoadMessagesPicksLatestRecordForAgent() {
    let older = ConversationRecord(
        timestamp: Date().addingTimeInterval(-60),
        messages: [
            ConversationMessage(role: .user, content: "旧问题"),
            ConversationMessage(role: .assistant, content: "旧回答"),
        ],
        aiModel: "Hermes"
    )
    let newer = ConversationRecord(
        timestamp: Date().addingTimeInterval(-10),
        messages: [
            ConversationMessage(role: .user, content: "新问题"),
        ],
        aiModel: "Hermes"
    )
    let otherAgent = ConversationRecord(
        timestamp: Date(),
        messages: [
            ConversationMessage(role: .user, content: "OpenClaw 的"),
        ],
        aiModel: "OpenClaw"
    )

    let messages = AgentConversationPersister.loadMessages(
        from: [otherAgent, newer, older],
        agentName: "Hermes"
    )
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertEqual(messages[0].text, "新问题")
  }

  func testLoadMessagesByRecordIDPicksSpecificRecord() {
    let target = ConversationRecord(
        messages: [
            ConversationMessage(role: .user, content: "目标会话问题"),
            ConversationMessage(role: .assistant, content: "目标会话回答"),
        ],
        aiModel: "Hermes"
    )
    let other = ConversationRecord(
        messages: [ConversationMessage(role: .user, content: "别的会话")],
        aiModel: "Hermes"
    )
    let openClaw = ConversationRecord(
        messages: [ConversationMessage(role: .user, content: "OpenClaw 会话")],
        aiModel: "OpenClaw"
    )

    let messages = AgentConversationPersister.loadMessages(
        from: [other, openClaw, target],
        recordID: target.id,
        agentName: "Hermes"
    )
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].text, "目标会话问题")
    XCTAssertEqual(messages[1].role, "assistant")
  }

  func testLoadMessagesByRecordIDReturnsEmptyWhenAgentMismatch() {
    let target = ConversationRecord(
        messages: [ConversationMessage(role: .user, content: "Hermes 会话")],
        aiModel: "Hermes"
    )
    let messages = AgentConversationPersister.loadMessages(
        from: [target],
        recordID: target.id,
        agentName: "OpenClaw"
    )
    XCTAssertTrue(messages.isEmpty)
  }

  func testLoadMessagesReturnsEmptyWhenNoMatch() {
    let records = [
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "你好")],
            aiModel: "OpenClaw"
        )
    ]
    XCTAssertTrue(AgentConversationPersister.loadMessages(from: records, agentName: "Hermes").isEmpty)
    XCTAssertTrue(AgentConversationPersister.loadMessages(from: [], agentName: "Hermes").isEmpty)
  }

  func testLatestSummaryPicksNewestRecordForAgent() {
    let older = ConversationRecord(
        timestamp: Date().addingTimeInterval(-60),
        messages: [
            ConversationMessage(role: .user, content: "旧问题"),
            ConversationMessage(role: .assistant, content: "旧回答"),
        ],
        aiModel: "Hermes"
    )
    let newer = ConversationRecord(
        timestamp: Date().addingTimeInterval(-10),
        messages: [
            ConversationMessage(role: .user, content: "新问题"),
            ConversationMessage(role: .assistant, content: "新回答"),
        ],
        aiModel: "Hermes"
    )

    let summary = AgentConversationPersister.latestSummary(
        from: [newer, older],
        agentName: "Hermes"
    )
    XCTAssertEqual(summary, "新回答")
  }

  func testLatestSummaryFiltersByAgentAndReturnsNilWhenAbsent() {
    let records = [
        ConversationRecord(
            messages: [ConversationMessage(role: .assistant, content: "OpenClaw 的回答")],
            aiModel: "OpenClaw"
        )
    ]
    XCTAssertNil(AgentConversationPersister.latestSummary(from: records, agentName: "Hermes"))
    XCTAssertNil(AgentConversationPersister.latestSummary(from: [], agentName: "Hermes"))
  }

  func testLatestSummaryReturnsNilWhenSummaryEmpty() {
    let records = [
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "")],
            aiModel: "Hermes"
        )
    ]
    XCTAssertNil(AgentConversationPersister.latestSummary(from: records, agentName: "Hermes"))
  }

  func testLoadMessagesByRecordIDHydratesAskRecordRegardlessOfAgentName() {
    let askRecord = ConversationRecord(
        messages: [
            ConversationMessage(role: .user, content: "这是什么植物？"),
            ConversationMessage(role: .assistant, content: "这是一株健康的室内观叶植物。"),
        ],
        aiModel: "agent-ask"
    )
    let messages = AgentConversationPersister.loadMessages(
        from: [askRecord],
        recordID: askRecord.id
    )
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertEqual(messages[0].text, "这是什么植物？")
    XCTAssertEqual(messages[1].role, "assistant")
    XCTAssertEqual(messages[1].text, "这是一株健康的室内观叶植物。")
  }

  func testLoadMessagesByRecordIDReturnsEmptyForUnknownID() {
    let record = ConversationRecord(
        messages: [ConversationMessage(role: .user, content: "你好")],
        aiModel: "Hermes"
    )
    XCTAssertTrue(
        AgentConversationPersister.loadMessages(
            from: [record],
            recordID: UUID()
        ).isEmpty
    )
  }
}

/// 对话记录 → 聊天页 Agent 打开方式（对话详情「在聊天中继续」用）
final class ConversationChatKindResolverTests: XCTestCase {

    private func record(aiModel: String) -> ConversationRecord {
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "你好")],
            aiModel: aiModel
        )
    }

    func testOpenClawRecordOpensOpenClawChat() {
        let resolved = ConversationChatKindResolver.resolve(record: record(aiModel: "OpenClaw"))
        XCTAssertEqual(resolved.kind, .openclaw)
        XCTAssertNil(resolved.customConfig)
    }

    func testHermesAndAskRecordsOpenHermesChat() {
        for model in ["Hermes", "agent-ask", "qwen-audio-agent", "Qwen"] {
            let resolved = ConversationChatKindResolver.resolve(record: record(aiModel: model))
            XCTAssertEqual(resolved.kind, .hermes, "\(model) 记录应打开 Hermes 聊天")
            XCTAssertNil(resolved.customConfig)
        }
    }

    func testCustomRecordOpensCorrespondingConfig() {
        let id = UUID()
        let config = CustomAgentConfig(
            id: id,
            name: "工作助手",
            baseURL: "http://example.com/v1",
            model: "gpt-4o-mini"
        )
        let resolved = ConversationChatKindResolver.resolve(
            record: record(aiModel: "custom.\(id.uuidString)"),
            customConfigProvider: { _ in config }
        )
        XCTAssertEqual(resolved.kind, .hermes)
        XCTAssertEqual(resolved.customConfig, config)
    }

    func testCustomRecordWithDeletedConfigFallsBackToHermes() {
        let id = UUID()
        let resolved = ConversationChatKindResolver.resolve(
            record: record(aiModel: "custom.\(id.uuidString)"),
            customConfigProvider: { _ in nil }
        )
        XCTAssertEqual(resolved.kind, .hermes)
        XCTAssertNil(resolved.customConfig)
    }

    func testCustomRecordWithMalformedIDFallsBackToHermes() {
        let resolved = ConversationChatKindResolver.resolve(
            record: record(aiModel: "custom.not-a-uuid"),
            customConfigProvider: { _ in XCTFail("不应调用配置查询"); return nil }
        )
        XCTAssertEqual(resolved.kind, .hermes)
        XCTAssertNil(resolved.customConfig)
    }
}
