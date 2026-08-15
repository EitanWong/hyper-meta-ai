/*
 * Agent Device Trigger
 * 把眼镜物理触发（镜腿单击/长按）映射为 Agent 交互事件。
 * DAT SDK 不暴露原始 captouch 事件，只以会话状态变化呈现：
 *   单击 = 会话 paused/resumed，长按 = 会话 stopped。
 * 本模块把会话状态流翻译成 Agent 层可消费的触发事件。
 */

import Foundation
import MWDATCore
import UIKit

/// 眼镜物理触发 → Agent 交互事件
enum AgentDeviceTrigger: Equatable {
    /// 镜腿单击：会话被暂停（映射为“打断/静音”）
    case tapPause
    /// 镜腿再次单击：会话恢复（映射为“继续”）
    case tapResume
    /// 镜腿长按：会话被停止（映射为“结束当前回合”）
    case longPressStop
}

/// 把 DeviceSession 状态流翻译成 AgentDeviceTrigger 的纯逻辑检测器。
/// 独立成类型以便单元测试，不依赖 DAT 运行时。
struct AgentDeviceTriggerDetector {
    private(set) var isSessionPaused = false

    mutating func consume(
        sessionState: DeviceSessionState,
        isAppStopping: Bool
    ) -> AgentDeviceTrigger? {
        switch sessionState {
        case .paused:
            guard !isAppStopping else { return nil }
            isSessionPaused = true
            return .tapPause
        case .started:
            guard isSessionPaused else { return nil }
            isSessionPaused = false
            return .tapResume
        case .stopped:
            guard !isAppStopping else {
                isSessionPaused = false
                return nil
            }
            isSessionPaused = false
            return .longPressStop
        case .idle, .starting, .stopping:
            return nil
        @unknown default:
            return nil
        }
    }

    mutating func reset() {
        isSessionPaused = false
    }
}

/// 设备会话"意外结束"判定（纯逻辑）：stopped 且非 App 主动停止。
/// 用于区分用户长按结束与眼镜断开，驱动断开降级提示。
enum AgentDeviceEndDetector {
    static func isUnexpectedEnd(
        sessionState: DeviceSessionState,
        isAppStopping: Bool
    ) -> Bool {
        sessionState == .stopped && !isAppStopping
    }
}

/// Agent 语音交互偏好（UserDefaults 持久化）
enum AgentVoiceSettings {
    static let replyEnabledKey = "agent.voice.reply.enabled"
    static let approvalPromptEnabledKey = "agent.voice.approval.prompt.enabled"
    static let quietModeEnabledKey = "agent.voice.quiet.enabled"

    static var replyEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: replyEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: replyEnabledKey)
        }
    }

    /// 审批到达语音提醒（大脑转发模式；网关不播报输出时由 TTS 提示看镜片）
    static var approvalPromptEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: approvalPromptEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: approvalPromptEnabledKey)
        }
    }

    /// 静默模式：抑制 Agent「主动打扰」类播报（任务完成回归 / 审批到达提醒 /
    /// 思考超时提示 / 提醒到点播报），直接回复与本地指令即时反馈不受影响。
    /// 镜片卡片与手机触觉反馈始终保留。
    static var quietModeEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: quietModeEnabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: quietModeEnabledKey)
        }
    }
}

/// 主动播报策略（纯逻辑，可测）：
/// 静默模式下仅抑制 `isProactive = true` 的播报（Agent 主动开口），
/// 用户直接询问 / 本地指令的即时反馈（`isProactive = false`）始终播报；
/// 开启「尊重专注模式」时，专注中的主动播报同样静音（显式回复不受影响）。
enum AgentQuietAnnouncementPolicy {
    static func shouldSpeak(
        isProactive: Bool,
        respectFocus: Bool = false,
        isFocusActive: Bool? = nil
    ) -> Bool {
        if isProactive, respectFocus, isFocusActive == true { return false }
        return !isProactive || !AgentVoiceSettings.quietModeEnabled
    }

    /// 主动播报快捷入口：叠加专注模式设置与系统专注状态（静默模式约束不变）
    static func shouldSpeakProactive() -> Bool {
        shouldSpeak(
            isProactive: true,
            respectFocus: AgentFocusSettings.respect() && AgentFocusSettings.muteProactiveTTS(),
            isFocusActive: SystemFocusService.shared.isFocusActive
        )
    }
}

/// Agent 持续在场偏好（UserDefaults 持久化）：
/// 开启后语音回合结束不退出，Agent 保持在场聆听；长按或说「结束对话」显式退出。
enum AgentPresenceSettings {
    static let presenceEnabledKey = "agent.presence.enabled"

    static var presenceEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: presenceEnabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: presenceEnabledKey)
        }
    }
}

/// 权限审批分级模式（对齐 qwen-audio-agent 的权限模式思路）
enum AgentPermissionMode: String, CaseIterable, Equatable {
    /// 始终询问（默认）：每个权限请求都弹审批卡
    case alwaysAsk
    /// 单次：同一权限首次请求弹卡，批准后本会话内该权限自动放行
    case singleUse
    /// 会话内：本会话所有权限请求自动放行（会话结束失效）
    case session
    /// 始终放行：持久生效（仍受撤销策略约束）
    case alwaysAllow
    /// 全部拒绝：自动拒绝并审计，不弹卡
    case denyAll

    var displayName: String {
        switch self {
        case .alwaysAsk: return "agent.permission.mode.alwaysAsk".localized
        case .singleUse: return "agent.permission.mode.singleUse".localized
        case .session: return "agent.permission.mode.session".localized
        case .alwaysAllow: return "agent.permission.mode.alwaysAllow".localized
        case .denyAll: return "agent.permission.mode.denyAll".localized
        }
    }

    var detail: String {
        switch self {
        case .alwaysAsk: return "agent.permission.mode.alwaysAsk.detail".localized
        case .singleUse: return "agent.permission.mode.singleUse.detail".localized
        case .session: return "agent.permission.mode.session.detail".localized
        case .alwaysAllow: return "agent.permission.mode.alwaysAllow.detail".localized
        case .denyAll: return "agent.permission.mode.denyAll.detail".localized
        }
    }
}

/// 权限分级偏好（UserDefaults 持久化）
enum AgentPermissionSettings {
    static let modeKey = "agent.permission.mode"

    static var mode: AgentPermissionMode {
        get {
            UserDefaults.standard
                .string(forKey: modeKey)
                .flatMap(AgentPermissionMode.init(rawValue:)) ?? .alwaysAsk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }
}

/// Agent 视野注入偏好（UserDefaults 持久化）
enum AgentVisionSettings {
    static let injectionEnabledKey = "agent.vision.injection.enabled"
    static let followUpEnabledKey = "agent.vision.followup.enabled"

    static var injectionEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: injectionEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: injectionEnabledKey)
        }
    }

    /// 视野连续追问：聊天页发送照片后，后续追问自动携带同一帧
    static var followUpEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: followUpEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: followUpEnabledKey)
        }
    }
}

/// 语音页新手引导（UserDefaults 持久化，看过一次后不再显示）
enum AgentOnboardingSettings {
    static let voiceHintSeenKey = "agent.onboarding.voice.seen"

    static var voiceHintSeen: Bool {
        get {
            UserDefaults.standard.bool(forKey: voiceHintSeenKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: voiceHintSeenKey)
        }
    }
}

/// Agent 交互时序偏好（UserDefaults 持久化）
enum AgentTimingSettings {
    static let approvalTimeoutKey = "agent.timing.approval.timeout"
    static let thinkingHintDelayKey = "agent.timing.thinking.hint.delay"

    /// 权限审批超时（秒）；0 = 不自动跳过
    static var approvalTimeout: TimeInterval {
        get {
            UserDefaults.standard.object(forKey: approvalTimeoutKey) as? TimeInterval ?? 60
        }
        set {
            UserDefaults.standard.set(newValue, forKey: approvalTimeoutKey)
        }
    }

    /// 思考超时提示延迟（秒）
    static var thinkingHintDelay: TimeInterval {
        get {
            UserDefaults.standard.object(forKey: thinkingHintDelayKey) as? TimeInterval ?? 8
        }
        set {
            UserDefaults.standard.set(newValue, forKey: thinkingHintDelayKey)
        }
    }
}

/// 审批卡超时倒计时的纯计算（不依赖 UI 定时器，可测）
enum AgentPermissionCountdown {
    /// 剩余秒数（向上取整，至少为 1 秒的展示粒度）；无截止时间或已超时返回 0
    static func remainingSeconds(
        expiresAt: Date?,
        now: Date = Date()
    ) -> Int {
        guard let expiresAt else { return 0 }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int(ceil(remaining))
    }

    /// 倒计时进度 0-1（1 = 刚开始，0 = 已超时），供进度条展示
    static func progressFraction(
        expiresAt: Date?,
        now: Date = Date(),
        timeout: TimeInterval
    ) -> Double {
        guard let expiresAt, timeout > 0 else { return 0 }
        let elapsed = timeout - expiresAt.timeIntervalSince(now)
        return min(1, max(0, elapsed / timeout))
    }
}

/// Agent 会话记忆偏好（UserDefaults 持久化）
enum AgentMemorySettings {
    /// 长期记忆开关（跨会话注入 Hermes / 自定义 Agent）
    static let enabledKey = "agent.memory.enabled"

    static var enabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static let voiceHistoryEnabledKey = "agent.memory.voice.history.enabled"
    static let chatHistoryEnabledKey = "agent.memory.chat.history.enabled"

    /// 进入语音页时自动恢复上次会话历史（默认开）
    static var voiceHistoryEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: voiceHistoryEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: voiceHistoryEnabledKey)
        }
    }

    /// 进入聊天页时自动恢复该 Agent 的最近会话（默认开）
    static var chatHistoryEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: chatHistoryEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: chatHistoryEnabledKey)
        }
    }
}

/// 眼镜触发后的手机端触觉反馈（戴眼镜时主要靠震动确认交互已传达）
enum AgentTriggerFeedback {
    private static var impactGenerator = UIImpactFeedbackGenerator(style: .medium)

    static func play(for trigger: AgentDeviceTrigger) {
        play()
    }

    /// 通用确认触觉反馈（触发中心 / 演示按钮等非回合触发使用）
    static func play() {
        let generator = impactGenerator
        generator.prepare()
        generator.impactOccurred()
    }
}
