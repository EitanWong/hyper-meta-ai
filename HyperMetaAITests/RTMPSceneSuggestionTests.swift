import XCTest

@testable import HyperMetaAI

final class RTMPSceneTitleSuggesterTests: XCTestCase {

  func testSuggestionsUseLabelAndSummary() {
    let suggestions = RTMPSceneTitleSuggester.suggestions(
      sceneLabel: "Restaurant",
      summary: "Restaurant, Food"
    )

    XCTAssertEqual(suggestions.count, 3)
    XCTAssertTrue(suggestions.allSatisfy { $0.contains("Restaurant") })
    XCTAssertEqual(Set(suggestions).count, suggestions.count)
  }

  func testKnownSceneGetsThemeEmoji() {
    let suggestions = RTMPSceneTitleSuggester.suggestions(
      sceneLabel: "Cafe",
      summary: "Coffee"
    )

    XCTAssertTrue(suggestions[0].hasPrefix("☕"))
  }

  func testUnknownSceneStillGetsSuggestionsWithoutEmoji() {
    let suggestions = RTMPSceneTitleSuggester.suggestions(
      sceneLabel: "Concert",
      summary: "Music"
    )

    XCTAssertEqual(suggestions.count, 3)
    XCTAssertTrue(suggestions[0].contains("Concert"))
    XCTAssertFalse(suggestions[0].contains("☕"))
  }

  func testEmptyLabelFallsBackToSummary() {
    let suggestions = RTMPSceneTitleSuggester.suggestions(
      sceneLabel: nil,
      summary: "Outdoor walk"
    )

    XCTAssertEqual(suggestions.count, 2)
    XCTAssertTrue(suggestions.allSatisfy { $0.contains("Outdoor walk") })
  }

  func testEmptySceneReturnsNoSuggestions() {
    XCTAssertTrue(RTMPSceneTitleSuggester.suggestions(sceneLabel: nil, summary: "").isEmpty)
    XCTAssertTrue(RTMPSceneTitleSuggester.suggestions(sceneLabel: "   ", summary: " ").isEmpty)
  }

  func testSuggestionsAreTruncatedAndUnique() {
    let longLabel = String(repeating: "Restaurant-", count: 12)
    let suggestions = RTMPSceneTitleSuggester.suggestions(
      sceneLabel: longLabel,
      summary: String(repeating: "Food,", count: 30)
    )

    XCTAssertFalse(suggestions.isEmpty)
    XCTAssertTrue(suggestions.allSatisfy { $0.count <= RTMPSceneTitleSuggester.maxTitleLength })
    XCTAssertEqual(Set(suggestions).count, suggestions.count)
  }
}

final class RTMPLiveSceneContextBuilderTests: XCTestCase {

  func testMemoryTextIncludesLabelSummaryAndPlatform() {
    let text = RTMPLiveSceneContextBuilder.memoryText(
      sceneLabel: "Restaurant",
      summary: "Restaurant, Food",
      platformName: "Douyin (抖音)"
    )

    XCTAssertEqual(text, "直播场景：Restaurant（Restaurant, Food） · Douyin (抖音)")
  }

  func testMemoryTextWithoutPlatformOmitsSuffix() {
    let text = RTMPLiveSceneContextBuilder.memoryText(
      sceneLabel: "Park",
      summary: "Nature",
      platformName: nil
    )

    XCTAssertEqual(text, "直播场景：Park（Nature）")
  }

  func testMemoryTextWithSummaryOnly() {
    let text = RTMPLiveSceneContextBuilder.memoryText(
      sceneLabel: nil,
      summary: "Market"
    )

    XCTAssertEqual(text, "直播场景：Market")
  }

  func testMemoryTextIsNilWhenNothingDetected() {
    XCTAssertNil(RTMPLiveSceneContextBuilder.memoryText(sceneLabel: nil, summary: ""))
    XCTAssertNil(RTMPLiveSceneContextBuilder.memoryText(sceneLabel: " ", summary: "  "))
  }

  func testMemoryTextIsTruncated() {
    let text = RTMPLiveSceneContextBuilder.memoryText(
      sceneLabel: "Restaurant",
      summary: String(repeating: "Food,", count: 60)
    )

    XCTAssertNotNil(text)
    XCTAssertLessThanOrEqual(text!.count, RTMPLiveSceneContextBuilder.maxContextLength)
  }
}
