import Foundation
import XCTest

@testable import HyperMetaAI

final class AgentListCommandParserTests: XCTestCase {
  func testAddItemToList() {
    XCTAssertEqual(
      AgentListCommandParser.parse("把牛奶加到购物单"),
      .add(item: "牛奶", list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("牛奶添加到购物单"),
      .add(item: "牛奶", list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单加牛奶"),
      .add(item: "牛奶", list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("待办里加买牛奶"),
      .add(item: "买牛奶", list: "待办")
    )
  }

  func testRemoveItemFromList() {
    XCTAssertEqual(
      AgentListCommandParser.parse("从购物单删掉牛奶"),
      .remove(item: "牛奶", list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单删掉牛奶"),
      .remove(item: "牛奶", list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("把牛奶从购物单删掉"),
      .remove(item: "牛奶", list: "购物单")
    )
  }

  func testQueryList() {
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单里有什么"),
      .query(list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("查一下购物单"),
      .query(list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("查一下待办里有哪些"),
      .query(list: "待办")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("清单里有什么"),
      .query(list: "清单")
    )
  }

  func testQueryListByIndex() {
    XCTAssertEqual(
      AgentListCommandParser.parse("第2个清单里有什么"),
      .queryIndex(index: 1)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第二个清单"),
      .queryIndex(index: 1)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("清单三"),
      .queryIndex(index: 2)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第 3 个清单里有什么"),
      .queryIndex(index: 2),
      "序号与「清单」之间的空格剥离后仍可命中"
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第十个清单"),
      .queryIndex(index: 9)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第十九个清单"),
      .queryIndex(index: 18)
    )
  }

  func testQueryListByIndexRejectsOthers() {
    XCTAssertNil(AgentListCommandParser.parse("第二十个清单"), "超出中文数字支持范围（1-19）不拦截")
    XCTAssertNil(AgentListCommandParser.parse("第2个任务"), "任务点名不归清单拦截")
    XCTAssertNil(AgentListCommandParser.parse("第2个"), "缺少清单关键词不拦截")
    XCTAssertEqual(
      AgentListCommandParser.parse("清单里有什么"),
      .query(list: "清单"),
      "无序号时仍走名称查询"
    )
  }

  func testQueryItemByOrdinal() {
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单第2条是什么"),
      .queryItem(list: "购物单", index: 1)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单第二条"),
      .queryItem(list: "购物单", index: 1)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("待办第 10 条"),
      .queryItem(list: "待办", index: 9),
      "序号与「条」之间的空格剥离后仍可命中"
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("我的购物单第三条"),
      .queryItem(list: "我的购物单", index: 2),
      "名称带修饰词也命中"
    )
  }

  func testQueryItemRejectsOthers() {
    XCTAssertNil(AgentListCommandParser.parse("购物单第二十条"), "超出支持范围（1-19）不拦截、不回溯")
    XCTAssertNil(AgentListCommandParser.parse("第二条是什么"), "缺少清单关键词不拦截")
    XCTAssertNil(AgentListCommandParser.parse("购物单第2个"), "「个」不是「条」，不归单条点名")
  }

  func testRenameList() {
    XCTAssertEqual(
      AgentListCommandParser.parse("把购物单改名为生活清单"),
      .rename(list: "购物单", newName: "生活清单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单改名成生活清单"),
      .rename(list: "购物单", newName: "生活清单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("将待办改成周计划"),
      .rename(list: "待办", newName: "周计划")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("购物清单更名为周末清单"),
      .rename(list: "购物清单", newName: "周末清单")
    )
  }

  func testRenameListRejectsOthers() {
    XCTAssertNil(AgentListCommandParser.parse("改名为生活清单"), "缺少清单名不拦截")
    XCTAssertNil(AgentListCommandParser.parse("购物单改名为"), "新名称为空不拦截")
    XCTAssertNil(AgentListCommandParser.parse("把方案改成这样"), "名称不含清单关键词不拦截")
  }

  func testQueryItemByIndexes() {
    XCTAssertEqual(
      AgentListCommandParser.parse("第2个清单第3条是什么"),
      .queryItemByIndexes(listIndex: 1, itemIndex: 2)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第二个清单第三条"),
      .queryItemByIndexes(listIndex: 1, itemIndex: 2)
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第 2 个清单第 3 条"),
      .queryItemByIndexes(listIndex: 1, itemIndex: 2),
      "序号间空格剥离后仍可命中"
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第十个清单第十条"),
      .queryItemByIndexes(listIndex: 9, itemIndex: 9)
    )
  }

  func testQueryItemByIndexesRejectsOthers() {
    XCTAssertEqual(
      AgentListCommandParser.parse("第二十个清单第三条"),
      .queryItem(list: "第二十个清单", index: 2),
      "组合清单序号超范围时降级为按名单条（最终播报清单不存在提示）"
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第二个清单第二十条"),
      .queryIndex(index: 1),
      "组合条目序号超范围时降级为清单序号点名（播报整个清单）"
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("第2个清单"),
      .queryIndex(index: 1),
      "单层清单序号仍走 queryIndex"
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("购物单第二条"),
      .queryItem(list: "购物单", index: 1),
      "按名单条点名仍走 queryItem"
    )
  }

  func testClearList() {
    XCTAssertEqual(
      AgentListCommandParser.parse("清空购物单"),
      .clear(list: "购物单")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("清空一下待办"),
      .clear(list: "待办")
    )
    XCTAssertEqual(
      AgentListCommandParser.parse("清空出差购物清单"),
      .clear(list: "出差购物清单")
    )
  }

  func testPlainChatIsNotIntercepted() {
    XCTAssertNil(AgentListCommandParser.parse("帮我写个清单"))
    XCTAssertNil(AgentListCommandParser.parse("你有什么清单吗"))
    XCTAssertNil(AgentListCommandParser.parse("把牛奶放进冰箱"))
    XCTAssertNil(AgentListCommandParser.parse("今天天气怎么样"))
    XCTAssertNil(AgentListCommandParser.parse("购物单"))
    XCTAssertNil(AgentListCommandParser.parse(""))
  }
}

final class AgentListStoreTests: XCTestCase {
  override func setUp() {
    super.setUp()
    AgentListStore.clear()
  }

  override func tearDown() {
    AgentListStore.clear()
    super.tearDown()
  }

  func testAddItemCreatesListOnDemand() {
    let updated = AgentListStore.addItem("牛奶", to: "购物单")
    XCTAssertEqual(updated?.name, "购物单")
    XCTAssertEqual(updated?.items, ["牛奶"])
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["牛奶"])
  }

  func testAddItemAppendsAndDeduplicates() {
    _ = AgentListStore.addItem("牛奶", to: "购物单")
    _ = AgentListStore.addItem("鸡蛋", to: "购物单")
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["牛奶", "鸡蛋"])

    XCTAssertNil(AgentListStore.addItem("牛奶", to: "购物单"), "重复条目不添加")
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items.count, 2)
  }

  func testNameMatchingIgnoresCaseAndWhitespace() {
    _ = AgentListStore.addItem("A", to: " 购物单 ")
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["A"])
  }

  func testRemoveItemAndClearItems() {
    _ = AgentListStore.addItem("牛奶", to: "购物单")
    _ = AgentListStore.addItem("鸡蛋", to: "购物单")
    AgentListStore.removeItem("牛奶", from: "购物单")
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["鸡蛋"])

    AgentListStore.clearItems(named: "购物单")
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, [], "清空后保留清单本身")
    XCTAssertNotNil(AgentListStore.list(named: "购物单"))
  }

  func testCreateListAndDuplicateRejection() {
    XCTAssertNotNil(AgentListStore.createList(named: "待办"))
    XCTAssertNil(AgentListStore.createList(named: "待办"), "重名清单不创建")
    XCTAssertNil(AgentListStore.createList(named: "  "), "空名称不创建")
    XCTAssertEqual(AgentListStore.lists.count, 1)
  }

  func testRenameListKeepsIdentityAndItems() {
    _ = AgentListStore.createList(named: "购物单")
    _ = AgentListStore.addItem("牛奶", to: "购物单")
    guard let original = AgentListStore.list(named: "购物单") else {
      return XCTFail("前置清单未创建")
    }
    let renamed = AgentListStore.renameList(id: original.id, to: "生活清单")
    XCTAssertNotNil(renamed)
    XCTAssertEqual(renamed?.id, original.id, "id 不变")
    XCTAssertEqual(renamed?.name, "生活清单")
    XCTAssertEqual(renamed?.items, ["牛奶"], "条目保留")
    XCTAssertEqual(renamed?.date, original.date, "更新时间保留")
    XCTAssertNil(AgentListStore.list(named: "购物单"), "旧名称不再命中")
    XCTAssertNotNil(AgentListStore.list(named: "生活清单"))
  }

  func testRenameListByOldName() {
    _ = AgentListStore.createList(named: "待办")
    XCTAssertNotNil(AgentListStore.renameList(named: "待办", to: "周计划"))
    XCTAssertNil(AgentListStore.list(named: "待办"))
    XCTAssertNotNil(AgentListStore.list(named: "周计划"))
  }

  func testRenameListRejections() {
    _ = AgentListStore.createList(named: "购物单")
    _ = AgentListStore.createList(named: "待办")
    guard let shopping = AgentListStore.list(named: "购物单") else {
      return XCTFail("前置清单未创建")
    }
    XCTAssertNil(AgentListStore.renameList(id: shopping.id, to: "待办"), "重名拒绝")
    XCTAssertNil(AgentListStore.renameList(id: shopping.id, to: "   "), "空名拒绝")
    XCTAssertNil(AgentListStore.renameList(id: UUID(), to: "新清单"), "清单不存在拒绝")
    XCTAssertNil(AgentListStore.renameList(named: "不存在", to: "新清单"), "按名找不到拒绝")
    XCTAssertEqual(AgentListStore.list(named: "购物单")?.name, "购物单", "失败时原名称不变")
  }

  func testMaxLimits() {
    for index in 0..<AgentListStore.maxListCount {
      XCTAssertNotNil(AgentListStore.createList(named: "清单\(index)"))
    }
    XCTAssertNil(AgentListStore.createList(named: "超限清单"), "清单数达上限后拒绝")

    AgentListStore.clear()
    _ = AgentListStore.createList(named: "购物单")
    for index in 0..<AgentListStore.maxItemsPerList {
      XCTAssertNotNil(AgentListStore.addItem("条目\(index)", to: "购物单"))
    }
    XCTAssertNil(AgentListStore.addItem("超限条目", to: "购物单"), "条目数达上限后拒绝")
  }
}

final class AgentListDisplayMappingTests: XCTestCase {
  override func setUp() {
    super.setUp()
    AgentListStore.clear()
  }

  override func tearDown() {
    AgentListStore.clear()
    super.tearDown()
  }

  func testHasLists() {
    XCTAssertFalse(AgentListDisplayMapping.hasLists())
    _ = AgentListStore.createList(named: "购物单")
    XCTAssertTrue(AgentListDisplayMapping.hasLists(), "空清单也展示入口，便于查看/管理")
  }

  func testRecentListsSortedByDateWithLimit() {
    let older = AgentNamedList(name: "旧清单", items: ["旧条目"], date: Date(timeIntervalSince1970: 1_700_000_000))
    let newer = AgentNamedList(name: "新清单", items: ["新条目"], date: Date(timeIntervalSince1970: 1_700_003_600))
    let newest = AgentNamedList(name: "最新清单", items: [], date: Date(timeIntervalSince1970: 1_700_007_200))
    AgentListStore.lists = [older, newer, newest]

    XCTAssertEqual(AgentListDisplayMapping.recentLists(limit: 10).map(\.name), ["最新清单", "新清单", "旧清单"], "按更新时间降序")
    XCTAssertEqual(AgentListDisplayMapping.recentLists(limit: 2).map(\.name), ["最新清单", "新清单"], "limit 生效")
  }

  func testMenuLabelTruncates() {
    let long = AgentNamedList(name: "周末超市购物清单明细", items: [], date: Date())
    XCTAssertEqual(AgentListDisplayMapping.menuLabel(for: long), "周末超市购物清单…")
    let short = AgentNamedList(name: "待办", items: [], date: Date())
    XCTAssertEqual(AgentListDisplayMapping.menuLabel(for: short), "待办")
  }

  func testResultTextWithItemsAndEmpty() {
    let list = AgentNamedList(name: "购物单", items: ["牛奶", "鸡蛋"], date: Date())
    XCTAssertEqual(
      AgentListDisplayMapping.resultText(for: list),
      String(format: "agent.lists.result".localized, "购物单", "牛奶" + "agent.lists.separator".localized + "鸡蛋")
    )

    let empty = AgentNamedList(name: "待办", items: [], date: Date())
    XCTAssertEqual(
      AgentListDisplayMapping.resultText(for: empty),
      String(format: "agent.lists.empty".localized, "待办")
    )
  }

  func testIconNameIsShoppingBag() {
    XCTAssertEqual(AgentListDisplayMapping.iconName(), "shopping_bag")
  }

  func testQueryIndexMessageHitsContent() {
    let list = AgentNamedList(name: "购物单", items: ["牛奶", "鸡蛋"], date: Date())
    let message = AgentListDisplayMapping.queryIndexMessage(index: 0, lists: [list])
    XCTAssertEqual(
      message,
      String(
        format: "agent.list.query.content".localized,
        "购物单",
        "牛奶" + "agent.lists.separator".localized + "鸡蛋"
      )
    )
  }

  func testQueryIndexMessageEmptyList() {
    let list = AgentNamedList(name: "待办", items: [], date: Date())
    XCTAssertEqual(
      AgentListDisplayMapping.queryIndexMessage(index: 0, lists: [list]),
      String(format: "agent.list.query.empty".localized, "待办")
    )
  }

  func testQueryIndexMessageOutOfRange() {
    XCTAssertEqual(
      AgentListDisplayMapping.queryIndexMessage(index: 2, lists: []),
      String(format: "agent.list.query.index.range".localized, 3, 0)
    )
    XCTAssertEqual(
      AgentListDisplayMapping.queryIndexMessage(index: 2, lists: [AgentNamedList(name: "购物单", items: [], date: Date())]),
      String(format: "agent.list.query.index.range".localized, 3, 1)
    )
    XCTAssertEqual(
      AgentListDisplayMapping.queryIndexMessage(index: -1, lists: []),
      String(format: "agent.list.query.index.range".localized, 0, 0),
      "负数序号按越界处理"
    )
  }

  func testShouldShowItemMenuThreshold() {
    let small = AgentNamedList(name: "购物单", items: ["牛奶", "鸡蛋", "面包"], date: Date())
    XCTAssertFalse(AgentListDisplayMapping.shouldShowItemMenu(for: small), "3 条以内直接整体播报")
    let long = AgentNamedList(name: "购物单", items: ["牛奶", "鸡蛋", "面包", "纸巾"], date: Date())
    XCTAssertTrue(AgentListDisplayMapping.shouldShowItemMenu(for: long), "超过 3 条进逐条子菜单")
    let empty = AgentNamedList(name: "待办", items: [], date: Date())
    XCTAssertFalse(AgentListDisplayMapping.shouldShowItemMenu(for: empty))
  }

  func testItemsCappedToScreenCapacity() {
    let list = AgentNamedList(name: "购物单", items: (1...10).map { "条目\($0)" }, date: Date())
    XCTAssertEqual(AgentListDisplayMapping.items(for: list).count, 8, "单屏最多 8 条")
    XCTAssertEqual(AgentListDisplayMapping.items(for: list, limit: 3).count, 3)
    let short = AgentNamedList(name: "购物单", items: ["牛奶"], date: Date())
    XCTAssertEqual(AgentListDisplayMapping.items(for: short), ["牛奶"])
  }

  func testItemMenuLabelWithIndexAndTruncation() {
    XCTAssertEqual(
      AgentListDisplayMapping.itemMenuLabel(for: "牛奶", index: 0),
      "1 牛奶"
    )
    XCTAssertEqual(
      AgentListDisplayMapping.itemMenuLabel(for: "周末要买的有机牛奶和全麦面包", index: 9),
      "10 周末要买的有机牛奶和…"
    )
    XCTAssertEqual(
      AgentListDisplayMapping.itemMenuLabel(for: "  牛奶  ", index: 0),
      "1 牛奶",
      "首尾空白剥离"
    )
  }

  func testItemResultText() {
    let list = AgentNamedList(name: "购物单", items: ["牛奶", "鸡蛋"], date: Date())
    XCTAssertEqual(
      AgentListDisplayMapping.itemResultText(for: "鸡蛋", index: 1, in: list),
      String(format: "agent.list.item.result".localized, "购物单", 2, "鸡蛋")
    )
  }
}

final class AgentListResponseTextTests: XCTestCase {
  func testAddMessages() {
    XCTAssertEqual(
      AgentListResponseText.added(item: "牛奶", to: "购物单"),
      String(format: "agent.list.added".localized, "牛奶", "购物单")
    )
    XCTAssertEqual(
      AgentListResponseText.duplicate(item: "牛奶", in: "购物单"),
      String(format: "agent.list.add.dup".localized, "牛奶", "购物单")
    )
    XCTAssertEqual(
      AgentListResponseText.full(list: "购物单"),
      String(format: "agent.list.add.full".localized, "购物单")
    )
  }

  func testRemoveMessages() {
    XCTAssertEqual(
      AgentListResponseText.removed(item: "牛奶", from: "购物单"),
      String(format: "agent.list.removed".localized, "牛奶", "购物单")
    )
    XCTAssertEqual(
      AgentListResponseText.missing(item: "牛奶", in: "购物单"),
      String(format: "agent.list.item.missing".localized, "牛奶", "购物单")
    )
  }

  func testQueryMessages() {
    XCTAssertEqual(
      AgentListResponseText.query(list: "购物单", items: []),
      String(format: "agent.list.query.empty".localized, "购物单")
    )
    XCTAssertEqual(
      AgentListResponseText.query(list: "购物单", items: ["牛奶", "鸡蛋"]),
      String(
        format: "agent.list.query.content".localized,
        "购物单",
        "牛奶" + "agent.lists.separator".localized + "鸡蛋"
      )
    )
  }

  func testQueryIndexDelegatesToDisplayMapping() {
    let list = AgentNamedList(name: "购物单", items: ["牛奶"], date: Date())
    XCTAssertEqual(
      AgentListResponseText.queryIndex(index: 0, lists: [list]),
      AgentListDisplayMapping.queryIndexMessage(index: 0, lists: [list])
    )
    XCTAssertEqual(
      AgentListResponseText.queryIndex(index: 5, lists: []),
      AgentListDisplayMapping.queryIndexMessage(index: 5, lists: [])
    )
  }

  func testClearedMessage() {
    XCTAssertEqual(
      AgentListResponseText.cleared(list: "购物单"),
      String(format: "agent.list.cleared".localized, "购物单")
    )
  }

  func testQueryItemHitReusesItemResultFormat() {
    XCTAssertEqual(
      AgentListResponseText.queryItem(list: "购物单", index: 1, items: ["牛奶", "鸡蛋"]),
      String(format: "agent.list.item.result".localized, "购物单", 2, "鸡蛋")
    )
  }

  func testQueryItemOutOfRange() {
    XCTAssertEqual(
      AgentListResponseText.queryItem(list: "购物单", index: 2, items: ["牛奶"]),
      String(format: "agent.list.query.item.range".localized, "购物单", 3, 1)
    )
    XCTAssertEqual(
      AgentListResponseText.queryItem(list: "待办", index: 0, items: []),
      String(format: "agent.list.query.item.range".localized, "待办", 1, 0),
      "空清单按越界处理"
    )
    XCTAssertEqual(
      AgentListResponseText.queryItem(list: "购物单", index: -1, items: ["牛奶"]),
      String(format: "agent.list.query.item.range".localized, "购物单", 0, 1)
    )
  }

  func testRenameMessages() {
    XCTAssertEqual(
      AgentListResponseText.renamed(list: "购物单", to: "生活清单"),
      String(format: "agent.list.renamed".localized, "购物单", "生活清单")
    )
    XCTAssertEqual(
      AgentListResponseText.renameDuplicate(name: "生活清单"),
      String(format: "agent.list.rename.dup".localized, "生活清单")
    )
    XCTAssertEqual(
      AgentListResponseText.renameNotFound(list: "购物单"),
      String(format: "agent.list.rename.notfound".localized, "购物单")
    )
  }

  func testQueryItemByIndexesMessages() {
    let list = AgentNamedList(name: "购物单", items: ["牛奶", "鸡蛋", "面包"], date: Date())
    XCTAssertEqual(
      AgentListResponseText.queryItemByIndexes(listIndex: 0, itemIndex: 1, lists: [list]),
      String(format: "agent.list.item.result".localized, "购物单", 2, "鸡蛋")
    )
    XCTAssertEqual(
      AgentListResponseText.queryItemByIndexes(listIndex: 2, itemIndex: 0, lists: [list]),
      String(format: "agent.list.query.index.range".localized, 3, 1),
      "清单越界提示"
    )
    XCTAssertEqual(
      AgentListResponseText.queryItemByIndexes(listIndex: 0, itemIndex: 3, lists: [list]),
      String(format: "agent.list.query.item.range".localized, "购物单", 4, 3),
      "条目越界提示"
    )
    XCTAssertEqual(
      AgentListResponseText.queryItemByIndexes(listIndex: -1, itemIndex: 0, lists: [list]),
      String(format: "agent.list.query.index.range".localized, 0, 1)
    )
  }
}
