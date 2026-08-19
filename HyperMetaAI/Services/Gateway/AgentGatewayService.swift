/*
 * Agent Gateway Service
 * 内置网关运行时：把 qwen-audio-agent 网关的核心职责（非阻塞工作受理、
 * owner FIFO 串行执行、协调协议重试、安全窗口公告）内置进 App，无需外部
 * Node 网关即可获得 spawn_thinking 语义。后端执行与公告出口可注入，便于测试。
 */

import Combine
import Foundation

/// 内置网关服务（@MainActor：后端服务回调均在主线程）
@MainActor
final class AgentGatewayService: ObservableObject {
    static let shared = AgentGatewayService()

    // MARK: - 注入点

    /// 后端执行器：发送一次协调提示词，回调原始结果
    struct BackendExecutor {
        var run: @MainActor (_ prompt: String, _ brain: AgentBrain, _ completion: @escaping (AgentGatewayRunResult) -> Void) -> Void
    }

    var executor: BackendExecutor
    /// 取消后端执行（默认走大脑路由取消；测试可注入避免触碰真实服务）
    var backendCanceller: (AgentBrain) -> Void = { brain in
        AgentBrainRouter.shared.cancel(to: brain)
    }
    /// 工作终态公告出口（语音会话在安全窗口播报）
    var onAnnouncement: ((AgentGatewayAnnouncement) -> Void)?
    /// 工作状态变化回调（UI 任务流）
    var onWorkEvent: ((AgentGatewayWork) -> Void)?
    /// 错误回调（不可恢复的失败）
    var onError: ((AgentGatewayError) -> Void)?
    /// 协调上下文组装（默认仅原话 + 当前时区；语音会话可注入记忆 / 会话上下文）
    var contextProvider: (AgentGatewayWork) -> AgentGatewayRunContext = { work in
        AgentGatewayRunContext(originalRequest: work.objective)
    }
    /// 单件工作执行超时（防后端挂起阻塞队列）
    var workTimeout: TimeInterval = 120

    // MARK: - 状态

    @Published private(set) var works: [AgentGatewayWork] = []
    @Published private(set) var isProcessing = false

    private var queue = AgentGatewayWorkQueue()
    /// 公告安全插入窗口（由语音会话驱动 beginTurn / endSpeech / responseDone 等）
    var window = AgentGatewayAnnouncementWindow()
    private var pendingAnnouncements: [AgentGatewayAnnouncement] = []
    private var runTasks: [String: Task<Void, Never>] = [:]
    /// 每件工作受理时的大脑选择（排队期间设置变化不影响已受理工作）
    private var workBrains: [String: AgentBrain] = [:]
    private var cancelRequested = Set<String>()

    // MARK: - 初始化

    init(executor: BackendExecutor? = nil) {
        self.executor = executor ?? Self.defaultExecutor()
    }

    /// 默认后端执行器：复用现有大脑路由（Hermes 流式聚合 / OpenClaw 快照 /
    /// Custom Agent 流式聚合），Auto 按规则路由。
    static func defaultExecutor() -> BackendExecutor {
        BackendExecutor { prompt, brain, completion in
            let resolved = AgentBrainRouter.resolvedBrain(prompt, selection: brain)
            switch resolved {
            case .auto, .none, .qwen:
                completion(AgentGatewayRunResult(
                    content: "",
                    failed: true,
                    errorMessage: "agent.gateway.error.backend.unavailable".localized
                ))
            case .hermes:
                HermesService.shared.sendMessage(
                    prompt,
                    image: nil,
                    instructions: nil,
                    onDelta: { _ in },
                    onTool: { _ in },
                    onComplete: { text in
                        completion(AgentGatewayRunResult(content: text))
                    },
                    onError: { message in
                        completion(AgentGatewayRunResult(
                            content: "",
                            failed: true,
                            errorMessage: message
                        ))
                    }
                )
            case .openclaw:
                let service = OpenClawNodeService.shared
                let previousHandler = service.onChatEvent
                var settled = false
                service.onChatEvent = { snapshot in
                    guard !settled else { return }
                    let parsed = AgentBrainEventParser.parseOpenClawEvent(snapshot)
                    guard parsed.isFinal else { return }
                    settled = true
                    service.onChatEvent = previousHandler
                    completion(AgentGatewayRunResult(content: parsed.text))
                }
                service.sendChatMessage(prompt)
            case .custom:
                guard let config = AgentBrainRouter.customAgentConfig() else {
                    completion(AgentGatewayRunResult(
                        content: "",
                        failed: true,
                        errorMessage: "custom.agent.brain.noconfig".localized
                    ))
                    return
                }
                CustomAgentService.shared.sendMessage(
                    config: config,
                    text: prompt,
                    image: nil,
                    systemPrompt: nil,
                    toolExecutor: { call in
                        await CustomAgentLocalTools.execute(call)
                    },
                    onDelta: { _ in },
                    onTool: { _ in },
                    onComplete: { text in
                        completion(AgentGatewayRunResult(content: text))
                    },
                    onError: { message in
                        completion(AgentGatewayRunResult(
                            content: "",
                            failed: true,
                            errorMessage: message
                        ))
                    }
                )
            }
        }
    }

    // MARK: - 工作受理

    /// 受理一件后台工作（spawn_thinking 语义：立即返回，不等待执行）。
    /// 返回受理后的工作；目标为空 / 重复 / 队列满返回 nil。
    @discardableResult
    func submitWork(
        objective: String,
        brain: AgentBrain = AgentBrainSettings.selected,
        owner: String = AgentGatewayOwner.personal
    ) -> AgentGatewayWork? {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onError?(.emptyObjective)
            return nil
        }
        let resolvedBrain = AgentBrainRouter.resolvedBrain(trimmed, selection: brain)
        guard resolvedBrain.isConcreteBackend else {
            // 对齐上游 frontend-only：无后台时不创建一个注定失败的任务。
            onError?(.backendUnavailable)
            return nil
        }
        let work = AgentGatewayWork(owner: owner, objective: trimmed)
        guard queue.accept(work) else {
            onError?(.queueFull)
            return nil
        }
        workBrains[work.id] = resolvedBrain
        syncPublishedWorks()
        if let accepted = queue.work(id: work.id) {
            onWorkEvent?(accepted)
        }
        Task { @MainActor [weak self] in
            self?.pump(brain: resolvedBrain)
        }
        return queue.work(id: work.id)
    }

    /// 取消工作：排队直接取消；执行中取消后端并标记取消
    func cancel(workId: String, brain: AgentBrain? = nil) {
        if let work = queue.work(id: workId), work.status == .running {
            cancelRequested.insert(workId)
            let resolvedBrain = brain ?? workBrains[workId] ?? AgentBrainSettings.selected
            backendCanceller(resolvedBrain)
        }
        if queue.cancel(id: workId) != nil {
            syncPublishedWorks()
        }
    }

    /// 取消某 owner 的全部排队工作
    func cancelAllQueued(owner: String = AgentGatewayOwner.personal) {
        if queue.cancelAllQueued(for: owner) > 0 {
            syncPublishedWorks()
        }
    }

    /// 清理早于 cutoff 的终态历史
    func purgeHistory(before cutoff: Date) {
        queue.purgeFinished(before: cutoff)
        syncPublishedWorks()
    }

    /// 会话结束：取消全部工作并清空状态
    func reset(brain: AgentBrain? = nil) {
        let active = queue.activeWorks
        for work in active where work.status == .running {
            let resolvedBrain = brain ?? AgentBrainSettings.selected
            backendCanceller(resolvedBrain)
        }
        for task in runTasks.values { task.cancel() }
        runTasks.removeAll()
        workBrains.removeAll()
        cancelRequested.removeAll()
        queue.reset()
        window.reset()
        pendingAnnouncements.removeAll()
        syncPublishedWorks()
        isProcessing = false
    }

    // MARK: - 单轮协调（Siri / 快捷指令问 JARVIS 路径）

    /// 单轮协调执行：不经队列，协调语义 + 重试后返回最终决策。
    func runSingleTurn(
        _ text: String,
        brain: AgentBrain,
        context: AgentGatewayRunContext = AgentGatewayRunContext(),
        completion: @escaping (Result<AgentGatewayDecision, AgentGatewayError>) -> Void
    ) {
        let resolvedBrain = AgentBrainRouter.resolvedBrain(text, selection: brain)
        guard resolvedBrain.isConcreteBackend else {
            completion(.failure(.backendUnavailable))
            return
        }
        let runId = UUID().uuidString
        let prompt = AgentGatewayCoordinatorPromptBuilder.build(
            originalRequest: text,
            objective: text,
            context: context,
            coordinationRunId: runId
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.executeCoordinated(
                prompt: prompt,
                runId: runId,
                brain: resolvedBrain
            )
            completion(result)
        }
    }

    // MARK: - 公告窗口

    /// 语音会话状态变化后调用：窗口解除阻塞时投递待发公告
    func windowDidChange() {
        guard !window.isBlocked(), !pendingAnnouncements.isEmpty else { return }
        let announcements = pendingAnnouncements
        pendingAnnouncements.removeAll()
        for announcement in announcements {
            onAnnouncement?(announcement)
        }
    }

    // MARK: - 执行泵

    private func pump(brain: AgentBrain) {
        tryBeginNextWork(brain: brain)
    }

    private func tryBeginNextWork(brain: AgentBrain) {
        // 找出第一个 owner 空闲的排队工作
        let runnableOwners = Set(queue.queued.map(\.owner)).filter { !queue.isOwnerRunning($0) }
        guard let owner = runnableOwners.sorted().first,
              let work = queue.beginNext(for: owner) else {
            isProcessing = !queue.running.isEmpty
            return
        }
        let workBrain = workBrains[work.id] ?? brain
        syncPublishedWorks()
        onWorkEvent?(work)
        startWorkTask(work, brain: workBrain)
    }

    private func startWorkTask(_ work: AgentGatewayWork, brain: AgentBrain) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeWork(work, brain: brain)
            self.runTasks.removeValue(forKey: work.id)
            self.tryBeginNextWork(brain: brain)
        }
        runTasks[work.id] = task
        isProcessing = true
    }

    private func executeWork(_ work: AgentGatewayWork, brain: AgentBrain) async {
        let runId = work.id
        let context = contextProvider(work)
        let prompt = AgentGatewayCoordinatorPromptBuilder.build(
            originalRequest: context.originalRequest.isEmpty ? work.objective : context.originalRequest,
            objective: work.objective,
            context: context,
            coordinationRunId: runId
        )
        let result = await self.executeCoordinated(prompt: prompt, runId: runId, brain: brain)
        switch result {
        case .success(let decision):
            if cancelRequested.contains(work.id) { return }
            finishWork(
                id: work.id,
                status: .completed,
                presentation: decision.presentation
            )
        case .failure(let error):
            if cancelRequested.contains(work.id) { return }
            if case .backendFailed(let reason) = error,
               reason == AgentGatewayError.timeout.errorDescription {
                let timeout = AgentGatewayError.timeout
                finishWork(
                    id: work.id,
                    status: .failed,
                    errorMessage: timeout.errorDescription ?? "agent.gateway.error.unknown".localized
                )
                onError?(timeout)
                return
            }
            let message = error.errorDescription ?? "agent.gateway.error.unknown".localized
            finishWork(id: work.id, status: .failed, errorMessage: message)
            onError?(error)
        }
    }

    private func executeCoordinated(
        prompt: String,
        runId: String,
        brain: AgentBrain
    ) async -> Result<AgentGatewayDecision, AgentGatewayError> {
        var current = await send(prompt, brain: brain)
        if current.failed {
            if current.errorMessage == AgentGatewayError.timeout.errorDescription {
                return .failure(.backendFailed(AgentGatewayError.timeout.errorDescription ?? ""))
            }
            return .failure(.backendFailed(current.errorMessage ?? "agent.gateway.error.unknown".localized))
        }
        guard !current.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.backendFailed("agent.gateway.error.backend.empty".localized))
        }
        for _ in 0..<AgentGatewayCoordinatorSemantics.maxRetryAttempts {
            let state = AgentGatewayCoordinatorParser.responseState(current.content)
            if state.isEmpty || state == AgentGatewayDecision.State.completed.rawValue {
                break
            }
            let retry = AgentGatewayCoordinatorPromptBuilder.retryPrompt(
                coordinationRunId: runId,
                state: state
            )
            current = await send(retry, brain: brain)
            if current.failed {
                return .failure(.backendFailed(current.errorMessage ?? "agent.gateway.error.unknown".localized))
            }
        }
        let finalState = AgentGatewayCoordinatorParser.responseState(current.content)
        if !finalState.isEmpty, finalState != AgentGatewayDecision.State.completed.rawValue {
            return .failure(.coordinatorDidNotFinish(state: finalState))
        }
        return .success(AgentGatewayCoordinatorParser.decision(current.content, expectedWorkId: runId))
    }

    private func send(_ prompt: String, brain: AgentBrain) async -> AgentGatewayRunResult {
        await withCheckedContinuation { continuation in
            var settled = false
            let timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(1, self.workTimeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.backendCanceller(brain)
                guard !settled else { return }
                settled = true
                continuation.resume(returning: AgentGatewayRunResult(
                    content: "",
                    failed: true,
                    errorMessage: AgentGatewayError.timeout.errorDescription
                ))
            }
            executor.run(prompt, brain) { result in
                timeoutTask.cancel()
                guard !settled else { return }
                settled = true
                continuation.resume(returning: result)
            }
        }
    }

    private func finishWork(
        id: String,
        status: AgentGatewayWorkStatus,
        presentation: AgentGatewayPresentation? = nil,
        errorMessage: String? = nil
    ) {
        cancelRequested.remove(id)
        workBrains.removeValue(forKey: id)
        guard let finished = queue.finish(
            id: id,
            status: status,
            presentation: presentation,
            errorMessage: errorMessage
        ) else { return }
        syncPublishedWorks()
        onWorkEvent?(finished)
        enqueueAnnouncement(for: finished)
        windowDidChange()
    }

    private func enqueueAnnouncement(for work: AgentGatewayWork) {
        switch work.status {
        case .completed:
            let speech: String
            if let value = work.presentation?.speech,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speech = value
            } else {
                speech = String(
                    format: "agent.gateway.announce.completed".localized,
                    work.objective
                )
            }
            pendingAnnouncements.append(AgentGatewayAnnouncement(
                kind: .completed(workId: work.id, objective: work.objective),
                speech: speech
            ))
        case .failed:
            pendingAnnouncements.append(AgentGatewayAnnouncement(
                kind: .failed(
                    workId: work.id,
                    objective: work.objective,
                    reason: work.errorMessage ?? "agent.gateway.error.unknown".localized
                ),
                speech: String(
                    format: "agent.gateway.announce.failed".localized,
                    work.objective
                )
            ))
        case .queued, .running, .cancelled:
            break
        }
    }

    private func syncPublishedWorks() {
        works = queue.allWorks
    }
}
