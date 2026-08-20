import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionAudioRouteTests: QwenVoiceSessionTestCase {
  func testVoiceFrontendUnavailableCancelsActivePlaybackAsPlaybackError() async {
    gateway.onEvent = { [weak session] event in
      session?.consume(event)
    }
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))
    XCTAssertTrue(session.isSpeaking)

    mockSocket.deliver([
      "type": "voice.connection",
      "state": "unavailable",
      "message": "provider unavailable"
    ])
    await waitUntil {
      if case .failed = self.session.connectionState { return true }
      return false
    }

    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")
  }

  func testAudioInterruptionBeganCancelsActivePlaybackAsPlaybackError() {
    gateway.connect()
    let captureGenerationBeforeInterruption = session.captureGeneration
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))
    XCTAssertTrue(session.isSpeaking)

    let startedAt = ProcessInfo.processInfo.systemUptime
    session.handleAudioInterruption(Notification(
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
      ]
    ))
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    let cancelled = !session.isSpeaking

    let attachment = XCTAttachment(
      string: "audioInterruptionCancelMs=\(cancelled ? String(elapsedMilliseconds) : "not_cancelled")"
    )
    attachment.name = "Qwen audio interruption cancellation latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertTrue(cancelled, "系统音频中断必须立即清除活动播放")
    XCTAssertEqual(
      session.captureGeneration,
      captureGenerationBeforeInterruption + 1,
      "系统中断必须同步停掉旧 VPIO 采集图"
    )
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 1)
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")
    if cancelled {
      XCTAssertLessThan(elapsedMilliseconds, 50)
    }

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r2"
    ))
    XCTAssertTrue(session.isSpeaking, "恢复后的下一响应不应要求重连 Qwen 会话")
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 2)
  }

  func testMediaServicesResetCancelsPlaybackAndKeepsSessionReusable() {
    gateway.connect()
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))

    session.handleMediaServicesReset()

    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 1)
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r2"
    ))
    XCTAssertTrue(session.isSpeaking)
  }

  func testAudioRouteRecoveryPolicySeparatesPhysicalFromSelfInitiatedChanges() {
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .newDeviceAvailable))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .oldDeviceUnavailable))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .wakeFromSleep))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .noSuitableRouteForCategory))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .routeConfigurationChange))

    XCTAssertFalse(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .unknown))
    XCTAssertFalse(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .categoryChange))
    XCTAssertFalse(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .override))
  }

  func testAudioRouteSettleWindowIsCoveredByRecoverySuppression() {
    XCTAssertEqual(QwenVoiceSession.audioRouteSettleNanoseconds, 750_000_000)
    XCTAssertGreaterThan(
      QwenVoiceSession.audioRouteConfigurationSuppressionInterval,
      Double(QwenVoiceSession.audioRouteSettleNanoseconds) / 1_000_000_000
    )
  }

  func testAudioEngineConfigurationChangeQuiescesCaptureBeforeRecovery() {
    let initialGeneration = session.captureGeneration
    session.consume(.voiceState(state: "listening"))

    session.handleAudioEngineConfigurationChange()

    XCTAssertEqual(session.captureGeneration, initialGeneration + 1)
    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 1)
  }

  func testAudioRouteRecoveryCoalescerRunsOneSettledRecoveryPerBurst() async {
    let settled = expectation(description: "settled route recovery")
    let coalescer = QwenAudioRouteRecoveryCoalescer(delayNanoseconds: 10_000_000)
    var immediateCount = 0
    var settledCount = 0

    coalescer.schedule(
      onFirst: { immediateCount += 1 },
      onSettled: {
        settledCount += 1
        settled.fulfill()
      }
    )
    coalescer.schedule(
      onFirst: { immediateCount += 1 },
      onSettled: {
        settledCount += 1
        settled.fulfill()
      }
    )

    XCTAssertEqual(immediateCount, 1)
    await fulfillment(of: [settled], timeout: 0.5)
    XCTAssertEqual(settledCount, 1)

    coalescer.schedule(
      onFirst: { immediateCount += 1 },
      onSettled: { settledCount += 1 }
    )
    coalescer.cancel()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(immediateCount, 2)
    XCTAssertEqual(settledCount, 1, "系统中断取消后不得执行迟到的路由恢复")
  }

  func testAudioCaptureRecoveryPolicyUsesBoundedLowLatencyBackoff() {
    let policy = QwenAudioCaptureRecoveryPolicy()

    XCTAssertEqual(policy.delay(forRetry: 1), 0.1)
    XCTAssertEqual(policy.delay(forRetry: 2), 0.25)
    XCTAssertEqual(policy.delay(forRetry: 3), 0.5)
    XCTAssertNil(policy.delay(forRetry: 0))
    XCTAssertNil(policy.delay(forRetry: 4))
  }

  func testAudioCaptureRecoverySchedulerAdvancesAndResetCancelsStaleWork() async {
    let scheduler = QwenAudioCaptureRecoveryScheduler(
      policy: QwenAudioCaptureRecoveryPolicy(retryDelays: [0.01, 0.015])
    )
    let firstRetry = expectation(description: "first capture retry")
    let secondRetry = expectation(description: "second capture retry")
    let startedAt = ProcessInfo.processInfo.systemUptime
    var firstRetryMilliseconds = 0.0
    var firedCount = 0

    XCTAssertTrue(scheduler.schedule {
      firstRetryMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      firedCount += 1
      firstRetry.fulfill()
    })
    await fulfillment(of: [firstRetry], timeout: 0.5)

    XCTAssertTrue(scheduler.schedule {
      firedCount += 1
      secondRetry.fulfill()
    })
    await fulfillment(of: [secondRetry], timeout: 0.5)
    XCTAssertFalse(scheduler.schedule { XCTFail("exhausted retry must not run") })

    let attachment = XCTAttachment(
      string: "captureRecoveryFirstRetryMs=\(firstRetryMilliseconds)"
    )
    attachment.name = "Qwen audio capture recovery retry latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(firedCount, 2)
    XCTAssertLessThan(firstRetryMilliseconds, 50)

    scheduler.reset()
    XCTAssertTrue(scheduler.schedule { firedCount += 1 })
    scheduler.reset()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(firedCount, 2, "reset 后迟到的采集恢复任务不得执行")
  }

  func testPhysicalAudioRouteChangeCancelsPlaybackCoalescesBurstAndKeepsSessionReusable() {
    gateway.connect()
    let captureGenerationBeforeRouteChange = session.captureGeneration
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))
    XCTAssertTrue(session.isSpeaking)

    let startedAt = ProcessInfo.processInfo.systemUptime
    session.handleAudioRouteChange(routeChangeNotification(reason: .oldDeviceUnavailable))
    XCTAssertEqual(session.captureGeneration, captureGenerationBeforeRouteChange + 1)
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    session.handleAudioRouteChange(routeChangeNotification(reason: .newDeviceAvailable))
    XCTAssertEqual(
      session.captureGeneration,
      captureGenerationBeforeRouteChange + 1,
      "同一路由突发只应拆除一次旧采集图"
    )
    let cancelled = !session.isSpeaking

    let attachment = XCTAttachment(
      string: "audioRouteChangeCancelMs=\(cancelled ? String(elapsedMilliseconds) : "not_cancelled")"
    )
    attachment.name = "Qwen physical audio route cancellation latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertTrue(cancelled, "物理音频路由变化必须立即清除旧路由上的播放")
    XCTAssertEqual(
      playbackPipeline.invalidateAudioSystemCallCount,
      1,
      "同一短突发只应同步失效一次播放图"
    )
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")
    if cancelled {
      XCTAssertLessThan(elapsedMilliseconds, 50)
    }

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r2"
    ))
    XCTAssertTrue(session.isSpeaking, "路由恢复后的下一响应不应要求重连 Qwen 会话")
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 2)
  }

  func testSelfInitiatedAudioRouteChangeDoesNotInvalidatePlayback() {
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))

    session.handleAudioRouteChange(routeChangeNotification(reason: .categoryChange))
    session.handleAudioRouteChange(routeChangeNotification(reason: .override))

    XCTAssertTrue(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 0)
  }

  func testRejectedAudioDoesNotClaimPlaybackStarted() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQ==", sampleRate: 24_000, responseId: "r1"))

    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 1)
    let playbackStarted = mockSocket.sentMessages.contains { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      return json["type"] as? String == "playback.started"
    }
    XCTAssertFalse(playbackStarted)
  }

  func testResponseStartedSendsPlaybackReceiptOnlyAfterAcceptedAudio() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(audioBase64: "AQ==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(playbackStartedMessages().isEmpty)

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    let messages = playbackStartedMessages()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?["responseId"] as? String, "r1")

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertEqual(playbackStartedMessages().count, 1)

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertEqual(
      playbackStartedMessages().compactMap { $0["responseId"] as? String },
      ["r1", "r2"]
    )
  }

  func testManualInterruptDropsAllAudioUntilResume() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    session.interrupt()

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertFalse(session.isSpeaking)

    session.resume()
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r3"))
    XCTAssertTrue(session.isSpeaking)
  }

  func testManualInterruptReportsUserInterruptionReason() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    session.interrupt()

    let cancellation = playbackCancelledMessages().last
    XCTAssertEqual(cancellation?["responseId"] as? String, "r1")
    XCTAssertEqual(cancellation?["reason"] as? String, "user_interruption")
    let wireTypes = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    let cancelledIndex = try? XCTUnwrap(wireTypes.lastIndex(of: "playback.cancelled"))
    let interruptIndex = try? XCTUnwrap(wireTypes.lastIndex(of: "interrupt"))
    if let cancelledIndex, let interruptIndex {
      XCTAssertLessThan(cancelledIndex, interruptIndex)
    }
  }

  func testPlaybackClearForwardsCancellationReason() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    session.consume(.playbackClear(reason: "desktop_hidden"))

    let cancellation = playbackCancelledMessages().last
    XCTAssertEqual(cancellation?["responseId"] as? String, "r1")
    XCTAssertEqual(cancellation?["reason"] as? String, "desktop_hidden")
  }

  private func playbackStartedMessages() -> [[String: Any]] {
    mockSocket.sentMessages.compactMap { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "playback.started"
      else { return nil }
      return json
    }
  }

  private func routeChangeNotification(
    reason: AVAudioSession.RouteChangeReason
  ) -> Notification {
    Notification(
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
    )
  }
}
