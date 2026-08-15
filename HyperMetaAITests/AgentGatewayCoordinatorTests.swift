/*
 * Agent Gateway Coordinator Tests
 * 协调协议（qwen_audio_agent_protocol）：载荷解析（围栏 / 花括号窗口）、
 * 最终决策、提示词组装与协调执行语义（重试 / 终态校验）。
 */

import XCTest
@testable import HyperMetaAI

// MARK: - 载荷解析

final class AgentGatewayCoordinatorParserTests: XCTestCase {
    func testParsesPlainJSON() {
        let payload = AgentGatewayCoordinatorParser.parsePayload(
            #"{"work_id":"w1","state":"completed"}"#
        )
        XCTAssertEqual(payload?["work_id"] as? String, "w1")
        XCTAssertEqual(payload?["state"] as? String, "completed")
    }

    func testParsesFencedJSON() {
        let payload = AgentGatewayCoordinatorParser.parsePayload(
            """
            ```json
            {"work_id":"w2","state":"delegated"}
            ```
            """
        )
        XCTAssertEqual(payload?["work_id"] as? String, "w2")
    }

    func testParsesFencedJSONCaseInsensitive() {
        let payload = AgentGatewayCoordinatorParser.parsePayload(
            """
            ```JSON
            {"work_id":"w3"}
            ```
            """
        )
        XCTAssertEqual(payload?["work_id"] as? String, "w3")
    }

    func testUnwrapsNestedStringPayload() {
        let payload = AgentGatewayCoordinatorParser.parsePayload(
            #""{"work_id":"w4","state":"completed"}""#
        )
        XCTAssertEqual(payload?["work_id"] as? String, "w4")
    }

    func testFallsBackToBraceWindow() {
        let payload = AgentGatewayCoordinatorParser.parsePayload(
            "前置说明 {\"work_id\":\"w5\",\"state\":\"completed\"} 后置说明"
        )
        XCTAssertEqual(payload?["work_id"] as? String, "w5")
    }

    func testReturnsNilForPlainText() {
        XCTAssertNil(AgentGatewayCoordinatorParser.parsePayload("这只是一段普通文本"))
        XCTAssertNil(AgentGatewayCoordinatorParser.parsePayload("   "))
    }

    func testResponseStateLowercasesAndCleans() {
        XCTAssertEqual(
            AgentGatewayCoordinatorParser.responseState(#"{"state":"COMPLETED"}"#),
            "completed"
        )
        XCTAssertEqual(AgentGatewayCoordinatorParser.responseState("没有协议"), "")
    }

    func testPresentationExtraction() {
        let presentation = AgentGatewayCoordinatorParser.presentation(
            #"{"presentation":{"speech":"好了","inline":{"title":"结果","format":"code","content":"print(1)"}}}"#
        )
        XCTAssertEqual(presentation?.speech, "好了")
        XCTAssertEqual(presentation?.inline?.title, "结果")
        XCTAssertEqual(presentation?.inline?.format, .code)
        XCTAssertEqual(presentation?.inline?.content, "print(1)")
    }

    func testPresentationRejectsEmptyInline() {
        let presentation = AgentGatewayCoordinatorParser.presentation(
            #"{"presentation":{"speech":"好了","inline":{"content":"  "}}}"#
        )
        XCTAssertEqual(presentation?.speech, "好了")
        XCTAssertNil(presentation?.inline)
    }

    func testNormalizeFormatWhitelist() {
        XCTAssertEqual(AgentGatewayCoordinatorParser.normalizeFormat("link"), .link)
        XCTAssertEqual(AgentGatewayCoordinatorParser.normalizeFormat("video"), .markdown)
        XCTAssertEqual(AgentGatewayCoordinatorParser.normalizeFormat(nil), .markdown)
    }

    func testNormalizeContentConvertsStringInlineToObject() {
        let normalized = AgentGatewayCoordinatorParser.normalizeContent(
            #"{"presentation":{"speech":"好了","inline":"详细内容"}}"#
        )
        let payload = AgentGatewayCoordinatorParser.parsePayload(normalized)
        let inline = (payload?["presentation"] as? [String: Any])?["inline"] as? [String: Any]
        XCTAssertEqual(inline?["title"] as? String, "Agent 结果")
        XCTAssertEqual(inline?["format"] as? String, "markdown")
        XCTAssertEqual(inline?["content"] as? String, "详细内容")
    }

    func testNormalizeContentReturnsOriginalForPlainText() {
        XCTAssertEqual(
            AgentGatewayCoordinatorParser.normalizeContent("  普通文本  "),
            "普通文本"
        )
    }
}

// MARK: - 最终决策

final class AgentGatewayDecisionTests: XCTestCase {
    func testDecisionUsesExpectedWorkIdFirst() {
        let decision = AgentGatewayCoordinatorParser.decision(
            #"{"work_id":"payload-id","presentation":{"speech":"好了"}}"#,
            expectedWorkId: "expected-id"
        )
        XCTAssertEqual(decision.workId, "expected-id")
        XCTAssertEqual(decision.state, .completed)
        XCTAssertEqual(decision.mode, .respond)
        XCTAssertEqual(decision.presentation.speech, "好了")
    }

    func testDecisionFallsBackToPayloadWorkId() {
        let decision = AgentGatewayCoordinatorParser.decision(
            #"{"work_id":"payload-id","presentation":{"speech":"好了"}}"#
        )
        XCTAssertEqual(decision.workId, "payload-id")
    }

    func testDecisionSpeechFallsBackToResponseThenContent() {
        let viaResponse = AgentGatewayCoordinatorParser.decision(
            #"{"work_id":"w1","response":"用 response 兜底"}"#
        )
        XCTAssertEqual(viaResponse.presentation.speech, "用 response 兜底")

        let viaContent = AgentGatewayCoordinatorParser.decision("纯文本回复")
        XCTAssertEqual(viaContent.presentation.speech, "纯文本回复")
        XCTAssertNil(viaContent.presentation.inline)
    }

    func testDecisionTruncatesInlineTitleAndFallsBackFormat() {
        let longTitle = String(repeating: "长", count: 200)
        let decision = AgentGatewayCoordinatorParser.decision(
            #"{"presentation":{"speech":"好了","inline":{"title":"\#(longTitle)","format":"html","content":"内容"}}}"#
        )
        XCTAssertEqual(decision.presentation.inline?.title.count, 120)
        XCTAssertEqual(decision.presentation.inline?.format, .markdown)
    }
}

// MARK: - 提示词组装

final class AgentGatewayCoordinatorPromptTests: XCTestCase {
    func testCanonicalScopeAliases() {
        XCTAssertEqual(AgentGatewayCoordinatorPromptBuilder.canonicalScope("Profile"), "user")
        XCTAssertEqual(AgentGatewayCoordinatorPromptBuilder.canonicalScope("rules"), "user")
        XCTAssertEqual(AgentGatewayCoordinatorPromptBuilder.canonicalScope("facts"), "memory")
        XCTAssertEqual(AgentGatewayCoordinatorPromptBuilder.canonicalScope("long_term"), "memory")
        XCTAssertEqual(AgentGatewayCoordinatorPromptBuilder.canonicalScope("unknown"), "unknown")
    }

    func testIsDirectiveScopeOnlyUser() {
        XCTAssertTrue(AgentGatewayCoordinatorPromptBuilder.isDirectiveScope("user"))
        XCTAssertTrue(AgentGatewayCoordinatorPromptBuilder.isDirectiveScope("profile"))
        XCTAssertFalse(AgentGatewayCoordinatorPromptBuilder.isDirectiveScope("memory"))
    }

    func testContextLinesKeepsLastTenAndMapsRoles() {
        let messages = (0..<12).map { index in
            AgentGatewayConversationMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "消息 \(index)"
            )
        }
        let lines = AgentGatewayCoordinatorPromptBuilder.contextLines(messages)
        XCTAssertTrue(lines.contains("助手: 消息 11"))
        XCTAssertTrue(lines.contains("用户: 消息 10"))
        XCTAssertFalse(lines.contains("消息 0"))
    }

    func testContextLinesEmptyFallback() {
        XCTAssertEqual(
            AgentGatewayCoordinatorPromptBuilder.contextLines([]),
            "- 无"
        )
    }

    func testRunLinesFormatsTasks() {
        let lines = AgentGatewayCoordinatorPromptBuilder.runLines([
            AgentGatewayTaskSnapshot(objective: "整理报告", status: "running"),
            AgentGatewayTaskSnapshot(objective: "查航班", status: "completed", result: "CA123")
        ])
        XCTAssertTrue(lines.contains("- 整理报告；状态=running"))
        XCTAssertTrue(lines.contains("- 查航班；状态=completed；结果=CA123"))
    }

    func testRunLinesEmptyFallback() {
        XCTAssertEqual(AgentGatewayCoordinatorPromptBuilder.runLines([]), "- 无")
    }

    func testBuildIncludesEnvelopeAndSections() {
        let prompt = AgentGatewayCoordinatorPromptBuilder.build(
            originalRequest: "帮我查航班",
            objective: "查询航班",
            context: AgentGatewayRunContext(
                originalRequest: "帮我查航班",
                memories: [
                    AgentGatewayMemoryRecord(scope: "user", content: "叫我小王"),
                    AgentGatewayMemoryRecord(scope: "memory", content: "常飞北京")
                ],
                conversation: [
                    AgentGatewayConversationMessage(role: .user, content: "你好")
                ],
                activeTasks: [
                    AgentGatewayTaskSnapshot(objective: "写周报", status: "running")
                ],
                timeZone: "Asia/Shanghai",
                workingDirectory: "/tmp/project"
            ),
            coordinationRunId: "run-1"
        )
        XCTAssertTrue(prompt.contains("<qwen_audio_agent_request>"))
        XCTAssertTrue(prompt.contains("\"request_id\": \"run-1\""))
        XCTAssertTrue(prompt.contains("\"timezone\": \"Asia/Shanghai\""))
        XCTAssertTrue(prompt.contains("/tmp/project"))
        XCTAssertTrue(prompt.contains("<user_preferences>"))
        XCTAssertTrue(prompt.contains("叫我小王"))
        XCTAssertTrue(prompt.contains("<user_memory>"))
        XCTAssertTrue(prompt.contains("常飞北京"))
        XCTAssertTrue(prompt.contains("<recent_voice_context>"))
        XCTAssertTrue(prompt.contains("<voice_work_context>"))
        XCTAssertTrue(prompt.contains("\"state\":\"completed\""))
        XCTAssertTrue(prompt.contains("user_preferences 是当前用户"))
    }

    func testBuildOmitsUserPreferencesWhenAbsent() {
        let prompt = AgentGatewayCoordinatorPromptBuilder.build(
            originalRequest: "查天气",
            objective: "查天气",
            context: AgentGatewayRunContext()
        )
        XCTAssertFalse(prompt.contains("<user_preferences>"))
        XCTAssertTrue(prompt.contains("- 无"))
    }

    func testRetryPromptCarriesStateAndRequestId() {
        let retry = AgentGatewayCoordinatorPromptBuilder.retryPrompt(
            coordinationRunId: "run-9",
            state: "active"
        )
        XCTAssertTrue(retry.contains("<qwen_audio_agent_protocol_retry>"))
        XCTAssertTrue(retry.contains("request_id=run-9"))
        XCTAssertTrue(retry.contains("state=active"))
        XCTAssertTrue(retry.contains("state=completed"))
    }
}

// MARK: - 协调执行语义

final class AgentGatewayCoordinatorSemanticsTests: XCTestCase {
    private func decisionJSON(speech: String, state: String = "completed") -> String {
        #"{"work_id":"w1","state":"\#(state)","mode":"respond","presentation":{"speech":"\#(speech)","inline":null}}"#
    }

    func testEmptyResponseFails() {
        let result = AgentGatewayCoordinatorSemantics.run(
            content: "   ",
            coordinationRunId: "w1",
            runAgain: { _ in
                XCTFail("不应重试")
                return AgentGatewayRunResult(content: "")
            }
        )
        guard case .failure(let error) = result else {
            return XCTFail("应当失败")
        }
        XCTAssertEqual(error, .backendFailed("agent.gateway.error.backend.empty".localized))
    }

    func testPlainTextPassesThroughAsSpeech() {
        let result = AgentGatewayCoordinatorSemantics.run(
            content: "直接回答",
            coordinationRunId: "w1",
            runAgain: { _ in
                XCTFail("不应重试")
                return AgentGatewayRunResult(content: "")
            }
        )
        XCTAssertEqual(try? result.get().presentation.speech, "直接回答")
    }

    func testNonFinalStateRetriesUpToTwoTimesThenFails() {
        var retryCount = 0
        let result = AgentGatewayCoordinatorSemantics.run(
            content: decisionJSON(speech: "还在做", state: "active"),
            coordinationRunId: "w1",
            runAgain: { prompt in
                retryCount += 1
                XCTAssertTrue(prompt.contains("state=active"))
                return AgentGatewayRunResult(content: self.decisionJSON(speech: "还在做", state: "active"))
            }
        )
        XCTAssertEqual(retryCount, 2)
        guard case .failure(let error) = result else {
            return XCTFail("应当失败")
        }
        XCTAssertEqual(error, .coordinatorDidNotFinish(state: "active"))
    }

    func testNonFinalThenCompletedSucceedsAfterOneRetry() {
        var retryCount = 0
        let result = AgentGatewayCoordinatorSemantics.run(
            content: decisionJSON(speech: "受理", state: "delegated"),
            coordinationRunId: "w1",
            runAgain: { _ in
                retryCount += 1
                return AgentGatewayRunResult(
                    content: self.decisionJSON(speech: "最终完成", state: "completed")
                )
            }
        )
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(try? result.get().presentation.speech, "最终完成")
    }

    func testRetryBackendFailurePropagates() {
        let result = AgentGatewayCoordinatorSemantics.run(
            content: decisionJSON(speech: "受理", state: "delegated"),
            coordinationRunId: "w1",
            runAgain: { _ in
                AgentGatewayRunResult(content: "", failed: true, errorMessage: "网络错误")
            }
        )
        guard case .failure(let error) = result else {
            return XCTFail("应当失败")
        }
        XCTAssertEqual(error, .backendFailed("网络错误"))
    }
}
