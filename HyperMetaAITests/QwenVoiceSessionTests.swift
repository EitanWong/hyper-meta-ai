import Foundation
import AVFAudio
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

private final class VoiceSessionMockPlaybackPipeline: RealtimeAudioPlaybackControlling {
  private(set) var enqueueCallCount = 0
  private(set) var lastReceivedAt: TimeInterval?
  private(set) var interruptCallCount = 0
  private(set) var invalidateAudioSystemCallCount = 0
  private(set) var prepareCallCount = 0
  private(set) var stopCallCount = 0
  var isActive = true

  func start(
    generation: Int,
    onFailure: @escaping RealtimeAudioPlaybackPipeline.FailureHandler,
    onResponsePlaybackComplete: @escaping RealtimeAudioPlaybackPipeline.PlaybackCompletionHandler,
    onAudioLevel: @escaping RealtimeAudioPlaybackPipeline.AudioLevelHandler
  ) {
    isActive = true
  }

  func prepare(generation: Int) {
    prepareCallCount += 1
  }

  func stop() {
    stopCallCount += 1
    isActive = false
  }

  func enqueue(
    _ data: Data,
    generation: Int,
    receivedAt: TimeInterval
  ) -> RealtimeAudioJitterOfferResult {
    enqueueCallCount += 1
    lastReceivedAt = receivedAt
    guard isActive else { return .inactive }
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
      return .invalidFrameAlignment
    }
    return .accepted
  }

  func finishResponse(generation: Int) {}

  /// Milliseconds the double reports as "already played" on interrupt, so tests
  /// can assert the truncate value forwarded to the gateway.
  var playedMillisecondsOnInterrupt = 0

  @discardableResult
  func interrupt(generation: Int) -> Int {
    interruptCallCount += 1
    return playedMillisecondsOnInterrupt
  }

  @discardableResult
  func invalidateAudioSystem(generation: Int) -> Int {
    invalidateAudioSystemCallCount += 1
    return playedMillisecondsOnInterrupt
  }
}

@MainActor
final class QwenVoiceSessionTests: XCTestCase {
  private var mockSocket: VoiceSessionMockSocket!
  private var gateway: QwenGatewayService!
  private var session: QwenVoiceSession!
  private var permissionResponder: MockPermissionResponder!
  private var playbackPipeline: VoiceSessionMockPlaybackPipeline!

  override func setUp() {
    super.setUp()
    mockSocket = VoiceSessionMockSocket()
    gateway = QwenGatewayService(socketFactory: { _ in self.mockSocket })
    gateway.mode = .external
    permissionResponder = MockPermissionResponder()
    playbackPipeline = VoiceSessionMockPlaybackPipeline()
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      audioPlaybackPipeline: playbackPipeline
    )
  }

  override func tearDown() {
    session.stop()
    gateway.disconnect()
    UserDefaults.standard.removeObject(forKey: AgentPermissionSettings.modeKey)
    session = nil
    playbackPipeline = nil
    permissionResponder = nil
    gateway = nil
    mockSocket = nil
    super.tearDown()
  }

  func testProviderTurnStateDoesNotConflateCaptureWithSpeech() {
    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)

    session.consume(.voiceState(state: "listening"))
    XCTAssertEqual(session.providerVoiceState, "listening")
    XCTAssertTrue(session.isInputActive)

    session.consume(.voiceState(state: "thinking"))
    XCTAssertEqual(session.providerVoiceState, "thinking")
    XCTAssertFalse(session.isInputActive)

    session.consume(.voiceState(state: "idle"))
    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)
  }

  func testTransportRecoveryClearsAnActiveSpeechTurn() {
    session.consume(.voiceState(state: "listening"))

    session.consume(.gatewayReconnecting(attempt: 1, maxAttempts: 5))

    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)
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
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "单次 0.128s 高能量不足")
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 2048), "累计 0.256s 触发")
    XCTAssertFalse(detector.consume(rms: 0.9, sampleCount: 2048), "触发后幂等")
  }

  func testBargeInDetectorShortGapsDoNotFullyReset() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "0.128s 不足")
    XCTAssertFalse(detector.consume(rms: 0.0, sampleCount: 2048), "间隙只衰减一半")
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "0.128+0.064 仍不足")
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 2048), "累计超过阈值触发")
  }

  func testBargeInDetectorResetClearsTrigger() {
    var detector = BargeInDetector(
      energyThreshold: 0.02,
      minimumDuration: 0.25,
      sampleRate: 16_000
    )
    _ = detector.consume(rms: 0.05, sampleCount: 2048)
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 2048))
    detector.reset()
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 2048), "reset 后重新累计")
  }

  func testBargeInDetectorHighConfidenceSpeechTriggersWithinFortyMilliseconds() {
    var detector = BargeInDetector()
    XCTAssertFalse(detector.consume(rms: 0.15, sampleCount: 320), "20ms 不应由单帧触发")
    let triggered = detector.consume(rms: 0.15, sampleCount: 320)

    let attachment = XCTAttachment(
      string: "fastBargeInAudioMs=\(triggered ? "40.0" : "not_triggered")"
    )
    attachment.name = "Qwen high-confidence barge-in audio latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertTrue(triggered, "高置信近讲语音应在连续 40ms 内触发")
  }

  func testCaptureBargeInGateUsesRawCaptureDurationBeforeNetworkDelivery() {
    let gate = QwenCaptureBargeInGate()
    let token = gate.arm()
    let twentyMilliseconds = RealtimeCapturedAudioFrameStats(
      rms: 0.15,
      sampleCount: 960,
      sampleRate: 48_000
    )

    XCTAssertNil(gate.consume(twentyMilliseconds))
    XCTAssertEqual(gate.consume(twentyMilliseconds), token)
    XCTAssertNil(gate.consume(twentyMilliseconds), "每次 arm 只触发一次")
  }

  func testCaptureBargeInGateRejectsStaleAndDisarmedSignals() {
    let gate = QwenCaptureBargeInGate()
    let twentyMilliseconds = RealtimeCapturedAudioFrameStats(
      rms: 0.15,
      sampleCount: 320,
      sampleRate: 16_000
    )

    let staleToken = gate.arm()
    XCTAssertNil(gate.consume(twentyMilliseconds))
    gate.disarm()
    XCTAssertNil(gate.consume(twentyMilliseconds))

    let currentToken = gate.arm()
    XCTAssertNotEqual(staleToken, currentToken)
    XCTAssertNil(gate.consume(twentyMilliseconds))
    XCTAssertEqual(gate.consume(twentyMilliseconds), currentToken)
  }

  func testBargeInDetectorLoudTransientDoesNotCarryAcrossModerateSpeech() {
    var detector = BargeInDetector()
    XCTAssertFalse(detector.consume(rms: 0.15, sampleCount: 320), "单个 20ms 高能量瞬态不足")
    XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 320), "普通语音帧应清除快速路径累计")
    XCTAssertFalse(detector.consume(rms: 0.15, sampleCount: 320), "新的高能量帧应从 20ms 重新累计")
  }

  func testBargeInDetectorModerateSpeechKeepsStandardWindow() {
    var detector = BargeInDetector()
    for _ in 0..<5 {
      XCTAssertFalse(detector.consume(rms: 0.05, sampleCount: 320))
    }
    XCTAssertTrue(detector.consume(rms: 0.05, sampleCount: 320), "普通语音仍需累计 120ms")
  }

  func testBargeInDetectorZeroDurationStillRequiresCurrentEnergy() {
    var detector = BargeInDetector(minimumDuration: 0)
    XCTAssertFalse(detector.consume(rms: 0, sampleCount: 320))
    XCTAssertTrue(detector.consume(rms: 0.02, sampleCount: 320))
  }

  func testCancelledResponseRegistryEvictsOldestIdentifier() {
    var registry = QwenCancelledResponseRegistry(capacity: 2)
    registry.insert("r1")
    registry.insert("r2")
    registry.insert("r3")

    XCTAssertFalse(registry.contains("r1"))
    XCTAssertTrue(registry.contains("r2"))
    XCTAssertTrue(registry.contains("r3"))
  }

  func testResponseOutputGateBlocksUncorrelatedAudioAfterCancellation() {
    var gate = QwenResponseOutputGate()
    gate.markCancelled()

    XCTAssertFalse(gate.acceptAudio(hasResponseID: false))
    XCTAssertTrue(gate.acceptAudio(hasResponseID: true))
    XCTAssertTrue(gate.acceptsTerminal(hasResponseID: false))
  }

  func testAudioBurstConsumptionKeepsMainActorWithinPerPacketBudget() {
    let packetCount = 10_000
    let packet = Data(repeating: 7, count: 1_920).base64EncodedString()
    let events = (0..<packetCount).map { _ in
      QwenGatewayEvent.audioDelta(
        audioBase64: packet,
        sampleRate: 24_000,
        responseId: "burst"
      )
    }
    session.consume(.responseStarted(responseId: "burst"))

    let startedAt = ProcessInfo.processInfo.systemUptime
    for event in events {
      session.consume(event)
    }
    let averageMicroseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000_000 / Double(packetCount)
    let attachment = XCTAttachment(
      string: "mainActorAudioConsumeAverageUs=\(averageMicroseconds)"
    )
    attachment.name = "Qwen MainActor audio burst consumption latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(playbackPipeline.enqueueCallCount, packetCount)
    XCTAssertLessThan(averageMicroseconds, 2)
  }

  func testAudioChunkPreservesGatewayReceiveTimeIntoPlaybackPipeline() {
    let receivedAt = 42.5
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1",
      receivedAt: receivedAt
    ))

    XCTAssertEqual(playbackPipeline.lastReceivedAt, receivedAt)
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

  func testBargeInDropsLateCancelledResponseEventsWithoutStoppingNextResponse() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.bargeIn()
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertFalse(session.isSpeaking, "已取消响应的迟到音频不应恢复播放")

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertTrue(session.isSpeaking, "新响应应正常播放")

    session.consume(.audioDone(responseId: "r1"))
    session.consume(.responseInterrupted(responseId: "r1"))
    XCTAssertTrue(session.isSpeaking, "旧响应终态不应结束新响应")

    session.consume(.responseInterrupted(responseId: "r2"))
    XCTAssertFalse(session.isSpeaking)
  }

  func testResponseStartedSupersedesTheActiveResponseBeforeItsFirstAudio() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.consume(.responseStarted(responseId: "r2"))
    XCTAssertFalse(session.isSpeaking)

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertFalse(session.isSpeaking, "被 supersede 的 response 不应重新开始播放")
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertTrue(session.isSpeaking)
  }

  func testUncorrelatedLateAudioStaysBlockedUntilNextResponseStarts() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: nil))
    XCTAssertTrue(session.isSpeaking)

    session.bargeIn()
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: nil))
    XCTAssertFalse(session.isSpeaking, "取消后的无 responseId 音频不应复活旧播报")

    session.consume(.responseStarted(responseId: nil))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: nil))
    XCTAssertTrue(session.isSpeaking, "明确的新 response 生命周期允许无 ID 音频")
  }

  func testGatewayDisconnectStopsPlaybackAndBlocksLateAudio() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(session.isSpeaking)

    session.consume(.gatewayDisconnected)
    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.interruptCallCount, 1)
    XCTAssertEqual(playbackPipeline.stopCallCount, 0)
    XCTAssertTrue(playbackPipeline.isActive)
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertFalse(session.isSpeaking, "传输丢失后的任何排队音频都必须等待新 response 生命周期")

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertTrue(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 2)
  }

  func testVoiceFrontendUnavailableCancelsActivePlaybackAsPlaybackError() async {
    gateway.onEvent = { [weak session] event in
      session?.consume(event)
    }
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))
    XCTAssertTrue(session.isSpeaking)

    mockSocket.deliver([
      "type": "voice.connection",
      "state": "unavailable",
      "message": "provider unavailable"
    ])
    await waitUntil {
      if case .failed = self.session.connectionState { return true }
      return false
    }

    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")
  }

  func testAudioInterruptionBeganCancelsActivePlaybackAsPlaybackError() {
    gateway.connect()
    let captureGenerationBeforeInterruption = session.captureGeneration
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))
    XCTAssertTrue(session.isSpeaking)

    let startedAt = ProcessInfo.processInfo.systemUptime
    session.handleAudioInterruption(Notification(
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
      ]
    ))
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    let cancelled = !session.isSpeaking

    let attachment = XCTAttachment(
      string: "audioInterruptionCancelMs=\(cancelled ? String(elapsedMilliseconds) : "not_cancelled")"
    )
    attachment.name = "Qwen audio interruption cancellation latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertTrue(cancelled, "系统音频中断必须立即清除活动播放")
    XCTAssertEqual(
      session.captureGeneration,
      captureGenerationBeforeInterruption + 1,
      "系统中断必须同步停掉旧 VPIO 采集图"
    )
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 1)
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")
    if cancelled {
      XCTAssertLessThan(elapsedMilliseconds, 50)
    }

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r2"
    ))
    XCTAssertTrue(session.isSpeaking, "恢复后的下一响应不应要求重连 Qwen 会话")
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 2)
  }

  func testMediaServicesResetCancelsPlaybackAndKeepsSessionReusable() {
    gateway.connect()
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))

    session.handleMediaServicesReset()

    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 1)
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r2"
    ))
    XCTAssertTrue(session.isSpeaking)
  }

  func testAudioRouteRecoveryPolicySeparatesPhysicalFromSelfInitiatedChanges() {
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .newDeviceAvailable))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .oldDeviceUnavailable))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .wakeFromSleep))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .noSuitableRouteForCategory))
    XCTAssertTrue(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .routeConfigurationChange))

    XCTAssertFalse(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .unknown))
    XCTAssertFalse(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .categoryChange))
    XCTAssertFalse(QwenAudioRouteRecoveryPolicy.requiresRecovery(for: .override))
  }

  func testAudioRouteSettleWindowIsCoveredByRecoverySuppression() {
    XCTAssertEqual(QwenVoiceSession.audioRouteSettleNanoseconds, 750_000_000)
    XCTAssertGreaterThan(
      QwenVoiceSession.audioRouteConfigurationSuppressionInterval,
      Double(QwenVoiceSession.audioRouteSettleNanoseconds) / 1_000_000_000
    )
  }

  func testAudioEngineConfigurationChangeQuiescesCaptureBeforeRecovery() {
    let initialGeneration = session.captureGeneration
    session.consume(.voiceState(state: "listening"))

    session.handleAudioEngineConfigurationChange()

    XCTAssertEqual(session.captureGeneration, initialGeneration + 1)
    XCTAssertEqual(session.providerVoiceState, "idle")
    XCTAssertFalse(session.isInputActive)
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 1)
  }

  func testAudioRouteRecoveryCoalescerRunsOneSettledRecoveryPerBurst() async {
    let settled = expectation(description: "settled route recovery")
    let coalescer = QwenAudioRouteRecoveryCoalescer(delayNanoseconds: 10_000_000)
    var immediateCount = 0
    var settledCount = 0

    coalescer.schedule(
      onFirst: { immediateCount += 1 },
      onSettled: {
        settledCount += 1
        settled.fulfill()
      }
    )
    coalescer.schedule(
      onFirst: { immediateCount += 1 },
      onSettled: {
        settledCount += 1
        settled.fulfill()
      }
    )

    XCTAssertEqual(immediateCount, 1)
    await fulfillment(of: [settled], timeout: 0.5)
    XCTAssertEqual(settledCount, 1)

    coalescer.schedule(
      onFirst: { immediateCount += 1 },
      onSettled: { settledCount += 1 }
    )
    coalescer.cancel()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(immediateCount, 2)
    XCTAssertEqual(settledCount, 1, "系统中断取消后不得执行迟到的路由恢复")
  }

  func testAudioCaptureRecoveryPolicyUsesBoundedLowLatencyBackoff() {
    let policy = QwenAudioCaptureRecoveryPolicy()

    XCTAssertEqual(policy.delay(forRetry: 1), 0.1)
    XCTAssertEqual(policy.delay(forRetry: 2), 0.25)
    XCTAssertEqual(policy.delay(forRetry: 3), 0.5)
    XCTAssertNil(policy.delay(forRetry: 0))
    XCTAssertNil(policy.delay(forRetry: 4))
  }

  func testAudioCaptureRecoverySchedulerAdvancesAndResetCancelsStaleWork() async {
    let scheduler = QwenAudioCaptureRecoveryScheduler(
      policy: QwenAudioCaptureRecoveryPolicy(retryDelays: [0.01, 0.015])
    )
    let firstRetry = expectation(description: "first capture retry")
    let secondRetry = expectation(description: "second capture retry")
    let startedAt = ProcessInfo.processInfo.systemUptime
    var firstRetryMilliseconds = 0.0
    var firedCount = 0

    XCTAssertTrue(scheduler.schedule {
      firstRetryMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      firedCount += 1
      firstRetry.fulfill()
    })
    await fulfillment(of: [firstRetry], timeout: 0.5)

    XCTAssertTrue(scheduler.schedule {
      firedCount += 1
      secondRetry.fulfill()
    })
    await fulfillment(of: [secondRetry], timeout: 0.5)
    XCTAssertFalse(scheduler.schedule { XCTFail("exhausted retry must not run") })

    let attachment = XCTAttachment(
      string: "captureRecoveryFirstRetryMs=\(firstRetryMilliseconds)"
    )
    attachment.name = "Qwen audio capture recovery retry latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(firedCount, 2)
    XCTAssertLessThan(firstRetryMilliseconds, 50)

    scheduler.reset()
    XCTAssertTrue(scheduler.schedule { firedCount += 1 })
    scheduler.reset()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(firedCount, 2, "reset 后迟到的采集恢复任务不得执行")
  }

  func testPhysicalAudioRouteChangeCancelsPlaybackCoalescesBurstAndKeepsSessionReusable() {
    gateway.connect()
    let captureGenerationBeforeRouteChange = session.captureGeneration
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))
    XCTAssertTrue(session.isSpeaking)

    let startedAt = ProcessInfo.processInfo.systemUptime
    session.handleAudioRouteChange(routeChangeNotification(reason: .oldDeviceUnavailable))
    XCTAssertEqual(session.captureGeneration, captureGenerationBeforeRouteChange + 1)
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    session.handleAudioRouteChange(routeChangeNotification(reason: .newDeviceAvailable))
    XCTAssertEqual(
      session.captureGeneration,
      captureGenerationBeforeRouteChange + 1,
      "同一路由突发只应拆除一次旧采集图"
    )
    let cancelled = !session.isSpeaking

    let attachment = XCTAttachment(
      string: "audioRouteChangeCancelMs=\(cancelled ? String(elapsedMilliseconds) : "not_cancelled")"
    )
    attachment.name = "Qwen physical audio route cancellation latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertTrue(cancelled, "物理音频路由变化必须立即清除旧路由上的播放")
    XCTAssertEqual(
      playbackPipeline.invalidateAudioSystemCallCount,
      1,
      "同一短突发只应同步失效一次播放图"
    )
    XCTAssertEqual(playbackCancelledMessages().last?["responseId"] as? String, "r1")
    XCTAssertEqual(playbackCancelledMessages().last?["reason"] as? String, "playback_error")
    if cancelled {
      XCTAssertLessThan(elapsedMilliseconds, 50)
    }

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r2"
    ))
    XCTAssertTrue(session.isSpeaking, "路由恢复后的下一响应不应要求重连 Qwen 会话")
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 2)
  }

  func testSelfInitiatedAudioRouteChangeDoesNotInvalidatePlayback() {
    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "r1"
    ))

    session.handleAudioRouteChange(routeChangeNotification(reason: .categoryChange))
    session.handleAudioRouteChange(routeChangeNotification(reason: .override))

    XCTAssertTrue(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.invalidateAudioSystemCallCount, 0)
  }

  func testRejectedAudioDoesNotClaimPlaybackStarted() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQ==", sampleRate: 24_000, responseId: "r1"))

    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(playbackPipeline.enqueueCallCount, 1)
    let playbackStarted = mockSocket.sentMessages.contains { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      return json["type"] as? String == "playback.started"
    }
    XCTAssertFalse(playbackStarted)
  }

  func testResponseStartedSendsPlaybackReceiptOnlyAfterAcceptedAudio() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.responseStarted(responseId: "r1"))
    session.consume(.audioDelta(audioBase64: "AQ==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertTrue(playbackStartedMessages().isEmpty)

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    let messages = playbackStartedMessages()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?["responseId"] as? String, "r1")

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    XCTAssertEqual(playbackStartedMessages().count, 1)

    session.consume(.responseStarted(responseId: "r2"))
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertEqual(
      playbackStartedMessages().compactMap { $0["responseId"] as? String },
      ["r1", "r2"]
    )
  }

  func testManualInterruptDropsAllAudioUntilResume() {
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    session.interrupt()

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r2"))
    XCTAssertFalse(session.isSpeaking)

    session.resume()
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r3"))
    XCTAssertTrue(session.isSpeaking)
  }

  func testManualInterruptReportsUserInterruptionReason() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    session.interrupt()

    let cancellation = playbackCancelledMessages().last
    XCTAssertEqual(cancellation?["responseId"] as? String, "r1")
    XCTAssertEqual(cancellation?["reason"] as? String, "user_interruption")
    let wireTypes = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    let cancelledIndex = try? XCTUnwrap(wireTypes.lastIndex(of: "playback.cancelled"))
    let interruptIndex = try? XCTUnwrap(wireTypes.lastIndex(of: "interrupt"))
    if let cancelledIndex, let interruptIndex {
      XCTAssertLessThan(cancelledIndex, interruptIndex)
    }
  }

  func testPlaybackClearForwardsCancellationReason() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }

    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))
    session.consume(.playbackClear(reason: "desktop_hidden"))

    let cancellation = playbackCancelledMessages().last
    XCTAssertEqual(cancellation?["responseId"] as? String, "r1")
    XCTAssertEqual(cancellation?["reason"] as? String, "desktop_hidden")
  }

  private func playbackStartedMessages() -> [[String: Any]] {
    mockSocket.sentMessages.compactMap { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "playback.started"
      else { return nil }
      return json
    }
  }

  func testBargeInForwardsActuallyPlayedMillisecondsSoServerCanTruncate() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    playbackPipeline.playedMillisecondsOnInterrupt = 820
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    session.bargeIn()

    XCTAssertEqual(interruptMessages().last?["playedMs"] as? Int, 820)
  }

  func testBargeInDuringThinkingCancelsTheResponseBeingGenerated() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    // thinking：服务端已收到用户上一句、正在生成，但首个音频块还没到。
    session.consume(.voiceState(state: "thinking"))
    XCTAssertFalse(session.isSpeaking)

    session.bargeIn()

    XCTAssertEqual(interruptMessages().count, 1, "thinking 阶段也必须能打断")
    XCTAssertEqual(playbackPipeline.interruptCallCount, 1)
  }

  func testProviderTurnStartDuringThinkingAlsoCancelsTheResponse() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.voiceState(state: "thinking"))

    session.consume(.turnStarted(turnId: "user-turn"))

    XCTAssertEqual(interruptMessages().count, 1)
  }

  func testServerInitiatedCancellationDoesNotEchoAnInterruptBack() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    session.consume(.responseInterrupted(responseId: "r1"))

    XCTAssertFalse(session.isSpeaking)
    XCTAssertTrue(
      interruptMessages().isEmpty,
      "服务端自己取消的回复，客户端不应再回发 interrupt/truncate"
    )
  }

  private func interruptMessages() -> [[String: Any]] {
    mockSocket.sentMessages.compactMap { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "interrupt"
      else { return nil }
      return json
    }
  }

  private func playbackCancelledMessages() -> [[String: Any]] {
    mockSocket.sentMessages.compactMap { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "playback.cancelled"
      else { return nil }
      return json
    }
  }

  private func routeChangeNotification(
    reason: AVAudioSession.RouteChangeReason
  ) -> Notification {
    Notification(
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
    )
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

  func testProviderVADAlsoInterruptsActivePlayback() async {
    gateway.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { self.gateway.connectionState == .connected }
    session.consume(.audioDelta(audioBase64: "AQIDBA==", sampleRate: 24_000, responseId: "r1"))

    session.consume(.turnStarted(turnId: "user-turn"))

    XCTAssertFalse(session.isSpeaking)
    let types = mockSocket.sentMessages.compactMap { message -> String? in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json["type"] as? String
    }
    XCTAssertTrue(types.contains("interrupt"))
    XCTAssertEqual(
      playbackCancelledMessages().last?["reason"] as? String,
      "user_interruption"
    )
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

  func testProviderReconnectLifecycleClearsFailureAndGatewayAttempt() {
    session.consume(.gatewayReconnecting(attempt: 2, maxAttempts: 5))
    session.consume(.voiceConnection(
      state: "unavailable",
      message: "provider temporarily unavailable"
    ))
    guard case .failed(let message) = session.connectionState else {
      return XCTFail("Provider unavailability must be surfaced")
    }
    XCTAssertEqual(message, "provider temporarily unavailable")

    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(session.connectionState, .connecting)

    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)
    XCTAssertNil(session.reconnectAttempt)
    XCTAssertNil(session.errorMessage)
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

    session.consume(.responseInterrupted(responseId: "r1"))
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

  func testVisualTranscriptRequestsOneOnDemandFrame() {
    var receivedIntent: AgentVisionIntent?
    session.onVisionRequest = { receivedIntent = $0 }

    session.consume(.transcriptFinal(role: "user", text: "我眼前是什么"))

    XCTAssertEqual(receivedIntent?.kind, .scene)
    XCTAssertEqual(receivedIntent?.prompt, "我眼前是什么")
  }

  func testOrdinaryTranscriptDoesNotRequestCamera() {
    var requestCount = 0
    session.onVisionRequest = { _ in requestCount += 1 }

    session.consume(.transcriptFinal(role: "user", text: "今天天气怎么样"))

    XCTAssertEqual(requestCount, 0)
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

  /// 启动 socket 并同步标记会话 ready；控制帧只要求底层 socket 存活。
  private func startConnectedSession() {
    session.start()
    session.consume(.voiceReady(inputSampleRate: 16_000))
    XCTAssertEqual(session.connectionState, .connected)
  }

  func testClientStateSleepingEntersSleep() {
    QwenVoiceSession.wakeWordEnabled = false
    session.consume(.clientState(state: "sleeping"))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(session.wakeWordPhase, .sleeping)
  }

  func testVoiceSleepCapabilityDoesNotBecomeConnectionFailure() {
    session.consume(.voiceReady(inputSampleRate: 16_000))

    session.consume(.voiceSleep(state: "enabled"))

    XCTAssertEqual(session.connectionState, .connected)
    XCTAssertFalse(session.isSleeping)
    XCTAssertNil(AgentTurnErrorClassifier.classify(
      connectionState: session.connectionState
    ))
  }

  func testSleepTransitionStopsActivePlaybackWithinBudget() {
    QwenVoiceSession.wakeWordEnabled = false
    startConnectedSession()
    session.consume(.responseStarted(responseId: "sleep-response"))
    session.consume(.audioDelta(
      audioBase64: "AQIDBA==",
      sampleRate: 24_000,
      responseId: "sleep-response"
    ))
    XCTAssertTrue(session.isSpeaking)
    let interruptsBeforeSleep = playbackPipeline.interruptCallCount
    let startedAt = ProcessInfo.processInfo.systemUptime

    session.consume(.voiceSleep(state: "sleeping"))

    let elapsedMilliseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000
    print("[QwenSleepLatency] sleepTransitionAudioStopMs=\(elapsedMilliseconds)")
    let latencyAttachment = XCTAttachment(
      string: "sleepTransitionAudioStopMs=\(elapsedMilliseconds)"
    )
    latencyAttachment.name = "Qwen sleep audio stop latency"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)
    XCTAssertLessThan(elapsedMilliseconds, 10)
    XCTAssertTrue(session.isSleeping)
    XCTAssertFalse(session.isSpeaking)
    XCTAssertEqual(String(describing: session.connectionState), "sleeping")
    XCTAssertEqual(playbackPipeline.interruptCallCount, interruptsBeforeSleep + 1)
  }

  func testWakeLifecycleKeepsWakingPriorityUntilProviderConnects() {
    QwenVoiceSession.wakeWordEnabled = false
    startConnectedSession()
    session.consume(.clientState(state: "sleeping"))
    XCTAssertEqual(String(describing: session.connectionState), "sleeping")

    session.wake()
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    let interruptsBeforeStaleSleep = playbackPipeline.interruptCallCount

    session.consume(.clientState(state: "sleeping"))
    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.consume(.voiceSleep(state: "sleeping"))
    session.consume(.clientState(state: "awake"))
    session.consume(.voiceSleep(state: "awake"))
    XCTAssertFalse(session.isSleeping)
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    XCTAssertEqual(playbackPipeline.interruptCallCount, interruptsBeforeStaleSleep)

    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(String(describing: session.connectionState), "waking")

    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)

    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.wake()
    session.consume(.voiceConnection(
      state: "sleeping",
      message: "wake provider unavailable"
    ))
    XCTAssertTrue(session.isSleeping)
    XCTAssertEqual(String(describing: session.connectionState), "sleeping")
  }

  func testRealtimeLifecycleKeepsUpstreamStatusPrecedenceAcrossLateEvents() {
    startConnectedSession()

    session.consume(.voiceConnection(
      state: "unavailable",
      message: "credential missing"
    ))
    session.consume(.voiceSleep(state: "detected"))
    session.consume(.clientState(state: "sleeping"))
    session.consume(.voiceReady(inputSampleRate: 16_000))
    guard case .failed(let message) = session.connectionState else {
      return XCTFail("unavailable must outrank waking, sleeping, and ready")
    }
    XCTAssertEqual(message, "credential missing")

    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)

    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.consume(.voiceReady(inputSampleRate: 16_000))
    session.consume(.voiceConnection(state: "connecting", message: nil))
    XCTAssertEqual(session.connectionState, .sleeping)

    session.consume(.voiceConnection(state: "sleeping", message: nil))
    session.wake()
    session.consume(.voiceReady(inputSampleRate: 16_000))
    XCTAssertEqual(String(describing: session.connectionState), "waking")
    session.consume(.voiceConnection(state: "connected", message: nil))
    XCTAssertEqual(session.connectionState, .connected)
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
    startConnectedSession()
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
    startConnectedSession()
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
    startConnectedSession()
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
