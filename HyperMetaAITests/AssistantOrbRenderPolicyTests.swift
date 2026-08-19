import XCTest

@testable import HyperMetaAI

final class AssistantOrbRenderPolicyTests: XCTestCase {
    func testAudioStepClampsAndQuantizesInput() {
        XCTAssertEqual(AssistantOrbRenderPolicy.audioStep(-1), 0)
        XCTAssertEqual(AssistantOrbRenderPolicy.audioStep(0.49), 3)
        XCTAssertEqual(AssistantOrbRenderPolicy.audioStep(2), 6)
    }

    func testIntensityStepClampsInput() {
        XCTAssertEqual(AssistantOrbRenderPolicy.intensityStep(-1), 0)
        XCTAssertEqual(AssistantOrbRenderPolicy.intensityStep(0.46), 5)
        XCTAssertEqual(AssistantOrbRenderPolicy.intensityStep(2), 10)
    }

    func testAudioResponseRemainsSubtleAndBounded() {
        XCTAssertEqual(
            AssistantOrbRenderPolicy.scale(state: .listening, audioLevel: 0),
            0.70,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AssistantOrbRenderPolicy.scale(state: .listening, audioLevel: 1),
            0.732,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            AssistantOrbRenderPolicy.scale(state: .idle, audioLevel: 1),
            AssistantOrbRenderPolicy.scale(state: .listening, audioLevel: 1)
        )
    }

    func testEveryAssistantStateHasAnExplicitMotionStyle() {
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .idle), .still)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .connecting), .connecting)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .listening), .listening)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .thinking), .thinking)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .speaking), .speaking)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .working), .working)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .error), .error)
        XCTAssertEqual(AssistantOrbRenderPolicy.motionStyle(for: .paused), .paused)
    }

    func testPausedStateIsVisuallyQuieterThanActiveStates() {
        XCTAssertLessThan(
            AssistantOrbRenderPolicy.scale(state: .paused, audioLevel: 1),
            AssistantOrbRenderPolicy.scale(state: .listening, audioLevel: 0)
        )
        XCTAssertLessThan(
            AssistantOrbRenderPolicy.coreOpacity(for: .paused),
            AssistantOrbRenderPolicy.coreOpacity(for: .speaking)
        )
    }
}
