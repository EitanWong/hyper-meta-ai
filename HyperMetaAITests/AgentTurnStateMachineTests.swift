import XCTest
@testable import HyperMetaAI

final class AgentTurnStateMachineTests: XCTestCase {
    func testInitialPhaseIsIdle() {
        XCTAssertEqual(AgentTurnStateMachine().phase, .idle)
    }

    func testFirstTapStartsAnIdleSession() {
        var machine = AgentTurnStateMachine()
        XCTAssertEqual(machine.handle(trigger: .tapStartSession), .wake)
        XCTAssertEqual(machine.phase, .listening)
    }

    func testSecondTapEndsAnActiveSession() {
        var machine = AgentTurnStateMachine()
        _ = machine.handle(trigger: .tapStartSession)
        XCTAssertEqual(machine.handle(trigger: .tapEndSession), .endTurn)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testStartLabeledTouchStillEndsPhoneStartedSession() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        XCTAssertEqual(machine.handle(trigger: .tapStartSession), .endTurn)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testEndLabeledTouchStillStartsAfterPhoneEndedSession() {
        var machine = AgentTurnStateMachine()
        XCTAssertEqual(machine.handle(trigger: .tapEndSession), .wake)
        XCTAssertEqual(machine.phase, .listening)
    }

    func testLongPressEndsEveryActivePhase() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.outputStarted()
        XCTAssertEqual(machine.handle(trigger: .longPressStop), .endTurn)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testLongPressWhenIdleIsIgnored() {
        var machine = AgentTurnStateMachine()
        XCTAssertEqual(machine.handle(trigger: .longPressStop), .none)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testOutputLifecycle() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.thinkingStarted()
        XCTAssertEqual(machine.phase, .thinking)
        machine.outputStarted()
        XCTAssertEqual(machine.phase, .speaking)
        machine.outputEnded()
        XCTAssertEqual(machine.phase, .listening)
    }

    func testThinkingDoesNotOverrideApproval() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        machine.thinkingStarted()
        XCTAssertEqual(machine.phase, .approval)
    }

    func testTapDuringApprovalOnlyEndsTheSession() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        XCTAssertEqual(machine.handle(trigger: .tapStartSession), .endTurn)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testPermissionResolvedReturnsToThinking() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        machine.permissionResolved()
        XCTAssertEqual(machine.phase, .thinking)
    }

    func testTurnEndedAndResetReturnToIdle() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.turnEnded()
        XCTAssertEqual(machine.phase, .idle)
        machine.turnStarted()
        machine.reset()
        XCTAssertEqual(machine.phase, .idle)
    }
}
