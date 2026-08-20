import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

/// 审批超时倒计时纯计算
final class AgentPermissionCountdownTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_772_884_800)

  func testRemainingSecondsCeilsUp() {
    XCTAssertEqual(
      AgentPermissionCountdown.remainingSeconds(expiresAt: now.addingTimeInterval(10.2), now: now),
      11,
      "向上取整到秒粒度"
    )
    XCTAssertEqual(
      AgentPermissionCountdown.remainingSeconds(expiresAt: now.addingTimeInterval(0.5), now: now),
      1
    )
    XCTAssertEqual(
      AgentPermissionCountdown.remainingSeconds(expiresAt: now.addingTimeInterval(60), now: now),
      60
    )
  }

  func testRemainingSecondsExpiredOrNil() {
    XCTAssertEqual(AgentPermissionCountdown.remainingSeconds(expiresAt: nil, now: now), 0)
    XCTAssertEqual(
      AgentPermissionCountdown.remainingSeconds(expiresAt: now.addingTimeInterval(-1), now: now),
      0,
      "已超时显示 0"
    )
    XCTAssertEqual(
      AgentPermissionCountdown.remainingSeconds(expiresAt: now, now: now),
      0,
      "恰好到点显示 0"
    )
  }

  func testProgressFractionBounds() {
    let expiresAt = now.addingTimeInterval(60)
    XCTAssertEqual(
      AgentPermissionCountdown.progressFraction(expiresAt: expiresAt, now: now, timeout: 60),
      0,
      "刚开始进度为 0"
    )
    XCTAssertEqual(
      AgentPermissionCountdown.progressFraction(
        expiresAt: expiresAt,
        now: expiresAt,
        timeout: 60
      ),
      1,
      "到点进度为 1"
    )
    XCTAssertEqual(
      AgentPermissionCountdown.progressFraction(
        expiresAt: now.addingTimeInterval(30),
        now: now,
        timeout: 60
      ),
      0.5,
      "还剩 30 秒（已过 30 秒）时进度为 0.5"
    )
    XCTAssertEqual(
      AgentPermissionCountdown.progressFraction(expiresAt: nil, now: now, timeout: 60),
      0
    )
    XCTAssertEqual(
      AgentPermissionCountdown.progressFraction(expiresAt: now, now: now, timeout: 0),
      0,
      "timeout 为 0（不自动跳过）时进度为 0"
    )
  }

}
