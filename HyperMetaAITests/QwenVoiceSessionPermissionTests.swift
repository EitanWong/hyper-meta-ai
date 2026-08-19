import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionPermissionTests: QwenVoiceSessionTestCase {
  // MARK: - 权限审批

  private func pendingPermissionEvent() -> QwenPermission {
    QwenPermission(
      id: "auth_1",
      workId: "run_1",
      status: .pending,
      category: "run_command",
      summary: "run_command：需要执行 shell 命令"
    )
  }

  func testPermissionRequestedShowsPendingCard() {
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))

    XCTAssertEqual(session.pendingPermission?.permission.id, "auth_1")
    XCTAssertEqual(session.pendingPermission?.taskId, "t1")
    XCTAssertEqual(session.taskFeed.last?.kind, .permissionRequested)
    XCTAssertEqual(session.taskFeed.last?.text, "run_command：需要执行 shell 命令")
    XCTAssertEqual(session.taskMessage, "run_command：需要执行 shell 命令")
  }

  func testPermissionExpiresAtLifecycle() async {
    XCTAssertNil(session.permissionExpiresAt)

    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    XCTAssertNotNil(session.permissionExpiresAt, "审批卡出现时记录超时截止时间")
    guard let expiresAt = session.permissionExpiresAt else {
      XCTFail("应已设置截止时间")
      return
    }
    XCTAssertGreaterThan(expiresAt.timeIntervalSinceNow, 0)

    session.dismissPermission()
    XCTAssertNil(session.permissionExpiresAt, "收起审批卡后清除截止时间")

    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    XCTAssertNotNil(session.permissionExpiresAt)
    permissionResponder.result = .success(
      QwenPermission(id: "auth_1", workId: "run_1", status: .denied, category: "run_command", summary: "")
    )
    let deny = await session.respondToPermission(.deny)
    XCTAssertTrue(deny)
    XCTAssertNil(session.permissionExpiresAt, "提交决策后清除截止时间")
  }

  func testPermissionRequestedNonPendingIsIgnored() {
    let resolved = QwenPermission(id: "auth_1", workId: nil, status: .approved, category: "", summary: "")
    session.consume(.permissionRequested(taskId: "t1", permission: resolved))
    XCTAssertNil(session.pendingPermission)
    XCTAssertTrue(session.taskFeed.isEmpty)
  }

  func testPermissionResolvedClearsPendingCard() {
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    let resolved = QwenPermission(id: "auth_1", workId: "run_1", status: .approved, category: "run_command", summary: "")
    session.consume(.permissionResolved(taskId: "t1", permission: resolved))

    XCTAssertNil(session.pendingPermission)
    XCTAssertEqual(session.taskFeed.last?.kind, .completed)
  }

  func testRespondToPermissionAllow() async {
    permissionResponder.result = .success(
      QwenPermission(id: "auth_1", workId: "run_1", status: .approved, category: "run_command", summary: "")
    )
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))

    let ok = await session.respondToPermission(.allow)
    XCTAssertTrue(ok)
    XCTAssertEqual(permissionResponder.receivedID, "auth_1")
    XCTAssertEqual(permissionResponder.receivedDecision, .allow)
    XCTAssertNil(session.pendingPermission)
    XCTAssertEqual(session.taskFeed.last?.kind, .completed)
    XCTAssertNil(session.permissionError)
  }

  func testRespondToPermissionDeny() async {
    permissionResponder.result = .success(
      QwenPermission(id: "auth_1", workId: "run_1", status: .denied, category: "run_command", summary: "")
    )
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))

    let ok = await session.respondToPermission(.deny)
    XCTAssertTrue(ok)
    XCTAssertEqual(permissionResponder.receivedDecision, .deny)
    XCTAssertNil(session.pendingPermission)
    XCTAssertEqual(session.taskFeed.last?.kind, .cancelled)
  }

  func testRespondToPermissionFailureKeepsPendingCard() async {
    permissionResponder.result = .failure(URLError(.badServerResponse))
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))

    let ok = await session.respondToPermission(.allow)
    XCTAssertFalse(ok)
    XCTAssertEqual(session.pendingPermission?.permission.id, "auth_1")
    XCTAssertEqual(session.pendingPermission?.isSubmitting, false)
    XCTAssertNotNil(session.permissionError)
  }

  func testResolvedEventAfterHttpResponseDoesNotDuplicateFeedItem() async {
    permissionResponder.result = .success(
      QwenPermission(id: "auth_1", workId: "run_1", status: .approved, category: "run_command", summary: "")
    )
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    await session.respondToPermission(.allow)

    let feedCountAfterHTTP = session.taskFeed.count
    session.consume(.permissionResolved(
      taskId: "t1",
      permission: QwenPermission(id: "auth_1", workId: "run_1", status: .approved, category: "run_command", summary: "")
    ))
    XCTAssertEqual(session.taskFeed.count, feedCountAfterHTTP, "WS resolved 事件不应重复追加结果条目")
  }

  func testDismissPermissionHidesCard() {
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    session.dismissPermission()
    XCTAssertNil(session.pendingPermission)
  }

  func testClearTaskFeedClearsPendingPermission() {
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    session.clearTaskFeed()
    XCTAssertNil(session.pendingPermission)
    XCTAssertNil(session.permissionError)
    XCTAssertTrue(session.taskFeed.isEmpty)
  }

  // MARK: - Helpers

  private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - 审批超时

  func testPermissionTimeoutAutoDismisses() async {
    let shortSession = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      permissionTimeout: 0.2
    )
    shortSession.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    XCTAssertNotNil(shortSession.pendingPermission)

    await waitUntil(timeout: 2) {
      shortSession.pendingPermission == nil && shortSession.permissionTimedOut
    }
    XCTAssertNil(shortSession.pendingPermission)
    XCTAssertTrue(shortSession.permissionTimedOut)
    shortSession.clearPermissionTimeout()
    XCTAssertFalse(shortSession.permissionTimedOut)
  }

  func testPermissionTimeoutCancelledByDismiss() async {
    let shortSession = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      permissionTimeout: 0.2
    )
    shortSession.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    shortSession.dismissPermission()

    try? await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertNil(shortSession.pendingPermission)
    XCTAssertFalse(shortSession.permissionTimedOut)
  }

  func testPermissionTimeoutPausedWhileCardDeferred() async {
    let shortSession = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      permissionTimeout: 0.2
    )
    shortSession.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    // 会话忙碌：审批卡延迟展示，超时计时暂停
    shortSession.pausePermissionTimeout()

    try? await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertNotNil(shortSession.pendingPermission, "延迟展示期间不得被超时自动跳过")
    XCTAssertFalse(shortSession.permissionTimedOut)

    // 会话空闲：卡片弹出，恢复超时计时
    shortSession.resumePermissionTimeout()
    await waitUntil(timeout: 2) {
      shortSession.pendingPermission == nil && shortSession.permissionTimedOut
    }
    XCTAssertNil(shortSession.pendingPermission)
    XCTAssertTrue(shortSession.permissionTimedOut)
  }

  func testResumePermissionTimeoutWithoutPendingIsNoop() async {
    let shortSession = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      permissionTimeout: 0.2
    )
    // 无待审批请求时恢复超时计时：不应崩溃、不应产生任何副作用
    shortSession.resumePermissionTimeout()
    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertNil(shortSession.pendingPermission)
    XCTAssertFalse(shortSession.permissionTimedOut)
  }

  // MARK: - 权限分级模式

  private func approvedPermission() -> QwenPermission {
    QwenPermission(
      id: "auth_1",
      workId: "run_1",
      status: .approved,
      category: "run_command",
      summary: "run_command：需要执行 shell 命令"
    )
  }

  private func deniedPermission() -> QwenPermission {
    QwenPermission(
      id: "auth_1",
      workId: "run_1",
      status: .denied,
      category: "run_command",
      summary: "run_command：需要执行 shell 命令"
    )
  }

  func testPermissionModeDefaultsAlwaysAsk() {
    UserDefaults.standard.removeObject(forKey: AgentPermissionSettings.modeKey)
    XCTAssertEqual(AgentPermissionSettings.mode, .alwaysAsk)
    AgentPermissionSettings.mode = .session
    XCTAssertEqual(AgentPermissionSettings.mode, .session)
    AgentPermissionSettings.mode = .denyAll
    XCTAssertEqual(AgentPermissionSettings.mode, .denyAll)
  }

  func testPermissionModeSessionAutoAllowsWithoutCard() async {
    AgentPermissionSettings.mode = .session
    permissionResponder.result = .success(approvedPermission())

    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    XCTAssertNil(session.pendingPermission, "会话内放行模式不应弹审批卡")

    let handled = await session.autoHandlePermission(taskId: "t1", permission: pendingPermissionEvent())
    XCTAssertTrue(handled)
    XCTAssertEqual(permissionResponder.receivedDecision, .allow)
    XCTAssertNil(session.pendingPermission)
    XCTAssertEqual(session.taskFeed.last?.kind, .completed)
  }

  func testPermissionModeDenyAllAutoDeniesWithoutCard() async {
    AgentPermissionSettings.mode = .denyAll
    permissionResponder.result = .success(deniedPermission())

    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    XCTAssertNil(session.pendingPermission, "全部拒绝模式不应弹审批卡")

    let handled = await session.autoHandlePermission(taskId: "t1", permission: pendingPermissionEvent())
    XCTAssertTrue(handled)
    XCTAssertEqual(permissionResponder.receivedDecision, .deny)
    XCTAssertNil(session.pendingPermission)
    XCTAssertEqual(session.taskFeed.last?.kind, .cancelled)
  }

  func testPermissionModeSingleUseShowsCardFirstThenAutoAllows() async {
    AgentPermissionSettings.mode = .singleUse
    permissionResponder.result = .success(approvedPermission())

    // 首次请求：弹卡
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    XCTAssertEqual(session.pendingPermission?.permission.id, "auth_1")

    // 人工批准后：本会话内同一权限自动放行
    let ok = await session.respondToPermission(.allow)
    XCTAssertTrue(ok)
    XCTAssertNil(session.pendingPermission)

    session.consume(.permissionRequested(taskId: "t2", permission: pendingPermissionEvent()))
    XCTAssertNil(session.pendingPermission, "已批准过的权限不应再次弹卡")

    // 不同权限 ID 仍弹卡
    let other = QwenPermission(
      id: "auth_2",
      workId: "run_2",
      status: .pending,
      category: "send_message",
      summary: "send_message：需要发送消息"
    )
    session.consume(.permissionRequested(taskId: "t3", permission: other))
    XCTAssertEqual(session.pendingPermission?.permission.id, "auth_2")
  }

  func testPermissionModeSingleUseMemoryClearsOnSessionStart() async {
    AgentPermissionSettings.mode = .singleUse
    permissionResponder.result = .success(approvedPermission())
    session.consume(.permissionRequested(taskId: "t1", permission: pendingPermissionEvent()))
    _ = await session.respondToPermission(.allow)

    // 新会话开始：记忆清空，同一权限再次弹卡
    session.start()
    session.stop()
    session.consume(.permissionRequested(taskId: "t2", permission: pendingPermissionEvent()))
    XCTAssertEqual(session.pendingPermission?.permission.id, "auth_1")
  }

  func testPermissionModeAutoHandleFailureFallsBackToCard() async {
    AgentPermissionSettings.mode = .session
    permissionResponder.result = .failure(URLError(.badServerResponse))

    let handled = await session.autoHandlePermission(taskId: "t1", permission: pendingPermissionEvent())
    XCTAssertFalse(handled)
    XCTAssertEqual(session.pendingPermission?.permission.id, "auth_1", "网关失败时应回退为人工审批")
    XCTAssertNotNil(session.permissionError)
  }
}
