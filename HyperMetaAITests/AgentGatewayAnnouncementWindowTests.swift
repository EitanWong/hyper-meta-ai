/*
 * Agent Gateway Announcement Window Tests
 * 公告安全插入窗口：回合挂起、音频排队、播放结束解除、打断与重置。
 */

import XCTest
@testable import HyperMetaAI

final class AgentGatewayAnnouncementWindowTests: XCTestCase {
    func testFreshWindowIsUnblocked() {
        let window = AgentGatewayAnnouncementWindow()
        XCTAssertFalse(window.isBlocked())
        XCTAssertFalse(window.isPlaying())
        XCTAssertEqual(window.queuedAudioCount, 0)
    }

    func testBeginTurnBlocksWindow() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        XCTAssertTrue(window.userSpeaking)
        XCTAssertTrue(window.turnPending)
        XCTAssertEqual(window.activeTurnId, "turn-1")
        XCTAssertTrue(window.isBlocked())
    }

    func testEndSpeechStillBlockedWhileTurnPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        XCTAssertFalse(window.userSpeaking)
        XCTAssertTrue(window.isBlocked())
    }

    func testResponseDoneWithoutAudioClearsPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.responseDone(turnId: "turn-1")
        XCTAssertFalse(window.turnPending)
        XCTAssertFalse(window.isBlocked())
    }

    func testResponseDoneWithAudioKeepsPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.responseDone(turnId: "turn-1", hasAudio: true)
        XCTAssertTrue(window.turnPending)
    }

    func testResponseDoneWithFunctionCallKeepsPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.responseDone(turnId: "turn-1", hasFunctionCall: true)
        XCTAssertTrue(window.turnPending)
        window.responseDone(turnId: "turn-1", hasFunctionCall: true, suppressed: true)
        XCTAssertFalse(window.turnPending)
    }

    func testAnnouncementOriginDoesNotClearPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.responseDone(turnId: "turn-1", origin: "announcement")
        XCTAssertTrue(window.turnPending)
    }

    func testOtherTurnDoesNotClearPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.responseDone(turnId: "turn-2")
        XCTAssertTrue(window.turnPending)
    }

    func testQueuedAudioBlocksWindow() {
        var window = AgentGatewayAnnouncementWindow()
        window.queueAudio("r1", turnId: "turn-1")
        XCTAssertTrue(window.isBlocked())
        XCTAssertEqual(window.queuedAudioCount, 1)
    }

    func testFinishPlaybackUnblocksAndClearsPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.queueAudio("r1", turnId: "turn-1")
        window.startPlayback("r1")
        XCTAssertTrue(window.isPlaying())
        window.finishPlayback("r1")
        XCTAssertFalse(window.isPlaying())
        XCTAssertFalse(window.isBlocked())
        XCTAssertFalse(window.turnPending)
    }

    func testFinishPlaybackWithFunctionCallKeepsPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.queueAudio("r1", turnId: "turn-1")
        window.finishPlayback("r1", hasFunctionCall: true)
        XCTAssertTrue(window.turnPending)
    }

    func testAnnouncementPlaybackDoesNotClearPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.queueAudio("a1", turnId: "turn-1", origin: "announcement")
        window.finishPlayback("a1")
        XCTAssertTrue(window.turnPending)
    }

    func testInterruptClearsPending() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.endSpeech()
        window.interrupt()
        XCTAssertFalse(window.turnPending)
        XCTAssertFalse(window.isBlocked())
    }

    func testResetClearsEverything() {
        var window = AgentGatewayAnnouncementWindow()
        window.beginTurn("turn-1")
        window.queueAudio("r1", turnId: "turn-1")
        window.reset()
        XCTAssertFalse(window.isBlocked())
        XCTAssertTrue(window.activeTurnId.isEmpty)
        XCTAssertEqual(window.queuedAudioCount, 0)
    }
}
