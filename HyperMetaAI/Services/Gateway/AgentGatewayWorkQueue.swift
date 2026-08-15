/*
 * Agent Gateway Work Queue
 * 对齐 qwen-audio-agent v1.8.3 的非阻塞工作队列语义：
 *   - 每 owner 一个 FIFO 队列，同一 owner 同时只执行一件工作
 *   - 受理（enqueue）立即返回；spawn_thinking 从不等待工作完成
 *   - 终态工作进入有界历史，便于状态查询与 UI 展示
 * 纯值模型，可测。
 */

import Foundation

/// 非阻塞工作队列（owner FIFO + 每 owner 单在飞）
struct AgentGatewayWorkQueue {
    /// 每 owner 最大排队数量（防止积压失控）
    static let maxQueuedPerOwner = 8
    /// 终态历史上限
    static let maxFinishedHistory = 40

    private(set) var queued: [AgentGatewayWork] = []
    private(set) var running: [AgentGatewayWork] = []
    private(set) var finished: [AgentGatewayWork] = []

    /// 全部工作（排队 + 在飞 + 终态历史，顺序稳定便于展示）
    var allWorks: [AgentGatewayWork] {
        queued + running + finished
    }

    /// 活动工作（排队或执行中）
    var activeWorks: [AgentGatewayWork] {
        queued + running
    }

    init() {}

    /// 受理一件工作；重复 ID / 空目标 / 队列满返回 false（对齐受理即时语义）
    @discardableResult
    mutating func accept(_ work: AgentGatewayWork, at date: Date = Date()) -> Bool {
        guard !work.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard !allWorks.contains(where: { $0.id == work.id }) else { return false }
        guard queued.filter({ $0.owner == work.owner }).count < Self.maxQueuedPerOwner else {
            return false
        }
        var item = work
        item.status = .queued
        item.updatedAt = date
        queued.append(item)
        return true
    }

    /// 取某 owner 的下一件排队工作；该 owner 已有在飞工作或队列为空返回 nil
    mutating func beginNext(for owner: String, at date: Date = Date()) -> AgentGatewayWork? {
        guard !running.contains(where: { $0.owner == owner }) else { return nil }
        guard let index = queued.firstIndex(where: { $0.owner == owner }) else { return nil }
        var work = queued.remove(at: index)
        work.status = .running
        work.updatedAt = date
        work.attemptCount += 1
        running.append(work)
        return work
    }

    /// 把在飞工作移入终态历史
    @discardableResult
    mutating func finish(
        id: String,
        status: AgentGatewayWorkStatus,
        presentation: AgentGatewayPresentation? = nil,
        errorMessage: String? = nil,
        at date: Date = Date()
    ) -> AgentGatewayWork? {
        guard let index = running.firstIndex(where: { $0.id == id }),
              status.isTerminal else {
            return nil
        }
        var work = running.remove(at: index)
        work.status = status
        work.presentation = presentation
        work.errorMessage = errorMessage
        work.updatedAt = date
        work.completedAt = date
        finished.append(work)
        trimHistory()
        return work
    }

    /// 取消：排队直接终态；在飞工作标记取消后移入历史
    @discardableResult
    mutating func cancel(id: String, at date: Date = Date()) -> AgentGatewayWork? {
        if let index = queued.firstIndex(where: { $0.id == id }) {
            var work = queued.remove(at: index)
            work.status = .cancelled
            work.updatedAt = date
            work.completedAt = date
            finished.append(work)
            trimHistory()
            return work
        }
        if let index = running.firstIndex(where: { $0.id == id }) {
            var work = running.remove(at: index)
            work.status = .cancelled
            work.updatedAt = date
            work.completedAt = date
            finished.append(work)
            trimHistory()
            return work
        }
        return nil
    }

    /// 取消某 owner 的全部排队工作；返回取消数量
    @discardableResult
    mutating func cancelAllQueued(for owner: String, at date: Date = Date()) -> Int {
        let targets = queued.filter { $0.owner == owner }
        guard !targets.isEmpty else { return 0 }
        queued.removeAll { $0.owner == owner }
        for work in targets {
            var item = work
            item.status = .cancelled
            item.updatedAt = date
            item.completedAt = date
            finished.append(item)
        }
        trimHistory()
        return targets.count
    }

    /// 按 ID 查询（含终态历史）
    func work(id: String) -> AgentGatewayWork? {
        allWorks.first { $0.id == id }
    }

    /// 某 owner 当前是否在飞
    func isOwnerRunning(_ owner: String) -> Bool {
        running.contains { $0.owner == owner }
    }

    /// 清理早于 cutoff 的终态历史
    mutating func purgeFinished(before cutoff: Date) {
        finished.removeAll { $0.completedAt.map { $0 < cutoff } ?? false }
    }

    /// 清空全部状态（会话结束）
    mutating func reset() {
        queued.removeAll()
        running.removeAll()
        finished.removeAll()
    }

    private mutating func trimHistory() {
        if finished.count > Self.maxFinishedHistory {
            finished.removeFirst(finished.count - Self.maxFinishedHistory)
        }
    }
}
