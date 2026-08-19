import Foundation
import XCTest

@testable import HyperMetaAI

final class QwenGatewayModelsTests: XCTestCase {
  private func parse(_ json: [String: Any]) -> QwenGatewayEvent? {
    QwenGatewayEventParser.parse(json)
  }

  func testConnectPayload() {
    let payload = QwenGatewayClientEvent.connect(
      timeZone: "Asia/Shanghai",
      locale: "zh-Hans",
      clientType: "ios",
      clientLabel: "HyperMetaAI",
      clientInstanceId: "abc"
    )
    XCTAssertEqual(payload["type"] as? String, "connect")
    XCTAssertEqual(payload["timeZone"] as? String, "Asia/Shanghai")
    XCTAssertEqual(payload["locale"] as? String, "zh-Hans")
    XCTAssertEqual(payload["clientType"] as? String, "ios")
    XCTAssertEqual(payload["clientLabel"] as? String, "HyperMetaAI")
    XCTAssertEqual(payload["clientInstanceId"] as? String, "abc")
    XCTAssertEqual(payload["voiceEnabled"] as? Bool, true)
    XCTAssertEqual(payload["inputEnabled"] as? Bool, true)
    XCTAssertEqual(payload["outputEnabled"] as? Bool, true)
    XCTAssertEqual(payload["takeover"] as? Bool, false)
  }

  func testAudioAppendPayload() {
    let payload = QwenGatewayClientEvent.audioAppend(pcmBase64: "AQID")
    XCTAssertEqual(payload["type"] as? String, "audio.append")
    XCTAssertEqual(payload["audio"] as? String, "AQID")
  }

  func testImageAppendPayload() {
    let payload = QwenGatewayClientEvent.imageAppend(jpegBase64: "AQID")
    XCTAssertEqual(payload["type"] as? String, "image.append")
    XCTAssertEqual(payload["image"] as? String, "AQID")
    XCTAssertEqual(payload["mimeType"] as? String, "image/jpeg")
  }

  func testTextAndInterruptPayloads() {
    XCTAssertEqual(QwenGatewayClientEvent.textMessage("你好")["text"] as? String, "你好")
    XCTAssertEqual(QwenGatewayClientEvent.interrupt()["type"] as? String, "interrupt")
    XCTAssertNil(
      QwenGatewayClientEvent.interrupt()["playedMs"],
      "播放进度未知时不应带 playedMs，网关据此跳过 truncate"
    )
    XCTAssertEqual(QwenGatewayClientEvent.interrupt(playedMs: 0)["playedMs"] as? Int, 0)
    XCTAssertEqual(QwenGatewayClientEvent.interrupt(playedMs: 640)["playedMs"] as? Int, 640)
    XCTAssertNil(QwenGatewayClientEvent.interrupt(playedMs: -1)["playedMs"])
    XCTAssertEqual(QwenGatewayClientEvent.inputMute()["type"] as? String, "input.mute")
    XCTAssertEqual(QwenGatewayClientEvent.inputUnmute()["type"] as? String, "input.unmute")
  }

  func testPlaybackCancelledPayloadCarriesOptionalReason() {
    let interrupted = QwenGatewayClientEvent.playbackCancelled(
      responseId: "r1",
      reason: "user_interruption"
    )
    XCTAssertEqual(interrupted["type"] as? String, "playback.cancelled")
    XCTAssertEqual(interrupted["responseId"] as? String, "r1")
    XCTAssertEqual(interrupted["reason"] as? String, "user_interruption")

    let unspecified = QwenGatewayClientEvent.playbackCancelled(responseId: "r2")
    XCTAssertNil(unspecified["reason"])
  }

  func testParseVoiceReady() {
    XCTAssertEqual(
      parse(["type": "voice.ready", "inputSampleRate": 16_000]),
      .voiceReady(inputSampleRate: 16_000)
    )
  }

  func testParseVoiceConnection() {
    XCTAssertEqual(
      parse(["type": "voice.connection", "state": "connected"]),
      .voiceConnection(state: "connected", message: nil)
    )
    XCTAssertEqual(
      parse(["type": "voice.connection", "state": "unavailable", "message": "boom"]),
      .voiceConnection(state: "unavailable", message: "boom")
    )
  }

  func testParseAudioDeltaAndDone() {
    let receivedAt = 42.5
    let event = QwenGatewayEventParser.parse(
      ["type": "audio.delta", "audio": "AQIDBA==", "sampleRate": 24_000, "responseId": "r1"],
      receivedAt: receivedAt
    )
    guard case .audioChunk(let data, let sampleRate, let responseId, let timestamp) = event else {
      return XCTFail("audio.delta should be decoded at the protocol boundary")
    }
    XCTAssertEqual(data, Data([1, 2, 3, 4]))
    XCTAssertEqual(sampleRate, 24_000)
    XCTAssertEqual(responseId, "r1")
    XCTAssertEqual(timestamp, receivedAt)
    XCTAssertEqual(
      parse(["type": "audio.done", "responseId": "r1"]),
      .audioDone(responseId: "r1")
    )
  }

  func testParseAudioDeltaRejectsMissingEmptyAndMalformedPCM() {
    XCTAssertNil(parse(["type": "audio.delta"]))
    XCTAssertNil(parse(["type": "audio.delta", "audio": ""]))
    XCTAssertNil(parse(["type": "audio.delta", "audio": "%%%"] ))
  }

  func testParseResponseInterruptedPreservesResponseID() {
    XCTAssertEqual(
      parse(["type": "response.interrupted", "responseId": "r1"]),
      .responseInterrupted(responseId: "r1")
    )
    XCTAssertEqual(
      parse(["type": "response.interrupted"]),
      .responseInterrupted(responseId: nil)
    )
  }

  func testParseResponseStartedPreservesResponseID() {
    XCTAssertEqual(
      parse(["type": "response.started", "responseId": "r1"]),
      .responseStarted(responseId: "r1")
    )
  }

  func testParseTranscriptUsesContentField() {
    XCTAssertEqual(
      parse(["type": "transcript.delta", "role": "assistant", "content": "正在处理"]),
      .transcriptDelta(role: "assistant", text: "正在处理")
    )
    XCTAssertEqual(
      parse(["type": "transcript.final", "role": "user", "content": "帮我查天气"]),
      .transcriptFinal(role: "user", text: "帮我查天气")
    )
  }

  func testParseTaskDelegatedExtractsTitle() {
    let task: [String: Any] = [
      "id": "task-1",
      "delegation": [
        "presentation": ["speech": "好的，马上帮你处理"]
      ]
    ]
    XCTAssertEqual(
      parse(["type": "task.delegated", "task": task]),
      .task(type: "task.delegated", taskId: "task-1", title: "好的，马上帮你处理")
    )
  }

  func testParseTaskCompletedWithResultContent() {
    let task: [String: Any] = [
      "id": "task-2",
      "resultMetadata": [
        "presentation": ["inline": ["content": "任务完成"]]
      ]
    ]
    XCTAssertEqual(
      parse(["type": "task.completed", "task": task]),
      .task(type: "task.completed", taskId: "task-2", title: "任务完成")
    )
  }

  func testParseTaskWithoutTitle() {
    XCTAssertEqual(
      parse(["type": "task.running", "task": ["id": "t3"]]),
      .task(type: "task.running", taskId: "t3", title: nil)
    )
  }

  func testParseTimelineInline() {
    XCTAssertEqual(
      parse(["type": "timeline.inline", "item": ["taskId": "t1", "content": "结果摘要"]]),
      .timelineInline(taskId: "t1", content: "结果摘要")
    )
  }

  func testParseErrorAndUnknown() {
    XCTAssertEqual(
      parse(["type": "error", "message": "连接失败"]),
      .error(message: "连接失败")
    )
    XCTAssertEqual(
      parse(["type": "something.new"]),
      .unknown(type: "something.new")
    )
    XCTAssertNil(parse(["hello": "world"]))
  }

  func testParsePermissionRequested() {
    let event = parse([
      "type": "task.permission.requested",
      "task": ["id": "task-9"],
      "permission": [
        "id": "auth_1",
        "workId": "run_1",
        "status": "pending",
        "category": "run_command",
        "summary": "run_command：需要执行 shell 命令",
      ],
    ])
    XCTAssertEqual(
      event,
      .permissionRequested(
        taskId: "task-9",
        permission: QwenPermission(
          id: "auth_1",
          workId: "run_1",
          status: .pending,
          category: "run_command",
          summary: "run_command：需要执行 shell 命令"
        )
      )
    )
  }

  func testParsePermissionRequestedFallsBackToTaskAuthorization() {
    let event = parse([
      "type": "task.permission.requested",
      "task": [
        "id": "task-9",
        "authorization": [
          "id": "auth_2",
          "status": "pending",
          "summary": "需要访问通讯录",
        ],
      ],
    ])
    guard case .permissionRequested(let taskId, let permission) = event else {
      return XCTFail("应为 permissionRequested，实际 \(String(describing: event))")
    }
    XCTAssertEqual(taskId, "task-9")
    XCTAssertEqual(permission.id, "auth_2")
    XCTAssertEqual(permission.status, .pending)
    XCTAssertEqual(permission.summary, "需要访问通讯录")
    XCTAssertEqual(permission.category, "")
  }

  func testParsePermissionResolved() {
    let event = parse([
      "type": "task.permission.resolved",
      "permission": [
        "id": "auth_1",
        "status": "approved",
        "category": "run_command",
        "summary": "run_command",
      ],
    ])
    XCTAssertEqual(
      event,
      .permissionResolved(
        taskId: nil,
        permission: QwenPermission(
          id: "auth_1",
          workId: nil,
          status: .approved,
          category: "run_command",
          summary: "run_command"
        )
      )
    )
  }

  func testParsePermissionWithoutPayloadFallsBackToGenericTask() {
    XCTAssertEqual(
      parse(["type": "task.permission.requested", "task": ["id": "t1"]]),
      .task(type: "task.permission.requested", taskId: "t1", title: nil)
    )
  }

  func testParsePermissionHTTPResponseShape() {
    let permission = QwenGatewayEventParser.parsePermission([
      "id": "auth_1",
      "status": "denied",
      "category": "run_command",
      "summary": "run_command：rm -rf /",
    ])
    XCTAssertEqual(permission?.id, "auth_1")
    XCTAssertEqual(permission?.status, .denied)
    XCTAssertEqual(permission?.summary, "run_command：rm -rf /")
  }
}
