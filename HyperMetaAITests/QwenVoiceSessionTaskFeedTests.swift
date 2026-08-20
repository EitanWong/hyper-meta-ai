import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionTaskFeedTests: QwenVoiceSessionTestCase {
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
}
