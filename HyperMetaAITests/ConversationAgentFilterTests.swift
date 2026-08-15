import XCTest
@testable import HyperMetaAI

final class ConversationAgentFilterTests: XCTestCase {

    private func record(agent: String) -> ConversationRecord {
        ConversationRecord(
            messages: [ConversationMessage(role: .user, content: "测试")],
            aiModel: agent
        )
    }

    func testAllFilterIncludesEverything() {
        let records = [
            record(agent: "OpenClaw"),
            record(agent: "Hermes"),
            record(agent: "qwen-audio-agent"),
        ]
        XCTAssertEqual(ConversationAgentFilter.filter(records, by: .all).count, 3)
    }

    func testFilterMatchesAgentDisplayNames() {
        let records = [
            record(agent: "OpenClaw"),
            record(agent: "Hermes"),
            record(agent: "qwen-audio-agent"),
            record(agent: "qwen3-omni-flash-realtime"),
        ]
        let openclaw = ConversationAgentFilter.filter(records, by: .openclaw)
        XCTAssertEqual(openclaw.count, 1)
        XCTAssertEqual(openclaw.first?.aiModel, "OpenClaw")

        let hermes = ConversationAgentFilter.filter(records, by: .hermes)
        XCTAssertEqual(hermes.count, 1)
        XCTAssertEqual(hermes.first?.aiModel, "Hermes")

        let qwen = ConversationAgentFilter.filter(records, by: .qwen)
        XCTAssertEqual(qwen.count, 1)
        XCTAssertEqual(qwen.first?.aiModel, "qwen-audio-agent")
    }

    func testFilterEmptyResult() {
        let records = [record(agent: "OpenClaw")]
        XCTAssertTrue(ConversationAgentFilter.filter(records, by: .hermes).isEmpty)
    }

    func testIconNameMapping() {
        XCTAssertEqual(ConversationAgentFilter.iconName(for: record(agent: "OpenClaw")), "link.circle.fill")
        XCTAssertEqual(ConversationAgentFilter.iconName(for: record(agent: "Hermes")), "wand.and.stars")
        XCTAssertEqual(ConversationAgentFilter.iconName(for: record(agent: "qwen-audio-agent")), "waveform")
        XCTAssertEqual(ConversationAgentFilter.iconName(for: record(agent: AgentAskArchiver.aiModel)), "sparkles")
    }

    func testAllCasesIdentifiable() {
        XCTAssertEqual(ConversationAgentFilter.allCases.map(\.id), ["all", "openclaw", "hermes", "qwen"])
    }
}
