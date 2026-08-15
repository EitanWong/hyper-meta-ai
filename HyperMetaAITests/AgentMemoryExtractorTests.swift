import XCTest
@testable import HyperMetaAI

final class AgentMemoryExtractorTests: XCTestCase {

  func testExplicitRememberAllPrefixes() {
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: "帮我记住：回答要简洁"), "回答要简洁")
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: "请记住：我在上海工作"), "我在上海工作")
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: "帮我记住我喜欢喝美式"), "我喜欢喝美式")
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: "请记住我叫小明"), "我叫小明")
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: "记住：项目叫 Hermes"), "项目叫 Hermes")
  }

  func testExplicitRememberTrimsAndRejectsEmpty() {
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: "  帮我记住：  咖啡少糖  "), "咖啡少糖")
    XCTAssertNil(AgentMemoryExtractor.explicitRememberTarget(from: "帮我记住"))
    XCTAssertNil(AgentMemoryExtractor.explicitRememberTarget(from: "帮我记住："))
    XCTAssertNil(AgentMemoryExtractor.explicitRememberTarget(from: "   "))
  }

  func testExplicitRememberLengthBounds() {
    let short = "帮我记住" + String(repeating: "好", count: 1)
    XCTAssertNil(AgentMemoryExtractor.explicitRememberTarget(from: short))
    let long = "帮我记住" + String(repeating: "好", count: 81)
    XCTAssertNil(AgentMemoryExtractor.explicitRememberTarget(from: long))
    let ok = "帮我记住" + String(repeating: "好", count: 80)
    XCTAssertEqual(AgentMemoryExtractor.explicitRememberTarget(from: ok)?.count, 80)
  }

  func testStatementCandidateHits() {
    XCTAssertEqual(AgentMemoryExtractor.statementCandidate(from: "我喜欢简洁的回答"), "我喜欢简洁的回答")
    XCTAssertEqual(AgentMemoryExtractor.statementCandidate(from: "我不喜欢辣"), "我不喜欢辣")
    XCTAssertEqual(AgentMemoryExtractor.statementCandidate(from: "我住在上海"), "我住在上海")
    XCTAssertEqual(AgentMemoryExtractor.statementCandidate(from: "我的名字是小明"), "我的名字是小明")
    XCTAssertEqual(AgentMemoryExtractor.statementCandidate(from: "我的目标是减肥"), "我的目标是减肥")
  }

  func testStatementCandidateRejectsQuestions() {
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "我喜欢什么？"))
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "我住在哪里"))
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "我住在上海吗"))
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "我喜欢简洁的回答，为什么？"))
  }

  func testStatementCandidateRejectsCommandAndIncomplete() {
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "帮我记住我喜欢猫"))
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "请记住我住在上海"))
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "我喜欢"))
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: "我叫"))
  }

  func testStatementCandidateRejectsTooLong() {
    let long = "我喜欢" + String(repeating: "好", count: 38)
    XCTAssertNil(AgentMemoryExtractor.statementCandidate(from: long))
  }

  func testExtractCandidatesDeduplicatesAndPrioritizesExplicit() {
    let texts = [
      "帮我记住我喜欢猫",
      "请记住我在上海",
      "我喜欢简洁的回答",
      "我喜欢简洁的回答",
    ]
    let extracted = AgentMemoryExtractor.extractCandidates(from: texts)
    XCTAssertEqual(extracted, ["我喜欢猫", "我在上海", "我喜欢简洁的回答"])
  }

  func testAgentMemoryCommandParser() {
    XCTAssertEqual(
      AgentMemoryCommandParser.parse("帮我记住：回答要简洁"),
      AgentMemoryCommand.remember("回答要简洁")
    )
    XCTAssertEqual(
      AgentMemoryCommandParser.parse("请记住我在上海"),
      AgentMemoryCommand.remember("我在上海")
    )
    XCTAssertNil(AgentMemoryCommandParser.parse("帮我记住"))
    XCTAssertNil(AgentMemoryCommandParser.parse("今天天气如何"))
  }
}

final class AgentMemoryCandidateStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentMemoryCandidateStore.clear()
    AgentMemoryStore.clear()
  }

  override func tearDown() {
    AgentMemoryCandidateStore.clear()
    AgentMemoryStore.clear()
    super.tearDown()
  }

  private func candidate(_ text: String) -> AgentMemoryCandidate {
    AgentMemoryCandidate(text: text, source: text)
  }

  func testAppendDeduplicates() {
    AgentMemoryCandidateStore.append([candidate("我喜欢简洁的回答"), candidate("我喜欢简洁的回答")])
    XCTAssertEqual(AgentMemoryCandidateStore.candidates.count, 1)
  }

  func testAppendSkipsTextAlreadyInMemoryStore() {
    _ = AgentMemoryStore.add(text: "我住在上海")
    AgentMemoryCandidateStore.append([candidate("我住在上海")])
    XCTAssertTrue(AgentMemoryCandidateStore.candidates.isEmpty)
  }

  func testAcceptMovesToMemoryStore() {
    AgentMemoryCandidateStore.append([candidate("我喜欢简洁的回答")])
    let id = AgentMemoryCandidateStore.candidates[0].id
    AgentMemoryCandidateStore.accept(id: id)
    XCTAssertTrue(AgentMemoryCandidateStore.candidates.isEmpty)
    XCTAssertEqual(AgentMemoryStore.entries.map(\.text), ["我喜欢简洁的回答"])
  }

  func testIgnoreRemoves() {
    AgentMemoryCandidateStore.append([candidate("甲"), candidate("乙")])
    let target = AgentMemoryCandidateStore.candidates[0].id
    AgentMemoryCandidateStore.ignore(id: target)
    XCTAssertEqual(AgentMemoryCandidateStore.candidates.count, 1)
    XCTAssertTrue(AgentMemoryStore.entries.isEmpty)
  }

  func testAppendRespectsMaxCount() {
    let many = (0..<15).map { candidate("候选\($0)") }
    AgentMemoryCandidateStore.append(many)
    XCTAssertEqual(AgentMemoryCandidateStore.candidates.count, AgentMemoryCandidateStore.maxCount)
  }

  func testClear() {
    AgentMemoryCandidateStore.append([candidate("甲")])
    AgentMemoryCandidateStore.clear()
    XCTAssertTrue(AgentMemoryCandidateStore.candidates.isEmpty)
  }
}

/// 记忆语音指令解析（存入 / 查询）
final class AgentMemoryCommandParserTests: XCTestCase {

  func testRememberCommands() {
    XCTAssertEqual(
      AgentMemoryCommandParser.parse("帮我记住我在上海"),
      AgentMemoryCommand.remember("我在上海")
    )
    XCTAssertEqual(
      AgentMemoryCommandParser.parse("请记住：咖啡少糖"),
      AgentMemoryCommand.remember("咖啡少糖")
    )
  }

  func testQueryCommands() {
    XCTAssertEqual(AgentMemoryCommandParser.parse("我记住了什么"), .query)
    XCTAssertEqual(AgentMemoryCommandParser.parse("我的记忆有哪些"), .query)
    XCTAssertEqual(AgentMemoryCommandParser.parse("有什么记忆"), .query)
    XCTAssertEqual(AgentMemoryCommandParser.parse("都记住了什么"), .query)
    XCTAssertEqual(AgentMemoryCommandParser.parse("what do you remember"), .query)
  }

  func testQueryTakesPriorityOverRemember() {
    XCTAssertEqual(AgentMemoryCommandParser.parse("我的记忆列表"), .query)
  }

  func testUnrelatedSpeechReturnsNil() {
    XCTAssertNil(AgentMemoryCommandParser.parse("今天天气怎么样"))
    XCTAssertNil(AgentMemoryCommandParser.parse("帮我查一下明天的天气"))
    XCTAssertNil(AgentMemoryCommandParser.parse(""))
    XCTAssertNil(AgentMemoryCommandParser.parse("   "))
  }
}
