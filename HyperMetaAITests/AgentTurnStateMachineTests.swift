import XCTest
@testable import HyperMetaAI

final class AgentTurnStateMachineTests: XCTestCase {

    func testInitialPhaseIsIdle() {
        let machine = AgentTurnStateMachine()
        XCTAssertEqual(machine.phase, .idle)
    }

    func testTapPauseDuringListeningInterrupts() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        XCTAssertEqual(machine.phase, .listening)

        XCTAssertEqual(machine.handle(trigger: .tapPause), .interrupt)
        XCTAssertEqual(machine.phase, .interrupted)
    }

    func testTapPauseDuringSpeakingInterrupts() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.outputStarted()
        XCTAssertEqual(machine.phase, .speaking)

        XCTAssertEqual(machine.handle(trigger: .tapPause), .interrupt)
        XCTAssertEqual(machine.phase, .interrupted)
    }

    func testTapPauseWhenIdleWakesNewTurn() {
        var machine = AgentTurnStateMachine()
        XCTAssertEqual(machine.handle(trigger: .tapPause), .wake)
        XCTAssertEqual(machine.phase, .listening)
    }

    func testWakeTurnCanBeEndedByLongPress() {
        var machine = AgentTurnStateMachine()
        _ = machine.handle(trigger: .tapPause)
        XCTAssertEqual(machine.phase, .listening)

        XCTAssertEqual(machine.handle(trigger: .longPressStop), .endTurn)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testWakeThenTapResumeIsIgnored() {
        var machine = AgentTurnStateMachine()
        _ = machine.handle(trigger: .tapPause)
        XCTAssertEqual(machine.phase, .listening)

        XCTAssertEqual(machine.handle(trigger: .tapResume), .none)
        XCTAssertEqual(machine.phase, .listening)
    }

    func testTapPauseWhileInterruptedIsIdempotent() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        _ = machine.handle(trigger: .tapPause)
        XCTAssertEqual(machine.phase, .interrupted)

        XCTAssertEqual(machine.handle(trigger: .tapPause), .none, "重复打断不应重复发命令")
        XCTAssertEqual(machine.phase, .interrupted)
    }

    func testTapResumeAfterInterruptResumes() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        _ = machine.handle(trigger: .tapPause)

        XCTAssertEqual(machine.handle(trigger: .tapResume), .resume)
        XCTAssertEqual(machine.phase, .listening)
    }

    func testTapResumeWhenNotInterruptedIsIgnored() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        XCTAssertEqual(machine.handle(trigger: .tapResume), .none)
        XCTAssertEqual(machine.phase, .listening)
    }

    func testLongPressEndsTurnFromAnyActivePhase() {
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

    func testLateOutputWhileInterruptedStaysInterrupted() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        _ = machine.handle(trigger: .tapPause)
        XCTAssertEqual(machine.phase, .interrupted)

        machine.outputStarted()
        XCTAssertEqual(machine.phase, .interrupted, "打断后的迟到输出不应改写打断状态")

        machine.outputEnded()
        XCTAssertEqual(machine.phase, .interrupted)
    }

    func testResumeThenOutputTransitionsToSpeaking() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        _ = machine.handle(trigger: .tapPause)
        _ = machine.handle(trigger: .tapResume)

        machine.outputStarted()
        XCTAssertEqual(machine.phase, .speaking)
        machine.outputEnded()
        XCTAssertEqual(machine.phase, .listening)
    }

    func testTurnEndedResetsToIdle() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.outputStarted()
        machine.turnEnded()
        XCTAssertEqual(machine.phase, .idle)
    }

    func testReset() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.reset()
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: - 权限审批阶段

    func testPermissionRequestedEntersApproval() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        XCTAssertEqual(machine.phase, .approval)
    }

    func testPermissionRequestedFromIdleStaysIdle() {
        var machine = AgentTurnStateMachine()
        machine.permissionRequested()
        XCTAssertEqual(machine.phase, .idle, "空闲时到达的权限请求不应唤醒回合")
    }

    func testPermissionRequestedIsIdempotent() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        machine.permissionRequested()
        XCTAssertEqual(machine.phase, .approval)
    }

    func testPermissionResolvedReturnsToThinking() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        machine.permissionResolved()
        XCTAssertEqual(machine.phase, .thinking)
    }

    func testTapDuringApprovalIsIgnored() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        XCTAssertEqual(machine.handle(trigger: .tapPause), .none)
        XCTAssertEqual(machine.phase, .approval)
        XCTAssertEqual(machine.handle(trigger: .tapResume), .none)
        XCTAssertEqual(machine.phase, .approval)
    }

    func testLongPressDuringApprovalEndsTurn() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        XCTAssertEqual(machine.handle(trigger: .longPressStop), .endTurn)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testOutputDuringApprovalDoesNotOverride() {
        var machine = AgentTurnStateMachine()
        machine.turnStarted()
        machine.permissionRequested()
        machine.outputStarted()
        XCTAssertEqual(machine.phase, .approval)
        machine.outputEnded()
        XCTAssertEqual(machine.phase, .approval)
    }
}
