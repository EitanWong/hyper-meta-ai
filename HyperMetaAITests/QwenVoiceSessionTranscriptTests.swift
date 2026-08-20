import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionTranscriptTests: QwenVoiceSessionTestCase {
  // MARK: - Transcript Import

  func testImportCombinesTranscriptsAndResults() {
    let log = [
        QwenTranscriptItem(role: .user, text: "帮我查天气"),
        QwenTranscriptItem(role: .assistant, text: "好的")
    ]
    let feed = [
        QwenTaskFeedItem(kind: .delegated, taskId: "t1", text: "马上处理"),
        QwenTaskFeedItem(kind: .completed, taskId: "t1", text: "处理完成"),
        QwenTaskFeedItem(kind: .result, taskId: "t1", text: "结果摘要")
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: feed)

    XCTAssertTrue(importer.hasContent)
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 4)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertEqual(messages[0].text, "帮我查天气")
    XCTAssertEqual(messages[1].role, "assistant")
    XCTAssertEqual(messages[2].text, "处理完成")
    XCTAssertEqual(messages[3].text, "结果摘要")
  }

  func testImportOnlyResultsWhenNoTranscripts() {
    let feed = [
        QwenTaskFeedItem(kind: .completed, taskId: "t1", text: "完成")
    ]
    let importer = AgentTranscriptImport(transcriptLog: [], taskFeed: feed)
    XCTAssertTrue(importer.hasContent)
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0].role, "assistant")
  }

  func testImportEmptyHasNoContent() {
    let importer = AgentTranscriptImport(transcriptLog: [], taskFeed: [
        QwenTaskFeedItem(kind: .progress, taskId: "t1", text: "进行中")
    ])
    XCTAssertFalse(importer.hasContent)
    XCTAssertTrue(importer.makeMessages().isEmpty)
  }

  func testAudioDeltaMarksSpeakingAndInterruptStopsIt() {
    session.consume(.voiceReady(inputSampleRate: 16_000))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.consume(.responseInterrupted(responseId: "r1"))
    XCTAssertFalse(session.isSpeaking)
  }

  func testErrorEventIsPublished() {
    session.consume(.error(message: "连接失败"))
    XCTAssertEqual(session.errorMessage, "连接失败")
  }

  func testTranscriptFinalAppendsToLog() {
    session.consume(.transcriptDelta(role: "user", text: "帮我"))
    XCTAssertTrue(session.transcriptLog.isEmpty, "delta 不应写入日志")

    session.consume(.transcriptFinal(role: "user", text: "帮我查天气"))
    XCTAssertEqual(session.transcriptLog.count, 1)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].text, "帮我查天气")

    session.consume(.transcriptFinal(role: "assistant", text: "好的"))
    XCTAssertEqual(session.transcriptLog.count, 2)
    XCTAssertEqual(session.transcriptLog[1].role, .assistant)
  }

  func testVisualTranscriptRequestsOneOnDemandFrame() {
    var receivedIntent: AgentVisionIntent?
    session.onVisionRequest = { receivedIntent = $0 }

    session.consume(.transcriptFinal(role: "user", text: "我眼前是什么"))

    XCTAssertEqual(receivedIntent?.kind, .scene)
    XCTAssertEqual(receivedIntent?.prompt, "我眼前是什么")
  }

  func testOrdinaryTranscriptDoesNotRequestCamera() {
    var requestCount = 0
    session.onVisionRequest = { _ in requestCount += 1 }

    session.consume(.transcriptFinal(role: "user", text: "今天天气怎么样"))

    XCTAssertEqual(requestCount, 0)
  }

  func testEmptyTranscriptIsNotLogged() {
    session.consume(.transcriptFinal(role: "user", text: ""))
    XCTAssertTrue(session.transcriptLog.isEmpty)
  }

  func testClearTranscriptLog() {
    session.consume(.transcriptFinal(role: "user", text: "你好"))
    session.clearTranscriptLog()
    XCTAssertTrue(session.transcriptLog.isEmpty)
  }

  func testWakeAfterEndPreservesTranscript() {
    session.consume(.transcriptFinal(role: "user", text: "第一段"))
    session.endSession()
    XCTAssertFalse(session.isActive)

    session.wake()
    XCTAssertEqual(session.transcriptLog.count, 1, "唤醒重启会话不应清掉未保存转写")
    XCTAssertEqual(session.transcriptLog[0].text, "第一段")
  }

  func testAppendAssistantTextAddsTranscript() {
    session.appendAssistantText("  大脑回复  ")
    XCTAssertEqual(session.transcriptLog.count, 1)
    XCTAssertEqual(session.transcriptLog[0].role, .assistant)
    XCTAssertEqual(session.transcriptLog[0].text, "大脑回复")
    XCTAssertEqual(session.lastAssistantText, "大脑回复")
  }

  func testAppendUserTextAddsTranscriptAndOptionalLabel() {
    session.appendUserText("视野描述", label: "已发送")
    XCTAssertEqual(session.transcriptLog.count, 2)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].text, "视野描述")
    XCTAssertEqual(session.transcriptLog[1].role, .system)
    XCTAssertEqual(session.transcriptLog[1].text, "已发送")
  }

  func testOutputEnabledPassthrough() {
    XCTAssertTrue(session.outputEnabled)
    session.outputEnabled = false
    XCTAssertFalse(session.outputEnabled)
  }

  func testToggleInterruptSendsMuteThenUnmute() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.toggleInterrupt()
    await waitUntil { self.mockSocket.sentMessages.count >= 3 }

    let types = mockSocket.sentMessages.dropFirst().compactMap { message -> String? in
      try? json(from: message)["type"] as? String
    }
    XCTAssertEqual(types, ["interrupt", "input.mute"])

    session.toggleInterrupt()
    await waitUntil { self.mockSocket.sentMessages.count >= 4 }
    let lastType = try? json(from: mockSocket.sentMessages.last)["type"] as? String
    XCTAssertEqual(lastType, "input.unmute")
  }

  // MARK: - 视野注入（sendText）

  func testSendTextSendsTextMessageAndLogsTranscript() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.sendText("我当前看到：一只猫", label: "📷 已发送当前视野")

    let sent = mockSocket.sentMessages
    let textMessages = sent.compactMap { message -> String? in
        guard let type = try? json(from: message)["type"] as? String,
              type == "text.message" else { return nil }
        return try? json(from: message)["text"] as? String
    }
    XCTAssertEqual(textMessages, ["我当前看到：一只猫"])
    XCTAssertEqual(session.transcriptLog.count, 2)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].text, "我当前看到：一只猫")
    XCTAssertEqual(session.transcriptLog[1].role, .system)
    XCTAssertEqual(session.transcriptLog[1].text, "📷 已发送当前视野")
  }

  func testSendTextWithoutLabelLogsOnlyUserEntry() {
    session.sendText("帮我看看前面是什么")
    XCTAssertEqual(session.transcriptLog.count, 1)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
  }

  func testSendTextEmptyTextIsIgnored() {
    session.sendText("   ")
    XCTAssertTrue(mockSocket.sentMessages.isEmpty)
    XCTAssertTrue(session.transcriptLog.isEmpty)
  }

  func testImportSkipsSystemEntries() {
    let log = [
      QwenTranscriptItem(role: .user, text: "我当前看到：一只猫"),
      QwenTranscriptItem(role: .system, text: "📷 已发送当前视野"),
      QwenTranscriptItem(role: .assistant, text: "你看到一只猫"),
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: [])
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertEqual(messages[0].text, "我当前看到：一只猫")
    XCTAssertEqual(messages[1].role, "assistant")
  }

  // MARK: - 视野上下文标记

  func testVisionContextImportGetsSceneTag() {
    let log = [
      QwenTranscriptItem(role: .user, text: "我当前看到：一只猫", kind: .vision),
      QwenTranscriptItem(role: .assistant, text: "你看到一只猫"),
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: [])
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertTrue(messages[0].isVisionContext)
    XCTAssertTrue(
      messages[0].text.hasPrefix("agent.vision.scene.tag".localized),
      "视野条目应带 [📷 场景] 前缀，实际: \(messages[0].text)"
    )
    XCTAssertEqual(messages[0].text, "agent.vision.scene.tag".localized + "我当前看到：一只猫")
    XCTAssertFalse(messages[1].isVisionContext)
    XCTAssertEqual(messages[1].text, "你看到一只猫")
  }

  func testNormalTranscriptHasNoSceneTag() {
    let log = [
      QwenTranscriptItem(role: .user, text: "帮我查天气"),
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: [])
    let messages = importer.makeMessages()
    XCTAssertEqual(messages[0].text, "帮我查天气")
    XCTAssertFalse(messages[0].isVisionContext)
  }

  func testSendTextWithVisionKind() {
    session.sendText("我当前看到：一只猫", label: "📷 已发送当前视野", kind: .vision)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].kind, .vision)
    XCTAssertEqual(session.transcriptLog[1].role, .system)
  }

  func testAppendUserTextWithVisionKind() {
    session.appendUserText("我当前看到：一只猫", label: "📷 已发送当前视野", kind: .vision)
    XCTAssertEqual(session.transcriptLog[0].kind, .vision)
  }
}
