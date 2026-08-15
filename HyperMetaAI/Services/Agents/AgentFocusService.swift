/*
 * Agent Focus Service
 * JARVIS 专注模式（Focus）联动：感知系统专注状态，主动打扰自动避让——
 * 通知播报在专注时整体暂停，连接问候 / 提醒 / 任务完成等主动语音在专注时静音；
 * 用户显式发起的语音回复不受影响（isProactive = false 不拦截）。
 * 纯决策（AgentFocusPolicy / shouldSpeak 组合）可注入测试，系统状态经协议隔离。
 */

import Foundation
import Intents

// MARK: - 授权状态（对齐 FocusStatusCenter）

enum AgentFocusAuthorization: Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unknown

    static func from(_ status: INFocusStatusAuthorizationStatus) -> AgentFocusAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }
}

// MARK: - 专注状态提供（测试注入 Mock）

protocol AgentFocusProviding {
    var authorization: AgentFocusAuthorization { get }
    /// 当前是否处于专注模式；nil = 未知（未授权 / 系统未共享状态），按不避让处理
    var isFocusActive: Bool? { get }
    func requestAuthorization() async -> AgentFocusAuthorization
}

/// 真实实现：读取 INFocusStatusCenter（iOS 15+，首次读取需用户授权）
final class SystemFocusService: AgentFocusProviding {
    static let shared = SystemFocusService()

    private init() {}

    var authorization: AgentFocusAuthorization {
        AgentFocusAuthorization.from(INFocusStatusCenter.default.authorizationStatus)
    }

    var isFocusActive: Bool? {
        guard authorization == .authorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    func requestAuthorization() async -> AgentFocusAuthorization {
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: AgentFocusAuthorization.from(status))
            }
        }
    }
}

// MARK: - 偏好（UserDefaults 持久化，可注入 defaults 便于测试）

enum AgentFocusSettings {
    /// 总开关：JARVIS 尊重专注模式
    static let respectKey = "agent.focus.respect"
    /// 专注时整体暂停通知播报（含镜片卡 / 触觉）
    static let pauseNotificationsKey = "agent.focus.pauseNotifications"
    /// 专注时静音主动语音（问候 / 提醒 / 任务完成等，镜片卡片保留）
    static let muteProactiveTTSKey = "agent.focus.muteProactiveTTS"

    static func respect(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: respectKey) as? Bool ?? true
    }

    static func setRespect(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: respectKey)
    }

    static func pauseNotifications(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pauseNotificationsKey) as? Bool ?? true
    }

    static func setPauseNotifications(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: pauseNotificationsKey)
    }

    static func muteProactiveTTS(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: muteProactiveTTSKey) as? Bool ?? true
    }

    static func setMuteProactiveTTS(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: muteProactiveTTSKey)
    }
}

// MARK: - 纯决策（可测）

enum AgentFocusPolicy {
    /// 专注模式避让：总开关与分项开关都开启且系统状态为专注 → 避让；
    /// 未知状态（nil）按不避让处理（fail-open，避免误伤正常播报）。
    static func shouldSuppress(respectFocus: Bool, isFocusActive: Bool?) -> Bool {
        respectFocus && isFocusActive == true
    }

    /// 主动语音是否应被专注模式静音（读设置 + 系统状态）
    static var muteProactiveTTS: Bool {
        shouldSuppress(
            respectFocus: AgentFocusSettings.respect() && AgentFocusSettings.muteProactiveTTS(),
            isFocusActive: SystemFocusService.shared.isFocusActive
        )
    }

    /// 通知播报是否应整体暂停（读设置 + 系统状态）
    static var pauseNotifications: Bool {
        shouldSuppress(
            respectFocus: AgentFocusSettings.respect() && AgentFocusSettings.pauseNotifications(),
            isFocusActive: SystemFocusService.shared.isFocusActive
        )
    }
}
