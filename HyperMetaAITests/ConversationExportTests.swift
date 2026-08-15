import XCTest

@testable import HyperMetaAI

final class ConversationExportTests: XCTestCase {
  private func makeDate() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 12, hour: 17, minute: 0, second: 1)
    )!
  }

  private func makeFormatter() -> DateFormatter {
    let formatter = ConversationExportBuilder.makeFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return formatter
  }

  func testExportContainsHeaderMetadata() {
    let conversation = ConversationRecord(
      timestamp: makeDate(),
      messages: [ConversationMessage(role: .user, content: "你好")],
      aiModel: "qwen3-omni-flash-realtime",
      language: "zh-CN"
    )

    let text = ConversationExportBuilder.exportText(
      conversation: conversation,
      dateFormatter: makeFormatter()
    )

    XCTAssertTrue(text.contains("Hyper Meta AI 对话记录"))
    XCTAssertTrue(text.contains("时间：2026-08-12 17:00:01"))
    XCTAssertTrue(text.contains("模型：qwen3-omni-flash-realtime"))
    XCTAssertTrue(text.contains("语言：zh-CN"))
    XCTAssertTrue(text.contains("消息：1 条"))
  }

  func testExportListsMessagesWithRoleLabelsAndOrder() {
    let conversation = ConversationRecord(
      timestamp: makeDate(),
      messages: [
        ConversationMessage(role: .user, content: "这是什么植物？", timestamp: makeDate()),
        ConversationMessage(role: .assistant, content: "这是一株绿萝。", timestamp: makeDate().addingTimeInterval(2)),
      ]
    )

    let text = ConversationExportBuilder.exportText(
      conversation: conversation,
      dateFormatter: makeFormatter()
    )

    let userIndex = text.range(of: "[用户]")!.lowerBound
    let assistantIndex = text.range(of: "[助手]")!.lowerBound
    XCTAssertLessThan(userIndex, assistantIndex)
    XCTAssertTrue(text.contains("[用户] 2026-08-12 17:00:01"))
    XCTAssertTrue(text.contains("[助手] 2026-08-12 17:00:03"))
    XCTAssertTrue(text.contains("这是什么植物？"))
    XCTAssertTrue(text.contains("这是一株绿萝。"))
  }

  func testExportEmptyMessagesKeepsHeaderOnly() {
    let conversation = ConversationRecord(
      timestamp: makeDate(),
      messages: [],
      aiModel: "gemini-2.0-flash-exp",
      language: "en"
    )

    let text = ConversationExportBuilder.exportText(
      conversation: conversation,
      dateFormatter: makeFormatter()
    )

    XCTAssertTrue(text.contains("消息：0 条"))
    XCTAssertFalse(text.contains("[用户]"))
    XCTAssertFalse(text.contains("[助手]"))
  }

  func testExportPreservesMultilineContent() {
    let conversation = ConversationRecord(
      messages: [ConversationMessage(role: .assistant, content: "第一行\n第二行\n第三行")]
    )

    let text = ConversationExportBuilder.exportText(
      conversation: conversation,
      dateFormatter: makeFormatter()
    )

    XCTAssertTrue(text.contains("第一行\n第二行\n第三行"))
  }
}
