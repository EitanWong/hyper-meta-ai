import XCTest

@testable import HyperMetaAI

/// 静默模式：设置持久化与主动播报策略（纯逻辑）
final class AgentQuietModeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.quietModeEnabledKey)
        super.tearDown()
    }

    func testQuietModeDefaultsToOff() {
        XCTAssertFalse(AgentVoiceSettings.quietModeEnabled)
    }

    func testQuietModePersistenceRoundtrip() {
        AgentVoiceSettings.quietModeEnabled = true
        XCTAssertTrue(AgentVoiceSettings.quietModeEnabled)
        AgentVoiceSettings.quietModeEnabled = false
        XCTAssertFalse(AgentVoiceSettings.quietModeEnabled)
    }

    func testReactiveAnnouncementsAlwaysSpeak() {
        AgentVoiceSettings.quietModeEnabled = false
        XCTAssertTrue(AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: false))

        AgentVoiceSettings.quietModeEnabled = true
        XCTAssertTrue(AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: false))
    }

    func testProactiveAnnouncementsSilentInQuietMode() {
        AgentVoiceSettings.quietModeEnabled = true
        XCTAssertFalse(AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: true))
    }

    func testProactiveAnnouncementsSpeakOutsideQuietMode() {
        AgentVoiceSettings.quietModeEnabled = false
        XCTAssertTrue(AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: true))
    }
}
