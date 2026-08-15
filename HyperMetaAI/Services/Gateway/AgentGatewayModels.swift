/*
 * Agent Gateway Models
 * 内置网关（对齐 qwen-audio-agent v1.8.3 server/src）的核心数据模型：
 *   - 非阻塞工作单元（spawn_thinking 语义）：受理立即返回，后台 FIFO 执行
 *   - 协调协议结果：state / mode / presentation（speech + inline）
 * 纯值模型，便于单元测试。
 */

import Foundation

// MARK: - 工作状态

/// 后台工作状态（对应 task-manager 的 queued / running / completed / failed / cancelled）
enum AgentGatewayWorkStatus: String, Equatable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }

    var isActive: Bool {
        self == .queued || self == .running
    }
}

// MARK: - 协调协议呈现

/// 适合屏幕查看的内联结果（title + markdown/code/link 内容）
struct AgentGatewayInlineResult: Equatable {
    enum Format: String, Equatable {
        case markdown
        case code
        case link
    }

    let title: String
    let format: Format
    let content: String
}

/// 最终呈现：语音（speech，必须）与可选的屏幕内联结果
struct AgentGatewayPresentation: Equatable {
    let speech: String
    let inline: AgentGatewayInlineResult?
}

// MARK: - 协调决策

/// 后端协调决策（qwen_audio_agent_protocol 解析结果）
struct AgentGatewayDecision: Equatable {
    enum State: String, Equatable {
        case completed
        case delegated
    }

    enum Mode: String, Equatable {
        case respond
        case delegate
    }

    let workId: String
    let state: State
    let mode: Mode
    let presentation: AgentGatewayPresentation
}

// MARK: - 工作单元

/// 一次后台工作（受理后立即返回，执行结果稍后呈现）
struct AgentGatewayWork: Identifiable, Equatable {
    let id: String
    var owner: String
    var objective: String
    var status: AgentGatewayWorkStatus
    var presentation: AgentGatewayPresentation?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var attemptCount: Int

    init(
        id: String = UUID().uuidString,
        owner: String,
        objective: String,
        status: AgentGatewayWorkStatus = .queued,
        presentation: AgentGatewayPresentation? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.owner = owner
        self.objective = objective
        self.status = status
        self.presentation = presentation
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.attemptCount = attemptCount
    }
}

// MARK: - 协调上下文

/// 记忆记录（对应 frontend memory 的 scope/format/content）
struct AgentGatewayMemoryRecord: Equatable {
    let scope: String
    let format: String
    let content: String

    init(scope: String, format: String = "markdown", content: String) {
        self.scope = scope
        self.format = format
        self.content = content
    }
}

/// 会话上下文消息（协调提示词最近 10 条）
struct AgentGatewayConversationMessage: Equatable {
    enum Role: String, Equatable {
        case user
        case assistant
    }

    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// 活动任务快照（协调提示词 voice_work_context）
struct AgentGatewayTaskSnapshot: Equatable {
    let objective: String
    let status: String
    let result: String?

    init(objective: String, status: String, result: String? = nil) {
        self.objective = objective
        self.status = status
        self.result = result
    }
}

/// 一次协调执行的上下文（内置网关组装提示词）
struct AgentGatewayRunContext: Equatable {
    var originalRequest: String
    var memories: [AgentGatewayMemoryRecord]
    var conversation: [AgentGatewayConversationMessage]
    var activeTasks: [AgentGatewayTaskSnapshot]
    var timeZone: String
    var workingDirectory: String?
    var voiceConnected: Bool
    var allowStatus: Bool

    init(
        originalRequest: String = "",
        memories: [AgentGatewayMemoryRecord] = [],
        conversation: [AgentGatewayConversationMessage] = [],
        activeTasks: [AgentGatewayTaskSnapshot] = [],
        timeZone: String = TimeZone.current.identifier,
        workingDirectory: String? = nil,
        voiceConnected: Bool = true,
        allowStatus: Bool = false
    ) {
        self.originalRequest = originalRequest
        self.memories = memories
        self.conversation = conversation
        self.activeTasks = activeTasks
        self.timeZone = timeZone
        self.workingDirectory = workingDirectory
        self.voiceConnected = voiceConnected
        self.allowStatus = allowStatus
    }
}

// MARK: - 执行结果 / 公告

/// 后端执行一次协调回合的原始结果
struct AgentGatewayRunResult: Equatable {
    let content: String
    let failed: Bool
    let errorMessage: String?

    init(content: String, failed: Bool = false, errorMessage: String? = nil) {
        self.content = content
        self.failed = failed
        self.errorMessage = errorMessage
    }
}

/// 工作终态公告（完成 / 失败 / 取消），由前端在安全插入窗口播报
struct AgentGatewayAnnouncement: Equatable, Identifiable {
    enum Kind: Equatable {
        case completed(workId: String, objective: String)
        case failed(workId: String, objective: String, reason: String)
        case cancelled(workId: String, objective: String)
    }

    let kind: Kind
    let speech: String
    let date: Date

    var id: String {
        switch kind {
        case .completed(let workId, _): return "completed:\(workId)"
        case .failed(let workId, _, _): return "failed:\(workId)"
        case .cancelled(let workId, _): return "cancelled:\(workId)"
        }
    }

    init(kind: Kind, speech: String, date: Date = Date()) {
        self.kind = kind
        self.speech = speech
        self.date = date
    }
}

/// 内置网关错误（本地化文案，可测）
enum AgentGatewayError: LocalizedError, Equatable {
    case emptyObjective
    case queueFull
    case duplicateWork
    case backendUnavailable
    case backendFailed(String)
    case coordinatorDidNotFinish(state: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .emptyObjective:
            return "agent.gateway.error.empty".localized
        case .queueFull:
            return "agent.gateway.error.queue.full".localized
        case .duplicateWork:
            return "agent.gateway.error.duplicate".localized
        case .backendUnavailable:
            return "agent.gateway.error.backend.unavailable".localized
        case .backendFailed(let reason):
            return String(format: "agent.gateway.error.backend.failed".localized, reason)
        case .coordinatorDidNotFinish(let state):
            return String(format: "agent.gateway.error.not.finished".localized, state)
        case .timeout:
            return "agent.gateway.error.timeout".localized
        }
    }
}

/// 内置网关所有者（对齐 acp-backend-session-utils 的 owner 默认值）
enum AgentGatewayOwner {
    static let personal = "personal"
}
