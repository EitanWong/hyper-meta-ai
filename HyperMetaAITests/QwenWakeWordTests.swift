import Foundation
import XCTest

@testable import HyperMetaAI

/// 语音唤醒词（「你好千问」）：
///   - 匹配器：变体命中、噪音不命中
///   - 状态机：idle → sleeping → listening → waking → idle 全流程与非法转换
final class QwenWakeWordTests: XCTestCase {
  // MARK: - Matcher

  func testMatchesPlainWakeWord() {
    XCTAssertTrue(QwenWakeWordMatcher().containsWakeWord(in: "你好千问"))
  }

  func testMatchesPunctuatedVariants() {
    let matcher = QwenWakeWordMatcher()
    XCTAssertTrue(matcher.containsWakeWord(in: "你好，千问"))
    XCTAssertTrue(matcher.containsWakeWord(in: "你好，千问！"))
    XCTAssertTrue(matcher.containsWakeWord(in: "嗨千问"))
  }

  func testMatchesWakeWordInsideSentence() {
    let matcher = QwenWakeWordMatcher()
    XCTAssertTrue(matcher.containsWakeWord(in: "你好千问，帮我查一下天气"))
    XCTAssertTrue(matcher.containsWakeWord(in: "现在 你好 千问 在吗"))
  }

  func testDoesNotMatchNoiseOrOtherPhrases() {
    let matcher = QwenWakeWordMatcher()
    XCTAssertFalse(matcher.containsWakeWord(in: "你好"))
    XCTAssertFalse(matcher.containsWakeWord(in: "今天天气怎么样"))
    XCTAssertFalse(matcher.containsWakeWord(in: ""))
    XCTAssertFalse(matcher.containsWakeWord(in: "，，，。。。"))
  }

  func testNormalizeStripsWhitespaceAndPunctuation() {
    XCTAssertEqual(QwenWakeWordMatcher.normalize("你好， 千问！"), "你好千问")
    XCTAssertEqual(QwenWakeWordMatcher.normalize("ABC-def"), "abcdef")
  }

  func testCustomKeywords() {
    let matcher = QwenWakeWordMatcher(keywords: ["Jarvis"])
    XCTAssertTrue(matcher.containsWakeWord(in: "Jarvis, are you there?"))
    XCTAssertFalse(matcher.containsWakeWord(in: "你好千问"))
  }

  // MARK: - State Machine

  func testFullWakeCycle() {
    var controller = QwenWakeSessionController()
    XCTAssertEqual(controller.phase, .idle)
    controller.enterSleep()
    XCTAssertEqual(controller.phase, .sleeping)
    controller.startListening()
    XCTAssertEqual(controller.phase, .listening)
    controller.matchWakeWord()
    XCTAssertEqual(controller.phase, .waking)
    controller.wakeCompleted()
    XCTAssertEqual(controller.phase, .idle)
  }

  func testIllegalTransitionsAreIgnored() {
    var controller = QwenWakeSessionController()
    // 未休眠时不能直接进入聆听
    controller.startListening()
    XCTAssertEqual(controller.phase, .idle)
    // 未聆听时不能命中唤醒词
    controller.enterSleep()
    controller.matchWakeWord()
    XCTAssertEqual(controller.phase, .sleeping)
  }

  func testListenStartFailureReturnsToSleeping() {
    var controller = QwenWakeSessionController()
    controller.enterSleep()
    controller.startListening()
    // 监听启动失败：直接从 listening 回落到 sleeping
    controller.wakeFailed()
    XCTAssertEqual(controller.phase, .sleeping)
  }

  func testWakeFailureReturnsToSleeping() {
    var controller = QwenWakeSessionController()
    controller.enterSleep()
    controller.startListening()
    controller.matchWakeWord()
    controller.wakeFailed()
    XCTAssertEqual(controller.phase, .sleeping)
    // 失败后可再次进入聆听（重试路径）
    controller.startListening()
    XCTAssertEqual(controller.phase, .listening)
  }

  func testWakeCompletedFromSleepingResets() {
    var controller = QwenWakeSessionController()
    controller.enterSleep()
    controller.wakeCompleted()
    XCTAssertEqual(controller.phase, .idle)
  }
}
