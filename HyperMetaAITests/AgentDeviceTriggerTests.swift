import Foundation
import XCTest
import MWDATCore

@testable import HyperMetaAI

final class AgentDeviceTriggerTests: XCTestCase {
  func testFirstTouchStartsSession() {
    var detector = AgentDeviceTriggerDetector()
    XCTAssertEqual(
      detector.consume(sessionState: .paused, isAppStopping: false),
      .tapStartSession
    )
    XCTAssertTrue(detector.isTouchSessionOpen)
  }

  func testSecondTouchEndsSession() {
    var detector = AgentDeviceTriggerDetector()
    _ = detector.consume(sessionState: .paused, isAppStopping: false)
    XCTAssertEqual(
      detector.consume(sessionState: .started, isAppStopping: false),
      .tapEndSession
    )
    XCTAssertFalse(detector.isTouchSessionOpen)
  }

  func testRepeatedPausedStateDoesNotCreateAnotherAppEvent() {
    var detector = AgentDeviceTriggerDetector()
    XCTAssertEqual(
      detector.consume(sessionState: .paused, isAppStopping: false),
      .tapStartSession
    )
    XCTAssertNil(
      detector.consume(sessionState: .paused, isAppStopping: false),
      "重复硬件状态不应生成暂停或重复开始事件"
    )
    XCTAssertTrue(detector.isTouchSessionOpen)
  }

  func testStartedWithoutPauseDoesNotEmit() {
    var detector = AgentDeviceTriggerDetector()
    XCTAssertNil(detector.consume(sessionState: .started, isAppStopping: false))
  }

  func testLongPressStopMapsToLongPressStop() {
    var detector = AgentDeviceTriggerDetector()
    XCTAssertEqual(
      detector.consume(sessionState: .stopped, isAppStopping: false),
      .longPressStop
    )
  }

  func testAppInitiatedStopDoesNotEmit() {
    var detector = AgentDeviceTriggerDetector()
    XCTAssertNil(detector.consume(sessionState: .stopped, isAppStopping: true))
    XCTAssertNil(detector.consume(sessionState: .paused, isAppStopping: true))
  }

  func testIntermediateStatesDoNotEmit() {
    var detector = AgentDeviceTriggerDetector()
    XCTAssertNil(detector.consume(sessionState: .idle, isAppStopping: false))
    XCTAssertNil(detector.consume(sessionState: .starting, isAppStopping: false))
    XCTAssertNil(detector.consume(sessionState: .stopping, isAppStopping: false))
  }

  func testMultipleTouchStartEndCycles() {
    var detector = AgentDeviceTriggerDetector()
    for _ in 0..<3 {
      XCTAssertEqual(
        detector.consume(sessionState: .paused, isAppStopping: false),
        .tapStartSession
      )
      XCTAssertEqual(
        detector.consume(sessionState: .started, isAppStopping: false),
        .tapEndSession
      )
    }
  }

  func testAppStopClearsTouchState() {
    var detector = AgentDeviceTriggerDetector()
    _ = detector.consume(sessionState: .paused, isAppStopping: false)
    XCTAssertNil(detector.consume(sessionState: .stopped, isAppStopping: true))
    // 之后一次真实的镜腿触控仍应正确触发
    XCTAssertEqual(
      detector.consume(sessionState: .paused, isAppStopping: false),
      .tapStartSession
    )
  }

  func testVoiceSettingsDefaultEnabled() {
    UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.replyEnabledKey)
    XCTAssertTrue(AgentVoiceSettings.replyEnabled)
    AgentVoiceSettings.replyEnabled = false
    XCTAssertFalse(AgentVoiceSettings.replyEnabled)
    UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.replyEnabledKey)
  }

  func testApprovalPromptSettingDefaultEnabled() {
    UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.approvalPromptEnabledKey)
    XCTAssertTrue(AgentVoiceSettings.approvalPromptEnabled)
    AgentVoiceSettings.approvalPromptEnabled = false
    XCTAssertFalse(AgentVoiceSettings.approvalPromptEnabled)
    UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.approvalPromptEnabledKey)
  }

  func testVoiceHistoryMemoryDefaultEnabled() {
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.voiceHistoryEnabledKey)
    XCTAssertTrue(AgentMemorySettings.voiceHistoryEnabled)
    AgentMemorySettings.voiceHistoryEnabled = false
    XCTAssertFalse(AgentMemorySettings.voiceHistoryEnabled)
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.voiceHistoryEnabledKey)
  }

  func testChatHistoryMemoryDefaultEnabled() {
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.chatHistoryEnabledKey)
    XCTAssertTrue(AgentMemorySettings.chatHistoryEnabled)
    AgentMemorySettings.chatHistoryEnabled = false
    XCTAssertFalse(AgentMemorySettings.chatHistoryEnabled)
    UserDefaults.standard.removeObject(forKey: AgentMemorySettings.chatHistoryEnabledKey)
  }

  func testVisionSettingsDefaultEnabled() {
    UserDefaults.standard.removeObject(forKey: AgentVisionSettings.injectionEnabledKey)
    XCTAssertTrue(AgentVisionSettings.injectionEnabled)
    AgentVisionSettings.injectionEnabled = false
    XCTAssertFalse(AgentVisionSettings.injectionEnabled)
    UserDefaults.standard.removeObject(forKey: AgentVisionSettings.injectionEnabledKey)
  }

  // MARK: - 设备意外结束检测

  func testUnexpectedEndWhenStoppedNotAppStopping() {
    XCTAssertTrue(
      AgentDeviceEndDetector.isUnexpectedEnd(sessionState: .stopped, isAppStopping: false),
      "设备自行停止（非 App 主动）应视为意外结束"
    )
  }

  func testNotUnexpectedEndWhenAppStopping() {
    XCTAssertFalse(
      AgentDeviceEndDetector.isUnexpectedEnd(sessionState: .stopped, isAppStopping: true),
      "App 主动停止会话不算意外结束"
    )
  }

  func testNotUnexpectedEndForOtherStates() {
    XCTAssertFalse(AgentDeviceEndDetector.isUnexpectedEnd(sessionState: .paused, isAppStopping: false))
    XCTAssertFalse(AgentDeviceEndDetector.isUnexpectedEnd(sessionState: .started, isAppStopping: false))
    XCTAssertFalse(AgentDeviceEndDetector.isUnexpectedEnd(sessionState: .idle, isAppStopping: false))
  }

  func testTimingSettingsDefaultsAndRoundtrip() {
    UserDefaults.standard.removeObject(forKey: AgentTimingSettings.approvalTimeoutKey)
    UserDefaults.standard.removeObject(forKey: AgentTimingSettings.thinkingHintDelayKey)
    XCTAssertEqual(AgentTimingSettings.approvalTimeout, 60)
    XCTAssertEqual(AgentTimingSettings.thinkingHintDelay, 8)

    AgentTimingSettings.approvalTimeout = 120
    AgentTimingSettings.thinkingHintDelay = 5
    XCTAssertEqual(AgentTimingSettings.approvalTimeout, 120)
    XCTAssertEqual(AgentTimingSettings.thinkingHintDelay, 5)

    AgentTimingSettings.approvalTimeout = 0
    XCTAssertEqual(AgentTimingSettings.approvalTimeout, 0, "0 表示不自动跳过")

    UserDefaults.standard.removeObject(forKey: AgentTimingSettings.approvalTimeoutKey)
    UserDefaults.standard.removeObject(forKey: AgentTimingSettings.thinkingHintDelayKey)
  }
}
