import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionReplayTests: QwenVoiceSessionTestCase {
  // MARK: - 重听状态（任务结果 / 助手回复）

  func testTaskResultTextPrefersInlineResult() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "开始生成"))
    session.consume(.timelineInline(taskId: "t1", content: "已生成 12 页周报"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "周报已生成"))
    XCTAssertEqual(session.lastTaskResultText, "已生成 12 页周报")
    XCTAssertNotNil(session.lastTaskResultAt)
  }

  func testTaskResultTextFallsBackToNaturalAnnouncement() {
    session.consume(.task(type: "task.completed", taskId: "t1", title: "周报已生成"))
    XCTAssertTrue(session.lastTaskResultText.contains("周报已生成"))
    XCTAssertNotEqual(session.lastTaskResultText, "周报已生成", "无详细结果时用自然回归话术")
  }

  func testAssistantReplyRecordsTimestamp() {
    session.appendAssistantText("  好的，马上办  ")
    XCTAssertEqual(session.lastAssistantText, "好的，马上办")
    XCTAssertNotNil(session.lastAssistantReplyAt)
  }

  func testClearTaskFeedResetsReplayState() {
    session.consume(.task(type: "task.completed", taskId: "t1", title: "完成"))
    XCTAssertFalse(session.lastTaskResultText.isEmpty)
    session.clearTaskFeed()
    XCTAssertTrue(session.lastTaskResultText.isEmpty)
    XCTAssertNil(session.lastTaskResultAt)
  }

  // MARK: - 任务相对时间

  func testRelativeTimeBuckets() {
    let now = Date()
    XCTAssertEqual(
        AgentTaskTimeFormatter.relativeTime(from: now.addingTimeInterval(-10), now: now),
        "agent.task.time.justnow".localized
    )
    XCTAssertEqual(
        AgentTaskTimeFormatter.relativeTime(from: now.addingTimeInterval(-150), now: now),
        "agent.task.time.minutes".localized(2)
    )
    XCTAssertEqual(
        AgentTaskTimeFormatter.relativeTime(from: now.addingTimeInterval(-3 * 3600), now: now),
        "agent.task.time.hours".localized(3)
    )
    XCTAssertEqual(
        AgentTaskTimeFormatter.relativeTime(from: now.addingTimeInterval(-2 * 86400), now: now),
        "agent.task.time.days".localized(2)
    )
  }
}
