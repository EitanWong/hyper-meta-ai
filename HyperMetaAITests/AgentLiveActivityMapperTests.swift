import XCTest
@testable import HyperMetaAI

/// Agent Live Activity 状态映射纯逻辑（不依赖 ActivityKit 运行时）
final class AgentLiveActivityMapperTests: XCTestCase {

    func testTaskContentNilWhenNoTask() {
        XCTAssertNil(AgentLiveActivityStateMapper.taskContent(count: 0, step: nil))
    }

    func testTaskContentSingleTitle() {
        let content = AgentLiveActivityStateMapper.taskContent(count: 1, step: nil)
        XCTAssertEqual(content?.mode, .taskProgress)
        XCTAssertEqual(content?.title, "agent.liveactivity.task.title.single".localized)
        XCTAssertEqual(content?.taskCount, 1)
    }

    func testTaskContentPluralTitle() {
        let content = AgentLiveActivityStateMapper.taskContent(count: 3, step: nil)
        XCTAssertEqual(content?.title, "agent.liveactivity.task.title.plural".localized(3))
        XCTAssertEqual(content?.taskCount, 3)
    }

    func testTaskContentStepAndDefaultDetail() {
        let withStep = AgentLiveActivityStateMapper.taskContent(count: 1, step: "正在整理报告")
        XCTAssertEqual(withStep?.detail, "正在整理报告")
        let withoutStep = AgentLiveActivityStateMapper.taskContent(count: 1, step: nil)
        XCTAssertEqual(withoutStep?.detail, "agent.liveactivity.task.detail.default".localized)
        let emptyStep = AgentLiveActivityStateMapper.taskContent(count: 1, step: "")
        XCTAssertEqual(emptyStep?.detail, "agent.liveactivity.task.detail.default".localized)
    }

    func testApprovalContentCarriesExpiry() {
        let expiry = Date(timeIntervalSinceNow: 60)
        let content = AgentLiveActivityStateMapper.approvalContent(
            text: "允许拍照吗",
            expiresAt: expiry
        )
        XCTAssertEqual(content.mode, .approval)
        XCTAssertEqual(content.title, "agent.liveactivity.approval.title".localized)
        XCTAssertEqual(content.detail, "允许拍照吗")
        XCTAssertEqual(content.approvalExpiresAt, expiry)
    }

    func testResultContentKinds() {
        let done = AgentLiveActivityStateMapper.resultContent(kind: .completed, text: "整理好了")
        XCTAssertEqual(done.mode, .result)
        XCTAssertEqual(done.title, "agent.liveactivity.result.done".localized)
        XCTAssertEqual(done.detail, "整理好了")
        XCTAssertEqual(
            done.resultKind,
            AgentLiveActivityAttributes.ResultKind.completed.rawValue,
            "成功结果标记 completed，锁屏渲染「追问」"
        )

        let failed = AgentLiveActivityStateMapper.resultContent(kind: .failed, text: "网关不可达")
        XCTAssertEqual(failed.title, "agent.liveactivity.result.failed".localized)
        XCTAssertEqual(
            failed.resultKind,
            AgentLiveActivityAttributes.ResultKind.failed.rawValue,
            "失败结果标记 failed，锁屏渲染「重试」"
        )

        let cancelled = AgentLiveActivityStateMapper.resultContent(kind: .cancelled, text: "已取消")
        XCTAssertEqual(cancelled.title, "agent.liveactivity.result.cancelled".localized)
        XCTAssertEqual(
            cancelled.resultKind,
            AgentLiveActivityAttributes.ResultKind.cancelled.rawValue
        )
    }

    func testNonResultModesCarryNilResultKind() {
        let task = AgentLiveActivityStateMapper.taskContent(count: 2, step: nil)
        XCTAssertNil(task?.resultKind)
        let approval = AgentLiveActivityStateMapper.approvalContent(
            text: "允许拍照吗",
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertNil(approval.resultKind)
    }

    func testVoiceContentShowsStatus() {
        let content = AgentLiveActivityStateMapper.voiceContent(
            text: "正在聆听…",
            phase: .listening
        )
        XCTAssertEqual(content?.mode, .voiceSession)
        XCTAssertEqual(content?.title, "agent.liveactivity.voice.title".localized)
        XCTAssertEqual(content?.detail, "正在聆听…")
        XCTAssertEqual(content?.voiceStatus, "正在聆听…")
        XCTAssertEqual(
            content?.voicePhase,
            AgentLiveActivityAttributes.VoicePhase.listening.rawValue
        )
        XCTAssertNil(content?.countdownFireDate)
    }

    func testVoiceContentPhaseNilByDefault() {
        let content = AgentLiveActivityStateMapper.voiceContent(text: "思考中…")
        XCTAssertNil(content?.voicePhase, "旧调用不传 phase 时字段为 nil（旧活动兼容）")
    }

    func testVoiceContentNilForEmptyText() {
        XCTAssertNil(AgentLiveActivityStateMapper.voiceContent(text: nil))
        XCTAssertNil(AgentLiveActivityStateMapper.voiceContent(text: ""))
        XCTAssertNil(AgentLiveActivityStateMapper.voiceContent(text: "   "))
    }

    func testContentStateCodableRoundtrip() throws {
        let original = AgentLiveActivityStateMapper.approvalContent(
            text: "允许拍照吗",
            expiresAt: Date(timeIntervalSinceNow: 45)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            AgentLiveActivityAttributes.ContentState.self,
            from: data
        )
        XCTAssertEqual(decoded, original)
    }

    func testReminderContentCarriesTextAndFireDate() {
        let fireDate = Date(timeIntervalSinceNow: 600)
        let content = AgentLiveActivityStateMapper.reminderContent(
            text: "喝水",
            fireDate: fireDate,
            now: Date()
        )
        XCTAssertEqual(content?.mode, .reminderCountdown)
        XCTAssertEqual(content?.title, "agent.liveactivity.reminder.title".localized)
        XCTAssertEqual(content?.detail, "喝水")
        XCTAssertEqual(content?.countdownFireDate, fireDate)
    }

    func testReminderContentNilWhenEmptyText() {
        let future = Date(timeIntervalSinceNow: 600)
        XCTAssertNil(AgentLiveActivityStateMapper.reminderContent(text: "", fireDate: future))
        XCTAssertNil(AgentLiveActivityStateMapper.reminderContent(text: "   ", fireDate: future))
    }

    func testReminderContentNilWhenPastOrNow() {
        let past = Date(timeIntervalSinceNow: -10)
        let now = Date()
        XCTAssertNil(AgentLiveActivityStateMapper.reminderContent(text: "喝水", fireDate: past, now: now))
        XCTAssertNil(AgentLiveActivityStateMapper.reminderContent(text: "喝水", fireDate: now, now: now))
    }
}

/// 语音会话 Live Activity 状态文案（纯逻辑）
final class AgentVoiceLiveActivityStatusTests: XCTestCase {
    func testInactiveReturnsNil() {
        XCTAssertNil(AgentVoiceLiveActivityStatus.text(
            isActive: false,
            isSleeping: false,
            isSpeaking: false,
            isInputActive: false,
            connectionState: .connected
        ))
    }

    func testSleepingHasPriority() {
        XCTAssertEqual(AgentVoiceLiveActivityStatus.text(
            isActive: true,
            isSleeping: true,
            isSpeaking: true,
            isInputActive: true,
            connectionState: .failed("down")
        ), "agent.liveactivity.voice.sleeping".localized)
    }

    func testConnectingAndFailed() {
        let connecting = AgentVoiceLiveActivityStatus.text(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .connecting
        )
        XCTAssertEqual(connecting, "agent.liveactivity.voice.connecting".localized)
        let failed = AgentVoiceLiveActivityStatus.text(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .failed("boom")
        )
        XCTAssertEqual(failed, "agent.liveactivity.voice.failed".localized)
        let disconnected = AgentVoiceLiveActivityStatus.text(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .disconnected
        )
        XCTAssertEqual(disconnected, "agent.liveactivity.voice.connecting".localized)
    }

    func testConnectedPhases() {
        XCTAssertEqual(AgentVoiceLiveActivityStatus.text(
            isActive: true, isSleeping: false, isSpeaking: true, isInputActive: false,
            connectionState: .connected
        ), "agent.liveactivity.voice.speaking".localized)
        XCTAssertEqual(AgentVoiceLiveActivityStatus.text(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: true,
            connectionState: .connected
        ), "agent.liveactivity.voice.listening".localized)
        XCTAssertEqual(AgentVoiceLiveActivityStatus.text(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .connected
        ), "agent.liveactivity.voice.thinking".localized)
    }

    func testPhaseMapping() {
        let phase = AgentVoiceLiveActivityStatus.phase(
            isActive: true, isSleeping: true, isSpeaking: true, isInputActive: true,
            connectionState: .failed("down")
        )
        XCTAssertEqual(phase, .sleeping)
        XCTAssertNil(AgentVoiceLiveActivityStatus.phase(
            isActive: false, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .connected
        ), "会话不活跃无阶段")
        XCTAssertEqual(AgentVoiceLiveActivityStatus.phase(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .connecting
        ), .connecting)
        XCTAssertEqual(AgentVoiceLiveActivityStatus.phase(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .failed("boom")
        ), .failed)
        XCTAssertEqual(AgentVoiceLiveActivityStatus.phase(
            isActive: true, isSleeping: false, isSpeaking: true, isInputActive: false,
            connectionState: .connected
        ), .speaking)
        XCTAssertEqual(AgentVoiceLiveActivityStatus.phase(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: true,
            connectionState: .connected
        ), .listening)
        XCTAssertEqual(AgentVoiceLiveActivityStatus.phase(
            isActive: true, isSleeping: false, isSpeaking: false, isInputActive: false,
            connectionState: .connected
        ), .thinking)
    }

    func testTextForPhaseMatchesPhase() {
        // text(for:) 与 phase 单一来源：每个阶段都有对应文案
        for phase in [AgentLiveActivityAttributes.VoicePhase.listening,
                      .thinking, .speaking, .sleeping, .connecting, .failed] {
            XCTAssertFalse(
                AgentVoiceLiveActivityStatus.text(for: phase).isEmpty,
                "\(phase.rawValue) 文案非空"
            )
        }
        XCTAssertEqual(
            AgentVoiceLiveActivityStatus.text(for: .sleeping),
            "agent.liveactivity.voice.sleeping".localized
        )
    }
}

/// 语音波形模式（纯逻辑）：确定性、阶段差异、值域与静止度
final class AgentVoiceWaveformPatternTests: XCTestCase {
    private let phases: [AgentLiveActivityAttributes.VoicePhase] = [
        .listening, .thinking, .speaking, .sleeping, .connecting, .failed
    ]

    private func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }

    func testBarCountFixed() {
        for phase in phases {
            XCTAssertEqual(
                AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
                    phase: phase, t: 0
                ).count,
                AgentLiveActivityAttributes.VoiceWaveformPattern.barCount
            )
        }
    }

    func testDeterministicForSameInputs() {
        let a = AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
            phase: .speaking, t: 1.5, seed: 3
        )
        let b = AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
            phase: .speaking, t: 1.5, seed: 3
        )
        XCTAssertEqual(a, b)
    }

    func testSeedChangesSequence() {
        let a = AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
            phase: .listening, t: 0, seed: 0
        )
        let b = AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
            phase: .listening, t: 0, seed: 5
        )
        XCTAssertNotEqual(a, b, "seed 应改变竖条序列")
    }

    func testValuesWithinRange() {
        for phase in phases {
            for t in stride(from: 0.0, through: 2.0, by: 0.25) {
                for height in AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
                    phase: phase, t: t
                ) {
                    XCTAssertGreaterThanOrEqual(height, 0.06)
                    XCTAssertLessThanOrEqual(height, 1.0)
                }
            }
        }
    }

    func testSpeakingMoreActiveThanListeningThanThinking() {
        let speaking = average(AgentLiveActivityAttributes.VoiceWaveformPattern.heights(phase: .speaking, t: 0))
        let listening = average(AgentLiveActivityAttributes.VoiceWaveformPattern.heights(phase: .listening, t: 0))
        let thinking = average(AgentLiveActivityAttributes.VoiceWaveformPattern.heights(phase: .thinking, t: 0))
        XCTAssertGreaterThan(speaking, listening)
        XCTAssertGreaterThan(listening, thinking)
    }

    func testSleepingNearlyFlat() {
        var samples: [Double] = []
        for t in stride(from: 0.0, through: 3.0, by: 0.25) {
            samples += AgentLiveActivityAttributes.VoiceWaveformPattern.heights(
                phase: .sleeping, t: t
            )
        }
        let span = (samples.max() ?? 0) - (samples.min() ?? 0)
        XCTAssertLessThan(span, 0.1, "休眠阶段应近乎静止，波动幅度小")
    }

    func testSpeedOrdering() {
        XCTAssertGreaterThan(
            AgentLiveActivityAttributes.VoiceWaveformPattern.speed(for: .speaking),
            AgentLiveActivityAttributes.VoiceWaveformPattern.speed(for: .listening)
        )
        XCTAssertGreaterThan(
            AgentLiveActivityAttributes.VoiceWaveformPattern.speed(for: .listening),
            AgentLiveActivityAttributes.VoiceWaveformPattern.speed(for: .sleeping)
        )
    }
}
