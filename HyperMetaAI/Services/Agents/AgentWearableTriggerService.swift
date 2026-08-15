/*
 * Agent Wearable Trigger Service
 * JARVIS 触发中心：统一「眼镜物理触发 × Apple 原生触发源」的事件模型、
 * 去抖路由、URL 触发解析与触发日志。
 *
 * 纯逻辑部分（Source / Gesture / Outcome / Router / URL 解析 / LogStore /
 * Formatter）不依赖 DAT SDK 运行时，便于单元测试；
 * AgentWearableTriggerCenter 负责副作用（语音会话 / 快速识图 / 触觉反馈），
 * 全部走既有路由（VoiceAssistantRouter / QwenVoiceSession / QuickVisionManager）。
 */

import Foundation
import UIKit

// MARK: - 触发源

/// JARVIS 触发来源（记录到触发日志，供审计展示）
enum AgentWearableSource: String, CaseIterable, Codable, Equatable {
    /// 镜腿物理触发（经 DAT 会话状态推断：单击暂停/恢复、长按结束）
    case glassesSession
    /// 镜片菜单点击（Display onTap，Display 眼镜）
    case glassesDisplay
    /// 模拟镜腿（Mock 设备，开发 / 演示）
    case mockCaptouch
    /// iPhone 背部轻点（辅助功能 → 快捷指令 → App Intent）
    case backTap
    /// iPhone 操作按钮（Action Button → 快捷指令 → App Intent）
    case actionButton
    /// Siri / 快捷指令 App（App Intent 直达）
    case shortcut
    /// hypermetaai://trigger 通用 URL 触发
    case urlScheme
    /// App 内演示按钮
    case inApp

    var displayName: String {
        "agent.wearable.source.\(rawValue)".localized
    }

    var iconName: String {
        switch self {
        case .glassesSession, .glassesDisplay:
            return "eyeglasses"
        case .mockCaptouch:
            return "hand.tap"
        case .backTap:
            return "hand.tap.fill"
        case .actionButton:
            return "button.programmable"
        case .shortcut:
            return "square.grid.2x2"
        case .urlScheme:
            return "link"
        case .inApp:
            return "app.badge"
        }
    }
}

// MARK: - 触发手势

/// 统一触发手势（与具体来源解耦）
enum AgentWearableGesture: String, CaseIterable, Codable, Equatable {
    /// 唤醒 / 开始新回合（空闲时 = 唤醒，活跃时 = 恢复聆听）
    case wake
    /// 打断当前输出并静音输入
    case interrupt
    /// 恢复输入聆听
    case resume
    /// 结束当前回合
    case endTurn
    /// 眼镜拍照并把视野送入识图（JARVIS「我眼前是什么」）
    case captureVision
    /// 重听最近一条助手回复
    case repeatLastReply
    /// 模拟镜腿单击（演示 / 测试）
    case mockTap
    /// 模拟镜腿长按（演示 / 测试）
    case mockTapAndHold

    var displayName: String {
        "agent.wearable.gesture.\(rawValue)".localized
    }
}

// MARK: - 路由结果

/// 触发路由结果（由上层执行副作用）
enum AgentWearableOutcome: Equatable {
    /// 回合控制命令（唤醒 / 打断 / 恢复 / 结束）
    case turn(AgentTurnCommand)
    /// 拍照识图（眼镜拍照 → 视野分析）
    case captureVision
    /// 重听最近回复
    case repeatLastReply
    /// 新建会话
    case newChat
    /// 关闭眼镜菜单
    case dismissMenu
    /// 触发被忽略（去抖 / 无活动会话）
    case ignored(AgentWearableIgnoreReason)

    var isIgnored: Bool {
        if case .ignored = self { return true }
        return false
    }

    /// 稳定日志编码（跨语言，供审计存储与展示）
    var code: String {
        switch self {
        case .turn(let command):
            switch command {
            case .wake: return "wake"
            case .interrupt: return "interrupt"
            case .resume: return "resume"
            case .endTurn: return "endTurn"
            case .none: return "none"
            }
        case .captureVision: return "captureVision"
        case .repeatLastReply: return "repeatLastReply"
        case .newChat: return "newChat"
        case .dismissMenu: return "dismiss"
        case .ignored(.cooldown): return "ignored.cooldown"
        case .ignored(.noActiveSession): return "ignored.noActiveSession"
        }
    }
}

/// 触发被忽略的原因
enum AgentWearableIgnoreReason: Equatable {
    /// 同一来源同一手势在去抖窗口内重复触发（防 Back Tap 与眼镜双触发）
    case cooldown
    /// 需要进行中的语音会话，但会话未激活
    case noActiveSession
}

// MARK: - 路由（含去抖）

/// 触发路由：来源 × 手势 → 结果；对同一来源同一手势做去抖。
struct AgentWearableTriggerRouter {
    /// 去抖窗口（秒）：短于该间隔的同源同手势视为重复触发
    static let cooldownInterval: TimeInterval = 0.8

    private(set) var lastEvent: (source: AgentWearableSource, gesture: AgentWearableGesture, date: Date)?

    mutating func route(
        source: AgentWearableSource,
        gesture: AgentWearableGesture,
        isSessionActive: Bool,
        now: Date = Date()
    ) -> AgentWearableOutcome {
        if let last = lastEvent,
           last.source == source,
           last.gesture == gesture,
           now.timeIntervalSince(last.date) < Self.cooldownInterval {
            return .ignored(.cooldown)
        }
        lastEvent = (source, gesture, now)

        switch gesture {
        case .wake:
            // 空闲唤醒 / 活跃恢复聆听：QwenVoiceSession.wake() 语义一致
            return .turn(.wake)
        case .interrupt:
            return isSessionActive ? .turn(.interrupt) : .ignored(.noActiveSession)
        case .resume:
            return isSessionActive ? .turn(.resume) : .ignored(.noActiveSession)
        case .endTurn:
            return isSessionActive ? .turn(.endTurn) : .ignored(.noActiveSession)
        case .captureVision:
            return .captureVision
        case .repeatLastReply:
            return isSessionActive ? .repeatLastReply : .ignored(.noActiveSession)
        case .mockTap:
            // 模拟镜腿单击 = 唤醒（与真实眼镜单击语义一致）
            return .turn(.wake)
        case .mockTapAndHold:
            return isSessionActive ? .turn(.endTurn) : .ignored(.noActiveSession)
        }
    }

    mutating func reset() {
        lastEvent = nil
    }
}

// MARK: - URL 触发解析

/// hypermetaai://trigger?gesture=wake 通用触发入口（纯逻辑，可测）
enum AgentWearableURLTrigger {
    static let scheme = "hypermetaai"
    static let host = "trigger"

    static func parse(url: URL) -> AgentWearableGesture? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "gesture" })?.value,
              let gesture = AgentWearableGesture(rawValue: raw) else { return nil }
        return gesture
    }
}

// MARK: - 触发日志

/// 一条触发审计记录（纯值，可持久化）
struct AgentWearableLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let source: AgentWearableSource
    let gesture: AgentWearableGesture
    let outcomeCode: String
    let timestamp: Date
}

/// 触发日志存储（UserDefaults，最新在前，上限 50 条）
enum AgentWearableLogStore {
    static let maxEntries = 50
    private static let storageKey = "agent.wearable.log.entries.v1"

    static func load(defaults: UserDefaults = .standard) -> [AgentWearableLogEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([AgentWearableLogEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [AgentWearableLogEntry], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    @discardableResult
    static func add(
        _ entry: AgentWearableLogEntry,
        defaults: UserDefaults = .standard
    ) -> [AgentWearableLogEntry] {
        var entries = load(defaults: defaults)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries, defaults: defaults)
        return entries
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

// MARK: - 日志展示

/// 触发日志文案（纯逻辑，可测）
enum AgentWearableLogFormatter {
    /// 结果编码 → 本地化文案
    static func outcomeText(code: String) -> String {
        switch code {
        case "wake": return "agent.wearable.outcome.wake".localized
        case "interrupt": return "agent.wearable.outcome.interrupt".localized
        case "resume": return "agent.wearable.outcome.resume".localized
        case "endTurn": return "agent.wearable.outcome.endTurn".localized
        case "captureVision": return "agent.wearable.outcome.captureVision".localized
        case "repeatLastReply": return "agent.wearable.outcome.repeatLastReply".localized
        case "newChat": return "agent.wearable.outcome.newChat".localized
        case "dismiss": return "agent.wearable.outcome.dismiss".localized
        case "ignored.cooldown": return "agent.wearable.outcome.ignored.cooldown".localized
        case "ignored.noActiveSession": return "agent.wearable.outcome.ignored.noActiveSession".localized
        default: return code
        }
    }

    /// 日志行主标题：来源 · 手势
    static func rowTitle(_ entry: AgentWearableLogEntry) -> String {
        "\(entry.source.displayName) · \(entry.gesture.displayName)"
    }

    /// 日志行副标题：路由结果
    static func rowDetail(_ entry: AgentWearableLogEntry) -> String {
        outcomeText(code: entry.outcomeCode)
    }

    /// 相对时间文案
    static func relativeTime(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "agent.wearable.log.relative.justNow".localized
        }
        if interval < 3600 {
            return "agent.wearable.log.relative.minutes".localized(Int(interval / 60))
        }
        if calendar.isDateInYesterday(date) {
            return "agent.wearable.log.relative.yesterday".localized
        }
        if interval < 86400 {
            return "agent.wearable.log.relative.hours".localized(Int(interval / 3600))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - 触发中心（副作用）

/// JARVIS 触发中心：统一分发所有来源的触发，写审计日志并执行副作用。
@MainActor
final class AgentWearableTriggerCenter: ObservableObject {
    static let shared = AgentWearableTriggerCenter()

    /// 重听回复请求（语音页 / 聊天页监听后朗读最近一条助手回复）
    static let repeatReplyNotification = Notification.Name("agent.wearable.trigger.repeatReply")

    @Published private(set) var entries: [AgentWearableLogEntry] = []
    private var router = AgentWearableTriggerRouter()

    private init() {
        entries = AgentWearableLogStore.load()
    }

    var lastTrigger: AgentWearableLogEntry? {
        entries.first
    }

    /// 分发一次触发：路由 → 审计 → 副作用。返回路由结果（测试与调用方判定用）。
    @discardableResult
    func dispatch(
        source: AgentWearableSource,
        gesture: AgentWearableGesture,
        now: Date = Date()
    ) -> AgentWearableOutcome {
        let outcome = router.route(
            source: source,
            gesture: gesture,
            isSessionActive: QwenVoiceSession.shared.isActive,
            now: now
        )
        let entry = AgentWearableLogEntry(
            id: UUID(),
            source: source,
            gesture: gesture,
            outcomeCode: outcome.code,
            timestamp: now
        )
        entries = AgentWearableLogStore.add(entry)
        apply(outcome)
        return outcome
    }

    func clearLog() {
        AgentWearableLogStore.clear()
        entries = []
    }

    private func apply(_ outcome: AgentWearableOutcome) {
        switch outcome {
        case .turn(let command):
            AgentTriggerFeedback.play()
            switch command {
            case .wake:
                // 空闲唤醒 + 请 Home 页呈现语音会话（请求在用户回到首页时被消费）
                VoiceAssistantRouter.shared.requestVoiceSession()
                QwenVoiceSession.shared.wake()
            case .interrupt:
                QwenVoiceSession.shared.interrupt()
            case .resume:
                QwenVoiceSession.shared.resume()
            case .endTurn:
                QwenVoiceSession.shared.endSession()
            case .none:
                break
            }
        case .captureVision:
            AgentTriggerFeedback.play()
            Task { @MainActor in
                await QuickVisionManager.shared.performQuickVisionWithMode(
                    .standard,
                    deferUntilStreamConfigured: true
                )
            }
        case .repeatLastReply:
            NotificationCenter.default.post(name: Self.repeatReplyNotification, object: nil)
        case .newChat, .dismissMenu, .ignored:
            break
        }
    }
}
