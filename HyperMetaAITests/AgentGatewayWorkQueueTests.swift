/*
 * Agent Gateway Work Queue Tests
 * 非阻塞队列：受理去重 / 上限、owner FIFO、每 owner 单在飞、
 * 终态流转、取消与历史清理。
 */

import XCTest
@testable import HyperMetaAI

final class AgentGatewayWorkQueueTests: XCTestCase {
    private func work(
        id: String = UUID().uuidString,
        owner: String = AgentGatewayOwner.personal,
        objective: String = "整理报告"
    ) -> AgentGatewayWork {
        AgentGatewayWork(id: id, owner: owner, objective: objective)
    }

    func testAcceptAddsToQueued() {
        var queue = AgentGatewayWorkQueue()
        let item = work(id: "w1")
        XCTAssertTrue(queue.accept(item))
        XCTAssertEqual(queue.queued.map(\.id), ["w1"])
        XCTAssertEqual(queue.work(id: "w1")?.status, .queued)
    }

    func testAcceptRejectsEmptyObjective() {
        var queue = AgentGatewayWorkQueue()
        XCTAssertFalse(queue.accept(work(id: "w1", objective: "   ")))
        XCTAssertTrue(queue.allWorks.isEmpty)
    }

    func testAcceptRejectsDuplicateId() {
        var queue = AgentGatewayWorkQueue()
        XCTAssertTrue(queue.accept(work(id: "w1")))
        XCTAssertFalse(queue.accept(work(id: "w1")))
        XCTAssertEqual(queue.queued.count, 1)
    }

    func testAcceptEnforcesPerOwnerLimit() {
        var queue = AgentGatewayWorkQueue()
        for index in 0..<AgentGatewayWorkQueue.maxQueuedPerOwner {
            XCTAssertTrue(queue.accept(work(id: "w\(index)")))
        }
        XCTAssertFalse(queue.accept(work(id: "overflow")))
    }

    func testBeginNextRunsFIFOWithinOwner() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        queue.accept(work(id: "w2"))
        let first = queue.beginNext(for: AgentGatewayOwner.personal)
        XCTAssertEqual(first?.id, "w1")
        XCTAssertEqual(first?.status, .running)
        XCTAssertEqual(queue.queued.map(\.id), ["w2"])
    }

    func testBeginNextBlocksWhenOwnerRunning() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        queue.accept(work(id: "w2"))
        _ = queue.beginNext(for: AgentGatewayOwner.personal)
        XCTAssertNil(queue.beginNext(for: AgentGatewayOwner.personal))
        XCTAssertEqual(queue.queued.map(\.id), ["w2"])
    }

    func testDifferentOwnersRunInParallel() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "a1", owner: "owner-a"))
        queue.accept(work(id: "b1", owner: "owner-b"))
        _ = queue.beginNext(for: "owner-a")
        let second = queue.beginNext(for: "owner-b")
        XCTAssertEqual(second?.id, "b1")
        XCTAssertTrue(queue.isOwnerRunning("owner-a"))
        XCTAssertTrue(queue.isOwnerRunning("owner-b"))
    }

    func testFinishMovesToHistoryWithPresentation() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        _ = queue.beginNext(for: AgentGatewayOwner.personal)
        let presentation = AgentGatewayPresentation(
            speech: "好了",
            inline: AgentGatewayInlineResult(title: "结果", format: .markdown, content: "内容")
        )
        let finished = queue.finish(
            id: "w1",
            status: .completed,
            presentation: presentation,
            at: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(finished?.status, .completed)
        XCTAssertEqual(finished?.presentation, presentation)
        XCTAssertEqual(finished?.completedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(queue.running.isEmpty)
        XCTAssertEqual(queue.finished.map(\.id), ["w1"])
    }

    func testFinishRejectsNonTerminalStatus() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        _ = queue.beginNext(for: AgentGatewayOwner.personal)
        XCTAssertNil(queue.finish(id: "w1", status: .running))
        XCTAssertEqual(queue.running.count, 1)
    }

    func testCancelQueuedWork() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        let cancelled = queue.cancel(id: "w1")
        XCTAssertEqual(cancelled?.status, .cancelled)
        XCTAssertTrue(queue.queued.isEmpty)
        XCTAssertEqual(queue.finished.map(\.id), ["w1"])
    }

    func testCancelRunningWork() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        _ = queue.beginNext(for: AgentGatewayOwner.personal)
        let cancelled = queue.cancel(id: "w1")
        XCTAssertEqual(cancelled?.status, .cancelled)
        XCTAssertTrue(queue.running.isEmpty)
    }

    func testCancelUnknownIdReturnsNil() {
        var queue = AgentGatewayWorkQueue()
        XCTAssertNil(queue.cancel(id: "missing"))
    }

    func testCancelAllQueuedForOwner() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "a1", owner: "owner-a"))
        queue.accept(work(id: "a2", owner: "owner-a"))
        queue.accept(work(id: "b1", owner: "owner-b"))
        let count = queue.cancelAllQueued(for: "owner-a")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(queue.queued.map(\.id), ["b1"])
        XCTAssertEqual(Set(queue.finished.map(\.id)), ["a1", "a2"])
    }

    func testHistoryTrimmedToLimit() {
        var queue = AgentGatewayWorkQueue()
        let total = AgentGatewayWorkQueue.maxFinishedHistory + 5
        for index in 0..<total {
            queue.accept(work(id: "w\(index)"))
            queue.cancel(id: "w\(index)")
        }
        XCTAssertEqual(queue.finished.count, AgentGatewayWorkQueue.maxFinishedHistory)
        XCTAssertNil(queue.work(id: "w0"))
        XCTAssertNotNil(queue.work(id: "w\(total - 1)"))
    }

    func testPurgeFinishedBeforeCutoff() {
        var queue = AgentGatewayWorkQueue()
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        queue.accept(work(id: "w1"))
        queue.cancel(id: "w1", at: old)
        queue.accept(work(id: "w2"))
        queue.cancel(id: "w2", at: recent)
        queue.purgeFinished(before: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(queue.finished.map(\.id), ["w2"])
    }

    func testResetClearsEverything() {
        var queue = AgentGatewayWorkQueue()
        queue.accept(work(id: "w1"))
        _ = queue.beginNext(for: AgentGatewayOwner.personal)
        queue.reset()
        XCTAssertTrue(queue.allWorks.isEmpty)
        XCTAssertFalse(queue.isOwnerRunning(AgentGatewayOwner.personal))
    }
}
