import Foundation
import XCTest

@testable import HyperMetaAI

private final class VoiceSessionMockSocket: QwenGatewaySocket {
  var sentMessages: [String] = []
  private var pendingReceives: [(Result<String, Error>) -> Void] = []
  private var queuedDeliveries: [Result<String, Error>] = []

  func send(_ string: String, completion: @escaping (Error?) -> Void) {
    sentMessages.append(string)
    completion(nil)
  }

  func receive(completion: @escaping (Result<String, Error>) -> Void) {
    if queuedDeliveries.isEmpty {
      pendingReceives.append(completion)
    } else {
      completion(queuedDeliveries.removeFirst())
    }
  }

  func close() {}

  func deliver(_ json: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let text = String(data: data, encoding: .utf8)!
    if pendingReceives.isEmpty {
      queuedDeliveries.append(.success(text))
    } else {
      pendingReceives.removeFirst()(.success(text))
    }
  }
}

private final class MockPermissionResponder: QwenPermissionResponding {
  var result: Result<QwenPermission, Error> = .failure(URLError(.badServerResponse))
  private(set) var receivedID: String?
  private(set) var receivedDecision: QwenPermissionDecision?

  func respondPermission(
    id: String,
    decision: QwenPermissionDecision
  ) async throws -> QwenPermission {
    receivedID = id
    receivedDecision = decision
    return try result.get()
  }
}

private final class MockWakeWordMonitor: QwenWakeWordListening {
  var isMonitoring = false
  var onWakeWord: ((String) -> Void)?
  var onTranscript: ((String) -> Void)?
  var shouldFail = false

  func startMonitoring() async throws {
    if shouldFail { throw QwenWakeWordError.recognizerUnavailable }
    isMonitoring = true
  }

  func stopMonitoring() {
    isMonitoring = false
  }
}

@MainActor
final class QwenVoiceSessionTests: XCTestCase {
  private var mockSocket: VoiceSessionMockSocket!
  private var gateway: QwenGatewayService!
  private var session: QwenVoiceSession!
  private var permissionResponder: MockPermissionResponder!

  override func setUp() {
    super.setUp()
    mockSocket = VoiceSessionMockSocket()
    gateway = QwenGatewayService(socketFactory: { _ in self.mockSocket })
    gateway.mode = .external
    permissionResponder = MockPermissionResponder()
    session = QwenVoiceSession(gateway: gateway, permissionResponder: permissionResponder)
  }

  override func tearDown() {
    session.stop()
    gateway.disconnect()
    UserDefaults.standard.removeObject(forKey: AgentPermissionSettings.modeKey)
    session = nil
    permissionResponder = nil
    gateway = nil
    mockSocket = nil
    super.tearDown()
  }

  func testVoiceReadyUpdatesConnectionState() {
    session.consume(.voiceReady(inputSampleRate: 16_000))
    XCTAssertEqual(session.connectionState, .connected)
  }

  func testTranscriptEventsUpdateText() {
    session.consume(.transcriptDelta(role: "user", text: "帮我"))
    session.consume(.transcriptFinal(role: "user", text: "帮我查天气"))
    XCTAssertEqual(session.lastUserText, "帮我查天气")

    session.consume(.transcriptFinal(role: "assistant", text: "好的"))
    XCTAssertEqual(session.lastAssistantText, "好的")
  }

  func testTaskEventUpdatesTaskMessage() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "正在帮你处理"))
    XCTAssertEqual(session.taskMessage, "正在帮你处理")
  }

  func testTaskDelegatedEmitsAcknowledgmentOnce() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.task(type: "task.progress", taskId: "t1", title: "正在整理"))
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))

    let receipts = session.transcriptLog.filter {
      $0.role == .system && $0.text.contains("整理报告")
    }
    XCTAssertEqual(receipts.count, 1, "同一任务重复事件只回执一次")
    XCTAssertEqual(session.acknowledgmentNotice?.taskId, "t1")
    XCTAssertEqual(session.acknowledgmentNotice?.title, "整理报告")
  }

  func testTaskScheduledEmitsAcknowledgment() {
    session.consume(.task(type: "task.scheduled", taskId: "t3", title: "排队任务"))

    XCTAssertEqual(session.acknowledgmentNotice?.taskId, "t3")
    XCTAssertTrue(session.transcriptLog.contains {
      $0.role == .system && $0.text.contains("排队任务")
    })
  }

  func testTaskDelegatedTracksWaitingTask() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))

    XCTAssertEqual(session.runningTaskCount, 1)
    XCTAssertEqual(session.agentTasks.count, 1)
    XCTAssertEqual(session.agentTasks[0].status, .waiting)
    XCTAssertEqual(session.agentTasks[0].title, "订餐厅")
    XCTAssertNotNil(session.acknowledgmentNotice)
  }

  func testAnnouncementGateWaitsForQuietWindow() {
    XCTAssertTrue(AgentAnnouncementGate.shouldAnnounce(
      isSpeaking: false,
      isInputActive: false,
      ttsSpeaking: false
    ))
    XCTAssertFalse(AgentAnnouncementGate.shouldAnnounce(
      isSpeaking: true,
      isInputActive: false,
      ttsSpeaking: false
    ), "网关播报中不抢话")
    XCTAssertFalse(AgentAnnouncementGate.shouldAnnounce(
      isSpeaking: false,
      isInputActive: true,
      ttsSpeaking: false
    ), "用户输入中不抢话")
    XCTAssertFalse(AgentAnnouncementGate.shouldAnnounce(
      isSpeaking: false,
      isInputActive: false,
      ttsSpeaking: true
    ), "本地 TTS 播报中不叠加")
  }

  // MARK: - 任务完成自然回归话术

  func testCompletionAnnouncementUsesNaturalCopyWhenNoResult() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "整理报告"))

    XCTAssertEqual(session.completionNotice?.text, "整理报告", "横幅仍展示原始标题")
    XCTAssertTrue(session.lastTaskResultText.contains("整理报告"))
    XCTAssertNotEqual(session.lastTaskResultText, "整理报告", "无详细结果时用自然话术而非干巴巴标题")
  }

  func testCompletionAnnouncementKeepsDetailedResult() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.timelineInline(taskId: "t1", content: "报告已生成，共 12 页"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "整理报告"))

    XCTAssertEqual(session.lastTaskResultText, "报告已生成，共 12 页")
  }

  // MARK: - 任务结果追问上下文（大脑转发模式）

  func testCompletionRecordsDetailedResultAsFollowUpContext() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.timelineInline(taskId: "t1", content: "报告已生成，共 12 页"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "整理报告"))

    XCTAssertEqual(session.resultFollowUpContext, "报告已生成，共 12 页")
    let message = session.followUpMessage("展开第三条")
    XCTAssertTrue(message.contains("报告已生成，共 12 页"))
    XCTAssertTrue(message.contains("展开第三条"))
    XCTAssertTrue(message.contains("【任务结果】"), "明确标注结果段，便于大脑区分上下文与追问")
  }

  func testCompletionWithoutDetailedResultClearsFollowUpContext() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "整理报告"))

    XCTAssertNil(session.resultFollowUpContext, "无详细结果（仅自然话术）时没有可追问内容")
    XCTAssertEqual(session.followUpMessage("展开第三条"), "展开第三条", "无上下文时原样返回")
  }

  func testFollowUpContextReplacedByNewerTask() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "任务一"))
    session.consume(.timelineInline(taskId: "t1", content: "任务一的结果"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "任务一"))

    session.consume(.task(type: "task.delegated", taskId: "t2", title: "任务二"))
    session.consume(.timelineInline(taskId: "t2", content: "任务二的结果"))
    session.consume(.task(type: "task.completed", taskId: "t2", title: "任务二"))

    XCTAssertEqual(session.resultFollowUpContext, "任务二的结果", "新任务结果覆盖旧结果")
  }

  func testFollowUpContextClearedWithTaskFeed() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.timelineInline(taskId: "t1", content: "报告已生成，共 12 页"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "整理报告"))
    XCTAssertNotNil(session.resultFollowUpContext)

    session.clearTaskFeed()
    XCTAssertNil(session.resultFollowUpContext)
    XCTAssertEqual(session.followUpMessage("展开第三条"), "展开第三条")
  }

  func testFollowUpContextTruncatedToMaxLength() {
    let longResult = String(repeating: "字", count: QwenVoiceSession.resultFollowUpMaxLength + 100)
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "长任务"))
    session.consume(.timelineInline(taskId: "t1", content: longResult))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "长任务"))

    XCTAssertEqual(session.resultFollowUpContext?.count, QwenVoiceSession.resultFollowUpMaxLength)
  }

  func testHasFollowUpContextReflectsResultContext() {
    XCTAssertFalse(session.hasFollowUpContext)

    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.timelineInline(taskId: "t1", content: "报告已生成，共 12 页"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "整理报告"))
    XCTAssertTrue(session.hasFollowUpContext, "有详细结果时可追问")

    session.consume(.task(type: "task.delegated", taskId: "t2", title: "发邮件"))
    session.consume(.task(type: "task.completed", taskId: "t2", title: "发邮件"))
    XCTAssertFalse(session.hasFollowUpContext, "无详细结果的新任务清空追问上下文")
  }

  // MARK: - 结果追问上下文恢复（通知 / 锁屏结果卡深链）

  func testRestoreFollowUpContextInjectsContext() {
    session.restoreFollowUpContext("  报告已生成，共 12 页  ")

    XCTAssertEqual(session.resultFollowUpContext, "报告已生成，共 12 页", "去空白后注入")
    XCTAssertEqual(session.lastTaskResultText, "报告已生成，共 12 页")
    XCTAssertTrue(session.hasFollowUpContext)
    let message = session.followUpMessage("展开第三条")
    XCTAssertTrue(message.contains("报告已生成，共 12 页"))
    XCTAssertTrue(message.contains("展开第三条"))
  }

  func testRestoreFollowUpContextTruncatesLongText() {
    let long = String(repeating: "字", count: QwenVoiceSession.resultFollowUpMaxLength + 200)
    session.restoreFollowUpContext(long)
    XCTAssertEqual(session.resultFollowUpContext?.count, QwenVoiceSession.resultFollowUpMaxLength)
    XCTAssertEqual(session.lastTaskResultText.count, QwenVoiceSession.resultFollowUpMaxLength)
  }

  func testRestoreFollowUpContextIgnoresWhitespace() {
    session.restoreFollowUpContext("   ")
    XCTAssertNil(session.resultFollowUpContext)
    XCTAssertFalse(session.hasFollowUpContext)
  }

  // MARK: - 任务指令 → 本地回复（语音页/聊天页共用）

  func testTaskCommandResponseBuilderQuery() {
    XCTAssertNil(AgentTaskCommandResponseBuilder.reply(for: .queryProgress, session: session))

    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    let reply = AgentTaskCommandResponseBuilder.reply(for: .queryProgress, session: session)
    XCTAssertNotNil(reply)
    XCTAssertTrue(reply!.contains("订餐厅"))
  }

  func testTaskCommandResponseBuilderIndexedQueryAndRange() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "整理报告"))

    let first = AgentTaskCommandResponseBuilder.reply(for: .queryProgressTask(0), session: session)
    XCTAssertTrue(first!.contains("订餐厅"))

    let second = AgentTaskCommandResponseBuilder.reply(for: .queryProgressTask(1), session: session)
    XCTAssertTrue(second!.contains("整理报告"))

    let outOfRange = AgentTaskCommandResponseBuilder.reply(for: .queryProgressTask(4), session: session)
    XCTAssertTrue(
      outOfRange!.contains(String(format: "agent.task.command.index.range".localized, 5, 2)),
      "越界提示当前数量：\(outOfRange!)"
    )
  }

  func testTaskCommandResponseBuilderCancel() {
    XCTAssertNil(AgentTaskCommandResponseBuilder.reply(for: .cancelLatest, session: session))

    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "整理报告"))

    let latest = AgentTaskCommandResponseBuilder.reply(for: .cancelLatest, session: session)
    XCTAssertTrue(latest!.contains("整理报告"), "取消最近任务：\(latest!)")

    let indexed = AgentTaskCommandResponseBuilder.reply(for: .cancelTask(0), session: session)
    XCTAssertTrue(indexed!.contains("订餐厅"), "按序号取消：\(indexed!)")

    let outOfRange = AgentTaskCommandResponseBuilder.reply(for: .cancelTask(9), session: session)
    XCTAssertTrue(
      outOfRange!.contains(String(format: "agent.task.command.index.range".localized, 10, 2)),
      "取消越界提示当前数量：\(outOfRange!)"
    )
  }

  func testTaskCommandResponseBuilderRetryNilWithoutFailedTasks() {
    XCTAssertNil(AgentTaskCommandResponseBuilder.reply(for: .retryLatest, session: session))

    // 仅有活动任务（无失败任务）不构成重试目标
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    XCTAssertNil(AgentTaskCommandResponseBuilder.reply(for: .retryLatest, session: session))
  }

  func testTaskRetryReplaysOriginalSourceText() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.sendText("帮我订周五晚上的餐厅")
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.failed", taskId: "t1", title: "订餐厅"))

    XCTAssertEqual(session.failedTasks.count, 1)
    XCTAssertEqual(session.failedTasks[0].sourceText, "帮我订周五晚上的餐厅")
    XCTAssertTrue(session.failedTasks[0].title.contains("订餐厅"))

    let reply = AgentTaskCommandResponseBuilder.reply(for: .retryLatest, session: session)
    XCTAssertNotNil(reply)
    XCTAssertTrue(reply!.contains("订餐厅"), "重试回复含任务名：\(reply!)")
    XCTAssertTrue(
      mockSocket.sentMessages.contains(where: { $0.contains("帮我订周五晚上的餐厅") }),
      "重试应原样重放原始口述，而不是重试指令"
    )
    XCTAssertEqual(session.lastUserText, "帮我订周五晚上的餐厅")

    // 复跑任务（新 taskId）继承同一来源文本，后续重试仍重放原始请求
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "订餐厅"))
    XCTAssertEqual(session.agentTasks.last?.sourceText, "帮我订周五晚上的餐厅")
  }

  func testTaskRetryFallsBackToInstructionWithoutSource() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    // 无口述来源（如快捷指令触发）：退化为自然语言重试指令
    session.consume(.task(type: "task.failed", taskId: "t1", title: "订餐厅"))

    let instruction = "agent.task.command.retry.instruction".localized("订餐厅")
    let reply = AgentTaskCommandResponseBuilder.reply(for: .retryLatest, session: session)
    XCTAssertNotNil(reply)
    XCTAssertTrue(reply!.contains("订餐厅"), "重试回复含任务名：\(reply!)")
    XCTAssertTrue(
      mockSocket.sentMessages.contains(where: { $0.contains(instruction) }),
      "无原始文本时发送自然语言重试指令"
    )
    XCTAssertTrue(
      session.transcriptLog.contains { $0.role == .system && $0.text.contains("订餐厅") },
      "重试发送后记录系统提示"
    )
  }

  func testTaskCommandResponseBuilderIndexedRetryAndRange() {
    session.consume(.task(type: "task.failed", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.failed", taskId: "t2", title: "整理报告"))

    let first = AgentTaskCommandResponseBuilder.reply(for: .retryTask(0), session: session)
    XCTAssertTrue(first!.contains("订餐厅"), "按序号重试：\(first!)")

    let outOfRange = AgentTaskCommandResponseBuilder.reply(for: .retryTask(4), session: session)
    XCTAssertTrue(
      outOfRange!.contains(String(format: "agent.task.command.index.range.failed".localized, 5, 2)),
      "重试越界提示当前失败任务数：\(outOfRange!)"
    )
  }

  func testTaskRetryByTaskIDTargetsSpecificTask() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.sendText("帮我订周五晚上的餐厅")
    session.consume(.task(type: "task.failed", taskId: "t1", title: "订餐厅"))
    session.sendText("整理会议纪要")
    session.consume(.task(type: "task.failed", taskId: "t2", title: "整理报告"))

    // 未知 taskId 返回 nil，不误伤
    XCTAssertNil(session.requestTaskRetry(taskId: "missing"))

    // 按 taskId 重试 t2：只重放 t2 自己的触发文本，不误放 t1 的
    let baseline = mockSocket.sentMessages.count
    let name = session.requestTaskRetry(taskId: "t2")
    XCTAssertEqual(name, "整理报告")
    let retrySends = mockSocket.sentMessages.dropFirst(baseline)
    XCTAssertTrue(
      retrySends.contains(where: { $0.contains("整理会议纪要") }),
      "重试 t2 应重放 t2 的触发文本"
    )
    XCTAssertFalse(
      retrySends.contains(where: { $0.contains("帮我订周五晚上的餐厅") }),
      "重试 t2 不应重放 t1 的触发文本"
    )

    // 重试 t1：重放 t1 自己的触发文本
    _ = session.requestTaskRetry(taskId: "t1")
    XCTAssertTrue(
      mockSocket.sentMessages.dropFirst(baseline).contains(where: {
        $0.contains("帮我订周五晚上的餐厅")
      })
    )
  }

  func testCompletionAnnouncementCoversFailureAndCancellation() {
    session.consume(.task(type: "task.failed", taskId: "t1", title: "订餐厅"))
    XCTAssertNotEqual(session.lastTaskResultText, "订餐厅")
    XCTAssertTrue(session.lastTaskResultText.contains("订餐厅"))

    session.consume(.task(type: "task.cancelled", taskId: "t2", title: "发邮件"))
    XCTAssertNotEqual(session.lastTaskResultText, "发邮件")
    XCTAssertTrue(session.lastTaskResultText.contains("发邮件"))
  }

  func testCompletionAnnouncementMappingKinds() {
    XCTAssertEqual(
      AgentCompletionAnnouncement.text(kind: .completed, title: "A", result: "详细结果"),
      "详细结果",
      "有详细结果直接播结果原文"
    )
    XCTAssertTrue(AgentCompletionAnnouncement.text(kind: .completed, title: "A").contains("A"))
    XCTAssertTrue(AgentCompletionAnnouncement.text(kind: .failed, title: "A").contains("A"))
    XCTAssertTrue(AgentCompletionAnnouncement.text(kind: .cancelled, title: "A").contains("A"))
    XCTAssertFalse(AgentCompletionAnnouncement.text(kind: .completed, title: "").isEmpty)
    XCTAssertFalse(AgentCompletionAnnouncement.text(kind: .failed, title: "  ").isEmpty)
  }

  func testTaskFeedTracksLifecycle() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的，马上处理"))
    session.consume(.task(type: "task.progress", taskId: "t1", title: "正在查询资料"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "处理完成"))

    XCTAssertEqual(session.taskFeed.count, 3)
    XCTAssertEqual(session.taskFeed[0].kind, .delegated)
    XCTAssertEqual(session.taskFeed[0].taskId, "t1")
    XCTAssertEqual(session.taskFeed[1].kind, .progress)
    XCTAssertEqual(session.taskFeed[2].kind, .completed)
    XCTAssertEqual(session.taskFeed[2].text, "处理完成")
  }

  func testTaskFailureAndCancellationKinds() {
    session.consume(.task(type: "task.failed", taskId: "t2", title: "执行失败"))
    XCTAssertEqual(session.taskFeed.last?.kind, .failed)

    session.consume(.task(type: "task.cancelled", taskId: "t2", title: "已取消"))
    XCTAssertEqual(session.taskFeed.last?.kind, .cancelled)
  }

  func testTimelineInlineAddsResultItem() {
    session.consume(.timelineInline(taskId: "t1", content: "任务结果摘要"))
    XCTAssertEqual(session.taskFeed.count, 1)
    XCTAssertEqual(session.taskFeed[0].kind, .result)
    XCTAssertEqual(session.taskFeed[0].text, "任务结果摘要")
    XCTAssertEqual(session.taskMessage, "任务结果摘要")
  }

  func testUnknownTaskTypeIsIgnoredInFeed() {
    session.consume(.task(type: "task.unknown", taskId: "t9", title: "忽略"))
    XCTAssertTrue(session.taskFeed.isEmpty)
  }

  func testRunningTaskCountTracksUniqueTasks() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的"))
    XCTAssertEqual(session.runningTaskCount, 1)
    session.consume(.task(type: "task.progress", taskId: "t1", title: "进行中"))
    XCTAssertEqual(session.runningTaskCount, 1, "同一任务不重复计数")
    session.consume(.task(type: "task.running", taskId: "t2", title: "第二个任务"))
    XCTAssertEqual(session.runningTaskCount, 2)

    session.consume(.task(type: "task.completed", taskId: "t1", title: "完成"))
    XCTAssertEqual(session.runningTaskCount, 1)
    session.consume(.task(type: "task.failed", taskId: "t2", title: "失败"))
    XCTAssertEqual(session.runningTaskCount, 0)
  }

  func testTaskWithoutIdDoesNotAffectCount() {
    session.consume(.task(type: "task.delegated", taskId: nil, title: "无 ID"))
    XCTAssertEqual(session.runningTaskCount, 0)
  }

  func testClearTaskFeedResetsCount() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的"))
    XCTAssertEqual(session.runningTaskCount, 1)
    session.clearTaskFeed()
    XCTAssertEqual(session.runningTaskCount, 0)
    XCTAssertTrue(session.taskFeed.isEmpty)
  }

  // MARK: - Agent Task Model

  func testAgentTaskTracksLifecycle() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的，马上处理"))
    XCTAssertEqual(session.agentTasks.count, 1)
    XCTAssertEqual(session.agentTasks[0].status, .waiting, "已委派未开始 = 等待中")
    XCTAssertEqual(session.agentTasks[0].title, "好的，马上处理")

    session.consume(.task(type: "task.progress", taskId: "t1", title: "正在查询资料"))
    XCTAssertEqual(session.agentTasks.count, 1, "同一任务不重复创建")
    XCTAssertEqual(session.agentTasks[0].title, "正在查询资料")
    XCTAssertEqual(session.agentTasks[0].status, .running)

    session.consume(.task(type: "task.completed", taskId: "t1", title: "处理完成"))
    XCTAssertEqual(session.agentTasks[0].status, .completed)
    XCTAssertEqual(session.completionNotice?.kind, .completed)
    XCTAssertEqual(session.completionNotice?.text, "处理完成")
  }

  func testTimelineInlinePromotesWaitingToRunning() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    XCTAssertEqual(session.agentTasks[0].status, .waiting)

    session.consume(.timelineInline(taskId: "t1", content: "正在打开文档"))
    XCTAssertEqual(session.agentTasks[0].status, .running)
    XCTAssertEqual(session.agentTasks[0].resultText, "正在打开文档")
  }

  func testTaskProgressSummaryQueuedTask() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))

    let summary = session.taskProgressSummary
    XCTAssertNotNil(summary)
    XCTAssertTrue(summary!.contains("订餐厅"))
    XCTAssertTrue(
      summary!.contains("queued") || summary!.contains("等待中"),
      "等待中的任务应播报排队状态: \(summary!)"
    )
  }

  func testLatestRunningTaskIncludesWaitingTasks() {
    session.consume(.task(type: "task.completed", taskId: "t1", title: "已完成任务"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "排队任务"))
    session.consume(.task(type: "task.running", taskId: "t3", title: "执行中任务"))

    XCTAssertEqual(session.latestRunningTask?.taskId, "t3")
    XCTAssertEqual(session.taskProgressSummary?.contains("执行中任务"), true)
  }

  func testAgentTaskCompletionNoticeFiresOnce() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "完成"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "完成"))
    XCTAssertEqual(session.completionNotice?.kind, .completed)
    session.clearCompletionNotice()
    XCTAssertNil(session.completionNotice)
  }

  func testAgentTaskFailedKeepsTitleWhenEventHasNone() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "整理报告"))
    session.consume(.task(type: "task.failed", taskId: "t1", title: nil))
    XCTAssertEqual(session.agentTasks[0].status, .failed)
    XCTAssertEqual(session.agentTasks[0].title, "整理报告")
    XCTAssertEqual(session.completionNotice?.text, "整理报告")
  }

  func testTimelineInlineAttachesResultToTask() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的"))
    session.consume(.timelineInline(taskId: "t1", content: "结果摘要"))
    XCTAssertEqual(session.agentTasks[0].resultText, "结果摘要")
    XCTAssertNil(session.completionNotice, "中间结果不触发完成播报")
  }

  func testSortedAgentTasksPutsRunningFirst() {
    session.consume(.task(type: "task.completed", taskId: "t1", title: "完成"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "运行中"))
    let sorted = session.sortedAgentTasks
    XCTAssertEqual(sorted[0].taskId, "t2")
    XCTAssertEqual(sorted[1].taskId, "t1")
  }

  func testClearTaskFeedResetsAgentTasksAndNotice() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "好的"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "完成"))
    XCTAssertFalse(session.agentTasks.isEmpty)
    session.clearTaskFeed()
    XCTAssertTrue(session.agentTasks.isEmpty)
    XCTAssertNil(session.completionNotice)
  }

  // MARK: - Barge-in（本地能量检测打断）

  func testBargeInDetectorRequiresSustainedEnergy() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    XCTAssertFalse(detector.consume(rms: 0.5, sampleCount: 2048), "单次 0.128s 高能量不足")
    XCTAssertTrue(detector.consume(rms: 0.5, sampleCount: 2048), "累计 0.256s 触发")
    XCTAssertFalse(detector.consume(rms: 0.9, sampleCount: 2048), "触发后幂等")
  }

  func testBargeInDetectorShortGapsDoNotFullyReset() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    XCTAssertFalse(detector.consume(rms: 0.5, sampleCount: 2048), "0.128s 不足")
    XCTAssertFalse(detector.consume(rms: 0.0, sampleCount: 2048), "间隙只衰减一半")
    XCTAssertFalse(detector.consume(rms: 0.5, sampleCount: 2048), "0.128+0.064 仍不足")
    XCTAssertTrue(detector.consume(rms: 0.5, sampleCount: 2048), "累计超过阈值触发")
  }

  func testBargeInDetectorResetClearsTrigger() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    _ = detector.consume(rms: 0.5, sampleCount: 2048)
    XCTAssertTrue(detector.consume(rms: 0.5, sampleCount: 2048))
    detector.reset()
    XCTAssertFalse(detector.consume(rms: 0.5, sampleCount: 2048), "reset 后重新累计")
  }

  func testBargeInStopsPlaybackWithoutMutingInput() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.bargeIn()
    XCTAssertFalse(session.isSpeaking)

    let types = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertTrue(types.contains("interrupt"), "应发送 interrupt 停止播报")
    XCTAssertFalse(types.contains("input.mute"), "barge-in 不应静音输入，网关需继续听")
  }

  func testBargeInWithoutSpeakingIsNoOp() {
    session.bargeIn()
    XCTAssertFalse(session.isSpeaking)
    let types = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertFalse(types.contains("interrupt"))
  }

  func testRmsEnergyComputesNormalizedValue() {
    let silence = Data(repeating: 0, count: 64)
    XCTAssertEqual(QwenVoiceSession.rmsEnergy(silence), 0)

    var fullScale = Data()
    for _ in 0..<8 {
      var value = Int16.max
      withUnsafeBytes(of: &value) { fullScale.append(contentsOf: $0) }
    }
    XCTAssertEqual(QwenVoiceSession.rmsEnergy(fullScale), 1.0, accuracy: 0.01)
  }

  func testOrbInputLevelAmplifiesAndClampsRms() {
    XCTAssertEqual(QwenVoiceSession.orbInputLevel(rms: -0.1), 0)
    XCTAssertEqual(QwenVoiceSession.orbInputLevel(rms: 0.05), 0.4, accuracy: 0.001)
    XCTAssertEqual(QwenVoiceSession.orbInputLevel(rms: 0.25), 1)
  }

  // MARK: - 断线自动重连

  func testGatewayReconnectingUpdatesState() {
    session.consume(.gatewayReconnecting(attempt: 2, maxAttempts: 5))
    XCTAssertEqual(session.connectionState, .connecting)
    XCTAssertEqual(session.reconnectAttempt, 2)
    XCTAssertEqual(session.reconnectMaxAttempts, 5)
  }

  func testGatewayReconnectFailedShowsError() {
    session.consume(.gatewayReconnecting(attempt: 1, maxAttempts: 5))
    session.consume(.gatewayReconnectFailed)
    XCTAssertNil(session.reconnectAttempt)
    guard case .failed = session.connectionState else {
      return XCTFail("重连失败后应为 failed 状态")
    }
  }

  func testGatewayDisconnectedClearsReconnectAttempt() {
    session.consume(.gatewayReconnecting(attempt: 1, maxAttempts: 5))
    session.consume(.gatewayDisconnected)
    XCTAssertNil(session.reconnectAttempt)
  }

  // MARK: - Idle Timeout

  func testIdleMonitorTimesOutAfterInterval() {
    var monitor = QwenIdleTimeoutMonitor(timeout: 2)
    let start = Date()
    XCTAssertFalse(monitor.hasTimedOut(at: start.addingTimeInterval(1)))
    XCTAssertTrue(monitor.hasTimedOut(at: start.addingTimeInterval(2.1)))
  }

  func testIdleMonitorActivityResetsTimer() {
    var monitor = QwenIdleTimeoutMonitor(timeout: 2)
    let start = Date()
    monitor.recordActivity(at: start.addingTimeInterval(1.5))
    XCTAssertFalse(monitor.hasTimedOut(at: start.addingTimeInterval(3.4)))
    XCTAssertTrue(monitor.hasTimedOut(at: start.addingTimeInterval(3.6)))
  }

  func testIdleAutoEndSettingDefaultsEnabled() {
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
    XCTAssertTrue(QwenVoiceSession.idleAutoEndEnabled)
    QwenVoiceSession.idleAutoEndEnabled = false
    XCTAssertFalse(QwenVoiceSession.idleAutoEndEnabled)
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
  }

  // MARK: - Transcript Import

  func testImportCombinesTranscriptsAndResults() {
    let log = [
        QwenTranscriptItem(role: .user, text: "帮我查天气"),
        QwenTranscriptItem(role: .assistant, text: "好的")
    ]
    let feed = [
        QwenTaskFeedItem(kind: .delegated, taskId: "t1", text: "马上处理"),
        QwenTaskFeedItem(kind: .completed, taskId: "t1", text: "处理完成"),
        QwenTaskFeedItem(kind: .result, taskId: "t1", text: "结果摘要")
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: feed)

    XCTAssertTrue(importer.hasContent)
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 4)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertEqual(messages[0].text, "帮我查天气")
    XCTAssertEqual(messages[1].role, "assistant")
    XCTAssertEqual(messages[2].text, "处理完成")
    XCTAssertEqual(messages[3].text, "结果摘要")
  }

  func testImportOnlyResultsWhenNoTranscripts() {
    let feed = [
        QwenTaskFeedItem(kind: .completed, taskId: "t1", text: "完成")
    ]
    let importer = AgentTranscriptImport(transcriptLog: [], taskFeed: feed)
    XCTAssertTrue(importer.hasContent)
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0].role, "assistant")
  }

  func testImportEmptyHasNoContent() {
    let importer = AgentTranscriptImport(transcriptLog: [], taskFeed: [
        QwenTaskFeedItem(kind: .progress, taskId: "t1", text: "进行中")
    ])
    XCTAssertFalse(importer.hasContent)
    XCTAssertTrue(importer.makeMessages().isEmpty)
  }

  func testAudioDeltaMarksSpeakingAndInterruptStopsIt() {
    session.consume(.voiceReady(inputSampleRate: 16_000))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.consume(.responseInterrupted)
    XCTAssertFalse(session.isSpeaking)
  }

  func testErrorEventIsPublished() {
    session.consume(.error(message: "连接失败"))
    XCTAssertEqual(session.errorMessage, "连接失败")
  }

  func testTranscriptFinalAppendsToLog() {
    session.consume(.transcriptDelta(role: "user", text: "帮我"))
    XCTAssertTrue(session.transcriptLog.isEmpty, "delta 不应写入日志")

    session.consume(.transcriptFinal(role: "user", text: "帮我查天气"))
    XCTAssertEqual(session.transcriptLog.count, 1)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].text, "帮我查天气")

    session.consume(.transcriptFinal(role: "assistant", text: "好的"))
    XCTAssertEqual(session.transcriptLog.count, 2)
    XCTAssertEqual(session.transcriptLog[1].role, .assistant)
  }

  func testEmptyTranscriptIsNotLogged() {
    session.consume(.transcriptFinal(role: "user", text: ""))
    XCTAssertTrue(session.transcriptLog.isEmpty)
  }

  func testClearTranscriptLog() {
    session.consume(.transcriptFinal(role: "user", text: "你好"))
    session.clearTranscriptLog()
    XCTAssertTrue(session.transcriptLog.isEmpty)
  }

  func testWakeAfterEndPreservesTranscript() {
    session.consume(.transcriptFinal(role: "user", text: "第一段"))
    session.endSession()
    XCTAssertFalse(session.isActive)

    session.wake()
    XCTAssertEqual(session.transcriptLog.count, 1, "唤醒重启会话不应清掉未保存转写")
    XCTAssertEqual(session.transcriptLog[0].text, "第一段")
  }

  func testAppendAssistantTextAddsTranscript() {
    session.appendAssistantText("  大脑回复  ")
    XCTAssertEqual(session.transcriptLog.count, 1)
    XCTAssertEqual(session.transcriptLog[0].role, .assistant)
    XCTAssertEqual(session.transcriptLog[0].text, "大脑回复")
    XCTAssertEqual(session.lastAssistantText, "大脑回复")
  }

  func testAppendUserTextAddsTranscriptAndOptionalLabel() {
    session.appendUserText("视野描述", label: "已发送")
    XCTAssertEqual(session.transcriptLog.count, 2)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].text, "视野描述")
    XCTAssertEqual(session.transcriptLog[1].role, .system)
    XCTAssertEqual(session.transcriptLog[1].text, "已发送")
  }

  func testOutputEnabledPassthrough() {
    XCTAssertTrue(session.outputEnabled)
    session.outputEnabled = false
    XCTAssertFalse(session.outputEnabled)
  }

  func testToggleInterruptSendsMuteThenUnmute() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.toggleInterrupt()
    await waitUntil { self.mockSocket.sentMessages.count >= 3 }

    let types = mockSocket.sentMessages.dropFirst().compactMap { message -> String? in
      try? json(from: message)["type"] as? String
    }
    XCTAssertEqual(types, ["interrupt", "input.mute"])

    session.toggleInterrupt()
    await waitUntil { self.mockSocket.sentMessages.count >= 4 }
    let lastType = try? json(from: mockSocket.sentMessages.last)["type"] as? String
    XCTAssertEqual(lastType, "input.unmute")
  }

  // MARK: - 视野注入（sendText）

  func testSendTextSendsTextMessageAndLogsTranscript() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.sendText("我当前看到：一只猫", label: "📷 已发送当前视野")

    let sent = mockSocket.sentMessages
    let textMessages = sent.compactMap { message -> String? in
        guard let type = try? json(from: message)["type"] as? String,
              type == "text.message" else { return nil }
        return try? json(from: message)["text"] as? String
    }
    XCTAssertEqual(textMessages, ["我当前看到：一只猫"])
    XCTAssertEqual(session.transcriptLog.count, 2)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].text, "我当前看到：一只猫")
    XCTAssertEqual(session.transcriptLog[1].role, .system)
    XCTAssertEqual(session.transcriptLog[1].text, "📷 已发送当前视野")
  }

  func testSendTextWithoutLabelLogsOnlyUserEntry() {
    session.sendText("帮我看看前面是什么")
    XCTAssertEqual(session.transcriptLog.count, 1)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
  }

  func testSendTextEmptyTextIsIgnored() {
    session.sendText("   ")
    XCTAssertTrue(mockSocket.sentMessages.isEmpty)
    XCTAssertTrue(session.transcriptLog.isEmpty)
  }

  func testImportSkipsSystemEntries() {
    let log = [
      QwenTranscriptItem(role: .user, text: "我当前看到：一只猫"),
      QwenTranscriptItem(role: .system, text: "📷 已发送当前视野"),
      QwenTranscriptItem(role: .assistant, text: "你看到一只猫"),
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: [])
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertEqual(messages[0].text, "我当前看到：一只猫")
    XCTAssertEqual(messages[1].role, "assistant")
  }

  // MARK: - 视野上下文标记

  func testVisionContextImportGetsSceneTag() {
    let log = [
      QwenTranscriptItem(role: .user, text: "我当前看到：一只猫", kind: .vision),
      QwenTranscriptItem(role: .assistant, text: "你看到一只猫"),
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: [])
    let messages = importer.makeMessages()
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "user")
    XCTAssertTrue(messages[0].isVisionContext)
    XCTAssertTrue(
      messages[0].text.hasPrefix("agent.vision.scene.tag".localized),
      "视野条目应带 [📷 场景] 前缀，实际: \(messages[0].text)"
    )
    XCTAssertEqual(messages[0].text, "agent.vision.scene.tag".localized + "我当前看到：一只猫")
    XCTAssertFalse(messages[1].isVisionContext)
    XCTAssertEqual(messages[1].text, "你看到一只猫")
  }

  func testNormalTranscriptHasNoSceneTag() {
    let log = [
      QwenTranscriptItem(role: .user, text: "帮我查天气"),
    ]
    let importer = AgentTranscriptImport(transcriptLog: log, taskFeed: [])
    let messages = importer.makeMessages()
    XCTAssertEqual(messages[0].text, "帮我查天气")
    XCTAssertFalse(messages[0].isVisionContext)
  }

  func testSendTextWithVisionKind() {
    session.sendText("我当前看到：一只猫", label: "📷 已发送当前视野", kind: .vision)
    XCTAssertEqual(session.transcriptLog[0].role, .user)
    XCTAssertEqual(session.transcriptLog[0].kind, .vision)
    XCTAssertEqual(session.transcriptLog[1].role, .system)
  }

  func testAppendUserTextWithVisionKind() {
    session.appendUserText("我当前看到：一只猫", label: "📷 已发送当前视野", kind: .vision)
    XCTAssertEqual(session.transcriptLog[0].kind, .vision)
  }

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

  private func json(from message: String?) throws -> [String: Any] {
    let text = try XCTUnwrap(message)
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

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

  // MARK: - 任务语音指令

  func testTaskCommandParserIgnoresWithoutActiveTasks() {
    XCTAssertNil(AgentTaskCommandParser.parse("任务进度如何", activeTaskCount: 0))
    XCTAssertNil(AgentTaskCommandParser.parse("取消那个任务", activeTaskCount: 0))
  }

  func testTaskCommandParserQueryProgress() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("任务进度怎么样了", activeTaskCount: 1),
      .queryProgress
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("还有多久能好", activeTaskCount: 2),
      .queryProgress
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("what's the progress?", activeTaskCount: 1),
      .queryProgress
    )
  }

  func testTaskCommandParserCancelLatest() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("取消那个任务", activeTaskCount: 1),
      .cancelLatest
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("别做了", activeTaskCount: 1),
      .cancelLatest
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("cancel it", activeTaskCount: 2),
      .cancelLatest
    )
  }

  func testTaskCommandParserCancelWinsOverQuery() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("取消任务，进度怎么样", activeTaskCount: 1),
      .cancelLatest
    )
  }

  func testTaskCommandParserIgnoresUnrelatedSpeech() {
    XCTAssertNil(AgentTaskCommandParser.parse("今天天气怎么样", activeTaskCount: 1))
    XCTAssertNil(AgentTaskCommandParser.parse("帮我查一下明天的天气", activeTaskCount: 1))
  }

  func testTaskCommandParserIndexedQuery() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("任务一进度", activeTaskCount: 2),
      .queryProgressTask(0)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("任务2完成了吗", activeTaskCount: 2),
      .queryProgressTask(1)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("第二个任务好了吗", activeTaskCount: 3),
      .queryProgressTask(1)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("第3个任务进度", activeTaskCount: 3),
      .queryProgressTask(2)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("任务三好了没有", activeTaskCount: 3),
      .queryProgressTask(2)
    )
  }

  func testTaskCommandParserIndexedCancel() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("取消任务三", activeTaskCount: 3),
      .cancelTask(2)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("取消第一个任务", activeTaskCount: 2),
      .cancelTask(0)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("停掉任务二", activeTaskCount: 2),
      .cancelTask(1)
    )
  }

  func testTaskCommandParserIndexRequiresIntentKeyword() {
    // 命中序号但无进度/取消关键词：不拦截，避免误吞普通对话
    XCTAssertNil(AgentTaskCommandParser.parse("第三个点你还没说", activeTaskCount: 3))
    XCTAssertNil(AgentTaskCommandParser.parse("任务二记得发我", activeTaskCount: 2))
  }

  func testTaskCommandParserRetryLatest() {
    XCTAssertNil(AgentTaskCommandParser.parse("重试一下", activeTaskCount: 0, failedTaskCount: 0))
    XCTAssertEqual(
      AgentTaskCommandParser.parse("重试", activeTaskCount: 0, failedTaskCount: 1),
      .retryLatest
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("再试一次", activeTaskCount: 2, failedTaskCount: 1),
      .retryLatest
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("try again", activeTaskCount: 1, failedTaskCount: 1),
      .retryLatest
    )
  }

  func testTaskCommandParserRetryRequiresFailedTasks() {
    // 没有失败任务时，重试词不拦截（转发给大脑）
    XCTAssertNil(AgentTaskCommandParser.parse("重试", activeTaskCount: 1, failedTaskCount: 0))
    XCTAssertNil(AgentTaskCommandParser.parse("retry", activeTaskCount: 1, failedTaskCount: 0))
    XCTAssertNil(AgentTaskCommandParser.parse("重试第一个任务", activeTaskCount: 2, failedTaskCount: 0))
  }

  func testTaskCommandParserIndexedRetry() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("重试任务二", activeTaskCount: 0, failedTaskCount: 2),
      .retryTask(1)
    )
    XCTAssertEqual(
      AgentTaskCommandParser.parse("重新做第一个任务", activeTaskCount: 1, failedTaskCount: 2),
      .retryTask(0)
    )
    // 无失败任务时即使命中序号也不拦截
    XCTAssertNil(AgentTaskCommandParser.parse("重试任务二", activeTaskCount: 2, failedTaskCount: 0))
  }

  func testTaskCommandParserCancelWinsOverRetry() {
    XCTAssertEqual(
      AgentTaskCommandParser.parse("取消任务，重试", activeTaskCount: 1, failedTaskCount: 1),
      .cancelLatest
    )
  }

  func testTaskIndexParserVariants() {
    XCTAssertEqual(AgentTaskCommandParser.taskIndex(from: "任务一进度"), 0)
    XCTAssertEqual(AgentTaskCommandParser.taskIndex(from: "任务2"), 1)
    XCTAssertEqual(AgentTaskCommandParser.taskIndex(from: "第二个任务"), 1)
    XCTAssertEqual(AgentTaskCommandParser.taskIndex(from: "第10个任务"), 9)
    XCTAssertEqual(AgentTaskCommandParser.taskIndex(from: "任务十"), 9)
    XCTAssertNil(AgentTaskCommandParser.taskIndex(from: "任务进度如何"))
    XCTAssertNil(AgentTaskCommandParser.taskIndex(from: "随便说说"))
  }

  func testTaskProgressSummaryByIndex() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "整理报告"))
    session.consume(.timelineInline(taskId: "t1", content: "正在比较三家餐厅"))

    let first = session.taskProgressSummary(for: 0)
    XCTAssertNotNil(first)
    XCTAssertTrue(first!.contains("订餐厅"))

    let second = session.taskProgressSummary(for: 1)
    XCTAssertNotNil(second)
    XCTAssertTrue(second!.contains("整理报告"))

    XCTAssertNil(session.taskProgressSummary(for: 2), "序号越界返回 nil")
    XCTAssertNil(session.taskProgressSummary(for: -1))
  }

  func testRequestTaskCancellationByIndex() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "整理报告"))

    let name = session.requestTaskCancellation(index: 1)
    XCTAssertEqual(name, "整理报告")

    let textMessages = mockSocket.sentMessages.compactMap { message -> String? in
      guard let type = try? json(from: message)["type"] as? String,
            type == "text.message" else { return nil }
      return try? json(from: message)["text"] as? String
    }
    XCTAssertEqual(textMessages.count, 1)
    XCTAssertTrue(textMessages[0].contains("整理报告"), "取消指令应点名对应任务：\(textMessages[0])")

    XCTAssertNil(session.requestTaskCancellation(index: 2), "序号越界返回 nil")
    XCTAssertNil(session.requestTaskCancellation(index: -1))
  }

  func testTaskProgressSummarySingleTask() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.timelineInline(taskId: "t1", content: "正在比较三家餐厅"))

    let summary = session.taskProgressSummary
    XCTAssertNotNil(summary)
    XCTAssertTrue(summary!.contains("订餐厅"))
    XCTAssertTrue(summary!.contains("正在比较三家餐厅"))
  }

  func testTaskProgressSummaryMultipleTasks() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "发邮件"))

    let summary = session.taskProgressSummary
    XCTAssertNotNil(summary)
    XCTAssertTrue(summary!.contains("订餐厅"))
    XCTAssertTrue(summary!.contains("发邮件"))
  }

  func testTaskProgressSummaryNilWhenNoRunning() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.completed", taskId: "t1", title: "订餐厅"))

    XCTAssertNil(session.taskProgressSummary)
  }

  func testLatestRunningTaskPicksNewest() {
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))
    session.consume(.task(type: "task.delegated", taskId: "t2", title: "发邮件"))

    XCTAssertEqual(session.latestRunningTask?.taskId, "t2")
  }

  func testRequestTaskCancellationSendsInstruction() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))

    let name = session.requestTaskCancellation()
    XCTAssertEqual(name, "订餐厅")

    let textMessages = mockSocket.sentMessages.compactMap { message -> String? in
      guard let type = try? json(from: message)["type"] as? String,
            type == "text.message" else { return nil }
      return try? json(from: message)["text"] as? String
    }
    XCTAssertEqual(textMessages.count, 1)
    XCTAssertTrue(
      textMessages[0].contains("订餐厅")
        && (textMessages[0].contains("cancel") || textMessages[0].contains("取消")),
      "sent: \(textMessages[0])"
    )

    let systemEntry = session.transcriptLog.last
    XCTAssertEqual(systemEntry?.role, .system)
    XCTAssertTrue(systemEntry?.text.contains("订餐厅") == true)
  }

  func testRequestTaskCancellationNilWithoutRunningTask() {
    XCTAssertNil(session.requestTaskCancellation())
    XCTAssertTrue(mockSocket.sentMessages.isEmpty)
  }

  func testRequestTaskAccelerationSendsInstruction() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.task(type: "task.delegated", taskId: "t1", title: "订餐厅"))

    let name = session.requestTaskAcceleration()
    XCTAssertEqual(name, "订餐厅")

    let textMessages = mockSocket.sentMessages.compactMap { message -> String? in
      guard let type = try? json(from: message)["type"] as? String,
            type == "text.message" else { return nil }
      return try? json(from: message)["text"] as? String
    }
    XCTAssertEqual(textMessages.count, 1)
    XCTAssertTrue(
      textMessages[0].contains("订餐厅")
        && (textMessages[0].contains("speed up") || textMessages[0].contains("加速")),
      "sent: \(textMessages[0])"
    )

    let systemEntry = session.transcriptLog.last
    XCTAssertEqual(systemEntry?.role, .system)
    XCTAssertTrue(systemEntry?.text.contains("订餐厅") == true)
  }

  func testRequestTaskAccelerationNilWithoutRunningTask() {
    XCTAssertNil(session.requestTaskAcceleration())
    XCTAssertTrue(mockSocket.sentMessages.isEmpty)
  }

  // MARK: - 语音本地指令

  func testLocalCommandParserRepeat() {
    XCTAssertEqual(AgentLocalCommandParser.parse("再说一遍"), .repeatLastReply)
    XCTAssertEqual(AgentLocalCommandParser.parse("没听清，重复一下"), .repeatLastReply)
    XCTAssertEqual(AgentLocalCommandParser.parse("repeat that please"), .repeatLastReply)
  }

  func testLocalCommandParserNewChat() {
    XCTAssertEqual(AgentLocalCommandParser.parse("新会话"), .newChat)
    XCTAssertEqual(AgentLocalCommandParser.parse("换个话题"), .newChat)
    XCTAssertEqual(AgentLocalCommandParser.parse("start over"), .newChat)
  }

  func testLocalCommandParserIgnoresUnrelatedSpeech() {
    XCTAssertNil(AgentLocalCommandParser.parse("帮我重新开始下载文件"))
    XCTAssertNil(AgentLocalCommandParser.parse("今天天气怎么样"))
    XCTAssertNil(AgentLocalCommandParser.parse("   "))
  }

  func testLocalCommandParserEndSession() {
    XCTAssertEqual(AgentLocalCommandParser.parse("结束对话"), .endSession)
    XCTAssertEqual(AgentLocalCommandParser.parse("先不聊了"), .endSession)
    XCTAssertEqual(AgentLocalCommandParser.parse("退出会话"), .endSession)
    XCTAssertEqual(AgentLocalCommandParser.parse("end the conversation"), .endSession)
    XCTAssertEqual(AgentLocalCommandParser.parse("exit the session"), .endSession)
  }

  func testLocalCommandParserDoesNotOverMatchEndSession() {
    XCTAssertNil(AgentLocalCommandParser.parse("比赛结束了吗"))
    XCTAssertNil(AgentLocalCommandParser.parse("换个思路试试"))
  }

  func testLocalCommandParserTodayOverview() {
    XCTAssertEqual(AgentLocalCommandParser.parse("今天有什么安排"), .todayOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("汇报今日安排"), .todayOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("今天要做什么"), .todayOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("what's my day look like"), .todayOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("What's on my schedule today?"), .todayOverview)
  }

  func testLocalCommandParserDoesNotOverMatchTodayOverview() {
    XCTAssertNil(AgentLocalCommandParser.parse("帮我把房间安排一下"))
    XCTAssertNil(AgentLocalCommandParser.parse("今天的天气适合安排爬山吗"))
    XCTAssertNil(AgentLocalCommandParser.parse("重新安排一下日程"))
  }

  func testLocalCommandParserTomorrowOverview() {
    XCTAssertEqual(AgentLocalCommandParser.parse("明天有什么安排"), .tomorrowOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("汇报明天安排"), .tomorrowOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("明天要做什么"), .tomorrowOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("明日计划"), .tomorrowOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("What's on my schedule tomorrow?"), .tomorrowOverview)
    XCTAssertEqual(AgentLocalCommandParser.parse("tomorrow's plan"), .tomorrowOverview)
  }

  func testLocalCommandParserDoesNotOverMatchTomorrowOverview() {
    XCTAssertEqual(AgentLocalCommandParser.parse("今天有什么安排"), .todayOverview)
    XCTAssertNil(AgentLocalCommandParser.parse("明天记得开会"))
    XCTAssertNil(AgentLocalCommandParser.parse("帮我把明天的会取消"))
    XCTAssertNil(AgentLocalCommandParser.parse("明天天气怎么样"))
  }

  // MARK: - 持续在场（Presence）

  func testPresenceSettingDefaultsOff() {
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
    XCTAssertFalse(AgentPresenceSettings.presenceEnabled)
    AgentPresenceSettings.presenceEnabled = true
    XCTAssertTrue(AgentPresenceSettings.presenceEnabled)
    AgentPresenceSettings.presenceEnabled = false
    XCTAssertFalse(AgentPresenceSettings.presenceEnabled)
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
  }

  func testShouldAutoEndIdleDefaultsTrue() {
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
    XCTAssertTrue(QwenVoiceSession.shouldAutoEndIdle)
  }

  func testShouldAutoEndIdleDisabledByPresence() {
    QwenVoiceSession.idleAutoEndEnabled = true
    AgentPresenceSettings.presenceEnabled = true
    XCTAssertFalse(QwenVoiceSession.shouldAutoEndIdle)
    AgentPresenceSettings.presenceEnabled = false
    XCTAssertTrue(QwenVoiceSession.shouldAutoEndIdle)
    QwenVoiceSession.idleAutoEndEnabled = false
    XCTAssertFalse(QwenVoiceSession.shouldAutoEndIdle)
    UserDefaults.standard.removeObject(forKey: "qwen_voice_auto_end_enabled")
    UserDefaults.standard.removeObject(forKey: AgentPresenceSettings.presenceEnabledKey)
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
  // MARK: - 休眠 / 唤醒词

  /// 启动会话并送达 voice.ready，使网关进入 online（send 才允许出站消息）
  private func startConnectedSession() async {
    session.start()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    for _ in 0..<10 {
      if session.connectionState == .connected { break }
      await Task.yield()
    }
    XCTAssertEqual(session.connectionState, .connected)
  }

  func testClientStateSleepingEntersSleep() {
    QwenVoiceSession.wakeWordEnabled = false
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .sleeping)
  }

  func testClientStateOtherDoesNotSleep() {
    session.consume(.clientState(state: "awake"))
    XCTAssertFalse(session.isSleeping)
  }

  func testWakeWordEnabledSleepStartsListening() {
    QwenVoiceSession.wakeWordEnabled = true
    let monitor = MockWakeWordMonitor()
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      wakeWordMonitorFactory: { monitor }
    )
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .listening)
  }

  func testRequestSleepSendsSleepEvent() async {
    await startConnectedSession()
    session.requestSleep()
    let types = mockSocket.sentMessages.compactMap { text -> String? in
      guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertTrue(types.contains("sleep"))
    XCTAssertTrue(session.isSleeping)
  }

  func testWakeFromSleepSendsWakeEventAndResumes() async {
    await startConnectedSession()
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    session.wake()
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .idle)
    let texts = mockSocket.sentMessages
    XCTAssertTrue(texts.contains { $0.contains("wake") })
  }

  func testWakeWordHitWakesSession() async {
    QwenVoiceSession.wakeWordEnabled = true
    let monitor = MockWakeWordMonitor()
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      wakeWordMonitorFactory: { monitor }
    )
    await startConnectedSession()
    session.consume(.clientState(state: "sleeping"))
    XCTAssertEqual(session.wakeWordPhase, .listening)

    monitor.onWakeWord?("你好千问")
    await Task.yield()
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .idle)
    XCTAssertEqual(session.lastWakeWordText, "你好千问")
    let texts = mockSocket.sentMessages
    XCTAssertTrue(texts.contains { $0.contains("wake") })
  }

  func testWakeWordMonitorFailureFallsBackToSleeping() async {
    QwenVoiceSession.wakeWordEnabled = true
    let monitor = MockWakeWordMonitor()
    monitor.shouldFail = true
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      wakeWordMonitorFactory: { monitor }
    )
    session.consume(.clientState(state: "sleeping"))
    XCTAssertEqual(session.wakeWordPhase, .listening)
    // 等待异步启动失败回落（Task 需要调度机会）
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(session.wakeWordPhase, .sleeping)
    XCTAssertNotNil(session.wakeWordMonitorError)
  }
}

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
