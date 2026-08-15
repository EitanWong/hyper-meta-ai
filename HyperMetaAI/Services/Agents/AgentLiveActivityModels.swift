/*
 * Agent Live Activity Models
 * 任务进度 / 审批状态 / 提醒倒计时 → 锁屏与灵动岛的 Live Activity 内容模型。
 * 本文件需同时编译进 App 与 Widget 扩展（ActivityKit 要求两端类型一致），
 * 因此不依赖任何 App 侧扩展（如 String.localized），文案由 App 侧生成后传入。
 */

import ActivityKit
import Foundation

/// Live Activity 属性（常量部分，当前无固定属性）
struct AgentLiveActivityAttributes: ActivityAttributes {
    /// 动态内容状态（App 侧每次更新替换整个状态）
    struct ContentState: Codable, Hashable {
        /// 展示模式
        var mode: Mode
        /// 标题（本地化文案，由 App 生成）
        var title: String
        /// 详情：任务步骤 / 审批摘要 / 结果摘要 / 提醒内容
        var detail: String
        /// 进行中任务数（taskProgress 模式用）
        var taskCount: Int
        /// 审批截止时间（approval 模式用，锁屏显示倒计时）
        var approvalExpiresAt: Date?
        /// 倒计时目标时间（reminderCountdown / calendarCountdown 模式用，系统自动走秒）
        var countdownFireDate: Date?
        /// 结果类型（result 模式用：completed / failed / cancelled；nil = 旧活动兼容）
        var resultKind: String?
        /// 语音会话状态文案（voiceSession 模式用，App 侧生成：聆听 / 思考 / 回复 / 休眠 / 连接）
        var voiceStatus: String?
        /// 语音会话阶段（voiceSession 模式用，扩展据此渲染「唤醒」按钮；nil = 旧活动兼容）
        var voicePhase: String?
    }

    /// 任务终态类型（result 模式；扩展进程据此渲染「重试 / 追问」按钮）
    enum ResultKind: String, Codable, Hashable {
        case completed
        case failed
        case cancelled
    }

    enum Mode: String, Codable, Hashable {
        /// 任务进行中
        case taskProgress
        /// 审批待确认
        case approval
        /// 任务终态（短暂展示后自动结束）
        case result
        /// 提醒倒计时（最近一条一次性提醒，到点由本地通知接力）
        case reminderCountdown
        /// 日程倒计时（下一个即将开始的日历日程）
        case calendarCountdown
        /// 语音会话进行中（聆听 / 思考 / 回复 / 休眠 / 连接，锁屏可停止 / 唤醒）
        case voiceSession
    }

    /// 语音会话阶段（与 App 侧 `AgentVoiceLiveActivityStatus` 同一语义，扩展据此渲染按钮）
    enum VoicePhase: String, Codable, Hashable {
        case listening
        case thinking
        case speaking
        case sleeping
        case connecting
        case failed
    }

    /// 语音波形模式（纯逻辑，可测）：
    /// 按会话阶段输出确定性高度序列（0-1 归一化），扩展据此渲染波形动画——
    /// 播报高幅快动、聆听中幅、思考低幅微动、休眠 / 连接 / 失败近乎静止。
    enum VoiceWaveformPattern {
        /// 竖条数量（扩展渲染固定使用，测试断言一致性）
        static let barCount = 7

        /// 阶段振幅（0-1）：波形活跃度的上限
        static func amplitude(for phase: VoicePhase) -> Double {
            switch phase {
            case .speaking: return 0.9
            case .listening: return 0.5
            case .thinking: return 0.28
            case .connecting: return 0.16
            case .sleeping: return 0.12
            case .failed: return 0.1
            }
        }

        /// 阶段动画速度（每秒波动周期数）：活跃阶段更快
        static func speed(for phase: VoicePhase) -> Double {
            switch phase {
            case .speaking: return 2.2
            case .listening: return 1.6
            case .thinking: return 0.8
            case .connecting: return 0.5
            case .sleeping: return 0.4
            case .failed: return 0.3
            }
        }

        /// 确定性高度序列（0-1）：同一 (phase, t, seed) 输出恒定；
        /// 竖条间相位错开形成流动感，静止阶段各条趋于一致低位。
        static func heights(
            phase: VoicePhase,
            t: Double,
            seed: Int = 0
        ) -> [Double] {
            let amp = amplitude(for: phase)
            let freq = speed(for: phase)
            return (0..<Self.barCount).map { index in
                let phaseOffset = Double(index) * 0.9 + Double(seed)
                let main = (sin(t * freq * .pi * 2 + phaseOffset) + 1) / 2
                let secondary = (sin(t * freq * 1.7 + phaseOffset * 2.3) + 1) / 2
                // 中心基准 + 波动，静止阶段整体低平
                let base = 0.5 * amp + 0.18
                let height = base + 0.32 * amp * main + 0.12 * amp * secondary
                return min(1.0, max(0.06, height))
            }
        }
    }
}
