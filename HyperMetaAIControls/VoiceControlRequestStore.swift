/*
 * Voice Control Request Store
 * App 与 Control Center 扩展共享的请求通道（App Group UserDefaults）。
 * 扩展进程只写标记，App 前台消费并映射到语音会话（start / stop）。
 */

import Foundation

enum VoiceControlRequest: Equatable {
    case start
    case stop
    /// 休眠中的会话恢复聆听（锁屏「唤醒」按钮 / 未来系统入口）
    case wake
}

enum VoiceControlRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "voice.control.request"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func request(_ action: VoiceControlRequest) {
        defaults.set(rawValue(action), forKey: requestKey)
    }

    static func consume() -> VoiceControlRequest? {
        guard let raw = defaults.string(forKey: requestKey) else { return nil }
        defaults.removeObject(forKey: requestKey)
        return action(from: raw)
    }

    static func rawValue(_ action: VoiceControlRequest) -> String {
        switch action {
        case .start: return "start"
        case .stop: return "stop"
        case .wake: return "wake"
        }
    }

    static func action(from raw: String) -> VoiceControlRequest {
        switch raw {
        case "start": return .start
        case "wake": return .wake
        default: return .stop
        }
    }

    static func clear() {
        defaults.removeObject(forKey: requestKey)
    }
}
