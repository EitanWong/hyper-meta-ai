import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

@MainActor
final class QwenVoiceSessionCommandTests: QwenVoiceSessionTestCase {
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
}
