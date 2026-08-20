/*
 * Agent Gateway Service Tests
 * 内置网关运行时：受理 → FIFO 执行 → 协调重试 → 完成公告（安全窗口）、
 * 超时 / 取消 / 单轮协调。后端执行与取消全部注入，不触碰真实服务。
 */

import XCTest
@testable import HyperMetaAI

@MainActor
final class AgentGatewayServiceTests: XCTestCase {
    /// 可编排的后端执行器：记录提示词，按队列返回预设结果
    private final class ScriptedBackend {
        var prompts: [String] = []
        var responses: [AgentGatewayRunResult] = []
        var onRun: ((String) -> Void)?

        func executor() -> AgentGatewayService.BackendExecutor {
            AgentGatewayService.BackendExecutor { [self] prompt, _, completion in
                prompts.append(prompt)
                onRun?(prompt)
                guard !responses.isEmpty else { return }
                completion(responses.removeFirst())
            }
        }
    }

    private func makeService(_ backend: ScriptedBackend) -> AgentGatewayService {
        let service = AgentGatewayService(executor: backend.executor())
        service.backendCanceller = { _ in }
        return service
    }

    private func decisionJSON(speech: String, state: String = "completed") -> String {
        #"{"work_id":"w","state":"\#(state)","mode":"respond","presentation":{"speech":"\#(speech)","inline":null}}"#
    }

    func testSubmitWorkCompletesAndAnnounces() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: decisionJSON(speech: "报告整理好了"))
        ]
        let service = makeService(backend)

        var announcements: [String] = []
        service.onAnnouncement = { announcement in
            announcements.append(announcement.speech)
        }

        let work = service.submitWork(objective: "整理报告", brain: .hermes)
        XCTAssertEqual(work?.status, .queued)

        let done = expectation(description: "completed")
        service.onWorkEvent = { event in
            if event.id == work?.id, event.status == .completed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)

        let finished = service.works.first { $0.id == work?.id }
        XCTAssertEqual(finished?.status, .completed)
        XCTAssertEqual(finished?.presentation?.speech, "报告整理好了")
        XCTAssertEqual(announcements, ["报告整理好了"])
        XCTAssertTrue(backend.prompts.first?.contains("<qwen_audio_agent_request>") == true)
        XCTAssertTrue(backend.prompts.first?.contains("整理报告") == true)
    }

    func testSubmitWorkRejectsEmptyObjective() async {
        let service = makeService(ScriptedBackend())
        var errors: [AgentGatewayError] = []
        service.onError = { errors.append($0) }
        XCTAssertNil(service.submitWork(objective: "   ", brain: .hermes))
        XCTAssertEqual(errors, [.emptyObjective])
    }

    func testSubmitWorkDoesNotCreateTaskWithoutBackend() {
        let backend = ScriptedBackend()
        let service = makeService(backend)
        var errors: [AgentGatewayError] = []
        service.onError = { errors.append($0) }

        XCTAssertNil(service.submitWork(objective: "整理报告", brain: .none))
        XCTAssertEqual(errors, [.backendUnavailable])
        XCTAssertTrue(service.works.isEmpty)
        XCTAssertTrue(backend.prompts.isEmpty)
    }

    func testWorksRunFIFOWithinOwner() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: decisionJSON(speech: "第一件完成")),
            AgentGatewayRunResult(content: decisionJSON(speech: "第二件完成"))
        ]
        let service = makeService(backend)

        let first = service.submitWork(objective: "第一件", brain: .hermes)
        let second = service.submitWork(objective: "第二件", brain: .hermes)
        XCTAssertEqual(first?.status, .queued)
        XCTAssertEqual(second?.status, .queued)

        let done = expectation(description: "both done")
        service.onWorkEvent = { event in
            if event.id == second?.id, event.status == .completed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(backend.prompts.count, 2)
        XCTAssertTrue(backend.prompts[0].contains("第一件"))
        XCTAssertTrue(backend.prompts[1].contains("第二件"))
    }

    func testNonFinalStateRetriesThenCompletes() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: decisionJSON(speech: "受理中", state: "active")),
            AgentGatewayRunResult(content: decisionJSON(speech: "最终完成", state: "completed"))
        ]
        let service = makeService(backend)
        let work = service.submitWork(objective: "查询航班", brain: .hermes)

        let done = expectation(description: "completed")
        service.onWorkEvent = { event in
            if event.id == work?.id, event.status == .completed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(backend.prompts.count, 2)
        XCTAssertTrue(backend.prompts[1].contains("<qwen_audio_agent_protocol_retry>"))
        XCTAssertTrue(backend.prompts[1].contains("state=active"))
        XCTAssertEqual(service.works.first(where: { $0.id == work?.id })?.presentation?.speech, "最终完成")
    }

    func testBackendFailureFailsWork() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: "", failed: true, errorMessage: "后端不可达")
        ]
        let service = makeService(backend)
        let work = service.submitWork(objective: "写周报", brain: .hermes)

        let done = expectation(description: "failed")
        service.onWorkEvent = { event in
            if event.id == work?.id, event.status == .failed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
        let finished = service.works.first { $0.id == work?.id }
        XCTAssertEqual(finished?.status, .failed)
        XCTAssertNotNil(finished?.errorMessage)
    }

    func testAnnouncementHeldWhileWindowBlocked() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: decisionJSON(speech: "好了"))
        ]
        let service = makeService(backend)
        var announcements: [String] = []
        service.onAnnouncement = { announcements.append($0.speech) }
        service.window.beginTurn("turn-1")

        let work = service.submitWork(objective: "查天气", brain: .hermes)
        let done = expectation(description: "completed")
        service.onWorkEvent = { event in
            if event.id == work?.id, event.status == .completed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(announcements.isEmpty)

        service.window.endSpeech()
        service.window.responseDone(turnId: "turn-1")
        service.windowDidChange()
        XCTAssertEqual(announcements, ["好了"])
    }

    func testCancelQueuedWork() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: decisionJSON(speech: "完成"))
        ]
        let service = makeService(backend)
        let first = service.submitWork(objective: "第一件", brain: .hermes)
        let second = service.submitWork(objective: "第二件", brain: .hermes)
        service.cancel(workId: second!.id)

        let done = expectation(description: "first done")
        service.onWorkEvent = { event in
            if event.id == first?.id, event.status == .completed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
        let cancelled = service.works.first { $0.id == second?.id }
        XCTAssertEqual(cancelled?.status, .cancelled)
        XCTAssertEqual(backend.prompts.count, 1)
    }

    func testTimeoutFailsWork() async {
        let backend = ScriptedBackend()
        backend.responses = [] // 永不返回 → 超时兜底
        let service = makeService(backend)
        service.workTimeout = 0.05
        let work = service.submitWork(objective: "长任务", brain: .hermes)

        let done = expectation(description: "timeout")
        service.onWorkEvent = { event in
            if event.id == work?.id, event.status == .failed {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
        let finished = service.works.first { $0.id == work?.id }
        XCTAssertEqual(finished?.status, .failed)
        XCTAssertEqual(finished?.errorMessage, AgentGatewayError.timeout.errorDescription)
    }

    func testRunSingleTurnReturnsFinalSpeech() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: decisionJSON(speech: "今天 32 度"))
        ]
        let service = makeService(backend)

        let result = await withCheckedContinuation { continuation in
            service.runSingleTurn("今天多少度", brain: .hermes) { result in
                continuation.resume(returning: result)
            }
        }
        XCTAssertEqual(try? result.get().presentation.speech, "今天 32 度")
    }

    func testRunSingleTurnPlainTextFallback() async {
        let backend = ScriptedBackend()
        backend.responses = [
            AgentGatewayRunResult(content: "直接回答你")
        ]
        let service = makeService(backend)

        let result = await withCheckedContinuation { continuation in
            service.runSingleTurn("今天多少度", brain: .hermes) { result in
                continuation.resume(returning: result)
            }
        }
        XCTAssertEqual(try? result.get().presentation.speech, "直接回答你")
    }

    func testRunSingleTurnWithoutBackendFailsImmediately() async {
        let backend = ScriptedBackend()
        let service = makeService(backend)

        let result = await withCheckedContinuation { continuation in
            service.runSingleTurn("今天多少度", brain: .none) { result in
                continuation.resume(returning: result)
            }
        }

        XCTAssertEqual(result, .failure(.backendUnavailable))
        XCTAssertTrue(backend.prompts.isEmpty)
    }
}
