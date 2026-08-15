import XCTest
@testable import HyperMetaAI

final class AgentShareQueueTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentShareQueue.clear()
    UserDefaults.standard.removeObject(forKey: AgentShareQueue.key)
    AgentMemoryStore.clear()
    AgentListStore.clear()
  }

  override func tearDown() {
    AgentShareQueue.clear()
    UserDefaults.standard.removeObject(forKey: AgentShareQueue.key)
    AgentMemoryStore.clear()
    AgentListStore.clear()
    super.tearDown()
  }

  func testEnqueueAndConsumeRoundTrip() {
    let request = AgentShareRequest(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      text: "  分享一段值得记住的内容  ",
      destination: .memory,
      date: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertTrue(AgentShareQueue.enqueue(request))
    let pending = AgentShareQueue.pending()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending[0].id, request.id)
    XCTAssertEqual(pending[0].text, "分享一段值得记住的内容", "入队应去除首尾空白")
    XCTAssertEqual(pending[0].destination, .memory)
    XCTAssertEqual(pending[0].date, request.date)

    let consumed = AgentShareQueue.consume()
    XCTAssertEqual(consumed, pending)
    XCTAssertTrue(AgentShareQueue.pending().isEmpty, "消费后队列应清空")
    XCTAssertTrue(AgentShareQueue.consume().isEmpty, "重复消费应幂等")
  }

  func testEnqueueRejectsEmptyText() {
    let request = AgentShareRequest(text: "   \n  ", destination: .list)
    XCTAssertFalse(AgentShareQueue.enqueue(request))
    XCTAssertTrue(AgentShareQueue.pending().isEmpty)
  }

  func testEnqueueTrimsToMaxCount() {
    for index in 0..<(AgentShareQueue.maxCount + 5) {
      XCTAssertTrue(AgentShareQueue.enqueue(AgentShareRequest(
        text: "内容\(index)",
        destination: .agent
      )))
    }
    let pending = AgentShareQueue.pending()
    XCTAssertEqual(pending.count, AgentShareQueue.maxCount)
    XCTAssertEqual(pending.first?.text, "内容5", "超出上限应丢弃最旧的 5 条")
    XCTAssertEqual(pending.last?.text, "内容\(AgentShareQueue.maxCount + 4)")
  }
}

final class AgentShareProcessorTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentShareQueue.clear()
    UserDefaults.standard.removeObject(forKey: AgentShareQueue.key)
    AgentMemoryStore.clear()
    AgentListStore.clear()
  }

  override func tearDown() {
    AgentShareQueue.clear()
    UserDefaults.standard.removeObject(forKey: AgentShareQueue.key)
    AgentMemoryStore.clear()
    AgentListStore.clear()
    super.tearDown()
  }

  func testMemoryDestinationAddsEntry() {
    let outcome = AgentShareProcessor.apply(AgentShareRequest(
      text: "  Meta Ray-Ban 的眼镜触发事件  ",
      destination: .memory
    ))
    XCTAssertEqual(outcome, .memoryAdded)
    XCTAssertEqual(AgentMemoryStore.entries.map(\.text), ["Meta Ray-Ban 的眼镜触发事件"])
  }

  func testMemoryDestinationRejectsDuplicate() {
    let text = "重复的记忆内容"
    XCTAssertEqual(AgentShareProcessor.apply(AgentShareRequest(text: text, destination: .memory)), .memoryAdded)
    XCTAssertEqual(AgentShareProcessor.apply(AgentShareRequest(text: text, destination: .memory)), .invalid)
    XCTAssertEqual(AgentMemoryStore.entries.count, 1)
  }

  func testListDestinationAutoCreatesNamedList() {
    let outcome = AgentShareProcessor.apply(AgentShareRequest(
      text: "周末采购清单第一项",
      destination: .list
    ))
    guard case .listAdded(let name) = outcome else {
      return XCTFail("应返回 listAdded，实际 \(outcome)")
    }
    XCTAssertEqual(name, AgentShareProcessor.defaultListName)
    XCTAssertEqual(AgentListStore.list(named: name)?.items, ["周末采购清单第一项"])
  }

  func testAgentDestinationReturnsInstruction() {
    let outcome = AgentShareProcessor.apply(AgentShareRequest(
      text: "把这篇链接存起来",
      destination: .agent
    ))
    XCTAssertEqual(outcome, .sentToAgent("把这篇链接存起来"))
  }

  func testEmptyTextIsInvalid() {
    let outcome = AgentShareProcessor.apply(AgentShareRequest(
      text: "   ",
      destination: .memory
    ))
    XCTAssertEqual(outcome, .invalid)
    XCTAssertTrue(AgentMemoryStore.entries.isEmpty)
  }
}

final class AgentShareConfirmationTests: XCTestCase {

  func testMemoryConfirmationContainsText() {
    let message = AgentShareConfirmation.message(for: .memoryAdded, text: "值得记住的片段")
    XCTAssertNotNil(message)
    XCTAssertTrue(message!.contains("值得记住的片段"))
  }

  func testListConfirmationContainsListName() {
    let message = AgentShareConfirmation.message(for: .listAdded("分享"), text: "内容")
    XCTAssertNotNil(message)
    XCTAssertTrue(message!.contains("分享"))
  }

  func testAgentAndInvalidHaveNoConfirmation() {
    XCTAssertNil(AgentShareConfirmation.message(for: .sentToAgent("指令"), text: "指令"))
    XCTAssertNil(AgentShareConfirmation.message(for: .invalid, text: "空"))
  }
}

final class AgentSharePayloadMirrorTests: XCTestCase {

  /// 镜像 Share Extension 的 ShareRequestPayload（字段与 rawValue 完全一致）
  private struct ExtensionPayload: Codable {
    var id: UUID
    var text: String
    var destination: String
    var date: Date
  }

  func testExtensionJSONDecodesAsAppRequest() throws {
    let payload = ExtensionPayload(
      id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
      text: "来自其他 App 的分享",
      destination: "list",
      date: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let data = try JSONEncoder().encode(payload)

    let request = try JSONDecoder().decode(AgentShareRequest.self, from: data)
    XCTAssertEqual(request.id, payload.id)
    XCTAssertEqual(request.text, payload.text)
    XCTAssertEqual(request.destination, .list)
    XCTAssertEqual(request.date, payload.date)
  }

  func testAppRequestEncodesAsExtensionPayload() throws {
    let request = AgentShareRequest(
      text: "交给大脑的分享",
      destination: .agent,
      date: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let data = try JSONEncoder().encode(request)

    let payload = try JSONDecoder().decode(ExtensionPayload.self, from: data)
    XCTAssertEqual(payload.text, request.text)
    XCTAssertEqual(payload.destination, "agent")
    XCTAssertEqual(payload.date, request.date)
  }

  func testAllDestinationsRawValuesMatchExtension() {
    XCTAssertEqual(AgentShareDestination.memory.rawValue, "memory")
    XCTAssertEqual(AgentShareDestination.list.rawValue, "list")
    XCTAssertEqual(AgentShareDestination.agent.rawValue, "agent")
  }
}
