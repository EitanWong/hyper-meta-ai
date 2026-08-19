import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionBargeInTests: QwenVoiceSessionTestCase {
  // MARK: - Barge-in（本地能量检测打断）

  func testBargeInDetectorRequiresSustainedEnergy() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "单次 0.128s 高能量不足")
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 2048), "累计 0.256s 触发")
    XCTAssertFalse(detector.consume(rms: 0.9, sampleCount: 2048), "触发后幂等")
  }

  func testBargeInDetectorShortGapsDoNotFullyReset() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "0.128s 不足")
    XCTAssertFalse(detector.consume(rms: 0.0, sampleCount: 2048), "间隙只衰减一半")
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "0.128+0.064 仍不足")
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 2048), "累计超过阈值触发")
  }

  func testBargeInDetectorResetClearsTrigger() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    _ = detector.consume(rms: 0.05, sampleCount: 2048)
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 2048))
    detector.reset()
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "reset 后重新累计")
  }

  func testBargeInDetectorHighConfidenceSpeechTriggersWithinFortyMilliseconds() {
    var detector = BargeInDetector()
    XCTAssertFalse(detector.consume(rms: 0.15, sampleCount: 320), "20ms 不应由单帧触发")
    let triggered = detector.consume(rms: 0.15, sampleCount: 320)

    let attachment = XCTAttachment(
      string: "fastBargeInAudioMs=\(triggered ? "40.0" : "not_triggered")"
    )
    attachment.name = "Qwen high-confidence barge-in audio latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertTrue(triggered, "高置信近讲语音应在连续 40ms 内触发")
  }

  func testCaptureBargeInGateUsesRawCaptureDurationBeforeNetworkDelivery() {
    let gate = QwenCaptureBargeInGate()
    let token = gate.arm()
    let twentyMilliseconds = RealtimeCapturedAudioFrameStats(
      rms: 0.15,
      sampleCount: 960,
      sampleRate: 48_000
    )

    XCTAssertNil(gate.consume(twentyMilliseconds))
    XCTAssertEqual(gate.consume(twentyMilliseconds), token)
    XCTAssertNil(gate.consume(twentyMilliseconds), "每次 arm 只触发一次")
  }

  func testCaptureBargeInGateRejectsStaleAndDisarmedSignals() {
    let gate = QwenCaptureBargeInGate()
    let twentyMilliseconds = RealtimeCapturedAudioFrameStats(
      rms: 0.15,
      sampleCount: 320,
      sampleRate: 16_000
    )

    let staleToken = gate.arm()
    XCTAssertNil(gate.consume(twentyMilliseconds))
    gate.disarm()
    XCTAssertNil(gate.consume(twentyMilliseconds))

    let currentToken = gate.arm()
    XCTAssertNotEqual(staleToken, currentToken)
    XCTAssertNil(gate.consume(twentyMilliseconds))
    XCTAssertEqual(gate.consume(twentyMilliseconds), currentToken)
  }

  func testBargeInDetectorLoudTransientDoesNotCarryAcrossModerateSpeech() {
    var detector = BargeInDetector()
    XCTAssertFalse(detector.consume(rms: 0.15, sampleCount: 320), "单个 20ms 高能量瞬态不足")
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 320), "普通语音帧应清除快速路径累计")
    XCTAssertFalse(detector.consume(rms: 0.15, sampleCount: 320), "新的高能量帧应从 20ms 重新累计")
  }

  func testBargeInDetectorModerateSpeechKeepsStandardWindow() {
    var detector = BargeInDetector()
    for _ in 0..<5 {
      XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 320))
    }
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 320), "普通语音仍需累计 120ms")
  }

  func testBargeInDetectorZeroDurationStillRequiresCurrentEnergy() {
    var detector = BargeInDetector(minimumDuration: 0)
    XCTAssertFalse(detector.consume(rms: 0, sampleCount: 320))
    XCTAssertTrue(detector.consume(rms: 0.02, sampleCount: 320))
  }

  func testCancelledResponseRegistryEvictsOldestIdentifier() {
    var registry = QwenCancelledResponseRegistry(capacity: 2)
    registry.insert("r1")
    registry.insert("r2")
    registry.insert("r3")

    XCTAssertFalse(registry.contains("r1"))
    XCTAssertTrue(registry.contains("r2"))
    XCTAssertTrue(registry.contains("r3"))
  }

  func testResponseOutputGateBlocksUncorrelatedAudioAfterCancellation() {
    var gate = QwenResponseOutputGate()
    gate.markCancelled()

    XCTAssertFalse(gate.acceptAudio(hasResponseID: false))
    XCTAssertTrue(gate.acceptAudio(hasResponseID: true))
    XCTAssertTrue(gate.acceptsTerminal(hasResponseID: false))
  }

  func testAudioBurstConsumptionKeepsMainActorWithinPerPacketBudget() {
    let packetCount = 10_000
    let packet = Data(repeating: 7, count: 1_920).base64EncodedString()
    let events = (0..<packetCount).map { _ in
      QwenGatewayEvent.audioDelta(
        audioBase64: packet,
        sampleRate: 24_000,
        responseId: "burst"
      )
    }
    session.consume(.responseStarted(responseId: "burst"))

    let startedAt = ProcessInfo.processInfo.systemUptime
    for event in events {
      session.consume(event)
    }
    let averageMicroseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000_000 / Double(packetCount)
    let attachment = XCTAttachment(
      string: "mainActorAudioConsumeAverageUs=\(averageMicroseconds)"
    )
    attachment.name = "Qwen MainActor audio burst consumption latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(playbackPipeline.enqueueCallCount, packetCount)
    XCTAssertLessThan(averageMicroseconds, 2)
  }

  func testAudioChunkPreservesGatewayReceiveTimeIntoPlaybackPipeline() {
    let receivedAt = 42.5
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1",
      receivedAt: receivedAt
    ))

    XCTAssertEqual(playbackPipeline.lastReceivedAt, receivedAt)
  }

  func testBargeInStopsPlaybackWithoutMutingInput() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.bargeIn()
    XCTAssertFalse(session.isSpeaking)

    let types = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertTrue(types.contains("interrupt"), "应发送 interrupt 停止播报")
    XCTAssertFalse(types.contains("input.mute"), "barge-in 不应静音输入，网关需继续听")
  }

  func testBargeInDropsLateCancelledResponseEventsWithoutStoppingNextResponse() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.bargeIn()
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertFalse(session.isSpeaking, "已取消响应的迟到音频不应恢复播放")

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertTrue(session.isSpeaking, "新响应应正常播放")

    session.consume(.audioDone(responseId: "r1"))
    session.consume(.responseInterrupted(responseId: "r1"))
    XCTAssertTrue(session.isSpeaking, "旧响应终态不应结束新响应")

    session.consume(.responseInterrupted(responseId: "r2"))
    XCTAssertFalse(session.isSpeaking)
  }

  func testResponseStartedSupersedesTheActiveResponseBeforeItsFirstAudio() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.consume(.responseStarted(responseId: "r2"))
    XCTAssertFalse(session.isSpeaking)

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertFalse(session.isSpeaking, "被 supersede 的 response 不应重新开始播放")
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertTrue(session.isSpeaking)
  }

  func testUncorrelatedLateAudioStaysBlockedUntilNextResponseStarts() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: nil))
    XCTAssertTrue(session.isSpeaking)

    session.bargeIn()
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: nil))
    XCTAssertFalse(session.isSpeaking, "取消后的无 responseId 音频不应复活旧播报")

    session.consume(.responseStarted(responseId: nil))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: nil))
    XCTAssertTrue(session.isSpeaking, "明确的新 response 生命周期允许无 ID 音频")
  }

  func testGatewayDisconnectStopsPlaybackAndBlocksLateAudio() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.consume(.gatewayDisconnected)
    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.interruptCallCount, 1)
    XCTAssertEqual(playbackPipeline.stopCallCount, 0)
    XCTAssertTrue(playbackPipeline.isActive)
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertFalse(session.isSpeaking, "传输丢失后的任何排队音频都必须等待新 response 生命周期")

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertTrue(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 2)
  }

  func testBargeInForwardsActuallyPlayedMillisecondsSoServerCanTruncate() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    playbackPipeline.playedMillisecondsOnInterrupt = 820
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    session.bargeIn()

    XCTAssertEqual(interruptMessages().last?["playedMs"] as? Int, 820)
  }

  func testBargeInDuringThinkingCancelsTheResponseBeingGenerated() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    // thinking：服务端已收到用户上一句、正在生成，但首个音频块还没到。
    session.consume(.voiceState(state: "thinking"))
    XCTAssertFalse(session.isSpeaking)

    session.bargeIn()

    XCTAssertEqual(interruptMessages().count, 1, "thinking 阶段也必须能打断")
    XCTAssertEqual(playbackPipeline.interruptCallCount, 1)
  }

  func testProviderTurnStartDuringThinkingAlsoCancelsTheResponse() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.voiceState(state: "thinking"))

    session.consume(.turnStarted(turnId: "user-turn"))

    XCTAssertEqual(interruptMessages().count, 1)
  }

  func testServerInitiatedCancellationDoesNotEchoAnInterruptBack() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    session.consume(.responseInterrupted(responseId: "r1"))

    XCTAssertFalse(session.isSpeaking)
    XCTAssertTrue(
      interruptMessages().isEmpty,
      "服务端自己取消的回复，客户端不应再回发 interrupt/truncate"
    )
  }

  private func interruptMessages() -> [[String: Any]] {
    mockSocket.sentMessages.compactMap { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "interrupt"
      else { return nil }
      return json
    }
  }

  func testBargeInWithoutSpeakingIsNoOp() {
    session.bargeIn()
    XCTAssertFalse(session.isSpeaking)
    let types = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertFalse(types.contains("interrupt"))
  }

  func testProviderVADAlsoInterruptsActivePlayback() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    session.consume(.turnStarted(turnId: "user-turn"))

    XCTAssertFalse(session.isSpeaking)
    let types = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertTrue(types.contains("interrupt"))
    XCTAssertEqual(
      playbackCancelledMessages().last?["reason"] as? String,
      "user_interruption"
    )
  }

  func testRmsEnergyComputesNormalizedValue() {
    let silence = Data(repeating: 0, count: 64)
    XCTAssertEqual(QwenVoiceSession.rmsEnergy(silence), 0)

    var fullScale = Data()
    for _ in 0..<8 {
      var value = Int16.max
      withUnsafeBytes(of: &value) { fullScale.append(contentsOf: $0) }
    }
    XCTAssertEqual(QwenVoiceSession.rmsEnergy(fullScale), 1.0, accuracy: 0.01)
  }

  func testOrbInputLevelAmplifiesAndClampsRms() {
    XCTAssertEqual(QwenVoiceSession.orbInputLevel(rms: -0.1), 0)
    XCTAssertEqual(QwenVoiceSession.orbInputLevel(rms: 0.05), 0.4, accuracy: 0.001)
    XCTAssertEqual(QwenVoiceSession.orbInputLevel(rms: 0.25), 1)
  }
}
