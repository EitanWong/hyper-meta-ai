/*
 * Agent Focus Tests
 * 专注模式联动：避让决策（含未知状态 fail-open）、设置默认值与持久化、
 * 主动播报策略叠加专注（显式回复不拦截）、授权状态映射。
 */

import Intents
import XCTest
@testable import HyperMetaAI

// MARK: - 避让决策

final class AgentFocusPolicyTests: XCTestCase {
    func testSuppressWhenRespectOnAndFocusActive() {
        XCTAssertTrue(AgentFocusPolicy.shouldSuppress(respectFocus: true, isFocusActive: true))
    }

    func testNoSuppressWhenRespectOff() {
        XCTAssertFalse(AgentFocusPolicy.shouldSuppress(respectFocus: false, isFocusActive: true))
    }

    func testNoSuppressWhenFocusInactive() {
        XCTAssertFalse(AgentFocusPolicy.shouldSuppress(respectFocus: true, isFocusActive: false))
    }

    func testNoSuppressWhenFocusUnknown() {
        // 未授权 / 系统未共享状态（nil）→ 不避让（fail-open）
        XCTAssertFalse(AgentFocusPolicy.shouldSuppress(respectFocus: true, isFocusActive: nil))
    }

    func testNoSuppressWhenEverythingOff() {
        XCTAssertFalse(AgentFocusPolicy.shouldSuppress(respectFocus: false, isFocusActive: nil))
    }
}

// MARK: - 设置持久化

final class AgentFocusSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.focus.settings")
        defaults.removePersistentDomain(forName: "test.agent.focus.settings")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.focus.settings")
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAreAllRespecting() {
        XCTAssertTrue(AgentFocusSettings.respect(defaults: defaults))
        XCTAssertTrue(AgentFocusSettings.pauseNotifications(defaults: defaults))
        XCTAssertTrue(AgentFocusSettings.muteProactiveTTS(defaults: defaults))
    }

    func testRespectRoundTrip() {
        AgentFocusSettings.setRespect(false, defaults: defaults)
        XCTAssertFalse(AgentFocusSettings.respect(defaults: defaults))
        AgentFocusSettings.setRespect(true, defaults: defaults)
        XCTAssertTrue(AgentFocusSettings.respect(defaults: defaults))
    }

    func testPauseNotificationsRoundTrip() {
        AgentFocusSettings.setPauseNotifications(false, defaults: defaults)
        XCTAssertFalse(AgentFocusSettings.pauseNotifications(defaults: defaults))
        AgentFocusSettings.setPauseNotifications(true, defaults: defaults)
        XCTAssertTrue(AgentFocusSettings.pauseNotifications(defaults: defaults))
    }

    func testMuteProactiveTTSRoundTrip() {
        AgentFocusSettings.setMuteProactiveTTS(false, defaults: defaults)
        XCTAssertFalse(AgentFocusSettings.muteProactiveTTS(defaults: defaults))
        AgentFocusSettings.setMuteProactiveTTS(true, defaults: defaults)
        XCTAssertTrue(AgentFocusSettings.muteProactiveTTS(defaults: defaults))
    }

    func testKeysDoNotCollide() {
        XCTAssertNotEqual(
            AgentFocusSettings.respectKey,
            AgentFocusSettings.pauseNotificationsKey
        )
        XCTAssertNotEqual(
            AgentFocusSettings.pauseNotificationsKey,
            AgentFocusSettings.muteProactiveTTSKey
        )
    }
}

// MARK: - 主动播报策略叠加专注模式

final class AgentQuietAnnouncementFocusTests: XCTestCase {
    private var savedQuietMode: Bool!

    override func setUp() {
        super.setUp()
        savedQuietMode = AgentVoiceSettings.quietModeEnabled
        AgentVoiceSettings.quietModeEnabled = false
    }

    override func tearDown() {
        AgentVoiceSettings.quietModeEnabled = savedQuietMode
        super.tearDown()
    }

    func testProactiveSuppressedWhenFocusActive() {
        XCTAssertFalse(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: true,
                respectFocus: true,
                isFocusActive: true
            )
        )
    }

    func testProactiveSpeaksWhenFocusInactive() {
        XCTAssertTrue(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: true,
                respectFocus: true,
                isFocusActive: false
            )
        )
    }

    func testProactiveSpeaksWhenFocusUnknown() {
        XCTAssertTrue(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: true,
                respectFocus: true,
                isFocusActive: nil
            )
        )
    }

    func testProactiveSpeaksWhenRespectOff() {
        XCTAssertTrue(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: true,
                respectFocus: false,
                isFocusActive: true
            )
        )
    }

    func testRepliesAlwaysSpeakEvenInFocus() {
        // 用户显式询问的回复不因专注模式静音
        XCTAssertTrue(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: false,
                respectFocus: true,
                isFocusActive: true
            )
        )
    }

    func testQuietModeStillSuppressesProactive() {
        AgentVoiceSettings.quietModeEnabled = true
        XCTAssertFalse(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: true,
                respectFocus: false,
                isFocusActive: nil
            )
        )
        // 专注 + 静默同时成立时仍不播报
        XCTAssertFalse(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: true,
                respectFocus: true,
                isFocusActive: true
            )
        )
    }

    func testQuietModeDoesNotSuppressReplies() {
        AgentVoiceSettings.quietModeEnabled = true
        XCTAssertTrue(
            AgentQuietAnnouncementPolicy.shouldSpeak(
                isProactive: false,
                respectFocus: true,
                isFocusActive: true
            )
        )
    }

    func testLegacySingleArgumentCallKeepsBehavior() {
        AgentVoiceSettings.quietModeEnabled = true
        XCTAssertFalse(AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: true))
        XCTAssertTrue(AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: false))
    }
}

// MARK: - 授权状态映射

final class AgentFocusAuthorizationTests: XCTestCase {
    func testMapsSystemStatus() {
        XCTAssertEqual(
            AgentFocusAuthorization.from(.notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            AgentFocusAuthorization.from(.restricted),
            .restricted
        )
        XCTAssertEqual(
            AgentFocusAuthorization.from(.denied),
            .denied
        )
        XCTAssertEqual(
            AgentFocusAuthorization.from(.authorized),
            .authorized
        )
    }
}
