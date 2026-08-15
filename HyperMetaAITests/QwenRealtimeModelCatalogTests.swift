import Foundation
import XCTest

@testable import HyperMetaAI

/// QwenRealtimeModelCatalog：镜像 qwen-audio-agent v1.8.3 的 DashScope Realtime 模型档案
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
  }

  func testCatalogContainsLatestModelLineup() {
    let ids = QwenRealtimeModelCatalog.all.map(\.id)
    XCTAssertTrue(ids.contains("qwen-audio-3.0-realtime-plus"))
    XCTAssertTrue(ids.contains("qwen-audio-3.0-realtime-flash"))
    XCTAssertTrue(ids.contains("qwen3.5-omni-flash-realtime"))
    XCTAssertTrue(ids.contains("qwen3.5-omni-plus-realtime"))
    // 旧模型仅保留兼容，不应是默认
    XCTAssertFalse(QwenRealtimeModelCatalog.all.contains {
      $0.id == "qwen3-omni-flash-realtime" && $0.isDefault
    })
  }

  func testOmniProfilesSupportImageInput() {
    for profile in QwenRealtimeModelCatalog.profiles(family: .omni) {
      XCTAssertTrue(profile.supportsImageInput, "\(profile.id) 应支持图像输入")
      XCTAssertTrue(profile.supportsFunctionCalling)
    }
  }

  func testAudioProfilesArePureVoice() {
    for profile in QwenRealtimeModelCatalog.profiles(family: .audio) {
      XCTAssertFalse(profile.supportsImageInput, "\(profile.id) 应为纯语音")
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
}
