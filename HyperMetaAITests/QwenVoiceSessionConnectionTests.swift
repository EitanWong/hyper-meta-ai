import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionConnectionTests: QwenVoiceSessionTestCase {
  func testProviderTurnStateDoesNotConflateCaptureWithSpeech() {
    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)

    session.consume(.voiceState(state: "listening"))
    XCTAssertEqual(session.providerVoiceState, "listening")
    XCTAssertTrue(session.isInputActive)

    session.consume(.voiceState(state: "thinking"))
    XCTAssertEqual(session.providerVoiceState, "thinking")
    XCTAssertFalse(session.isInputActive)

    session.consume(.voiceState(state: "idle"))
    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)
  }

  func testTransportRecoveryClearsAnActiveSpeechTurn() {
    session.consume(.voiceState(state: "listening"))

    session.consume(.gatewayReconnecting(attempt: 1, maxAttempts: 5))

    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)
  }

  func testVoiceReadyUpdatesConnectionState() {
    session.consume(.voiceReady(inputSampleRate: 16_000))
    XCTAssertEqual(session.connectionState, .connected)
  }

  // MARK: - 断线自动重连

  func testGatewayReconnectingUpdatesState() {
    session.consume(.gatewayReconnecting(attempt: 2, maxAttempts: 5))
    XCTAssertEqual(session.connectionState, .connecting)
    XCTAssertEqual(session.reconnectAttempt, 2)
    XCTAssertEqual(session.reconnectMaxAttempts, 5)
  }

  func testGatewayReconnectFailedShowsError() {
    session.consume(.gatewayReconnecting(attempt: 1, maxAttempts: 5))
    session.consume(.gatewayReconnectFailed)
    XCTAssertNil(session.reconnectAttempt)
    guard case .failed = session.connectionState else {
      return XCTFail("重连失败后应为 failed 状态")
    }
  }

  func testGatewayDisconnectedClearsReconnectAttempt() {
    session.consume(.gatewayReconnecting(attempt: 1, maxAttempts: 5))
    session.consume(.gatewayDisconnected)
    XCTAssertNil(session.reconnectAttempt)
  }

  func testProviderReconnectLifecycleClearsFailureAndGatewayAttempt() {
    session.consume(.gatewayReconnecting(attempt: 2, maxAttempts: 5))
    session.consume(.voiceConnection(
      state: "unavailable",
      message: "provider temporarily unavailable"
    ))
    guard case .failed(let message) = session.connectionState else {
      return XCTFail("Provider unavailability must be surfaced")
    }
    XCTAssertEqual(message, "provider temporarily unavailable")

    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(session.connectionState, .connecting)

    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)
    XCTAssertNil(session.reconnectAttempt)
    XCTAssertNil(session.errorMessage)
  }

  // MARK: - Idle Timeout

  func testIdleMonitorTimesOutAfterInterval() {
    var monitor = QwenIdleTimeoutMonitor(timeout: 2)
    let start = Date()
    XCTAssertFalse(monitor.hasTimedOut(at: start.addingTimeInterval(1)))
    XCTAssertTrue(monitor.hasTimedOut(at: start.addingTimeInterval(2.1)))
  }

  func testIdleMonitorActivityResetsTimer() {
    var monitor = QwenIdleTimeoutMonitor(timeout: 2)
    let start = Date()
    monitor.recordActivity(at: start.addingTimeInterval(1.5))
    XCTAssertFalse(monitor.hasTimedOut(at: start.addingTimeInterval(3.4)))
    XCTAssertTrue(monitor.hasTimedOut(at: start.addingTimeInterval(3.6)))
  }

  func testIdleAutoEndSettingDefaultsEnabled() {
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
    XCTAssertTrue(QwenVoiceSession.idleAutoEndEnabled)
    QwenVoiceSession.idleAutoEndEnabled = false
    XCTAssertFalse(QwenVoiceSession.idleAutoEndEnabled)
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
  }
}
