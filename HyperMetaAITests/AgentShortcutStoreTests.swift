import XCTest
@testable import HyperMetaAI

final class AgentShortcutStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentShortcutStore.clear()
  }

  override func tearDown() {
    AgentShortcutStore.clear()
    super.tearDown()
  }

  func testStoreDefaultsEmpty() {
    XCTAssertTrue(AgentShortcutStore.shortcuts.isEmpty)
  }

  func testAddTrimsAndRejectsEmpty() {
    XCTAssertTrue(AgentShortcutStore.add(title: "  查路况  ", prompt: "  帮我查一下今天的路况  "))
    XCTAssertEqual(AgentShortcutStore.shortcuts.count, 1)
    XCTAssertEqual(AgentShortcutStore.shortcuts[0].title, "查路况")
    XCTAssertEqual(AgentShortcutStore.shortcuts[0].prompt, "帮我查一下今天的路况")

    XCTAssertFalse(AgentShortcutStore.add(title: "   ", prompt: "内容"))
    XCTAssertFalse(AgentShortcutStore.add(title: "标题", prompt: "   "))
    XCTAssertEqual(AgentShortcutStore.shortcuts.count, 1)
  }

  func testAddRespectsMaxCount() {
    for index in 0..<AgentShortcutStore.maxCount {
      XCTAssertTrue(AgentShortcutStore.add(title: "指令\(index)", prompt: "内容\(index)"))
    }
    XCTAssertEqual(AgentShortcutStore.shortcuts.count, AgentShortcutStore.maxCount)
    XCTAssertFalse(AgentShortcutStore.add(title: "超限", prompt: "内容"), "达到上限后应拒绝新增")
  }

  func testRemoveById() {
    _ = AgentShortcutStore.add(title: "查路况", prompt: "帮我查路况")
    _ = AgentShortcutStore.add(title: "播报日程", prompt: "播报今日日程")
    let target = AgentShortcutStore.shortcuts[0]
    AgentShortcutStore.remove(id: target.id)
    XCTAssertEqual(AgentShortcutStore.shortcuts.map(\.title), ["播报日程"])
  }

  func testStorePersistsRoundtrip() {
    _ = AgentShortcutStore.add(title: "查天气", prompt: "今天天气怎么样")
    let decoded = AgentShortcutStore.shortcuts
    XCTAssertEqual(decoded.count, 1)
    XCTAssertEqual(decoded[0].title, "查天气")
    XCTAssertEqual(decoded[0].prompt, "今天天气怎么样")
  }

  func testVoiceMenuIncludesShortcuts() {
    XCTAssertTrue(AgentDisplayMenuMapping.actions(for: .voice).contains(.shortcuts))
    XCTAssertTrue(AgentDisplayMenuMapping.actions(for: .chat).contains(.shortcuts))
  }

  func testShortcutsTitleAndIcon() {
    XCTAssertEqual(AgentDisplayMenuMapping.title(for: .shortcuts), "Shortcuts")
    XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .shortcuts), "star")
    XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .shortcuts))
  }
}
