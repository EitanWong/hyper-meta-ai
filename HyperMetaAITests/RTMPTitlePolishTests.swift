import XCTest

@testable import HyperMetaAI

final class RTMPTitlePolishParserTests: XCTestCase {

  func testNumberedListParsed() {
    let titles = RTMPTitlePolishParser.parse("1. 深夜探店直击\n2. 街头美食现场\n3. 一起云逛夜市")

    XCTAssertEqual(titles, ["深夜探店直击", "街头美食现场", "一起云逛夜市"])
  }

  func testBulletAndDashPrefixesStripped() {
    let titles = RTMPTitlePolishParser.parse("• 标题甲\n- 标题乙\n– 标题丙")

    XCTAssertEqual(titles, ["标题甲", "标题乙", "标题丙"])
  }

  func testChineseNumberedWithParticleStripped() {
    let titles = RTMPTitlePolishParser.parse("1、标题甲\n2、标题乙")

    XCTAssertEqual(titles, ["标题甲", "标题乙"])
  }

  func testMarkdownBoldStripped() {
    let titles = RTMPTitlePolishParser.parse("**深夜探店直击**")

    XCTAssertEqual(titles, ["深夜探店直击"])
  }

  func testQuotesStripped() {
    let titles = RTMPTitlePolishParser.parse("“深夜探店直击”\n「街头美食现场」")

    XCTAssertEqual(titles, ["深夜探店直击", "街头美食现场"])
  }

  func testDuplicateTitlesDeduplicated() {
    let titles = RTMPTitlePolishParser.parse("1. 深夜探店直击\n2. 深夜探店直击\n3. 街头美食现场")

    XCTAssertEqual(titles, ["深夜探店直击", "街头美食现场"])
  }

  func testLongTitleClippedToMaxLength() {
    let long = String(repeating: "很", count: 60)
    let titles = RTMPTitlePolishParser.parse(long)

    XCTAssertEqual(titles.count, 1)
    XCTAssertEqual(titles[0].count, 40)
  }

  func testEmptyInputReturnsEmpty() {
    XCTAssertTrue(RTMPTitlePolishParser.parse("").isEmpty)
    XCTAssertTrue(RTMPTitlePolishParser.parse("\n  \n").isEmpty)
  }

  func testScaffoldingLinesSkipped() {
    let titles = RTMPTitlePolishParser.parse("以下是润色后的标题：\n1. 深夜探店直击")

    XCTAssertEqual(titles, ["深夜探店直击"])
  }

  func testLimitRespected() {
    let titles = RTMPTitlePolishParser.parse(
      "1. 甲\n2. 乙\n3. 丙\n4. 丁\n5. 戊",
      limit: 3
    )

    XCTAssertEqual(titles, ["甲", "乙", "丙"])
  }
}

final class RTMPTitlePolishPromptTests: XCTestCase {

  func testMessageContainsDraftAndSceneContext() {
    let message = RTMPTitlePolishPrompt.message(
      draftTitle: "Restaurant 现场直击 · 实时互动",
      sceneLabel: "Restaurant",
      summary: "Restaurant, Food",
      platformName: "抖音"
    )

    XCTAssertTrue(message.contains("Restaurant 现场直击 · 实时互动"))
    XCTAssertTrue(message.contains("直播场景：Restaurant"))
    XCTAssertTrue(message.contains("场景摘要：Restaurant, Food"))
    XCTAssertTrue(message.contains("直播平台：抖音"))
    XCTAssertTrue(message.contains(RTMPTitlePolishPrompt.formatRequirement))
  }

  func testEmptyContextLinesOmitted() {
    let message = RTMPTitlePolishPrompt.message(
      draftTitle: "标题",
      sceneLabel: nil,
      summary: "",
      platformName: nil
    )

    XCTAssertTrue(message.contains("原标题：标题"))
    XCTAssertFalse(message.contains("直播场景："))
    XCTAssertFalse(message.contains("场景摘要："))
    XCTAssertFalse(message.contains("直播平台："))
  }

  func testMessageDoesNotExposeSecrets() {
    let message = RTMPTitlePolishPrompt.message(
      draftTitle: "标题",
      sceneLabel: "Cafe",
      summary: "Coffee",
      platformName: "抖音"
    )

    XCTAssertFalse(message.contains("rtmp://"))
    XCTAssertFalse(message.contains("streamKey"))
  }
}
