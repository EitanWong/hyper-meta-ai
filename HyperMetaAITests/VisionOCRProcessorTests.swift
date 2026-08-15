import XCTest
@testable import HyperMetaAI

final class VisionOCRTextProcessorTests: XCTestCase {

  func testNormalizeLineCollapsesWhitespace() {
    XCTAssertEqual(VisionOCRTextProcessor.normalizeLine("   Hello   World  "), "Hello World")
    XCTAssertEqual(VisionOCRTextProcessor.normalizeLine(""), "")
    XCTAssertEqual(VisionOCRTextProcessor.normalizeLine("  \n  "), "")
  }

  func testNormalizedTextDropsEmptyLines() {
    let result = VisionOCRTextProcessor.normalizedText(from: ["   ", "第一行", "", "第二行"])
    XCTAssertEqual(result, "第一行\n第二行")
  }

  func testNormalizedTextDeduplicatesConsecutiveLines() {
    let result = VisionOCRTextProcessor.normalizedText(from: ["重复行", "重复行", "第二行"])
    XCTAssertEqual(result, "重复行\n第二行")
  }

  func testNormalizedTextPreservesNonConsecutiveDuplicates() {
    let result = VisionOCRTextProcessor.normalizedText(from: ["甲", "乙", "甲"])
    XCTAssertEqual(result, "甲\n乙\n甲")
  }

  func testNormalizedTextRespectsMaxLength() {
    let long = (0..<100).map { "行\($0)" }
    let result = VisionOCRTextProcessor.normalizedText(from: long, maxLength: 20)
    XCTAssertLessThanOrEqual(result.count, 20)
    XCTAssertTrue(result.hasPrefix("行0"))
  }

  func testDisplayTextCollapsesNewlines() {
    XCTAssertEqual(
      VisionOCRTextProcessor.displayText(from: "第一行\n第二行\n第三行"),
      "第一行 第二行 第三行"
    )
  }

  func testDisplayTextShortPassesThrough() {
    XCTAssertEqual(VisionOCRTextProcessor.displayText(from: "你好世界"), "你好世界")
  }

  func testDisplayTextTruncatesWithEllipsis() {
    let long = String(repeating: "字", count: 200)
    let result = VisionOCRTextProcessor.displayText(from: long, maxLength: 10)
    XCTAssertEqual(result, "字字字字字字字字字字…")
    XCTAssertEqual(result.count, 11)
  }
}

final class VisionOCRServiceTests: XCTestCase {

  /// 集成验证：用 UIKit 渲染一段文字，端侧 OCR 应能识别出关键词（模拟器可跑）
  func testRecognizeTextOnRenderedImage() async {
    let image = makeTextImage("HELLO WORLD 123")
    let text = await VisionOCRService.recognizedText(in: image)
    XCTAssertTrue(
      text.uppercased().contains("HELLO"),
      "OCR 应识别出渲染的文字，实际: \(text)"
    )
  }

  func testRecognizeEmptyImageReturnsEmpty() async {
    let image = makeBlankImage()
    let lines = await VisionOCRService.recognizeText(in: image)
    XCTAssertTrue(lines.isEmpty)
  }

  private func makeTextImage(_ text: String) -> UIImage {
    let size = CGSize(width: 600, height: 200)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 48),
        .foregroundColor: UIColor.black,
      ]
      let nsText = text as NSString
      nsText.draw(at: CGPoint(x: 40, y: 70), withAttributes: attributes)
    }
  }

  private func makeBlankImage() -> UIImage {
    let size = CGSize(width: 200, height: 100)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
  }
}

final class VisionTranslationPlannerTests: XCTestCase {

  func testContainsCJK() {
    XCTAssertTrue(VisionTranslationPlanner.containsCJK("你好世界"))
    XCTAssertTrue(VisionTranslationPlanner.containsCJK("Hello 你好"))
    XCTAssertTrue(VisionTranslationPlanner.containsCJK("こんにちは"))
    XCTAssertTrue(VisionTranslationPlanner.containsCJK("안녕하세요"))
    XCTAssertFalse(VisionTranslationPlanner.containsCJK("Hello World"))
    XCTAssertFalse(VisionTranslationPlanner.containsCJK("123"))
    XCTAssertFalse(VisionTranslationPlanner.containsCJK(""))
  }

  func testTargetLanguageDirection() {
    XCTAssertEqual(
      VisionTranslationPlanner.targetLanguage(for: "菜单上的价格"),
      Locale.Language(identifier: "en")
    )
    XCTAssertEqual(
      VisionTranslationPlanner.targetLanguage(for: "Lunch menu with prices"),
      Locale.Language(identifier: "zh-Hans")
    )
    XCTAssertEqual(
      VisionTranslationPlanner.targetLanguage(for: "おすすめランチ"),
      Locale.Language(identifier: "en")
    )
  }
}

final class AgentVisionOCRStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AgentVisionOCRStore.clear()
  }

  override func tearDown() {
    AgentVisionOCRStore.clear()
    super.tearDown()
  }

  func testSetAndClear() {
    XCTAssertNil(AgentVisionOCRStore.lastText)
    AgentVisionOCRStore.set("菜单")
    XCTAssertEqual(AgentVisionOCRStore.lastText, "菜单")
    XCTAssertNotNil(AgentVisionOCRStore.lastDate)
    AgentVisionOCRStore.clear()
    XCTAssertNil(AgentVisionOCRStore.lastText)
  }

  func testTranslateInstructionCarriesTextAndTarget() {
    let cjk = VisionTranslationPlanner.translateInstruction(for: "菜单上的价格")
    XCTAssertTrue(cjk.contains("菜单上的价格"))
    XCTAssertTrue(cjk.contains("English"))

    let latin = VisionTranslationPlanner.translateInstruction(for: "Lunch menu")
    XCTAssertTrue(latin.contains("Lunch menu"))
    XCTAssertTrue(latin.contains("中文"))
  }
}
