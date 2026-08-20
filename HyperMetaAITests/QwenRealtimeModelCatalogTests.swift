import Foundation
import XCTest

@testable import HyperMetaAI

/// QwenRealtimeModelCatalog：镜像 qwen-audio-agent v1.10.1 的 DashScope Realtime 模型档案
final class QwenRealtimeModelCatalogTests: XCTestCase {
  private let defaultsKey = QwenRealtimeModelCatalog.userDefaultsKey
  private var savedModelID: String?

  override func setUp() {
    super.setUp()
    savedModelID = UserDefaults.standard.string(forKey: defaultsKey)
  }

  override func tearDown() {
    if let savedModelID {
      UserDefaults.standard.set(savedModelID, forKey: defaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
    super.tearDown()
  }

  func testDefaultModelIsLatestAudioPlus() {
    XCTAssertEqual(QwenRealtimeModelCatalog.defaultModelID, "qwen-audio-3.0-realtime-plus")
    XCTAssertEqual(QwenRealtimeModelCatalog.defaultProfile.id, "qwen-audio-3.0-realtime-plus")
    XCTAssertEqual(QwenRealtimeModelCatalog.defaultProfile.family, .audio)
    XCTAssertTrue(QwenRealtimeModelCatalog.defaultProfile.isDefault)
    XCTAssertEqual(QwenRealtimeModelCatalog.defaultProfile.defaultVoice, "longanqian")
    XCTAssertEqual(QwenRealtimeModelCatalog.defaultProfile.turnDetectionType, "smart_turn")
  }

  func testCatalogContainsLatestModelLineup() {
    let ids = QwenRealtimeModelCatalog.all.map(\.id)
    XCTAssertEqual(ids, [
      "qwen-audio-3.0-realtime-plus",
      "qwen-audio-3.0-realtime-flash",
      "qwen3.5-omni-flash-realtime",
      "qwen3.5-omni-plus-realtime",
    ])
    XCTAssertEqual(QwenAudioAgentUpstream.releaseTag, "v1.10.1")
    XCTAssertEqual(
      QwenAudioAgentUpstream.commit,
      "1dea8779e73d9e1aaebfd8c6a847270cce39572f"
    )
  }

  func testOmniProfilesSupportImageInput() {
    for profile in QwenRealtimeModelCatalog.profiles(family: .omni) {
      XCTAssertTrue(profile.supportsImageInput, "\(profile.id) 应支持图像输入")
      XCTAssertFalse(profile.transportSupportsImageInput)
      XCTAssertTrue(profile.supportsFunctionCalling)
      XCTAssertEqual(profile.defaultVoice, "Ethan")
      XCTAssertEqual(profile.turnDetectionType, "semantic_vad")
    }
  }

  func testAudioProfilesArePureVoice() {
    for profile in QwenRealtimeModelCatalog.profiles(family: .audio) {
      XCTAssertFalse(profile.supportsImageInput, "\(profile.id) 应为纯语音")
      XCTAssertFalse(profile.transportSupportsImageInput)
      XCTAssertEqual(profile.inputSampleRate, 16_000)
      XCTAssertEqual(profile.outputSampleRate, 24_000)
    }
  }

  func testResolveUnknownFallsBackToDefault() {
    XCTAssertEqual(QwenRealtimeModelCatalog.resolve(nil).id, QwenRealtimeModelCatalog.defaultModelID)
    XCTAssertEqual(QwenRealtimeModelCatalog.resolve("").id, QwenRealtimeModelCatalog.defaultModelID)
    XCTAssertEqual(QwenRealtimeModelCatalog.resolve("not-a-model").id, QwenRealtimeModelCatalog.defaultModelID)
  }

  func testResolveKnownModel() {
    XCTAssertEqual(QwenRealtimeModelCatalog.resolve("qwen3.5-omni-plus-realtime").family, .omni)
    XCTAssertEqual(QwenRealtimeModelCatalog.resolve("qwen-audio-3.0-realtime-flash").family, .audio)
  }

  func testSelectedPersistsAndFallsBack() {
    QwenRealtimeModelCatalog.setSelected("qwen3.5-omni-flash-realtime")
    XCTAssertEqual(QwenRealtimeModelCatalog.selected.id, "qwen3.5-omni-flash-realtime")
    QwenRealtimeModelCatalog.setSelected("expired-model")
    XCTAssertEqual(QwenRealtimeModelCatalog.selected.id, QwenRealtimeModelCatalog.defaultModelID)
  }

  func testResolveForFamilyUsesUserChoiceWhenFamilyMatches() {
    QwenRealtimeModelCatalog.setSelected("qwen-audio-3.0-realtime-flash")
    XCTAssertEqual(QwenRealtimeModelCatalog.resolveForFamily(.audio).id, "qwen-audio-3.0-realtime-flash")
  }

  func testResolveForFamilyFallsBackToOmniWhenUserChoseAudio() {
    QwenRealtimeModelCatalog.setSelected("qwen-audio-3.0-realtime-plus")
    let resolved = QwenRealtimeModelCatalog.resolveForFamily(.omni)
    XCTAssertEqual(resolved.family, .omni)
    XCTAssertFalse(resolved.displayName.contains("旧"))
    XCTAssertTrue(resolved.supportsImageInput)
  }

  func testAudioAndOmniVoiceOverridesAreIndependent() throws {
    let suiteName = "QwenRealtimeModelCatalogTests.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let audio = try XCTUnwrap(QwenRealtimeModelCatalog.profiles(family: .audio).first)
    let omni = try XCTUnwrap(QwenRealtimeModelCatalog.profiles(family: .omni).first)

    XCTAssertEqual(QwenRealtimeModelCatalog.voice(for: audio, preferences: preferences), "longanqian")
    XCTAssertEqual(QwenRealtimeModelCatalog.voice(for: omni, preferences: preferences), "Ethan")

    preferences.set("Cherry", forKey: QwenRealtimeModelCatalog.audioVoiceUserDefaultsKey)
    preferences.set("Serena", forKey: QwenRealtimeModelCatalog.omniVoiceUserDefaultsKey)
    XCTAssertEqual(QwenRealtimeModelCatalog.voice(for: audio, preferences: preferences), "Cherry")
    XCTAssertEqual(QwenRealtimeModelCatalog.voice(for: omni, preferences: preferences), "Serena")
  }

  func testLegacyVoiceOverrideOnlyAppliesToAudio() throws {
    let suiteName = "QwenRealtimeModelCatalogTests.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let audio = try XCTUnwrap(QwenRealtimeModelCatalog.profiles(family: .audio).first)
    let omni = try XCTUnwrap(QwenRealtimeModelCatalog.profiles(family: .omni).first)

    preferences.set("LegacyVoice", forKey: "qwen_realtime_voice")
    XCTAssertEqual(QwenRealtimeModelCatalog.voice(for: audio, preferences: preferences), "LegacyVoice")
    XCTAssertEqual(QwenRealtimeModelCatalog.voice(for: omni, preferences: preferences), "Ethan")
  }
}
