import XCTest
@testable import HyperMetaAI

final class AgentDisplayStatusTests: XCTestCase {

    func testEveryPhaseHasIconAndTitle() {
        let phases: [AgentTurnPhase] = [
            .idle, .listening, .thinking, .speaking, .interrupted, .approval,
        ]
        for phase in phases {
            let icon = AgentDisplayStatusMapping.iconName(for: phase)
            XCTAssertFalse(icon.isEmpty, "\(phase) 缺少图标")
            XCTAssertTrue(AgentDisplayStatusMapping.isValidIcon(icon), "\(phase) 图标无效: \(icon)")
        }
    }

    func testActivePhasesHaveTitles() {
        XCTAssertEqual(AgentDisplayStatusMapping.title(for: .listening), "Listening")
        XCTAssertEqual(AgentDisplayStatusMapping.title(for: .thinking), "Thinking")
        XCTAssertEqual(AgentDisplayStatusMapping.title(for: .speaking), "Speaking")
        XCTAssertEqual(AgentDisplayStatusMapping.title(for: .interrupted), "Paused")
        XCTAssertEqual(AgentDisplayStatusMapping.title(for: .approval), "Approve?")
        XCTAssertEqual(AgentDisplayStatusMapping.title(for: .idle), "", "idle 不显示文字")
    }

    func testDistinctIconsForDistinctPhases() {
        let phases: [AgentTurnPhase] = [.listening, .thinking, .speaking, .interrupted, .approval]
        let icons = Set(phases.map(AgentDisplayStatusMapping.iconName(for:)))
        XCTAssertEqual(icons.count, phases.count, "各状态应使用不同图标")
    }

  // MARK: - 结果摘要映射

  func testResultMappingTitlesForTerminalKinds() {
    XCTAssertEqual(AgentDisplayResultMapping.title(for: .completed), "Done")
    XCTAssertEqual(AgentDisplayResultMapping.title(for: .result), "Done")
    XCTAssertEqual(AgentDisplayResultMapping.title(for: .failed), "Failed")
    XCTAssertEqual(AgentDisplayResultMapping.title(for: .cancelled), "Cancelled")
  }

  func testResultMappingHapticForTerminalKinds() {
    XCTAssertEqual(AgentDisplayResultMapping.haptic(for: .completed), .success)
    XCTAssertEqual(AgentDisplayResultMapping.haptic(for: .result), .success)
    XCTAssertEqual(AgentDisplayResultMapping.haptic(for: .failed), .error)
    XCTAssertEqual(AgentDisplayResultMapping.haptic(for: .cancelled), .warning)
    XCTAssertEqual(AgentDisplayResultMapping.haptic(for: .progress), .success)
    XCTAssertEqual(AgentDisplayResultMapping.haptic(for: .delegated), .success)
  }

  func testResultMappingBuildsViewWithTitleAndText() {
    let view = AgentDisplayResultMapping.makeView(title: "Done", text: "已生成周报")
    XCTAssertNotNil(view)
    XCTAssertEqual(view?.direction, .column)
  }

  func testResultMappingBuildsViewWithEmptyText() {
    let view = AgentDisplayResultMapping.makeView(title: "Done", text: "")
    XCTAssertNotNil(view)
  }

  // MARK: - 任务进度映射

  func testTaskMappingIconIsValid() {
    XCTAssertTrue(AgentDisplayStatusMapping.isValidIcon(AgentDisplayTaskMapping.iconName))
  }

  func testTaskMappingTitles() {
    XCTAssertEqual(AgentDisplayTaskMapping.title(count: 1), "Task")
    XCTAssertEqual(AgentDisplayTaskMapping.title(count: 2), "Tasks 2")
  }

  func testTaskMappingBuildsView() {
    let view = AgentDisplayTaskMapping.makeView(count: 2)
    XCTAssertNotNil(view)
    XCTAssertEqual(view?.direction, .row)
  }

  func testTaskMappingBuildsViewWithTitle() {
    let view = AgentDisplayTaskMapping.makeView(count: 1, title: "正在生成周报")
    XCTAssertNotNil(view)
    XCTAssertEqual(view?.direction, .column, "带步骤文案时使用双行布局")
  }

  func testTaskMappingIgnoresEmptyTitle() {
    let view = AgentDisplayTaskMapping.makeView(count: 1, title: "")
    XCTAssertNotNil(view)
    XCTAssertEqual(view?.direction, .row, "空文案回退单行布局")
  }

}

// MARK: - 任务生命周期 Presenter（纯决策）

@MainActor
final class AgentTaskLensPresenterTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.quietModeEnabledKey)
        UserDefaults.standard.removeObject(forKey: AgentVoiceSettings.replyEnabledKey)
        super.tearDown()
    }

    // MARK: progressVisible

    func testProgressVisibleInListeningAndIdle() {
        XCTAssertTrue(AgentTaskLensPresenter.progressVisible(phase: .listening, hasCompletionNotice: false))
        XCTAssertTrue(AgentTaskLensPresenter.progressVisible(phase: .idle, hasCompletionNotice: false))
    }

    func testProgressHiddenInNonListeningPhases() {
        for phase in [AgentTurnPhase.thinking, .speaking, .interrupted, .approval] {
            XCTAssertFalse(AgentTaskLensPresenter.progressVisible(phase: phase, hasCompletionNotice: false), "\(phase)")
        }
    }

    func testProgressHiddenWhenCompletionNoticePending() {
        XCTAssertFalse(AgentTaskLensPresenter.progressVisible(phase: .listening, hasCompletionNotice: true))
        XCTAssertFalse(AgentTaskLensPresenter.progressVisible(phase: .idle, hasCompletionNotice: true))
    }

    // MARK: stepVisible

    func testStepVisibleInLivePhases() {
        for phase in [AgentTurnPhase.listening, .thinking, .idle] {
            XCTAssertTrue(AgentTaskLensPresenter.stepVisible(phase: phase), "\(phase)")
        }
    }

    func testStepHiddenInTerminalPhases() {
        for phase in [AgentTurnPhase.speaking, .interrupted, .approval] {
            XCTAssertFalse(AgentTaskLensPresenter.stepVisible(phase: phase), "\(phase)")
        }
    }

    // MARK: shouldAnnounceCompletion

    func testAnnounceAllowedByDefault() {
        AgentVoiceSettings.quietModeEnabled = false
        AgentVoiceSettings.replyEnabled = true
        XCTAssertTrue(AgentTaskLensPresenter.shouldAnnounceCompletion(
            isSpeaking: false, isInputActive: false, ttsSpeaking: false
        ))
    }

    func testAnnounceSilentInQuietMode() {
        AgentVoiceSettings.quietModeEnabled = true
        AgentVoiceSettings.replyEnabled = true
        XCTAssertFalse(AgentTaskLensPresenter.shouldAnnounceCompletion(
            isSpeaking: false, isInputActive: false, ttsSpeaking: false
        ))
    }

    func testAnnounceSilentWhenRepliesDisabled() {
        AgentVoiceSettings.quietModeEnabled = false
        AgentVoiceSettings.replyEnabled = false
        XCTAssertFalse(AgentTaskLensPresenter.shouldAnnounceCompletion(
            isSpeaking: false, isInputActive: false, ttsSpeaking: false
        ))
    }

    func testAnnounceSilentInsideAnnouncementWindow() {
        AgentVoiceSettings.quietModeEnabled = false
        AgentVoiceSettings.replyEnabled = true
        XCTAssertFalse(AgentTaskLensPresenter.shouldAnnounceCompletion(
            isSpeaking: true, isInputActive: false, ttsSpeaking: false
        ))
        XCTAssertFalse(AgentTaskLensPresenter.shouldAnnounceCompletion(
            isSpeaking: false, isInputActive: true, ttsSpeaking: false
        ))
        XCTAssertFalse(AgentTaskLensPresenter.shouldAnnounceCompletion(
            isSpeaking: false, isInputActive: false, ttsSpeaking: true
        ))
    }
}

// MARK: - 审批弹卡延迟策略（纯决策）

final class AgentApprovalDeferralPolicyTests: XCTestCase {
    func testNotDeferredWhenIdleAndQuiet() {
        XCTAssertFalse(AgentApprovalDeferralPolicy.shouldDefer(
            phase: .idle, isInputActive: false, isSpeaking: false, ttsSpeaking: false
        ))
        XCTAssertFalse(AgentApprovalDeferralPolicy.shouldDefer(
            phase: .listening, isInputActive: false, isSpeaking: false, ttsSpeaking: false
        ))
        // thinking → approval 是权限请求的正常路径，不延迟
        XCTAssertFalse(AgentApprovalDeferralPolicy.shouldDefer(
            phase: .thinking, isInputActive: false, isSpeaking: false, ttsSpeaking: false
        ))
    }

    func testDeferredWhileUserSpeaking() {
        XCTAssertTrue(AgentApprovalDeferralPolicy.shouldDefer(
            phase: .listening, isInputActive: true, isSpeaking: false, ttsSpeaking: false
        ))
    }

    func testDeferredWhileGatewaySpeaking() {
        XCTAssertTrue(AgentApprovalDeferralPolicy.shouldDefer(
            phase: .speaking, isInputActive: false, isSpeaking: true, ttsSpeaking: false
        ))
    }

    func testDeferredWhileTTSSpeaking() {
        XCTAssertTrue(AgentApprovalDeferralPolicy.shouldDefer(
            phase: .listening, isInputActive: false, isSpeaking: false, ttsSpeaking: true
        ))
    }

    func testDeferredInBusyPhases() {
        for phase in [AgentTurnPhase.speaking, .interrupted, .approval] {
            XCTAssertTrue(AgentApprovalDeferralPolicy.shouldDefer(
                phase: phase, isInputActive: false, isSpeaking: false, ttsSpeaking: false
            ), "\(phase)")
        }
    }
}
