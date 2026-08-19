/*
 * Qwen Voice Session
 * 把 QwenGatewayService 与音频采集/播放管线组装成完整实时语音会话：
 *   输入: iPhone 麦克风 → 16kHz PCM16 → 网关 audio.append
 *   输出: 网关 audio.delta → 24kHz PCM16 → RealtimeAudioPlaybackPipeline
 * 同时消费 transcript / task 事件，供 UI 展示任务进度。
 */

import AVFoundation
import Foundation
import os.lock
import UIKit

/// 空闲超时检测（纯逻辑，便于测试）
struct QwenIdleTimeoutMonitor {
    let timeout: TimeInterval
    private(set) var lastActivityDate = Date()

    mutating func recordActivity(at date: Date = Date()) {
        lastActivityDate = date
    }

    func hasTimedOut(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(lastActivityDate) >= timeout
    }
}

/// 后台 Agent 任务进度条目（qwen 网关 task.* / timeline.inline 事件）
struct QwenTaskFeedItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case delegated
        case progress
        case completed
        case failed
        case cancelled
        case permissionRequested
        case result
    }

    let id = UUID()
    let kind: Kind
    let taskId: String?
    let text: String
    let date = Date()

    init(kind: Kind, taskId: String?, text: String) {
        self.kind = kind
        self.taskId = taskId
        self.text = text
    }
}

/// 后台 Agent 任务的结构化状态（驱动任务列表 UI）
struct QwenAgentTask: Identifiable, Equatable {
    enum Status: Equatable {
        /// 已委派/排队，Agent 尚未开始执行
        case waiting
        /// 正在执行
        case running
        case completed
        case failed
        case cancelled
    }

    let taskId: String
    var title: String
    var status: Status
    /// 最近一次结果摘要（timeline.inline / 完成事件）
    var resultText: String?
    /// 触发该任务的原始用户文本（重试时原样重放给网关；无口述来源时为 nil）
    var sourceText: String? = nil
    let createdAt: Date
    var updatedAt: Date

    var id: String { taskId }

    /// 是否仍处于活动（等待中或进行中）
    var isActive: Bool {
        status == .waiting || status == .running
    }

    /// 状态显示文案（跟随 App 语言）
    var statusLabel: String {
        switch status {
        case .waiting: return "agent.task.status.waiting".localized
        case .running: return "agent.task.status.running".localized
        case .completed: return "agent.task.status.completed".localized
        case .failed: return "agent.task.status.failed".localized
        case .cancelled: return "agent.task.status.cancelled".localized
        }
    }
}

/// 任务语音指令（大脑模式本地拦截：不转发给大脑，直接作用于活动任务）
enum AgentTaskCommand: Equatable {
    /// 询问后台任务进度（全部活动任务）
    case queryProgress
    /// 询问第 N 个活动任务进度（0-based）
    case queryProgressTask(Int)
    /// 取消最近的活动任务
    case cancelLatest
    /// 取消第 N 个活动任务（0-based）
    case cancelTask(Int)
    /// 重试最近失败的任务
    case retryLatest
    /// 重试第 N 个失败任务（0-based）
    case retryTask(Int)

    /// 是否取消类指令（镜片横幅文案区分）
    var isCancellation: Bool {
        switch self {
        case .cancelLatest, .cancelTask: return true
        default: return false
        }
    }

    /// 是否重试类指令（镜片横幅文案区分）
    var isRetry: Bool {
        switch self {
        case .retryLatest, .retryTask: return true
        default: return false
        }
    }
}

/// 把用户转写解析为任务指令的纯逻辑（可测试）。
/// 仅当存在活动任务时拦截；关键词保守匹配，避免误吞普通对话。
enum AgentTaskCommandParser {
    /// 进度询问关键词
    static let queryKeywords = [
        "进度", "进展", "到哪一步", "完成了吗", "好了没有", "任务好了吗",
        "跑完了吗", "还有多久", "多久能好", "什么时候能好", "进行到哪",
        "progress", "how long", "done yet", "finished yet", "status",
    ]

    /// 取消任务关键词
    static let cancelKeywords = [
        "取消任务", "取消这个任务", "取消那个任务", "任务取消",
        "别做了", "不做了", "别再做了", "停掉",
        "cancel the task", "cancel it", "stop the task", "stop it",
    ]

    /// 重试失败任务关键词（保守匹配，避免误吞普通对话）
    static let retryKeywords = [
        "重试", "再试一次", "再试一遍", "重新执行", "重新做", "重新做一遍",
        "再跑一次", "再来一次", "再来一遍", "重做",
        "retry", "try again", "do it again", "redo", "run it again",
    ]

    /// 中文数字映射（任务一 ~ 任务十）
    static let chineseNumerals: [String: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// 解析一条用户转写；无活动任务且无失败任务，或未命中关键词时返回 nil。
    /// - Parameters:
    ///   - activeTaskCount: 活动任务数（进度 / 取消指令的拦截前提）
    ///   - failedTaskCount: 失败任务数（重试指令的拦截前提；序号按失败任务列表计）
    static func parse(
        _ text: String,
        activeTaskCount: Int,
        failedTaskCount: Int = 0
    ) -> AgentTaskCommand? {
        guard activeTaskCount > 0 || failedTaskCount > 0 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let index = taskIndex(from: trimmed)
        if let index {
            // 序号场景允许独立触发词：「取消第一个任务」中「取消」与「任务」不连续
            if cancelKeywords.contains(where: { lowered.contains($0) })
                || lowered.contains("取消") || lowered.contains("cancel") {
                return .cancelTask(index)
            }
            if queryKeywords.contains(where: { lowered.contains($0) }) {
                return .queryProgressTask(index)
            }
            if failedTaskCount > 0,
               retryKeywords.contains(where: { lowered.contains($0) }) {
                return .retryTask(index)
            }
            return nil
        }
        if cancelKeywords.contains(where: { lowered.contains($0) }) {
            return .cancelLatest
        }
        if queryKeywords.contains(where: { lowered.contains($0) }) {
            return .queryProgress
        }
        if failedTaskCount > 0,
           retryKeywords.contains(where: { lowered.contains($0) }) {
            return .retryLatest
        }
        return nil
    }

    /// 从文本提取任务序号（0-based），支持「任务二 / 任务2 / 第二个任务 / 第2个」；
    /// 无序号返回 nil。仅返回数字本身，意图判断仍由关键词负责。
    static func taskIndex(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = "(?:任务|第)([0-9]+|[一二三四五六七八九十]+)(?:个任务|个)?"
        guard let range = trimmed.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(trimmed[range])
        let digits = matched.filter { $0.isNumber || "一二三四五六七八九十".contains($0) }
        guard !digits.isEmpty, let value = numeralValue(digits), value >= 1 else { return nil }
        return value - 1
    }

    /// 数字串转数值：阿拉伯数字直接解析；中文数字支持 一~十 与 十一~十九
    static func numeralValue(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("十") {
            let rest = String(s.dropFirst())
            if rest.isEmpty { return 10 }
            guard let tail = numeralValue(rest), tail >= 1, tail <= 9 else { return nil }
            return 10 + tail
        }
        guard s.count == 1, let v = chineseNumerals[s] else { return nil }
        return v
    }
}

/// 任务语音指令 → 本地回复文本的纯逻辑（语音页 / 聊天页共用）。
/// 副作用（向网关发送取消指令、记录系统提示）发生在 session 方法内部；
/// 返回 nil 表示无可处理对象（如无任务可取消），调用方应放弃拦截继续转发。
@MainActor
enum AgentTaskCommandResponseBuilder {
    static func reply(
        for command: AgentTaskCommand,
        session: QwenVoiceSession
    ) -> String? {
        switch command {
        case .queryProgress:
            return session.taskProgressSummary
        case .queryProgressTask(let index):
            if let summary = session.taskProgressSummary(for: index) {
                return summary
            }
            // 序号越界（如只有 2 个任务却说「任务五」）：提示当前数量而不是转发大脑
            return String(
                format: "agent.task.command.index.range".localized,
                index + 1,
                session.activeTasks.count
            )
        case .cancelLatest:
            guard let name = session.requestTaskCancellation() else { return nil }
            return "agent.task.command.cancel.reply".localized(name)
        case .cancelTask(let index):
            if let name = session.requestTaskCancellation(index: index) {
                return "agent.task.command.cancel.reply".localized(name)
            }
            return String(
                format: "agent.task.command.index.range".localized,
                index + 1,
                session.activeTasks.count
            )
        case .retryLatest:
            guard let name = session.requestTaskRetry() else { return nil }
            return "agent.task.command.retry.reply".localized(name)
        case .retryTask(let index):
            if let name = session.requestTaskRetry(index: index) {
                return "agent.task.command.retry.reply".localized(name)
            }
            return String(
                format: "agent.task.command.index.range.failed".localized,
                index + 1,
                session.failedTasks.count
            )
        }
    }
}

/// 语音本地指令（大脑模式拦截，不转发给大脑）
enum AgentLocalCommand: Equatable {
    /// 重听最近一次回复/任务结果
    case repeatLastReply
    /// 开始新会话（当前会话先落盘到记录）
    case newChat
    /// 结束当前会话（持续在场模式下的显式退出；仅在场模式拦截）
    case endSession
    /// 今日安排总览（下一场日程 + 提醒 + 任务，本地组装播报）
    case todayOverview
    /// 明日安排总览（明天日程，本地组装播报）
    case tomorrowOverview
}

/// 把用户转写解析为本地指令的纯逻辑（可测试）。
/// 关键词保守匹配，避免误吞普通对话。
enum AgentLocalCommandParser {
    static let repeatKeywords = [
        "再说一遍", "再说一次", "重复一下", "重听", "没听清",
        "repeat", "say that again",
    ]

    static let newChatKeywords = [
        "新会话", "清空对话", "清空聊天", "换个话题",
        "new chat", "start over",
    ]

    /// 显式结束会话的关键词（保守匹配，避免吞掉正常对话）
    static let endSessionKeywords = [
        "结束对话", "结束会话", "退出会话", "先不聊了",
        "end the conversation", "end this conversation",
        "stop the conversation", "exit the session",
    ]

    /// 今日安排口令（保守匹配，避免吞掉普通对话）
    static let todayOverviewKeywords = [
        "今天有什么安排", "今天什么安排", "今天安排", "今日安排",
        "今天要做什么", "今天做什么", "今天有什么计划", "今日计划",
        "汇报今日安排", "汇报今天安排",
        "what's on my schedule", "what's my day", "today's schedule",
        "today's plan", "what am i doing today",
    ]

    /// 明日安排口令（保守匹配，避免吞掉普通对话）
    static let tomorrowOverviewKeywords = [
        "明天有什么安排", "明天什么安排", "明天安排", "明日安排",
        "明天要做什么", "明天做什么", "明天有什么计划", "明日计划",
        "汇报明天安排", "汇报明日安排",
        "what's on my schedule tomorrow", "tomorrow's schedule",
        "tomorrow's plan", "what am i doing tomorrow",
    ]

    static func parse(_ text: String) -> AgentLocalCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if repeatKeywords.contains(where: { lowered.contains($0) }) {
            return .repeatLastReply
        }
        if newChatKeywords.contains(where: { lowered.contains($0) }) {
            return .newChat
        }
        if endSessionKeywords.contains(where: { lowered.contains($0) }) {
            return .endSession
        }
        if tomorrowOverviewKeywords.contains(where: { lowered.contains($0) }) {
            return .tomorrowOverview
        }
        if todayOverviewKeywords.contains(where: { lowered.contains($0) }) {
            return .todayOverview
        }
        return nil
    }
}

/// 任务卡片相对时间的纯格式化（可测，跟随 App 语言切换）
enum AgentTaskTimeFormatter {
    static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "agent.task.time.justnow".localized }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "agent.task.time.minutes".localized(minutes) }
        let hours = Int(elapsed / 3600)
        if hours < 24 { return "agent.task.time.hours".localized(hours) }
        let days = Int(elapsed / 86400)
        return "agent.task.time.days".localized(days)
    }
}

/// 后台任务完成播报（完成/失败/取消时触发，UI 展示横幅 + 触觉反馈）
struct QwenTaskCompletionNotice: Equatable {
    let kind: QwenTaskFeedItem.Kind
    let taskId: String
    let text: String
}

/// 任务受理回执（task.delegated / task.scheduled 到达时触发，UI 立即反馈「收到」）
struct QwenTaskAcknowledgmentNotice: Equatable {
    let taskId: String
    let title: String
}

/// 长任务自动进度播报（对齐 qwen-audio-agent v1.8.2 的「长时间任务自动汇报进度」）：
/// 任务持续运行超过阈值后，主动播报一次进度（每任务一次），不抢话、静默模式可抑制。
struct QwenTaskProgressNotice: Equatable {
    let taskId: String
    let text: String
}

/// 长任务进度自动汇报的纯决策（可测）：活跃任务运行超时且未汇报过 → 轮到汇报。
enum AgentTaskProgressCheckIn {
    /// 触发阈值：任务创建后持续多久未完成才主动汇报（秒）
    static let defaultThreshold: TimeInterval = 120
    /// 定时器轮询间隔（秒）
    static let defaultInterval: TimeInterval = 30

    static func dueCheckIns(
        tasks: [(id: String, createdAt: Date, isActive: Bool)],
        threshold: TimeInterval = defaultThreshold,
        checkedIn: Set<String>,
        now: Date = Date()
    ) -> [String] {
        tasks
            .filter { task in
                task.isActive &&
                    !checkedIn.contains(task.id) &&
                    now.timeIntervalSince(task.createdAt) >= threshold
            }
            .map { $0.id }
    }

    /// 播报文案：「还在整理「周报」，已进行约 N 分钟，有进展我会告诉你。」
    static func announcementText(
        title: String?,
        elapsed: TimeInterval
    ) -> String {
        let minutes = max(1, Int(elapsed / 60))
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return String(format: "agent.task.checkin.generic".localized, minutes)
        }
        return String(format: "agent.task.checkin".localized, name, minutes)
    }
}

/// 播报安全窗口：正在说话 / 输入中 / 已有 TTS 播报时不抢话，等用户停顿处再播。
enum AgentAnnouncementGate {
    static func shouldAnnounce(
        isSpeaking: Bool,
        isInputActive: Bool,
        ttsSpeaking: Bool
    ) -> Bool {
        !isSpeaking && !isInputActive && !ttsSpeaking
    }
}

/// 任务终态自然回归话术（对齐 qwen-audio-agent 的 "It's ready."）：有详细结果用结果原文，
/// 否则用短句 + 任务名（如「整理报告搞定了。」），避免只播报干巴巴的任务名。
enum AgentCompletionAnnouncement {
    static func text(
        kind: QwenTaskFeedItem.Kind,
        title: String,
        result: String? = nil
    ) -> String {
        if let result, !result.isEmpty {
            return result
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            switch kind {
            case .failed: return "agent.task.announce.failed.generic".localized
            case .cancelled: return "agent.task.announce.cancelled.generic".localized
            default: return "agent.task.announce.completed.generic".localized
            }
        }
        switch kind {
        case .failed: return String(format: "agent.task.announce.failed".localized, name)
        case .cancelled: return String(format: "agent.task.announce.cancelled".localized, name)
        default: return String(format: "agent.task.announce.completed".localized, name)
        }
    }
}

/// 本地能量检测的语音打断（barge-in）检测器。
/// 仅在 Agent 播报期间启用：检测到持续超过阈值的语音能量时触发打断，
/// 让"用户一开口就立刻停止播报"的反馈没有网关往返延迟。
struct BargeInDetector {
    /// 归一化 RMS 能量阈值（0~1）
    let energyThreshold: Float
    /// 需要持续超过阈值的最短时长
    let minimumDuration: TimeInterval
    /// 高置信近讲语音阈值；连续满足时走低延迟快速路径。
    let fastEnergyThreshold: Float
    /// 快速路径仍要求连续能量，避免单个短爆音触发。
    let fastMinimumDuration: TimeInterval
    /// 音频采样率（用于把样本数换算为时长）
    let sampleRate: Double

    private(set) var isTriggered = false
    private var highEnergyDuration: TimeInterval = 0
    private var fastHighEnergyDuration: TimeInterval = 0

    init(
        energyThreshold: Float = 0.02,
        minimumDuration: TimeInterval = 0.12,
        fastEnergyThreshold: Float = 0.12,
        fastMinimumDuration: TimeInterval = 0.04,
        sampleRate: Double = 16_000
    ) {
        self.energyThreshold = energyThreshold
        self.minimumDuration = minimumDuration
        self.fastEnergyThreshold = max(energyThreshold, fastEnergyThreshold)
        self.fastMinimumDuration = fastMinimumDuration
        self.sampleRate = sampleRate
    }

    /// 消费一个音频缓冲的 RMS 能量；触发后返回 true（之后幂等）。
    mutating func consume(rms: Float, sampleCount: Int) -> Bool {
        consume(
            rms: rms,
            duration: Double(sampleCount) / sampleRate
        )
    }

    mutating func consume(rms: Float, duration: TimeInterval) -> Bool {
        guard !isTriggered else { return false }
        guard duration.isFinite, duration > 0 else { return false }
        let bufferDuration = duration
        if rms >= energyThreshold {
            highEnergyDuration += bufferDuration
        } else {
            // 低于阈值的短暂间隙不整体清零（避免断句误判），只做半速衰减
            highEnergyDuration = max(0, highEnergyDuration - bufferDuration * 0.5)
        }
        if rms >= fastEnergyThreshold {
            fastHighEnergyDuration += bufferDuration
        } else {
            fastHighEnergyDuration = 0
        }
        let normalPathTriggered = rms >= energyThreshold
            && highEnergyDuration >= minimumDuration
        let fastPathTriggered = rms >= fastEnergyThreshold
            && fastHighEnergyDuration >= fastMinimumDuration
        if normalPathTriggered || fastPathTriggered {
            isTriggered = true
            return true
        }
        return false
    }

    /// 新一轮播报开始前重置（每次响应只允许打断一次）
    mutating func reset() {
        isTriggered = false
        highEnergyDuration = 0
        fastHighEnergyDuration = 0
    }
}

/// Keeps full-duplex barge-in detection on the capture path instead of behind
/// PCM encoding or WebSocket backpressure. Tokens prevent a delayed trigger
/// from cancelling a newer playback response on the MainActor.
final class QwenCaptureBargeInGate: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var detector: BargeInDetector
    private var nextToken: UInt64 = 0
    private var activeToken: UInt64?

    init(detector: BargeInDetector = BargeInDetector()) {
        self.detector = detector
    }

    func arm() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        nextToken &+= 1
        detector.reset()
        activeToken = nextToken
        return nextToken
    }

    func disarm() {
        os_unfair_lock_lock(&lock)
        activeToken = nil
        detector.reset()
        os_unfair_lock_unlock(&lock)
    }

    func consume(_ stats: RealtimeCapturedAudioFrameStats) -> UInt64? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let activeToken,
              detector.consume(rms: stats.rms, duration: stats.duration) else {
            return nil
        }
        self.activeToken = nil
        return activeToken
    }
}

enum QwenAudioRouteRecoveryPolicy {
    static func reason(from notification: Notification) -> AVAudioSession.RouteChangeReason? {
        guard let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        else { return nil }
        return AVAudioSession.RouteChangeReason(rawValue: rawValue)
    }

    static func requiresRecovery(for reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .newDeviceAvailable,
             .oldDeviceUnavailable,
             .wakeFromSleep,
             .noSuitableRouteForCategory,
             .routeConfigurationChange:
            return true
        case .unknown, .categoryChange, .override:
            return false
        @unknown default:
            return true
        }
    }
}

@MainActor
final class QwenAudioRouteRecoveryCoalescer {
    typealias Action = @MainActor () -> Void

    private let delayNanoseconds: UInt64
    private var generation = 0
    private var task: Task<Void, Never>?

    init(delayNanoseconds: UInt64 = 80_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func schedule(onFirst: Action, onSettled: @escaping Action) {
        if task == nil {
            onFirst()
        }
        task?.cancel()
        generation &+= 1
        let scheduledGeneration = generation
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.delayNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == scheduledGeneration else { return }
            self.task = nil
            onSettled()
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}

struct QwenAudioCaptureRecoveryPolicy: Equatable {
    static let defaultRetryDelays: [TimeInterval] = [0.1, 0.25, 0.5]

    let retryDelays: [TimeInterval]

    init(retryDelays: [TimeInterval] = QwenAudioCaptureRecoveryPolicy.defaultRetryDelays) {
        self.retryDelays = retryDelays.map { $0.isFinite ? max(0, $0) : 0 }
    }

    func delay(forRetry retry: Int) -> TimeInterval? {
        guard retry >= 1, retry <= retryDelays.count else { return nil }
        return retryDelays[retry - 1]
    }
}

@MainActor
final class QwenAudioCaptureRecoveryScheduler {
    typealias Action = @MainActor () -> Void

    private let policy: QwenAudioCaptureRecoveryPolicy
    private var generation = 0
    private var task: Task<Void, Never>?
    private var retryCount = 0

    init(policy: QwenAudioCaptureRecoveryPolicy = QwenAudioCaptureRecoveryPolicy()) {
        self.policy = policy
    }

    @discardableResult
    func schedule(_ action: @escaping Action) -> Bool {
        let nextRetry = retryCount + 1
        guard let delay = policy.delay(forRetry: nextRetry) else { return false }

        task?.cancel()
        retryCount = nextRetry
        generation &+= 1
        let scheduledGeneration = generation
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == scheduledGeneration else { return }
            self.task = nil
            action()
        }
        return true
    }

    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        retryCount = 0
    }
}

/// Bounded tombstones for responses cancelled locally. WebSocket delivery can
/// race an interrupt, so late audio and completion events must not revive or
/// terminate a different response.
struct QwenCancelledResponseRegistry {
    private let capacity: Int
    private var identifiers = Set<String>()
    private var insertionOrder: [String] = []

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    mutating func insert(_ identifier: String?) {
        guard let identifier = Self.normalized(identifier),
              identifiers.insert(identifier).inserted else { return }
        insertionOrder.append(identifier)
        while insertionOrder.count > capacity {
            identifiers.remove(insertionOrder.removeFirst())
        }
    }

    func contains(_ identifier: String?) -> Bool {
        guard let identifier = Self.normalized(identifier) else { return false }
        return identifiers.contains(identifier)
    }

    mutating func removeAll() {
        identifiers.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }

    static func normalized(_ identifier: String?) -> String? {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// Keeps uncorrelated provider audio behind an explicit response lifecycle.
/// Qwen's gateway normally supplies response IDs, but the embedded adapter and
/// older compatible gateways can briefly omit them around cancellation.
struct QwenResponseOutputGate: Equatable {
    private(set) var awaitsResponseStart = false
    private var requiresResponseStart = false

    mutating func reset() {
        awaitsResponseStart = false
        requiresResponseStart = false
    }

    mutating func markCancelled() {
        awaitsResponseStart = true
        requiresResponseStart = false
    }

    mutating func markTransportLost() {
        awaitsResponseStart = true
        requiresResponseStart = true
    }

    mutating func markResponseStarted() {
        awaitsResponseStart = false
        requiresResponseStart = false
    }

    mutating func acceptAudio(hasResponseID: Bool) -> Bool {
        guard !requiresResponseStart else { return false }
        guard hasResponseID || !awaitsResponseStart else { return false }
        awaitsResponseStart = false
        return true
    }

    func acceptsTerminal(hasResponseID: Bool) -> Bool {
        !requiresResponseStart && (hasResponseID || !awaitsResponseStart)
    }
}

/// 待用户审批的权限请求（task.permission.requested 事件）
struct QwenPermissionRequest: Identifiable, Equatable {
    let taskId: String?
    let permission: QwenPermission
    /// 审批请求已提交，等待网关返回
    var isSubmitting = false

    var id: String { permission.id }
}

/// 语音会话转写条目（用于回填聊天记录）
struct QwenTranscriptItem: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        /// 过程提示（如"已发送视野"），仅语音页显示，不回填聊天记录
        case system
    }

    enum Kind: Equatable {
        /// 普通语音转写
        case normal
        /// 视野注入上下文（回填聊天记录时标记 [📷 场景]）
        case vision
    }

    let id = UUID()
    let role: Role
    let text: String
    var kind: Kind = .normal
    let date = Date()
}

/// 导入聊天记录的单条消息（vision 条目带场景标记）
struct AgentImportedMessage: Equatable {
    let role: String
    let text: String
    let isVisionContext: Bool
}

/// 语音会话回填聊天记录的纯逻辑（转写 + 任务结果 → 消息列表）
struct AgentTranscriptImport {
    let transcriptLog: [QwenTranscriptItem]
    let taskFeed: [QwenTaskFeedItem]

    var resultItems: [QwenTaskFeedItem] {
        taskFeed.filter {
            $0.kind == .completed || $0.kind == .failed || $0.kind == .result
        }
    }

    var hasContent: Bool {
        !transcriptLog.isEmpty || !resultItems.isEmpty
    }

    func makeMessages() -> [AgentImportedMessage] {
        var messages: [AgentImportedMessage] = []
        for item in transcriptLog {
            guard item.role != .system else { continue }
            let isVision = item.kind == .vision
            let text = isVision
                ? "agent.vision.scene.tag".localized + item.text
                : item.text
            messages.append(AgentImportedMessage(
                role: item.role == .user ? "user" : "assistant",
                text: text,
                isVisionContext: isVision
            ))
        }
        for item in resultItems {
            messages.append(AgentImportedMessage(
                role: "assistant",
                text: item.text,
                isVisionContext: false
            ))
        }
        return messages
    }
}

@MainActor
final class QwenVoiceSession: ObservableObject {
    static let shared = QwenVoiceSession()
    static let defaultIdleTimeout: TimeInterval = 120
    static let audioRouteSettleNanoseconds: UInt64 = 750_000_000
    static let audioRouteConfigurationSuppressionInterval: TimeInterval = 1.25

    @Published private(set) var isActive = false {
        didSet { syncVoiceLiveActivity() }
    }
    @Published private(set) var isInputActive = false {
        didSet { syncVoiceLiveActivity() }
    }
    /// Provider turn phase. Capture readiness is intentionally separate from
    /// speech activity so a running microphone cannot look like an endless turn.
    @Published private(set) var providerVoiceState = "idle"
    @Published private(set) var isSpeaking = false {
        didSet { syncVoiceLiveActivity() }
    }
    /// Normalized microphone energy used by the Metal orb. It is visual-only and never persisted.
    @Published private(set) var inputLevel: Float = 0
    /// Normalized post-mix playback energy. This follows audio actually reaching the speaker.
    @Published private(set) var outputLevel: Float = 0
    var orbAudioLevel: Float {
        isSpeaking ? outputLevel : inputLevel
    }
    @Published private(set) var connectionState: QwenGatewayConnectionState = .disconnected {
        didSet { syncVoiceLiveActivity() }
    }
    /// 语音前端是否处于休眠（网关 client.state: sleeping / 手动休眠），休眠时等待唤醒词
    @Published private(set) var isSleeping = false {
        didSet { syncVoiceLiveActivity() }
    }
    /// 正在自动重连时的第几次尝试（nil = 未在重连）
    @Published private(set) var reconnectAttempt: Int?
    @Published private(set) var reconnectMaxAttempts = 5
    @Published private(set) var lastUserText = ""
    @Published private(set) var lastAssistantText = ""
    /// 最近一次任务结果文案（眼镜菜单 Repeat 可重听，优先取 timeline.inline 详细结果）
    @Published private(set) var lastTaskResultText = ""
    /// 最近一次由语音页拍摄的画面帧（仅内存持有，供端侧工具 vision.ocr / vision.scene 使用；
    /// 会话显式结束时由视图清空，遵守视觉数据生命周期）
    var latestVisionFrame: UIImage?
    /// 最近一次任务结果到达时间（用于与大脑回复比较新旧）
    private(set) var lastTaskResultAt: Date?
    /// 任务结果追问上下文（大脑转发模式）：最新任务的详细结果；
    /// 用户说「展开第三条」时随下一条转发消息前置给大脑，新结果覆盖旧结果，reset 清空
    private(set) var resultFollowUpContext: String?
    /// 是否有可追问的任务结果（镜片菜单「Ask」动态出现的依据）
    var hasFollowUpContext: Bool {
        resultFollowUpContext != nil
    }
    /// 最近一次大脑/助手回复时间
    private(set) var lastAssistantReplyAt: Date?
    @Published private(set) var taskMessage: String? {
        didSet { syncLiveActivity() }
    }
    @Published private(set) var taskFeed: [QwenTaskFeedItem] = []
    @Published private(set) var agentTasks: [QwenAgentTask] = []
    @Published private(set) var completionNotice: QwenTaskCompletionNotice?
    /// 任务受理回执（同一任务只回执一次）
    @Published private(set) var acknowledgmentNotice: QwenTaskAcknowledgmentNotice?
    /// 长任务自动进度播报（每任务一次；UI 播报后调用 clearProgressCheckInNotice 清除）
    @Published private(set) var progressCheckInNotice: QwenTaskProgressNotice?
    /// 待用户确认的权限请求（nil = 无待办审批）
    @Published private(set) var pendingPermission: QwenPermissionRequest? {
        didSet { syncLiveActivity() }
    }
    @Published private(set) var permissionError: String?
    /// 审批请求超时未处理（UI 提示后由 clearPermissionTimeout 清除）
    @Published private(set) var permissionTimedOut = false
    /// 审批卡超时截止时间（UI 倒计时展示；无待处理审批时为 nil）
    @Published private(set) var permissionExpiresAt: Date? {
        didSet {
            guard pendingPermission != nil, permissionExpiresAt != nil else { return }
            syncLiveActivity()
        }
    }
    /// 正在执行的后台任务数（同一任务只计一次）
    @Published private(set) var runningTaskCount = 0 {
        didSet {
            syncLiveActivity()
            AgentWidgetSnapshotCenter.refresh()
        }
    }
    /// 本次会话的完整转写（start() 时清空，供上层回填聊天记录）
    @Published private(set) var transcriptLog: [QwenTranscriptItem] = []
    @Published private(set) var errorMessage: String?

    private let gateway: QwenGatewayService
    private let permissionResponder: QwenPermissionResponding
    private var audioEngine: AVAudioEngine?
    private var captureActivationTask: Task<Void, Never>?
    private(set) var captureGeneration = 0
    private let audioUploadPipeline: RealtimeAudioUploadPipeline
    private let audioPlaybackPipeline: any RealtimeAudioPlaybackControlling
    private let imageUploadPipeline = RealtimeImageUploadPipeline(
        label: "com.lunflux.hyper-meta-ai.qwen.image-upload",
        compressionQuality: 0.62
    )
    private var playbackGeneration = 0
    private var isInputMuted = false
    private var bargeInDetector = BargeInDetector()
    private let captureBargeInGate = QwenCaptureBargeInGate()
    private var captureBargeInToken: UInt64?
    private var externalSpeechWasActive = false
    private var lastInputLevelUpdateAt: TimeInterval = 0
    private var activeResponseId: String?
    private var hasSentPlaybackStartedReceipt = false
    private var cancelledResponseIDs = QwenCancelledResponseRegistry()
    private var responseOutputGate = QwenResponseOutputGate()
    private var realtimeConnectionStatus = QwenRealtimeConnectionStatus()
    private var runningTaskIds = Set<String>()
    private var noticedTaskIds = Set<String>()
    /// 已完成自动进度汇报的任务 ID（避免反复打扰；任务清空时重置）
    private var autoCheckedInTaskIds = Set<String>()
    /// 长任务进度轮询定时器（有活跃任务时运行）
    private var progressCheckInTimer: Timer?
    /// 已发过受理回执的任务 ID（task.delegated / task.scheduled 去重）
    private var acknowledgedTaskIds = Set<String>()
    /// 已记录处理结果的权限 ID（HTTP 响应与 WS resolved 事件去重）
    private var resolvedPermissionIds = Set<String>()
    /// 单次放行模式：本会话内已人工批准过的权限 ID（会话开始即清空）
    private var autoApprovedPermissionIDs = Set<String>()
    private var idleMonitor = QwenIdleTimeoutMonitor(timeout: defaultIdleTimeout)
    /// 休眠/唤醒状态机（纯逻辑，测试直接驱动）
    private(set) var wakeController = QwenWakeSessionController()
    /// 唤醒词监听当前阶段（驱动 UI：休眠提示 / 聆听波形）
    var wakeWordPhase: QwenWakeSessionController.Phase {
        wakeController.phase
    }
    /// 唤醒词监听器（测试注入 Mock；默认 Speech framework 实现）
    private var wakeWordMonitor: QwenWakeWordListening?
    private let wakeWordMonitorFactory: () -> QwenWakeWordListening
    private var idleWatchdogTask: Task<Void, Never>?
    private var permissionTimeoutTask: Task<Void, Never>?
    /// 审批超时覆盖值（测试注入用）；nil 时使用 AgentTimingSettings
    private let permissionTimeoutOverride: TimeInterval?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var audioSessionInactiveObserver: NSObjectProtocol?
    private var audioSessionResumptionObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var audioRouteChangeObserver: NSObjectProtocol?
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    private let audioRouteRecoveryCoalescer = QwenAudioRouteRecoveryCoalescer()
    private let audioCaptureRecoveryScheduler = QwenAudioCaptureRecoveryScheduler()
    private var audioRouteConfigurationSuppressedUntil: TimeInterval = 0
    private var isAudioSessionInterrupted = false
    /// 权限决策审计出口（默认写入 AgentAuditStore；测试可注入）
    var auditSink: (AgentAuditEntry) -> Void = { entry in
        AgentAuditStore.append(
            toolID: entry.toolID,
            action: entry.action,
            detail: entry.detail,
            date: entry.date
        )
    }

    /// 语音唤醒词开关（「你好千问」）：休眠时用 Speech framework 监听 iPhone 麦克风
    static var wakeWordEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "qwen_voice_wake_word_enabled") as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "qwen_voice_wake_word_enabled")
        }
    }

    static var idleAutoEndEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "qwen_voice_auto_end_enabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "qwen_voice_auto_end_enabled")
        }
    }

    /// 空闲自动结束是否生效：持续在场模式开启后不再自动结束会话，
    /// Agent 保持聆听，由长按或「结束对话」指令显式退出。
    static var shouldAutoEndIdle: Bool {
        idleAutoEndEnabled && !AgentPresenceSettings.presenceEnabled
    }

    /// 最近一次唤醒词监听转写（UI 展示聆听状态）
    @Published private(set) var wakeWordTranscript = ""
    /// 最近一次命中的唤醒词文本（UI 反馈）
    @Published private(set) var lastWakeWordText: String?
    /// 唤醒词监听启动失败原因（UI 提示）
    @Published private(set) var wakeWordMonitorError: String?

    init(
        gateway: QwenGatewayService = .shared,
        permissionResponder: QwenPermissionResponding? = nil,
        permissionTimeout: TimeInterval? = nil,
        wakeWordMonitorFactory: (() -> QwenWakeWordListening)? = nil,
        audioPlaybackPipeline: (any RealtimeAudioPlaybackControlling)? = nil
    ) {
        self.gateway = gateway
        self.permissionResponder = permissionResponder ?? gateway
        self.permissionTimeoutOverride = permissionTimeout
        self.wakeWordMonitorFactory = wakeWordMonitorFactory ?? { QwenSpeechWakeWordMonitor() }
        let audioProfile = RealtimeProviderAudioProfiles.qwen
        self.audioUploadPipeline = RealtimeAudioUploadPipeline(
            label: "com.lunflux.hyper-meta-ai.qwen.audio-upload",
            targetSampleRate: audioProfile.inputSampleRate,
            slotCount: 4,
            maximumFramesPerBuffer: 4_096,
            sendTimeout: audioProfile.uploadSendTimeout,
            maximumQueuedFrameAge: audioProfile.maximumQueuedInputAge
        )
        self.audioPlaybackPipeline = audioPlaybackPipeline ?? RealtimeAudioPlaybackPipeline(
            label: "com.lunflux.hyper-meta-ai.qwen.audio-playback",
            outputFormat: audioProfile.outputFormat,
            maximumJitterMilliseconds: audioProfile.maximumJitterMilliseconds,
            maximumBufferedResponseMilliseconds: audioProfile.maximumBufferedResponseMilliseconds,
            maximumBufferedResponseChunks: audioProfile.maximumBufferedResponseChunkCount,
            responseBufferOverflowPolicy: .rejectIncoming
        )
    }

    // MARK: - Session Control

    func start() {
        guard !isActive else { return }
        isActive = true
        providerVoiceState = "idle"
        errorMessage = nil
        reconnectAttempt = nil
        taskMessage = nil
        taskFeed = []
        agentTasks = []
        AgentTaskNotificationStore.save([])
        completionNotice = nil
        acknowledgmentNotice = nil
        progressCheckInNotice = nil
        autoCheckedInTaskIds.removeAll()
        progressCheckInTimer?.invalidate()
        progressCheckInTimer = nil
        runningTaskCount = 0
        runningTaskIds.removeAll()
        noticedTaskIds.removeAll()
        acknowledgedTaskIds.removeAll()
        autoApprovedPermissionIDs.removeAll()
        lastTaskResultText = ""
        lastTaskResultAt = nil
        resultFollowUpContext = nil
        lastAssistantReplyAt = nil
        transcriptLog = []
        lastUserText = ""
        lastAssistantText = ""
        activeResponseId = nil
        hasSentPlaybackStartedReceipt = false
        cancelledResponseIDs.removeAll()
        responseOutputGate.reset()
        disarmCaptureBargeIn()
        audioCaptureRecoveryScheduler.reset()
        isAudioSessionInterrupted = false
        isSleeping = false
        wakeController = QwenWakeSessionController()
        stopWakeWordListening()
        idleMonitor.recordActivity()
        startIdleWatchdog()

        playbackGeneration &+= 1
        let generation = playbackGeneration
        imageUploadPipeline.start(generation: generation)
        audioPlaybackPipeline.start(
            generation: generation,
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self,
                          self.isActive,
                          self.playbackGeneration == generation else { return }
                    self.errorMessage = message
                }
            },
            onResponsePlaybackComplete: { [weak self] completedGeneration in
                Task { @MainActor in
                    guard let self,
                          self.isActive,
                          self.playbackGeneration == completedGeneration else { return }
                    self.disarmCaptureBargeIn()
                    self.isSpeaking = false
                    self.outputLevel = 0
                    if let responseId = self.activeResponseId {
                        self.gateway.notifyPlaybackEnded(responseId: responseId)
                        self.activeResponseId = nil
                        self.hasSentPlaybackStartedReceipt = false
                    }
                }
            },
            onAudioLevel: { [weak self] level in
                guard let self,
                      self.isActive,
                      self.playbackGeneration == generation else { return }
                self.outputLevel = level
            }
        )

        gateway.onEvent = { [weak self] event in
            self?.consume(event)
        }
        gateway.connect()
        startCapture()
        startAudioRecoveryObservers()
        AgentWidgetSnapshotCenter.refresh()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isInputActive = false
        providerVoiceState = "idle"
        isSpeaking = false
        inputLevel = 0
        outputLevel = 0
        // 打断（静音）状态必须随会话重置，否则下次会话麦克风保持静音
        isInputMuted = false
        bargeInDetector.reset()
        disarmCaptureBargeIn()
        externalSpeechWasActive = false
        lastInputLevelUpdateAt = 0
        reconnectAttempt = nil
        activeResponseId = nil
        hasSentPlaybackStartedReceipt = false
        cancelledResponseIDs.removeAll()
        responseOutputGate.reset()
        audioCaptureRecoveryScheduler.reset()
        isAudioSessionInterrupted = false
        idleWatchdogTask?.cancel()
        idleWatchdogTask = nil
        progressCheckInTimer?.invalidate()
        progressCheckInTimer = nil
        cancelPermissionTimeout()
        stopCapture()
        stopAudioRecoveryObservers()
        stopWakeWordListening()
        isSleeping = false
        wakeController = QwenWakeSessionController()
        realtimeConnectionStatus.markDisconnected()
        publishRealtimeConnectionStatus()
        audioPlaybackPipeline.stop()
        imageUploadPipeline.stop()
        gateway.onEvent = nil
        gateway.disconnect()
        AgentWidgetSnapshotCenter.refresh()
    }

    /// 清空本次会话转写（上层导入聊天记录后调用）
    func clearTranscriptLog() {
        transcriptLog = []
    }

    /// 清空任务 feed 与计数（上层回填聊天记录后调用）
    func clearTaskFeed() {
        taskFeed = []
        taskMessage = nil
        agentTasks = []
        AgentTaskNotificationStore.save([])
        completionNotice = nil
        progressCheckInNotice = nil
        autoCheckedInTaskIds.removeAll()
        progressCheckInTimer?.invalidate()
        progressCheckInTimer = nil
        runningTaskCount = 0
        runningTaskIds.removeAll()
        noticedTaskIds.removeAll()
        autoApprovedPermissionIDs.removeAll()
        lastTaskResultText = ""
        lastTaskResultAt = nil
        resultFollowUpContext = nil
        resolvedPermissionIds.removeAll()
        pendingPermission = nil
        permissionError = nil
        permissionTimedOut = false
        cancelPermissionTimeout()
    }

    /// 清除完成播报（UI 横幅展示完毕后调用）
    func clearCompletionNotice() {
        completionNotice = nil
    }

    /// 追问上下文注入的最大长度（字符），防止长结果撑爆单条转发消息
    static let resultFollowUpMaxLength = 600

    /// 生成带结果上下文的追问消息；无上下文时原样返回用户文本。
    /// 大脑转发模式调用：任务完成后用户直接说「展开第三条」，大脑能基于结果回答。
    func followUpMessage(_ userText: String) -> String {
        guard let context = resultFollowUpContext, !context.isEmpty else { return userText }
        return "【任务结果】\n\(context)\n\n【用户继续追问】\n\(userText)"
    }

    /// 恢复追问上下文（结果通知「追问」深链进入语音页时注入）：
    /// 不经过任务事件也能让后续语音（如「展开第三条」）携带结果上下文；
    /// 空白文本忽略（清空请传 nil / 空串不会误清已有上下文）。
    func restoreFollowUpContext(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        resultFollowUpContext = Self.followUpContextText(trimmed)
        lastTaskResultText = String(trimmed.prefix(Self.resultFollowUpMaxLength))
        lastTaskResultAt = Date()
    }

    private static func followUpContextText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(resultFollowUpMaxLength))
    }

    /// 任务列表排序：进行中在前，其余按更新时间倒序
    var sortedAgentTasks: [QwenAgentTask] {
        agentTasks.sorted { a, b in
            switch (a.isActive, b.isActive) {
            case (true, false): return true
            case (false, true): return false
            default: return a.updatedAt > b.updatedAt
            }
        }
    }

    // MARK: - 任务语音指令

    /// 最近更新的活动任务（任务指令的取消目标）
    var latestRunningTask: QwenAgentTask? {
        agentTasks
            .filter { $0.isActive }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// 活动任务（等待中/进行中），按创建先后排序（任务一 = 最早创建）
    var activeTasks: [QwenAgentTask] {
        agentTasks.filter { $0.isActive }
    }

    /// 按序号取活动任务（0-based；越界返回 nil）
    func activeTask(at index: Int) -> QwenAgentTask? {
        guard index >= 0, index < activeTasks.count else { return nil }
        return activeTasks[index]
    }

    /// 失败任务（终态失败，可重试），按创建先后排序（与活动任务一致）
    var failedTasks: [QwenAgentTask] {
        agentTasks.filter { $0.status == .failed }
    }

    /// 最近更新的失败任务（重试指令的默认目标）
    var latestFailedTask: QwenAgentTask? {
        failedTasks.max { $0.updatedAt < $1.updatedAt }
    }

    /// 按序号取失败任务（0-based；越界返回 nil）
    func failedTask(at index: Int) -> QwenAgentTask? {
        guard index >= 0, index < failedTasks.count else { return nil }
        return failedTasks[index]
    }

    /// 任务进度播报摘要（纯文本，供 TTS / 转写 / 眼镜展示）
    var taskProgressSummary: String? {
        let active = activeTasks
        guard !active.isEmpty else { return nil }
        if active.count == 1, let task = active.first {
            return Self.progressSummary(for: task)
        }
        let parts = active.map { task -> String in
            let name = task.title.isEmpty ? "agent.task.untitled".localized : task.title
            if task.status == .waiting {
                return name + "（" + "agent.task.status.waiting".localized + "）"
            }
            guard let step = task.resultText, !step.isEmpty else { return name }
            return name + "（" + step + "）"
        }
        return "agent.task.command.progress.many".localized(active.count, parts.joined(separator: "；"))
    }

    /// 第 N 个活动任务的进度摘要（0-based）；越界返回 nil
    func taskProgressSummary(for index: Int) -> String? {
        guard let task = activeTask(at: index) else { return nil }
        return Self.progressSummary(for: task)
    }

    private static func progressSummary(for task: QwenAgentTask) -> String {
        let name = task.title.isEmpty ? "agent.task.untitled".localized : task.title
        switch task.status {
        case .waiting:
            return "agent.task.command.progress.queued".localized(name)
        default:
            let step = (task.resultText?.isEmpty == false)
                ? task.resultText!
                : "agent.task.status.running".localized
            return "agent.task.command.progress.one".localized(name, step)
        }
    }

    /// 请求取消最近的活动任务：向网关发送自然语言取消指令（任务由网关 Agent 执行），
    /// 本地记录一条系统提示。返回任务显示名；无可取消任务时返回 nil。
    @discardableResult
    func requestTaskCancellation() -> String? {
        guard let task = latestRunningTask else { return nil }
        return cancelTask(named: task.title)
    }

    /// 取消第 N 个活动任务（0-based）；越界返回 nil
    @discardableResult
    func requestTaskCancellation(index: Int) -> String? {
        guard let task = activeTask(at: index) else { return nil }
        return cancelTask(named: task.title)
    }

    private func cancelTask(named title: String) -> String {
        let name = title.isEmpty ? "agent.task.untitled".localized : title
        gateway.sendText("agent.task.command.cancel.instruction".localized(name))
        transcriptLog.append(QwenTranscriptItem(
            role: .system,
            text: "agent.task.command.cancel.sent".localized(name)
        ))
        idleMonitor.recordActivity()
        return name
    }

    /// 请求加速最近的活动任务：向网关发送自然语言催促指令（任务由网关 Agent 执行），
    /// 本地记录一条系统提示。返回任务显示名；无活动任务时返回 nil。
    @discardableResult
    func requestTaskAcceleration() -> String? {
        guard let task = latestRunningTask else { return nil }
        return accelerateTask(named: task.title)
    }

    private func accelerateTask(named title: String) -> String {
        let name = title.isEmpty ? "agent.task.untitled".localized : title
        gateway.sendText("agent.task.command.accelerate.instruction".localized(name))
        transcriptLog.append(QwenTranscriptItem(
            role: .system,
            text: "agent.task.command.accelerate.sent".localized(name)
        ))
        idleMonitor.recordActivity()
        return name
    }

    /// 请求重试最近失败的任务：优先把触发任务的原始口述原样重发给网关（真正的重放），
    /// 无原始文本时退化为自然语言重试指令（与取消指令同构）。
    /// 本地记录一条系统提示。返回任务显示名；无失败任务时返回 nil。
    @discardableResult
    func requestTaskRetry() -> String? {
        guard let task = latestFailedTask else { return nil }
        return retryTask(task)
    }

    /// 重试第 N 个失败任务（0-based）；越界返回 nil
    @discardableResult
    func requestTaskRetry(index: Int) -> String? {
        guard let task = failedTask(at: index) else { return nil }
        return retryTask(task)
    }

    /// 重试指定 taskId 的失败任务（通知「重试」Action 入口）；未持有该任务返回 nil
    @discardableResult
    func requestTaskRetry(taskId: String) -> String? {
        guard let task = failedTasks.first(where: { $0.taskId == taskId }) else { return nil }
        return retryTask(task)
    }

    private func retryTask(_ task: QwenAgentTask) -> String {
        let name = task.title.isEmpty ? "agent.task.untitled".localized : task.title
        let source = task.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty {
            // 原样重放触发文本：网关 Agent 视为一次全新请求，重新委派执行
            gateway.sendText(source)
            // 让随后创建的复跑任务继承同一来源文本（后续再次重试仍然重放原始请求）
            lastUserText = source
            transcriptLog.append(QwenTranscriptItem(
                role: .system,
                text: "agent.task.command.retry.sent.source".localized(name)
            ))
        } else {
            let instruction = "agent.task.command.retry.instruction".localized(name)
            gateway.sendText(instruction)
            lastUserText = instruction
            transcriptLog.append(QwenTranscriptItem(
                role: .system,
                text: "agent.task.command.retry.sent".localized(name)
            ))
        }
        idleMonitor.recordActivity()
        return name
    }

    /// 提交权限审批决策（允许/拒绝）。成功后等待网关回发 task.permission.resolved。
    @discardableResult
    func respondToPermission(_ decision: QwenPermissionDecision) async -> Bool {
        guard let request = pendingPermission, !request.isSubmitting else { return false }
        let ok = await submitPermissionDecision(
            request: request,
            decision: decision,
            clearsPending: true
        )
        // 单次放行模式：人工批准后本会话内该权限自动放行
        if ok, decision == .allow {
            autoApprovedPermissionIDs.insert(request.permission.id)
        }
        return ok
    }

    /// 权限分级模式自动处理入口：命中模式时提交决策且不弹卡，返回 true。
    /// 网关失败时回退为弹卡人工处理。
    @discardableResult
    func autoHandlePermission(
        taskId: String?,
        permission: QwenPermission
    ) async -> Bool {
        guard permission.status == .pending,
              let decision = automaticDecision(for: permission.id) else { return false }
        let request = QwenPermissionRequest(taskId: taskId, permission: permission)
        let ok = await submitPermissionDecision(
            request: request,
            decision: decision,
            clearsPending: false
        )
        if !ok {
            pendingPermission = request
            startPermissionTimeout()
        }
        return ok
    }

    /// 当前权限分级模式下该权限是否自动处理（nil = 需要人工弹卡）
    private func automaticDecision(for permissionID: String) -> QwenPermissionDecision? {
        switch AgentPermissionSettings.mode {
        case .alwaysAsk:
            return nil
        case .denyAll:
            return .deny
        case .session, .alwaysAllow:
            return .allow
        case .singleUse:
            return autoApprovedPermissionIDs.contains(permissionID) ? .allow : nil
        }
    }

    /// 提交审批决策的公共路径（人工审批与自动模式共用）
    private func submitPermissionDecision(
        request: QwenPermissionRequest,
        decision: QwenPermissionDecision,
        clearsPending: Bool
    ) async -> Bool {
        cancelPermissionTimeout()
        if clearsPending {
            pendingPermission?.isSubmitting = true
        }
        permissionError = nil
        do {
            let resolved = try await permissionResponder.respondPermission(
                id: request.permission.id,
                decision: decision
            )
            if clearsPending, pendingPermission?.permission.id == resolved.id {
                pendingPermission = nil
            }
            auditSink(AgentAuditEntry(
                id: UUID(),
                date: Date(),
                toolID: resolved.id,
                action: decision == .allow ? .granted : .denied,
                detail: request.permission.summary
            ))
            if resolvedPermissionIds.insert(resolved.id).inserted,
               let item = Self.resolutionItem(for: resolved) {
                taskFeed.append(QwenTaskFeedItem(kind: item.kind, taskId: request.taskId, text: item.text))
            }
            return true
        } catch {
            permissionError = error.localizedDescription
            if clearsPending {
                pendingPermission?.isSubmitting = false
            }
            startPermissionTimeout()
            return false
        }
    }

    /// 收起审批卡片（不发送决策，网关可能稍后再次询问）。
    /// - Parameter audit: 审计动作；用户主动收起为 .later，超时自动跳过为 .skipped
    func dismissPermission(audit action: AgentAuditAction = .later) {
        if let pending = pendingPermission {
            auditSink(AgentAuditEntry(
                id: UUID(),
                date: Date(),
                toolID: pending.permission.id,
                action: action,
                detail: pending.permission.summary
            ))
        }
        cancelPermissionTimeout()
        pendingPermission = nil
        permissionError = nil
    }

    /// 清除审批超时提示（UI 展示完毕后调用）
    func clearPermissionTimeout() {
        permissionTimedOut = false
    }

    /// 审批卡延迟展示期间暂停超时计时（避免用户还没看到卡片就被自动跳过）。
    /// 幂等：与 startPermissionTimeout 一样先取消再等待，重复调用无副作用。
    func pausePermissionTimeout() {
        cancelPermissionTimeout()
    }

    /// 审批卡实际展示时启动/重启超时计时（幂等：先取消再启动）。
    func resumePermissionTimeout() {
        guard pendingPermission != nil else { return }
        startPermissionTimeout()
    }

    /// 审批请求超时未处理时自动收起（不发送决策，网关可稍后再问）
    private func startPermissionTimeout() {
        permissionTimeoutTask?.cancel()
        let timeout = permissionTimeoutOverride ?? AgentTimingSettings.approvalTimeout
        guard timeout > 0 else { return }
        permissionExpiresAt = Date().addingTimeInterval(timeout)
        permissionTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.pendingPermission != nil else { return }
            guard self.pendingPermission?.isSubmitting != true else { return }
            self.dismissPermission(audit: .skipped)
            self.permissionTimedOut = true
        }
    }

    private func cancelPermissionTimeout() {
        permissionTimeoutTask?.cancel()
        permissionTimeoutTask = nil
        permissionExpiresAt = nil
    }

    /// 发送文本消息给语音 Agent（如视野描述），并记录到会话转写。
    /// - Parameters:
    ///   - text: 发送给 Agent 的文本
    ///   - label: 可选过程提示（.system 条目，仅显示不回填）
    func sendText(
        _ text: String,
        label: String? = nil,
        kind: QwenTranscriptItem.Kind = .normal
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 同步更新最近用户文本：任务重试需在任务事件到达前拿到触发文本，
        // 不依赖网关 transcript 回显的到达时序
        lastUserText = trimmed
        gateway.sendText(trimmed)
        transcriptLog.append(QwenTranscriptItem(role: .user, text: trimmed, kind: kind))
        if let label, !label.isEmpty {
            transcriptLog.append(QwenTranscriptItem(role: .system, text: label))
        }
        idleMonitor.recordActivity()
    }

    /// Replays a turn already present in the local transcript after switching
    /// from a failed backend to a fresh native Qwen realtime session.
    func sendTextWithoutTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastUserText = trimmed
        gateway.sendText(trimmed)
        idleMonitor.recordActivity()
    }

    /// 刷新空闲看门狗：持续在场开关切换后立即生效（关闭时重新评估自动结束）
    func refreshIdleWatchdog() {
        startIdleWatchdog()
    }

    private func startIdleWatchdog() {
        idleWatchdogTask?.cancel()
        guard Self.shouldAutoEndIdle else { return }
        idleWatchdogTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, self.isActive else { return }
                if self.idleMonitor.hasTimedOut() {
                    self.stop()
                    self.onIdleTimeout?()
                    return
                }
            }
        }
    }

    /// 打断当前输出并静音输入（幂等：已静音时不重复发送）
    func interrupt() {
        guard !isInputMuted else { return }
        let cancelled = cancelActivePlayback()
        if let responseId = cancelled.responseId {
            gateway.notifyPlaybackCancelled(
                responseId: responseId,
                reason: "user_interruption"
            )
        }
        gateway.interrupt(playedMs: cancelled.playedMilliseconds)
        audioUploadPipeline.stop()
        gateway.setInputMuted(true)
        isInputMuted = true
        inputLevel = 0
    }

    /// 自然语音打断（barge-in）：本地检测到用户开口，立即停止播报，
    /// 但保持麦克风输入，让网关继续接收用户当前说的话。
    ///
    /// 注意这里**不能**用 `guard isSpeaking` 收口：用户完全有理由在
    /// thinking 阶段（首个音频块还没到）就改主意开口，此时若不打断，
    /// 那条正在生成的回复稍后会突然插进用户的新话里。判断条件因此改为
    /// "有在途输出即可打断"。
    func bargeIn() {
        let hasInFlightOutput = isSpeaking
            || activeResponseId != nil
            || providerVoiceState == "thinking"
        guard hasInFlightOutput else { return }
        let cancelled = cancelActivePlayback()
        if let responseId = cancelled.responseId {
            gateway.notifyPlaybackCancelled(
                responseId: responseId,
                reason: "user_interruption"
            )
        }
        gateway.interrupt(playedMs: cancelled.playedMilliseconds)
    }

    private func handleCaptureSideBargeIn(token: UInt64) {
        guard isActive,
              captureBargeInToken == token else { return }
        bargeIn()
    }

    private func disarmCaptureBargeIn() {
        captureBargeInToken = nil
        captureBargeInGate.disarm()
    }

    /// Cancel an in-flight answer before injecting a glasses frame, while keeping input live.
    func prepareForVisionInjection() {
        let cancelled = cancelActivePlayback()
        if let responseId = cancelled.responseId {
            gateway.notifyPlaybackCancelled(
                responseId: responseId,
                reason: "user_interruption"
            )
        }
        gateway.interrupt(playedMs: cancelled.playedMilliseconds)
    }

    /// 取消在途播放，并回报用户实际听到的毫秒数（用于 truncate）。
    struct CancelledPlayback {
        let responseId: String?
        let playedMilliseconds: Int
    }

    @discardableResult
    private func cancelActivePlayback() -> CancelledPlayback {
        // interrupt() 内部先取快照再清零，所以这里拿到的是"被打断前真正播出去"的量。
        let playedMilliseconds = audioPlaybackPipeline.interrupt(generation: playbackGeneration)
        let responseId = clearActivePlaybackState(markResponseCancelled: true)
        return CancelledPlayback(
            responseId: responseId,
            playedMilliseconds: playedMilliseconds
        )
    }

    @discardableResult
    private func clearActivePlaybackState(markResponseCancelled: Bool) -> String? {
        let responseId = activeResponseId
        disarmCaptureBargeIn()
        if markResponseCancelled {
            cancelledResponseIDs.insert(responseId)
            responseOutputGate.markCancelled()
        }
        activeResponseId = nil
        hasSentPlaybackStartedReceipt = false
        outputLevel = 0
        isSpeaking = false
        return responseId
    }

    private func invalidatePlaybackForAudioSystemFailure() {
        let hasInFlightOutput = activeResponseId != nil
            || hasSentPlaybackStartedReceipt
            || isSpeaking
        let playedMilliseconds = audioPlaybackPipeline
            .invalidateAudioSystem(generation: playbackGeneration)
        let responseId = clearActivePlaybackState(
            markResponseCancelled: hasInFlightOutput
        )
        if let responseId {
            gateway.notifyPlaybackCancelled(
                responseId: responseId,
                reason: "playback_error"
            )
        }
        // 音频系统失败同样会让用户只听到半句话；若不截断，模型仍以为整段
        // 都播出去了。这里与 barge-in 走同一条纠正路径。
        if hasInFlightOutput {
            gateway.interrupt(playedMs: playedMilliseconds)
        }
    }

    private func stopRealtimeAudioForTransportLoss() {
        cancelledResponseIDs.insert(activeResponseId)
        responseOutputGate.markTransportLost()
        disarmCaptureBargeIn()
        audioUploadPipeline.stop()
        audioPlaybackPipeline.interrupt(generation: playbackGeneration)
        activeResponseId = nil
        hasSentPlaybackStartedReceipt = false
        providerVoiceState = "idle"
        isInputActive = false
        isSpeaking = false
        inputLevel = 0
        outputLevel = 0
    }

    /// Sends a Ray-Ban frame directly when the selected embedded Omni transport supports images.
    var supportsDirectVision: Bool {
        gateway.supportsDirectVision && gateway.connectionState.isOnline
    }

    @discardableResult
    func sendVisionFrame(_ image: UIImage, prompt: String) -> Bool {
        guard isActive, supportsDirectVision else { return false }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let generation = playbackGeneration
        let result = imageUploadPipeline.submit(image, generation: generation) { [weak self] data in
            Task { @MainActor in
                guard let self, self.isActive, self.playbackGeneration == generation else { return }
                guard self.gateway.sendImage(jpegData: data) else { return }
                self.gateway.sendText(trimmed)
                self.transcriptLog.append(QwenTranscriptItem(
                    role: .system,
                    text: "qwen.voice.vision.sent".localized
                ))
                self.idleMonitor.recordActivity()
            }
        }
        return result.isAccepted
    }

    /// 恢复输入聆听（幂等：未静音时不重复发送）
    func resume() {
        if !isSleeping,
           wakeWordMonitor == nil,
           audioEngine?.isRunning != true {
            restartCapture()
        }
        guard isInputMuted else { return }
        gateway.setInputMuted(false)
        isInputMuted = false
        startAudioUploadPipelineIfPossible()
        idleMonitor.recordActivity()
    }

    /// 镜腿单击交替打断/恢复（供 UI 主按钮等旧入口使用）
    func toggleInterrupt() {
        if isInputMuted {
            resume()
        } else {
            interrupt()
        }
    }

    /// 镜腿长按：结束会话
    func endSession() {
        stop()
    }

    /// 镜腿单击唤醒：会话已停止时重新连接并开始聆听（保留已有转写）；
    /// 会话活跃但被静音时恢复聆听；会话休眠时请求网关唤醒并恢复聆听。
    func wake() {
        if !isActive {
            let savedTranscript = transcriptLog
            start()
            transcriptLog = savedTranscript + transcriptLog
            return
        }
        if isSleeping {
            beginWakeTransition()
            gateway.requestWake()
        }
        resume()
    }

    /// 手动进入休眠：请求网关休眠；若开启语音唤醒词，同时启动唤醒词监听
    func requestSleep() {
        guard isActive else { return }
        gateway.requestSleep()
        enterSleepState()
    }

    /// 收到网关 client.state: sleeping（或用户手动休眠）后统一进入休眠状态
    private func enterSleepState() {
        realtimeConnectionStatus.markSleeping()
        publishRealtimeConnectionStatus()
        applySleepTransitionSideEffects()
    }

    private func applySleepTransitionSideEffects() {
        guard connectionState == .sleeping else { return }
        errorMessage = nil
        guard !isSleeping else { return }
        audioCaptureRecoveryScheduler.reset()
        stopRealtimeAudioForTransportLoss()
        isSleeping = true
        wakeController.enterSleep()
        if Self.wakeWordEnabled {
            beginWakeWordListening()
        } else {
            stopCapture()
        }
    }

    private func beginWakeTransition() {
        realtimeConnectionStatus.markWaking()
        publishRealtimeConnectionStatus()
        applyWakeTransitionSideEffects()
    }

    private func applyWakeTransitionSideEffects() {
        guard connectionState == .waking else { return }
        if isSleeping {
            isSleeping = false
            stopWakeWordListening()
            wakeController.wakeCompleted()
        }
        errorMessage = nil
    }

    private func applyConnectedTransitionSideEffects() {
        guard connectionState == .connected else { return }
        if isSleeping {
            isSleeping = false
            stopWakeWordListening()
            wakeController.wakeCompleted()
        }
        reconnectAttempt = nil
        errorMessage = nil
        startAudioUploadPipelineIfPossible()
    }

    private func publishRealtimeConnectionStatus() {
        let nextState = realtimeConnectionStatus.connectionState
        if connectionState != nextState {
            connectionState = nextState
        }
    }

    /// 关闭唤醒词开关时停止监听（休眠状态保持，可随时重新开启）
    func stopWakeWordMonitoring() {
        stopWakeWordListening()
    }

    /// 休眠期间重启用唤醒词监听（设置开关变化时由 UI 调用）
    func restartWakeWordListening() {
        guard isSleeping else { return }
        stopWakeWordListening()
        wakeWordTranscript = ""
        beginWakeWordListening()
    }

    /// 启动唤醒词监听（休眠 + 开关开启时）
    private func beginWakeWordListening() {
        guard Self.wakeWordEnabled else { return }
        // Speech recognition and the realtime gateway must not install two
        // simultaneous input taps. Keep the session claim while swapping engines.
        stopCapture(releaseAudioSession: false)
        wakeController.startListening()
        let monitor = wakeWordMonitorFactory()
        monitor.onTranscript = { [weak self] text in
            Task { @MainActor in
                self?.wakeWordTranscript = text
            }
        }
        monitor.onWakeWord = { [weak self] text in
            Task { @MainActor in
                self?.handleWakeWord(text)
            }
        }
        wakeWordMonitor = monitor
        Task {
            do {
                try await monitor.startMonitoring()
            } catch {
                await MainActor.run {
                    self.wakeController.wakeFailed()
                    self.wakeWordMonitorError = error.localizedDescription
                }
            }
        }
    }

    /// 唤醒词命中：请求网关唤醒并恢复聆听
    private func handleWakeWord(_ text: String) {
        guard isSleeping, wakeController.phase == .listening else { return }
        wakeController.matchWakeWord()
        lastWakeWordText = text
        beginWakeTransition()
        gateway.requestWake()
        resume()
    }

    private func stopWakeWordListening() {
        wakeWordMonitor?.stopMonitoring()
        wakeWordMonitor = nil
    }

    /// 带配置变更的重启（如切换大脑模式）：保留已有转写
    func restart() {
        let savedTranscript = transcriptLog
        stop()
        start()
        transcriptLog = savedTranscript + transcriptLog
    }

    /// 大脑模式的回复文本是否输出语音（由网关 connect 参数控制，重启后生效）
    var outputEnabled: Bool {
        get { gateway.outputEnabled }
        set { gateway.outputEnabled = newValue }
    }

    /// 追加一条大脑（Hermes/OpenClaw）的回复转写，供界面展示与历史落盘
    func appendAssistantText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastAssistantText = trimmed
        lastAssistantReplyAt = Date()
        transcriptLog.append(QwenTranscriptItem(role: .assistant, text: trimmed))
        idleMonitor.recordActivity()
    }

    /// 追加一条用户侧上下文（如视野描述）到转写，不发送给网关（大脑模式用）
    func appendUserText(
        _ text: String,
        label: String? = nil,
        kind: QwenTranscriptItem.Kind = .normal
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastUserText = trimmed
        transcriptLog.append(QwenTranscriptItem(role: .user, text: trimmed, kind: kind))
        if let label, !label.isEmpty {
            transcriptLog.append(QwenTranscriptItem(role: .system, text: label))
        }
        idleMonitor.recordActivity()
    }

    // MARK: - Audio Capture

    private func startCapture(stopSessionOnFailure: Bool = true) {
        suppressRouteConfigurationRecovery()
        captureActivationTask?.cancel()
        captureGeneration &+= 1
        let generation = captureGeneration
        captureActivationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                try await AudioSessionCoordinator.shared.activateAsync(
                    .qwenVoice,
                    profile: .voiceChat
                )
                guard !Task.isCancelled,
                      self.isActive,
                      !self.isSleeping,
                      !self.isAudioSessionInterrupted,
                      self.captureGeneration == generation else { return }
                try await Task.sleep(nanoseconds: Self.audioRouteSettleNanoseconds)
                guard !Task.isCancelled,
                      self.isActive,
                      !self.isSleeping,
                      !self.isAudioSessionInterrupted,
                      self.captureGeneration == generation else { return }
                try self.startCaptureEngine()
                self.audioCaptureRecoveryScheduler.reset()
                self.errorMessage = nil
            } catch {
                guard self.isActive, self.captureGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
                if stopSessionOnFailure {
                    self.stop()
                } else {
                    self.audioUploadPipeline.stop()
                    self.isInputActive = false
                    self.inputLevel = 0
                    self.scheduleAudioCaptureRecovery()
                }
            }
        }
    }

    private func startCaptureEngine() throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        var didInstallInputTap = false
        do {
            try AppleVoiceAudioFrontEnd.configure(engine)
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0,
                  inputFormat.channelCount > 0 else {
                throw VoiceAudioFrontEndError.inputFormatUnavailable
            }
            let generation = captureGeneration
            startAudioUploadPipeline(inputFormat: inputFormat, generation: generation)
            let uploadPipeline = audioUploadPipeline
            inputNode.installTap(
                onBus: 0,
                bufferSize: 2048,
                // Let AVAudioEngine provide the route's actual tap format.
                // VPIO can renegotiate the input format after activation;
                // pinning the pre-start format can yield a running engine with
                // no usable tap callbacks on standalone iPhone routes.
                format: nil
            ) { [uploadPipeline] buffer, _ in
                uploadPipeline.capture(buffer, generation: generation)
            }
            didInstallInputTap = true
            observeConfigurationChanges(for: engine)
            engine.prepare()
            try engine.start()
            // The gateway can become ready while the audio graph is settling.
            // Re-bind after the engine is running so that transition is not
            // lost between the initial readiness check and the first tap.
            startAudioUploadPipelineIfPossible()
            audioPlaybackPipeline.prepare(generation: playbackGeneration)
        } catch {
            audioUploadPipeline.stop()
            stopObservingAudioEngineConfigurationChanges()
            if didInstallInputTap {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            audioEngine = nil
            throw error
        }
    }

    var isCaptureEngineRunning: Bool {
        audioEngine?.isRunning == true
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        stopObservingAudioEngineConfigurationChanges()
        audioEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            // AVAudioEngine posts this on an internal queue and forbids teardown
            // inside the callback. Hop to MainActor before replacing the graph.
            Task { @MainActor [weak self, weak engine] in
                guard let self,
                      let engine,
                      self.audioEngine === engine else { return }
                self.handleAudioEngineConfigurationChange()
            }
        }
    }

    private func stopObservingAudioEngineConfigurationChanges() {
        guard let audioEngineConfigurationObserver else { return }
        NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
        self.audioEngineConfigurationObserver = nil
    }

    private func startAudioUploadPipelineIfPossible() {
        guard let engine = audioEngine, engine.isRunning else { return }
        startAudioUploadPipeline(
            inputFormat: engine.inputNode.outputFormat(forBus: 0),
            generation: captureGeneration
        )
    }

    private func startAudioUploadPipeline(
        inputFormat: AVAudioFormat,
        generation: Int
    ) {
        guard isActive else {
            audioUploadPipeline.stop()
            return
        }
        guard !isSleeping else {
            audioUploadPipeline.stop()
            return
        }
        guard !isInputMuted else {
            audioUploadPipeline.stop()
            return
        }
        guard captureGeneration == generation else {
            audioUploadPipeline.stop()
            return
        }
        guard gateway.connectionState.isOnline else {
            audioUploadPipeline.stop()
            return
        }

        let transport = gateway.audioTransport
        let captureBargeInGate = captureBargeInGate
        audioUploadPipeline.start(
            generation: generation,
            inputFormat: inputFormat,
            messageBuilder: Self.makeAudioUploadMessage,
            messageSender: { message, completion in
                transport.send(message, completion: completion)
            },
            onCapturedAudio: { [weak self] stats in
                guard let token = captureBargeInGate.consume(stats) else { return }
                Task { @MainActor in
                    self?.handleCaptureSideBargeIn(token: token)
                }
            },
            onEncodedAudio: { [weak self] stats in
                self?.consumeInputAudioStats(stats, generation: generation)
            },
            onFirstAudioSent: {},
            onFailure: { [weak self] message in
                guard let self,
                      self.isActive,
                      self.captureGeneration == generation else { return }
                self.errorMessage = message
                self.gateway.recoverFromAudioTransportFailure()
            }
        )
    }

    private static func makeAudioUploadMessage(
        _ pcmData: Data
    ) -> URLSessionWebSocketTask.Message? {
        let payload = QwenGatewayClientEvent.audioAppend(
            pcmBase64: pcmData.base64EncodedString()
        )
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return .string(text)
    }

    private func consumeInputAudioStats(
        _ stats: RealtimeEncodedAudioFrameStats,
        generation: Int
    ) {
        guard isActive,
              !isInputMuted,
              captureGeneration == generation else { return }

        // Keep every encoded frame for external speech detection, but publish
        // visual energy at 12.5 Hz so microphone activity cannot drive full-screen SwiftUI work.
        let externalSpeechIsActive = TTSService.shared.isSpeaking
        if externalSpeechIsActive, !externalSpeechWasActive {
            bargeInDetector.reset()
        }
        externalSpeechWasActive = externalSpeechIsActive
        if externalSpeechIsActive,
           bargeInDetector.consume(rms: stats.rms, sampleCount: stats.sampleCount) {
            TTSService.shared.stop()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastInputLevelUpdateAt >= 0.08 {
            lastInputLevelUpdateAt = now
            inputLevel = Self.orbInputLevel(rms: stats.rms)
        }
        if stats.rms >= bargeInDetector.energyThreshold {
            idleMonitor.recordActivity()
        }
    }

    /// 归一化 RMS 能量（0~1），用于本地 barge-in 检测
    static func rmsEnergy(_ data: Data) -> Float {
        RealtimePCM16AudioMeter.stats(for: data).rms
    }

    static func orbInputLevel(rms: Float) -> Float {
        min(max(rms * 8, 0), 1)
    }

    private func stopCapture(
        releaseAudioSession: Bool = true,
        resetRecovery: Bool = true
    ) {
        if resetRecovery {
            audioCaptureRecoveryScheduler.reset()
        }
        captureActivationTask?.cancel()
        captureActivationTask = nil
        captureGeneration &+= 1
        audioUploadPipeline.stop()
        isInputActive = false
        inputLevel = 0
        stopObservingAudioEngineConfigurationChanges()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if releaseAudioSession {
            AudioSessionCoordinator.shared.deactivateAsync(.qwenVoice)
        }
    }

    /// Foreground return is a recovery hint, not a new session. Background audio remains active.
    func recoverAfterForeground() {
        guard isActive else { return }
        if isSleeping,
           Self.wakeWordEnabled,
           wakeWordMonitor?.isMonitoring != true {
            restartWakeWordListening()
        } else if !isSleeping, audioEngine?.isRunning != true {
            restartCapture()
        }
        if !gateway.hasActiveTransport {
            gateway.connect()
        }
    }

    private func restartCapture() {
        audioCaptureRecoveryScheduler.reset()
        performAudioCaptureRecoveryAttempt()
    }

    private func performAudioCaptureRecoveryAttempt() {
        suppressRouteConfigurationRecovery()
        stopCapture(resetRecovery: false)
        guard isActive, !isSleeping, !isAudioSessionInterrupted else { return }
        startCapture(stopSessionOnFailure: false)
    }

    private func scheduleAudioCaptureRecovery() {
        guard isActive, !isSleeping, !isAudioSessionInterrupted else { return }
        audioCaptureRecoveryScheduler.schedule { [weak self] in
            guard let self,
                  self.isActive,
                  !self.isSleeping,
                  !self.isAudioSessionInterrupted else { return }
            self.performAudioCaptureRecoveryAttempt()
        }
    }

    private func startAudioRecoveryObservers() {
        stopAudioRecoveryObservers()
        let center = NotificationCenter.default
        let audioSession = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            audioSessionInactiveObserver = center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioSessionBecameInactive(notification)
                }
            }
            audioSessionResumptionObserver = center.addObserver(
                forName: AVAudioSession.resumptionRecommendationNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioSessionResumptionRecommendation(notification)
                }
            }
        } else {
            audioInterruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioInterruption(notification)
                }
            }
        }
        mediaServicesResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.handleMediaServicesReset()
            }
        }
        audioRouteChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.handleAudioRouteChange(notification)
            }
        }
    }

    private func stopAudioRecoveryObservers() {
        audioRouteRecoveryCoalescer.cancel()
        let center = NotificationCenter.default
        if let audioInterruptionObserver {
            center.removeObserver(audioInterruptionObserver)
            self.audioInterruptionObserver = nil
        }
        if let audioSessionInactiveObserver {
            center.removeObserver(audioSessionInactiveObserver)
            self.audioSessionInactiveObserver = nil
        }
        if let audioSessionResumptionObserver {
            center.removeObserver(audioSessionResumptionObserver)
            self.audioSessionResumptionObserver = nil
        }
        if let mediaServicesResetObserver {
            center.removeObserver(mediaServicesResetObserver)
            self.mediaServicesResetObserver = nil
        }
        if let audioRouteChangeObserver {
            center.removeObserver(audioRouteChangeObserver)
            self.audioRouteChangeObserver = nil
        }
    }

    func handleMediaServicesReset() {
        audioRouteRecoveryCoalescer.cancel()
        suppressRouteConfigurationRecovery()
        quiesceRealtimeAudioForSystemFailure()
        if isSleeping, Self.wakeWordEnabled {
            restartWakeWordListening()
        } else {
            restartCapture()
        }
    }

    func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            beginAudioSessionInterruption()
        case .ended:
            endAudioSessionInterruption()
        @unknown default:
            break
        }
    }

    @available(iOS 27.0, *)
    func handleAudioSessionBecameInactive(_ notification: Notification) {
        guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext,
              context.source == .system else { return }
        beginAudioSessionInterruption()
    }

    @available(iOS 27.0, *)
    func handleAudioSessionResumptionRecommendation(_ notification: Notification) {
        guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                as? AVAudioSession.ResumptionContext,
              context.recommendation == .shouldResume else { return }
        endAudioSessionInterruption()
    }

    private func beginAudioSessionInterruption() {
        guard !isAudioSessionInterrupted else { return }
        isAudioSessionInterrupted = true
        audioRouteRecoveryCoalescer.cancel()
        quiesceRealtimeAudioForSystemFailure()
    }

    private func endAudioSessionInterruption() {
        guard isAudioSessionInterrupted else { return }
        isAudioSessionInterrupted = false
        guard isActive else { return }
        suppressRouteConfigurationRecovery()
        if isSleeping, Self.wakeWordEnabled {
            restartWakeWordListening()
        } else {
            restartCapture()
        }
    }

    func handleAudioEngineConfigurationChange() {
        guard !isAudioSessionInterrupted else { return }
        scheduleAudioSystemRecovery()
    }

    func handleAudioRouteChange(_ notification: Notification) {
        guard !isAudioSessionInterrupted,
              let reason = QwenAudioRouteRecoveryPolicy.reason(from: notification),
              QwenAudioRouteRecoveryPolicy.requiresRecovery(for: reason) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if reason == .routeConfigurationChange,
           now < audioRouteConfigurationSuppressedUntil {
            return
        }

        scheduleAudioSystemRecovery()
    }

    private func scheduleAudioSystemRecovery() {
        audioRouteRecoveryCoalescer.schedule(
            onFirst: { [weak self] in
                guard let self else { return }
                self.quiesceRealtimeAudioForSystemFailure()
            },
            onSettled: { [weak self] in
                guard let self,
                      self.isActive,
                      !self.isAudioSessionInterrupted else { return }
                self.suppressRouteConfigurationRecovery()
                if self.isSleeping, Self.wakeWordEnabled {
                    self.restartWakeWordListening()
                } else if !self.isSleeping {
                    self.restartCapture()
                }
            }
        )
    }

    private func quiesceRealtimeAudioForSystemFailure() {
        audioCaptureRecoveryScheduler.reset()
        stopWakeWordListening()
        stopCapture(releaseAudioSession: false, resetRecovery: false)
        invalidatePlaybackForAudioSystemFailure()
        providerVoiceState = "idle"
        outputLevel = 0
    }

    private func suppressRouteConfigurationRecovery() {
        audioRouteConfigurationSuppressedUntil = max(
            audioRouteConfigurationSuppressedUntil,
            ProcessInfo.processInfo.systemUptime
                + Self.audioRouteConfigurationSuppressionInterval
        )
    }

    // MARK: - Gateway Events

    /// 处理单个网关事件（internal 以便单元测试）
    func consume(_ event: QwenGatewayEvent) {
        idleMonitor.recordActivity()
        switch event {
        case .voiceReady:
            realtimeConnectionStatus.markReady()
            publishRealtimeConnectionStatus()
            applyConnectedTransitionSideEffects()
        case .voiceConnection(let state, let message):
            realtimeConnectionStatus.applyVoiceConnection(state: state, message: message)
            publishRealtimeConnectionStatus()
            if state == "connected" {
                applyConnectedTransitionSideEffects()
            } else if state == "waking" {
                applyWakeTransitionSideEffects()
            } else if state == "connecting" {
                errorMessage = nil
            } else if state == "sleeping" {
                applySleepTransitionSideEffects()
            } else if state == "unavailable" {
                if hasSentPlaybackStartedReceipt, let activeResponseId {
                    gateway.notifyPlaybackCancelled(
                        responseId: activeResponseId,
                        reason: "playback_error"
                    )
                }
                stopRealtimeAudioForTransportLoss()
            }
        case .voiceState(let state):
            providerVoiceState = state
            isInputActive = (state == "listening")
        case .voiceSleep(let state):
            realtimeConnectionStatus.applyVoiceSleep(state: state)
            publishRealtimeConnectionStatus()
            if state == "sleeping" {
                applySleepTransitionSideEffects()
            } else if state == "detected" {
                applyWakeTransitionSideEffects()
            } else if state == "awake" {
                if gateway.connectionState == .connected {
                    realtimeConnectionStatus.markConnected()
                    publishRealtimeConnectionStatus()
                    applyConnectedTransitionSideEffects()
                }
            }
        case .clientState(let state):
            realtimeConnectionStatus.applyClientState(state: state)
            publishRealtimeConnectionStatus()
            if state == "sleeping" {
                applySleepTransitionSideEffects()
            } else if state == "awake" {
                if gateway.connectionState == .connected {
                    realtimeConnectionStatus.markConnected()
                    publishRealtimeConnectionStatus()
                    applyConnectedTransitionSideEffects()
                } else {
                    applyWakeTransitionSideEffects()
                }
            }
        case .turnStarted:
            // Provider VAD is a second full-duplex barge-in path when local energy detection misses.
            // 不再用 isSpeaking 收口：thinking 阶段服务端检测到新一轮开口同样要打断，
            // 否则那条还在生成的回复会插进用户的新话里。bargeIn() 自带空转保护。
            bargeIn()
        case .responseStarted(let responseId):
            let responseId = QwenCancelledResponseRegistry.normalized(responseId)
            if let responseId {
                guard !cancelledResponseIDs.contains(responseId) else { return }
                if let activeResponseId, activeResponseId != responseId {
                    // 服务端自己换了 response，说明它已经知道旧的那条作废了，
                    // 这里只报播放取消，不再回发 interrupt/truncate。
                    let superseded = cancelActivePlayback()
                    if let supersededResponseId = superseded.responseId {
                        gateway.notifyPlaybackCancelled(responseId: supersededResponseId)
                    }
                }
                if activeResponseId != responseId {
                    hasSentPlaybackStartedReceipt = false
                }
                activeResponseId = responseId
                responseOutputGate.markResponseStarted()
            } else if activeResponseId == nil {
                hasSentPlaybackStartedReceipt = false
                responseOutputGate.markResponseStarted()
            }
        case .audioChunk(let data, _, let responseId, let receivedAt):
            guard !isInputMuted else { return }
            let responseId = QwenCancelledResponseRegistry.normalized(responseId)
            guard !cancelledResponseIDs.contains(responseId) else { return }
            guard responseOutputGate.acceptAudio(hasResponseID: responseId != nil) else { return }
            if let activeResponseId,
               let responseId,
               activeResponseId != responseId {
                let superseded = cancelActivePlayback()
                if let supersededResponseId = superseded.responseId {
                    gateway.notifyPlaybackCancelled(responseId: supersededResponseId)
                }
            }
            let enqueueResult = audioPlaybackPipeline.enqueue(
                data,
                generation: playbackGeneration,
                receivedAt: receivedAt.isFinite && receivedAt > 0
                    ? receivedAt
                    : ProcessInfo.processInfo.systemUptime
            )
            guard enqueueResult.isAccepted else { return }
            if activeResponseId == nil {
                activeResponseId = responseId
            }
            if !hasSentPlaybackStartedReceipt {
                gateway.notifyPlaybackStarted(responseId: activeResponseId ?? responseId)
                hasSentPlaybackStartedReceipt = true
            }
            // 新一轮播报开始：重置打断检测（每次响应只允许打断一次）
            if !isSpeaking {
                bargeInDetector.reset()
                captureBargeInToken = captureBargeInGate.arm()
                isSpeaking = true
            }
        case .audioDone(let responseId):
            let responseId = QwenCancelledResponseRegistry.normalized(responseId)
            guard !cancelledResponseIDs.contains(responseId) else { return }
            guard responseOutputGate.acceptsTerminal(hasResponseID: responseId != nil) else { return }
            if let activeResponseId,
               let responseId,
               activeResponseId != responseId {
                return
            }
            if activeResponseId == nil, responseId != nil {
                return
            }
            audioPlaybackPipeline.finishResponse(generation: playbackGeneration)
        case .responseInterrupted(let responseId):
            let responseId = QwenCancelledResponseRegistry.normalized(responseId)
            cancelledResponseIDs.insert(responseId)
            if responseId == nil {
                responseOutputGate.markCancelled()
            }
            guard responseId == nil || responseId == activeResponseId else { return }
            // 这两条都是服务端主动通知的取消，服务端上下文已经自洽，
            // 所以只回报播放状态，不再补 interrupt/truncate。
            let cancelled = cancelActivePlayback()
            if let cancelledResponseId = cancelled.responseId {
                gateway.notifyPlaybackCancelled(responseId: cancelledResponseId)
            }
        case .playbackClear(let reason):
            let cleared = cancelActivePlayback()
            if let clearedResponseId = cleared.responseId {
                gateway.notifyPlaybackCancelled(
                    responseId: clearedResponseId,
                    reason: reason
                )
            }
        case .transcriptDelta(let role, let text):
            if role == "user" { lastUserText = text } else { lastAssistantText = text }
        case .transcriptFinal(let role, let text):
            if role == "user" { lastUserText = text } else { lastAssistantText = text }
            if !text.isEmpty {
                transcriptLog.append(QwenTranscriptItem(
                    role: role == "user" ? .user : .assistant,
                    text: text
                ))
            }
            if role == "user", let intent = AgentVisionIntentParser.parse(text) {
                onVisionRequest?(intent)
            }
        case .task(let type, let taskId, let title):
            trackTaskStatus(type: type, taskId: taskId, title: title)
            if let title {
                taskMessage = title
                if let item = Self.taskFeedItem(type: type, taskId: taskId, title: title) {
                    taskFeed.append(item)
                }
            }
        case .timelineInline(let taskId, let content):
            if let content, !content.isEmpty {
                taskMessage = content
                taskFeed.append(QwenTaskFeedItem(kind: .result, taskId: taskId, text: content))
                if let taskId,
                   let index = agentTasks.firstIndex(where: { $0.taskId == taskId }) {
                    agentTasks[index].resultText = content
                    agentTasks[index].updatedAt = Date()
                    // 已有步骤输出说明任务已开始执行
                    if agentTasks[index].status == .waiting {
                        agentTasks[index].status = .running
                    }
                }
            }
        case .permissionRequested(let taskId, let permission):
            guard permission.status == .pending else { break }
            // 权限分级模式：命中自动处理时不弹卡，直接提交决策
            if automaticDecision(for: permission.id) != nil {
                taskMessage = permission.summary
                Task { @MainActor [weak self] in
                    _ = await self?.autoHandlePermission(taskId: taskId, permission: permission)
                }
                break
            }
            pendingPermission = QwenPermissionRequest(taskId: taskId, permission: permission)
            startPermissionTimeout()
            taskMessage = permission.summary
            taskFeed.append(QwenTaskFeedItem(
                kind: .permissionRequested,
                taskId: taskId,
                text: permission.summary
            ))
        case .permissionResolved(let taskId, let permission):
            if pendingPermission?.permission.id == permission.id {
                cancelPermissionTimeout()
                pendingPermission = nil
                permissionError = nil
            }
            if resolvedPermissionIds.insert(permission.id).inserted,
               let item = Self.resolutionItem(for: permission) {
                taskFeed.append(QwenTaskFeedItem(kind: item.kind, taskId: taskId, text: item.text))
            }
        case .error(let message):
            errorMessage = message
        case .gatewayReconnecting(let attempt, let maxAttempts):
            stopRealtimeAudioForTransportLoss()
            inputLevel = 0
            reconnectAttempt = attempt
            reconnectMaxAttempts = maxAttempts
            realtimeConnectionStatus.beginConnecting(resetLifecycle: true)
            publishRealtimeConnectionStatus()
        case .gatewayReconnectFailed:
            stopRealtimeAudioForTransportLoss()
            inputLevel = 0
            reconnectAttempt = nil
            realtimeConnectionStatus.markUnavailable("qwen.error.reconnect.limit".localized)
            publishRealtimeConnectionStatus()
        case .gatewayDisconnected:
            stopRealtimeAudioForTransportLoss()
            inputLevel = 0
            realtimeConnectionStatus.markDisconnected()
            publishRealtimeConnectionStatus()
            reconnectAttempt = nil
        default:
            break
        }
    }

    /// 空闲超时回调（View 用于提示）
    var onIdleTimeout: (() -> Void)?
    /// Explicit visual language asks the owning view to capture one glasses frame on demand.
    var onVisionRequest: ((AgentVisionIntent) -> Void)?

    /// 语音会话状态 → 锁屏 Live Activity 同步：
    /// 会话活跃时展示「聆听 / 思考 / 回复 / 休眠 / 连接」状态行（高于任务进度）；
    /// 会话结束清空语音卡并回落（任务进度 / 倒计时由各自缓存接管）。
    private func syncVoiceLiveActivity() {
        AgentLiveActivityManager.updateVoiceStatus(
            text: AgentVoiceLiveActivityStatus.text(
                isActive: isActive,
                isSleeping: isSleeping,
                isSpeaking: isSpeaking,
                isInputActive: isInputActive,
                connectionState: connectionState
            ),
            phase: AgentVoiceLiveActivityStatus.phase(
                isActive: isActive,
                isSleeping: isSleeping,
                isSpeaking: isSpeaking,
                isInputActive: isInputActive,
                connectionState: connectionState
            )
        )
    }

    /// 任务 / 审批状态变化 → 锁屏 Live Activity 同步（审批优先，其余展示任务进度）
    private func syncLiveActivity() {
        if let pending = pendingPermission {
            AgentLiveActivityManager.showApproval(
                text: pending.permission.summary,
                expiresAt: permissionExpiresAt
            )
        } else if runningTaskCount > 0 {
            AgentLiveActivityManager.updateTaskProgress(
                count: runningTaskCount,
                step: taskMessage
            )
        } else {
            AgentLiveActivityManager.end()
        }
    }

    private func trackTaskStatus(type: String, taskId: String?, title: String?) {
        guard let taskId else { return }
        switch type {
        case "task.delegated", "task.scheduled":
            if runningTaskIds.insert(taskId).inserted {
                runningTaskCount += 1
            }
            upsertTask(
                taskId: taskId,
                title: title,
                status: .waiting,
                sourceText: lastUserText
            )
            acknowledgeTask(taskId: taskId, title: title)
            startProgressCheckInTimerIfNeeded()
        case "task.running", "task.progress", "task.finalizing", "task.cancelling":
            if runningTaskIds.insert(taskId).inserted {
                runningTaskCount += 1
            }
            upsertTask(
                taskId: taskId,
                title: title,
                status: .running,
                sourceText: lastUserText
            )
            startProgressCheckInTimerIfNeeded()
        case "task.completed", "task.failed", "task.cancelled":
            if runningTaskIds.remove(taskId) != nil {
                runningTaskCount = max(0, runningTaskCount - 1)
            }
            stopProgressCheckInTimerIfNeeded()
            let status: QwenAgentTask.Status = type == "task.completed"
                ? .completed
                : (type == "task.failed" ? .failed : .cancelled)
            let kind: QwenTaskFeedItem.Kind = type == "task.completed"
                ? .completed
                : (type == "task.failed" ? .failed : .cancelled)
            upsertTask(
                taskId: taskId,
                title: title,
                status: status,
                sourceText: lastUserText
            )
            if let text = title ?? agentTasks.first(where: { $0.taskId == taskId })?.title,
               !text.isEmpty {
                notifyCompletion(taskId: taskId, text: text, kind: kind)
            }
        default:
            break
        }
    }

    /// 有活跃任务时启动长任务进度轮询（幂等）
    private func startProgressCheckInTimerIfNeeded() {
        guard progressCheckInTimer == nil, runningTaskCount > 0 else { return }
        let timer = Timer(timeInterval: AgentTaskProgressCheckIn.defaultInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.performProgressCheckIn()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressCheckInTimer = timer
    }

    /// 无活跃任务时停止轮询并重置已汇报集合
    private func stopProgressCheckInTimerIfNeeded() {
        guard runningTaskCount == 0 else { return }
        progressCheckInTimer?.invalidate()
        progressCheckInTimer = nil
        autoCheckedInTaskIds.removeAll()
    }

    /// 轮询一次：最早超过阈值的活跃任务置自动进度播报（每任务一次）
    private func performProgressCheckIn() {
        let due = AgentTaskProgressCheckIn.dueCheckIns(
            tasks: agentTasks.map { ($0.taskId, $0.createdAt, $0.isActive) },
            checkedIn: autoCheckedInTaskIds
        )
        guard let taskId = due.first,
              let task = agentTasks.first(where: { $0.taskId == taskId }) else { return }
        autoCheckedInTaskIds.insert(taskId)
        progressCheckInNotice = QwenTaskProgressNotice(
            taskId: taskId,
            text: AgentTaskProgressCheckIn.announcementText(
                title: task.title,
                elapsed: Date().timeIntervalSince(task.createdAt)
            )
        )
    }

    /// 清除自动进度播报（UI 播报 / 上镜片后调用）
    func clearProgressCheckInNotice() {
        progressCheckInNotice = nil
    }

    /// 任务受理回执：转写追加一条系统提示并置 acknowledgmentNotice（同一任务只回执一次）。
    /// 对齐 qwen-audio-agent 的 spawn_thinking 即时受理语义，避免用户以为没听懂。
    private func acknowledgeTask(taskId: String, title: String?) {
        guard acknowledgedTaskIds.insert(taskId).inserted else { return }
        let displayTitle = title ?? agentTasks.first(where: { $0.taskId == taskId })?.title ?? ""
        let text = displayTitle.isEmpty
            ? "agent.task.acknowledged.generic".localized
            : String(format: "agent.task.acknowledged".localized, displayTitle)
        transcriptLog.append(QwenTranscriptItem(role: .system, text: text))
        acknowledgmentNotice = QwenTaskAcknowledgmentNotice(taskId: taskId, title: displayTitle)
    }

    /// 新建或更新结构化任务状态；title 为空时保留已有标题。
    /// sourceText 仅在新建时生效（重试需重放原始触发文本；更新路径忽略）。
    private func upsertTask(
        taskId: String,
        title: String?,
        status: QwenAgentTask.Status,
        sourceText: String? = nil
    ) {
        let now = Date()
        if let index = agentTasks.firstIndex(where: { $0.taskId == taskId }) {
            if let title, !title.isEmpty {
                agentTasks[index].title = title
            }
            agentTasks[index].status = status
            agentTasks[index].updatedAt = now
        } else {
            let source = sourceText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            agentTasks.append(QwenAgentTask(
                taskId: taskId,
                title: title ?? "",
                status: status,
                resultText: nil,
                sourceText: (source?.isEmpty == false) ? source : nil,
                createdAt: now,
                updatedAt: now
            ))
        }
        // 同步后台巡检快照（任务完成 / 失败时后台推送系统通知）
        AgentTaskNotificationStore.save(agentTasks)
    }

    /// 任务进入终态时触发完成播报（同一任务同一终态只播报一次）
    private func notifyCompletion(
        taskId: String,
        text: String,
        kind: QwenTaskFeedItem.Kind
    ) {
        let key = "\(taskId):\(kind)"
        guard noticedTaskIds.insert(key).inserted else { return }
        // 优先重听 timeline.inline 的详细结果，其次用任务标题
        if let index = agentTasks.firstIndex(where: { $0.taskId == taskId }),
           let result = agentTasks[index].resultText,
           !result.isEmpty {
            lastTaskResultText = result
            // 详细结果作为追问上下文：用户随后说「展开第三条」时随消息前置给大脑
            resultFollowUpContext = Self.followUpContextText(result)
        } else {
            // 无详细结果时用自然回归话术（如「整理报告搞定了。」），重听同样生效
            lastTaskResultText = AgentCompletionAnnouncement.text(kind: kind, title: text)
            // 没有可追问的内容（如仅「搞定了」），不注入上下文
            resultFollowUpContext = nil
        }
        lastTaskResultAt = Date()
        completionNotice = QwenTaskCompletionNotice(
            kind: kind,
            taskId: taskId,
            text: text
        )
    }

    private static func taskFeedItem(
        type: String,
        taskId: String?,
        title: String
    ) -> QwenTaskFeedItem? {
        let kind: QwenTaskFeedItem.Kind
        switch type {
        case "task.delegated":
            kind = .delegated
        case "task.progress", "task.running", "task.scheduled", "task.finalizing", "task.cancelling":
            kind = .progress
        case "task.completed":
            kind = .completed
        case "task.failed":
            kind = .failed
        case "task.cancelled":
            kind = .cancelled
        case "task.permission.requested":
            kind = .permissionRequested
        default:
            return nil
        }
        return QwenTaskFeedItem(kind: kind, taskId: taskId, text: title)
    }

    /// 权限处理结果 → (feed 类型, 短文本)；未结束状态返回 nil
    private static func resolutionItem(
        for permission: QwenPermission
    ) -> (kind: QwenTaskFeedItem.Kind, text: String)? {
        switch permission.status {
        case .approved:
            return (.completed, "qwen.permission.approved".localized)
        case .denied:
            return (.cancelled, "qwen.permission.denied".localized)
        case .cancelled:
            return (.cancelled, "qwen.permission.cancelled".localized)
        case .pending, .unknown:
            return nil
        }
    }
}
