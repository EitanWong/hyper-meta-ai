import XCTest
@testable import HyperMetaAI

/// 追问上下文恢复（纯逻辑）：会话内存优先，快照回退取最近带详细结果的已完成任务
final class AgentTaskFollowUpRestorerTests: XCTestCase {

    private func task(
        id: String,
        status: String = "completed",
        result: String?,
        updatedAt: TimeInterval
    ) -> PersistedAgentTask {
        PersistedAgentTask(
            taskId: id,
            title: "任务",
            status: status,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            resultText: result
        )
    }

    func testPrefersSessionContext() {
        let tasks = [task(id: "t1", result: "快照结果", updatedAt: 100)]
        XCTAssertEqual(
            AgentTaskFollowUpRestorer.restoreContext(
                sessionContext: "会话结果",
                storedTasks: tasks
            ),
            "会话结果"
        )
    }

    func testFallsBackToLatestCompletedTaskWithResult() {
        let tasks = [
            task(id: "t1", result: "旧结果", updatedAt: 100),
            task(id: "t2", result: nil, updatedAt: 200),
            task(id: "t3", result: "最新结果", updatedAt: 300),
        ]
        XCTAssertEqual(
            AgentTaskFollowUpRestorer.restoreContext(
                sessionContext: nil,
                storedTasks: tasks
            ),
            "最新结果"
        )
    }

    func testIgnoresEmptySessionContextAndWhitespaceResult() {
        let tasks = [
            task(id: "t1", result: "   ", updatedAt: 100),
            task(id: "t2", result: "有效结果", updatedAt: 50),
        ]
        XCTAssertEqual(
            AgentTaskFollowUpRestorer.restoreContext(
                sessionContext: "   ",
                storedTasks: tasks
            ),
            "有效结果",
            "空白会话上下文视为无上下文"
        )
    }

    func testFailedTasksNotUsed() {
        let tasks = [
            task(id: "t1", status: "failed", result: "失败详情", updatedAt: 100),
            task(id: "t2", status: "running", result: "进行中", updatedAt: 90),
        ]
        XCTAssertNil(
            AgentTaskFollowUpRestorer.restoreContext(
                sessionContext: nil,
                storedTasks: tasks
            ),
            "只有已完成任务可作追问来源"
        )
    }

    func testNilWhenNothingUsable() {
        XCTAssertNil(
            AgentTaskFollowUpRestorer.restoreContext(
                sessionContext: nil,
                storedTasks: []
            )
        )
        XCTAssertNil(
            AgentTaskFollowUpRestorer.restoreContext(
                sessionContext: nil,
                storedTasks: [task(id: "t1", result: nil, updatedAt: 100)]
            )
        )
    }
}

/// Live Activity「追问」按钮请求标记
final class AgentTaskFollowUpTapStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.task.followup.tap.v1")
        suite.removePersistentDomain(forName: "test.task.followup.tap.v1")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.task.followup.tap.v1")
        super.tearDown()
    }

    func testConsumeRoundTrip() {
        suite.set(true, forKey: AgentTaskFollowUpTapStore.requestKey)
        XCTAssertTrue(AgentTaskFollowUpTapStore.consume(defaults: suite))
        XCTAssertFalse(AgentTaskFollowUpTapStore.consume(defaults: suite), "一次性消费")
    }

    func testConsumeWithoutMarkerReturnsFalse() {
        XCTAssertFalse(AgentTaskFollowUpTapStore.consume(defaults: suite))
    }
}

/// 持久化任务快照：resultText 编解码（旧数据无该字段兼容）
final class PersistedAgentTaskResultTextTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let task = PersistedAgentTask(
            taskId: "t1",
            title: "订餐厅",
            status: "completed",
            updatedAt: Date(timeIntervalSince1970: 100),
            resultText: "已订好，明晚 7 点"
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(PersistedAgentTask.self, from: data)
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.resultText, "已订好，明晚 7 点")
    }

    func testDecodesLegacySnapshotWithoutResultText() throws {
        let legacy = """
        [{"taskId":"t1","title":"旧任务","status":"completed","updatedAt":100.0}]
        """
        let tasks = try JSONDecoder().decode(
            [PersistedAgentTask].self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].resultText, "旧快照无 resultText 字段应兼容解码")
    }
}

/// 协调器：恢复上下文 + 请求语音会话（Live Activity 按钮消费接线）
@MainActor
final class AgentTaskFollowUpCoordinatorTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "test.task.followup.coordinator.v1")
        suite.removePersistentDomain(forName: "test.task.followup.coordinator.v1")
        VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "test.task.followup.coordinator.v1")
        VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
        super.tearDown()
    }

    func testRequestFollowUpCarriesRestoredContext() {
        let tasks = [
            PersistedAgentTask(
                taskId: "t1",
                title: "整理报告",
                status: "completed",
                updatedAt: Date(),
                resultText: "报告已生成，共 12 页"
            )
        ]
        AgentTaskFollowUpCoordinator.requestFollowUp(
            sessionContext: nil,
            storedTasks: tasks
        )
        let request = VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
        XCTAssertEqual(request?.followUpContext, "报告已生成，共 12 页")
        XCTAssertNil(request?.instruction)
        XCTAssertNil(request?.brain)
    }

    func testRequestFollowUpWithoutContextStillOpensVoicePage() {
        AgentTaskFollowUpCoordinator.requestFollowUp(
            sessionContext: nil,
            storedTasks: []
        )
        let request = VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
        XCTAssertNotNil(request)
        XCTAssertNil(request?.followUpContext)
    }

    func testConsumeIfNeededConsumesMarkerAndRequests() {
        suite.set(true, forKey: AgentTaskFollowUpTapStore.requestKey)
        let handled = AgentTaskFollowUpCoordinator.consumeIfNeeded(defaults: suite)
        XCTAssertTrue(handled)
        XCTAssertNotNil(VoiceAssistantRouter.shared.consumeVoiceSessionRequest())
        XCTAssertFalse(AgentTaskFollowUpTapStore.consume(defaults: suite), "标记已清除")
    }

    func testConsumeIfNeededWithoutMarkerIsNoOp() {
        let handled = AgentTaskFollowUpCoordinator.consumeIfNeeded(defaults: suite)
        XCTAssertFalse(handled)
        XCTAssertNil(VoiceAssistantRouter.shared.consumeVoiceSessionRequest())
    }
}

/// 对话记录「继续追问」上下文提取（纯逻辑）：详情页按钮 → 语音页注入
@MainActor
final class ConversationFollowUpContextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    }

    override func tearDown() {
        VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
        super.tearDown()
    }

    private func record(_ messages: [ConversationMessage]) -> ConversationRecord {
        ConversationRecord(messages: messages)
    }

    private func message(
        _ role: ConversationMessage.MessageRole,
        _ content: String
    ) -> ConversationMessage {
        ConversationMessage(role: role, content: content)
    }

    func testUsesLastAssistantReply() {
        let conversation = record([
            message(.user, "查一下明天天气"),
            message(.assistant, "明天上海 26°C，晴。"),
        ])
        XCTAssertEqual(conversation.followUpContext, "明天上海 26°C，晴。")
    }

    func testIgnoresTrailingUserMessage() {
        let conversation = record([
            message(.user, "推荐一部电影"),
            message(.assistant, "《奥本海默》，IMDb 8.4。"),
            message(.user, "还有呢？"),
        ])
        XCTAssertEqual(
            conversation.followUpContext,
            "《奥本海默》，IMDb 8.4。",
            "以最后一条助手回复为准，不被未回答的用户消息影响"
        )
    }

    func testTrimsWhitespace() {
        let conversation = record([
            message(.user, "你好"),
            message(.assistant, "  你好，我是 JARVIS。  "),
        ])
        XCTAssertEqual(conversation.followUpContext, "你好，我是 JARVIS。")
    }

    func testNilWhenNoAssistantReply() {
        XCTAssertNil(record([]).followUpContext)
        XCTAssertNil(record([message(.user, "还没回答")]).followUpContext)
    }

    func testNilWhenAssistantReplyBlank() {
        let conversation = record([
            message(.user, "问个问题"),
            message(.assistant, "   \n "),
        ])
        XCTAssertNil(conversation.followUpContext)
    }

    func testCoordinatorCarriesConversationContext() {
        let conversation = record([
            message(.user, "帮我总结今天的会议"),
            message(.assistant, "会议结论：上线时间定为下周三。"),
        ])
        AgentTaskFollowUpCoordinator.requestFollowUp(
            sessionContext: conversation.followUpContext,
            storedTasks: []
        )
        let request = VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
        XCTAssertEqual(request?.followUpContext, "会议结论：上线时间定为下周三。")
        XCTAssertNil(request?.instruction)
        XCTAssertNil(request?.brain)
    }
}

/// 任务卡「在聊天中追问」资格判断（纯逻辑）：仅已完成且有非空结果的任务可追问
final class AgentTaskFollowUpOfferTests: XCTestCase {

    private func task(
        status: QwenAgentTask.Status,
        result: String?
    ) -> QwenAgentTask {
        QwenAgentTask(
            taskId: "t1",
            title: "整理报告",
            status: status,
            resultText: result,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
    }

    func testEligibleWhenCompletedWithResult() {
        XCTAssertTrue(
            AgentTaskFollowUpOffer.isEligible(task(status: .completed, result: "报告已生成，共 12 页"))
        )
    }

    func testNotEligibleWithoutResult() {
        XCTAssertFalse(AgentTaskFollowUpOffer.isEligible(task(status: .completed, result: nil)))
        XCTAssertFalse(AgentTaskFollowUpOffer.isEligible(task(status: .completed, result: "   \n ")))
    }

    func testNotEligibleForOtherStatuses() {
        for status: QwenAgentTask.Status in [.waiting, .running, .failed, .cancelled] {
            XCTAssertFalse(
                AgentTaskFollowUpOffer.isEligible(task(status: status, result: "有结果也不能追问")),
                "\(status) 状态任务不应出现聊天追问"
            )
        }
    }
}

/// 聊天页「在聊天中追问」一次性包装门（纯逻辑）：首条消息携带结果上下文，随后透传
final class TaskFollowUpWrapGateTests: XCTestCase {

    func testArmedConsumesExactlyOnce() {
        var gate = TaskFollowUpWrapGate(armed: true)
        XCTAssertTrue(gate.consumeIfArmed(), "武装状态下首条消息应携带上下文")
        XCTAssertFalse(gate.consumeIfArmed(), "包装标记应一次性消费")
        XCTAssertFalse(gate.consumeIfArmed())
    }

    func testUnarmedNeverConsumes() {
        var gate = TaskFollowUpWrapGate()
        XCTAssertFalse(gate.consumeIfArmed())
        XCTAssertFalse(gate.consumeIfArmed())
    }

    func testReArmAfterConsume() {
        var gate = TaskFollowUpWrapGate(armed: true)
        _ = gate.consumeIfArmed()
        gate = TaskFollowUpWrapGate(armed: true)
        XCTAssertTrue(gate.consumeIfArmed(), "重新武装后应再次生效")
    }
}
