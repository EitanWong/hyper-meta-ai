/*
 * Agent Turn State Machine
 * 统一「眼镜物理触发 × Agent 回合」的交互语义，供文字聊天与实时语音共用。
 *
 * 回合（Turn）生命周期：
 *   idle →（单击）listening → thinking → speaking → listening
 *   任意非 idle 状态 → idle（再次单击或长按：结束回合）
 *
 * 状态机只描述“应该做什么”，不持有硬件/网络副作用，便于单元测试。
 */

import Foundation

/// 一个 Agent 回合的交互阶段
enum AgentTurnPhase: Equatable {
    /// 无进行中的回合
    case idle
    /// 聆听用户输入
    case listening
    /// Agent 正在思考（无音频输出）
    case thinking
    /// Agent 正在播报/输出
    case speaking
    /// 内部输出中断保护态：迟到输出只入历史，不改变当前会话开关
    case interrupted
    /// 后台任务请求权限：等待用户在手机端确认；镜腿触控仍可结束当前 Session。
    case approval
}

/// 状态机输出的交互命令（由上层执行副作用）
enum AgentTurnCommand: Equatable {
    /// idle 时单击：唤醒新回合（开始聆听/打开输入）
    case wake
    /// 打断当前输出并静音输入
    case interrupt
    /// 恢复输入聆听
    case resume
    /// 结束当前回合
    case endTurn
    /// 无需动作
    case none
}

/// 统一交互状态机：消费眼镜触发与 Agent 输出事件，产出交互命令。
struct AgentTurnStateMachine {
    private(set) var phase: AgentTurnPhase = .idle

    /// 消费一个眼镜物理触发事件
    mutating func handle(trigger: AgentDeviceTrigger) -> AgentTurnCommand {
        switch trigger {
        case .tapStartSession, .tapEndSession:
            return toggleSession()
        case .longPressStop:
            return longPressTapped()
        }
    }

    /// Agent 开始输出（收到回复/开始播报）
    mutating func outputStarted() {
        switch phase {
        case .interrupted:
            // 被打断期间的迟到输出仍算被打断，不切换阶段
            break
        case .approval:
            // 等待授权期间的新输出不打断审批提示
            break
        default:
            phase = .speaking
        }
    }

    /// The backend accepted the turn but has not produced audible output yet.
    mutating func thinkingStarted() {
        switch phase {
        case .listening, .speaking, .thinking:
            phase = .thinking
        case .idle, .interrupted, .approval:
            break
        }
    }

    /// Agent 输出结束
    mutating func outputEnded() {
        switch phase {
        case .speaking:
            phase = .listening
        case .interrupted, .approval:
            break
        default:
            break
        }
    }

    /// Agent 请求执行权限：进入等待确认阶段（idle/已等待时不切换）
    mutating func permissionRequested() {
        guard phase != .idle, phase != .approval else { return }
        phase = .approval
    }

    /// 权限已处理（授权/拒绝/取消）：回到思考阶段
    mutating func permissionResolved() {
        guard phase == .approval else { return }
        phase = .thinking
    }

    /// 回合开始（用户开始说话/新回合）
    mutating func turnStarted() {
        phase = .listening
    }

    /// 回合结束（无论何种原因）
    mutating func turnEnded() {
        phase = .idle
    }

    mutating func reset() {
        phase = .idle
    }

    // MARK: - Triggers

    private mutating func toggleSession() -> AgentTurnCommand {
        if phase == .idle {
            phase = .listening
            return .wake
        }
        phase = .idle
        return .endTurn
    }

    private mutating func longPressTapped() -> AgentTurnCommand {
        guard phase != .idle else {
            return .none
        }
        phase = .idle
        return .endTurn
    }
}
