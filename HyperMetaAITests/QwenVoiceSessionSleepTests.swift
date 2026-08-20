import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionSleepTests: QwenVoiceSessionTestCase {
  // MARK: - 持续在场（Presence）

  func testPresenceSettingDefaultsOff() {
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
    XCTAssertFalse(AgentPresenceSettings.presenceEnabled)
    AgentPresenceSettings.presenceEnabled = true
    XCTAssertTrue(AgentPresenceSettings.presenceEnabled)
    AgentPresenceSettings.presenceEnabled = false
    XCTAssertFalse(AgentPresenceSettings.presenceEnabled)
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
  }

  func testShouldAutoEndIdleDefaultsTrue() {
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
    XCTAssertTrue(QwenVoiceSession.shouldAutoEndIdle)
  }

  func testShouldAutoEndIdleDisabledByPresence() {
    QwenVoiceSession.idleAutoEndEnabled = true
    AgentPresenceSettings.presenceEnabled = true
    XCTAssertFalse(QwenVoiceSession.shouldAutoEndIdle)
    AgentPresenceSettings.presenceEnabled = false
    XCTAssertTrue(QwenVoiceSession.shouldAutoEndIdle)
    QwenVoiceSession.idleAutoEndEnabled = false
    XCTAssertFalse(QwenVoiceSession.shouldAutoEndIdle)
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
  }

  // MARK: - 休眠 / 唤醒词

  /// 启动 socket 并同步标记会话 ready；控制帧只要求底层 socket 存活。

  private func startConnectedSession() {
    session.start()
    session.consume(.voiceReady(inputSampleRate: 16_000))
    XCTAssertEqual(session.connectionState, .connected)
  }

  func testClientStateSleepingEntersSleep() {
    QwenVoiceSession.wakeWordEnabled = false
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .sleeping)
  }

  func testVoiceSleepCapabilityDoesNotBecomeConnectionFailure() {
    session.consume(.voiceReady(inputSampleRate: 16_000))

    session.consume(.voiceSleep(state: "enabled"))

    XCTAssertEqual(session.connectionState, .connected)
    XCTAssertFalse(session.isSleeping)
    XCTAssertNil(AgentTurnErrorClassifier.classify(
      connectionState: session.connectionState
    ))
  }

  func testSleepTransitionStopsActivePlaybackWithinBudget() {
    QwenVoiceSession.wakeWordEnabled = false
    startConnectedSession()
    session.consume(.responseStarted(responseId: "sleep-response"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "sleep-response"
    ))
    XCTAssertTrue(session.isSpeaking)
    let interruptsBeforeSleep = playbackPipeline.interruptCallCount
    let startedAt = ProcessInfo.processInfo.systemUptime

    session.consume(.voiceSleep(state: "sleeping"))

    let elapsedMilliseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000
    print("[QwenSleepLatency] sleepTransitionAudioStopMs=\(elapsedMilliseconds)")
    let latencyAttachment = XCTAttachment(
      string: "sleepTransitionAudioStopMs=\(elapsedMilliseconds)"
    )
    latencyAttachment.name = "Qwen sleep audio stop latency"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)
    XCTAssertLessThan(elapsedMilliseconds, 10)
    XCTAssertTrue(session.isSleeping)
    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(String(describing: session.connectionState), "sleeping")
    XCTAssertEqual(playbackPipeline.interruptCallCount, interruptsBeforeSleep + 1)
  }

  func testWakeLifecycleKeepsWakingPriorityUntilProviderConnects() {
    QwenVoiceSession.wakeWordEnabled = false
    startConnectedSession()
    session.consume(.clientState(state: "sleeping"))
    XCTAssertEqual(String(describing: session.connectionState), "sleeping")

    session.wake()
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    let interruptsBeforeStaleSleep = playbackPipeline.interruptCallCount

    session.consume(.clientState(state: "sleeping"))
    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.consume(.voiceSleep(state: "sleeping"))
    session.consume(.clientState(state: "awake"))
    session.consume(.voiceSleep(state: "awake"))
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    XCTAssertEqual(playbackPipeline.interruptCallCount, interruptsBeforeStaleSleep)

    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(String(describing: session.connectionState), "waking")

    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)

    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.wake()
    session.consume(.voiceConnection(
      state: "sleeping",
      message: "wake provider unavailable"
    ))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(String(describing: session.connectionState), "sleeping")
  }

  func testRealtimeLifecycleKeepsUpstreamStatusPrecedenceAcrossLateEvents() {
    startConnectedSession()

    session.consume(.voiceConnection(
      state: "unavailable",
      message: "credential missing"
    ))
    session.consume(.voiceSleep(state: "detected"))
    session.consume(.clientState(state: "sleeping"))
    session.consume(.voiceReady(inputSampleRate: 16_000))
    guard case .failed(let message) = session.connectionState else {
      return XCTFail("unavailable must outrank waking, sleeping, and ready")
    }
    XCTAssertEqual(message, "credential missing")

    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)

    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.consume(.voiceReady(inputSampleRate: 16_000))
    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(session.connectionState, .sleeping)

    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.wake()
    session.consume(.voiceReady(inputSampleRate: 16_000))
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)
  }

  func testClientStateOtherDoesNotSleep() {
    session.consume(.clientState(state: "awake"))
    XCTAssertFalse(session.isSleeping)
  }

  func testWakeWordEnabledSleepStartsListening() {
    QwenVoiceSession.wakeWordEnabled = true
    let monitor = MockWakeWordMonitor()
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      wakeWordMonitorFactory: { monitor }
    )
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .listening)
  }

  func testRequestSleepSendsSleepEvent() async {
    startConnectedSession()
    session.requestSleep()
    let types = mockSocket.sentMessages.compactMap { text -> String? in
      guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertTrue(types.contains("sleep"))
    XCTAssertTrue(session.isSleeping)
  }

  func testWakeFromSleepSendsWakeEventAndResumes() async {
    startConnectedSession()
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    session.wake()
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .idle)
    let texts = mockSocket.sentMessages
    XCTAssertTrue(texts.contains { $0.contains("wake") })
  }

  func testWakeWordHitWakesSession() async {
    QwenVoiceSession.wakeWordEnabled = true
    let monitor = MockWakeWordMonitor()
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      wakeWordMonitorFactory: { monitor }
    )
    startConnectedSession()
    session.consume(.clientState(state: "sleeping"))
    XCTAssertEqual(session.wakeWordPhase, .listening)

    monitor.onWakeWord?("你好千问")
    await Task.yield()
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .idle)
    XCTAssertEqual(session.lastWakeWordText, "你好千问")
    let texts = mockSocket.sentMessages
    XCTAssertTrue(texts.contains { $0.contains("wake") })
  }

  func testWakeWordMonitorFailureFallsBackToSleeping() async {
    QwenVoiceSession.wakeWordEnabled = true
    let monitor = MockWakeWordMonitor()
    monitor.shouldFail = true
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      wakeWordMonitorFactory: { monitor }
    )
    session.consume(.clientState(state: "sleeping"))
    XCTAssertEqual(session.wakeWordPhase, .listening)
    // 等待异步启动失败回落（Task 需要调度机会）
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(session.wakeWordPhase, .sleeping)
    XCTAssertNotNil(session.wakeWordMonitorError)
  }
}
