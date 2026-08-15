/*
 * Agent URL Command Router
 * JARVIS URL 命令协议：把 hypermetaai:// 从单一手势触发扩展为完整命令集，
 * 让快捷指令 / 自动化 / 第三方工具都能精确唤起 JARVIS：
 *   hypermetaai://trigger?gesture=wake      手势触发（兼容既有协议）
 *   hypermetaai://ask?text=...&brain=hermes 问 JARVIS（后台单轮问答）
 *   hypermetaai://lens?text=...&speak=1     文本上镜片（可选 TTS 播报）
 *   hypermetaai://briefing                  立即播报今日晨报
 * 解析与分发为纯逻辑 / 协议注入，可测。
 */

import Foundation

// MARK: - 命令（纯值）

enum AgentURLCommand: Equatable {
    case trigger(AgentWearableGesture)
    case ask(text: String, brain: AgentAskBrainOption)
    case lens(text: String, speak: Bool)
    case briefing
}

// MARK: - 解析（纯逻辑，可测）

enum AgentURLCommandParser {
    static let scheme = "hypermetaai"
    static let hostTrigger = "trigger"
    static let hostAsk = "ask"
    static let hostLens = "lens"
    static let hostBriefing = "briefing"

    /// 解析 hypermetaai:// URL；不是 JARVIS 命令时返回 nil（留给其他处理方）
    static func parse(url: URL) -> AgentURLCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.host?.lowercased() {
        case hostTrigger:
            guard let raw = query("gesture", in: components),
                  let gesture = AgentWearableGesture(rawValue: raw) else { return nil }
            return .trigger(gesture)
        case hostAsk:
            guard let text = query("text", in: components),
                  !text.isEmpty else { return nil }
            let brain = AgentAskBrainOption(rawValue: query("brain", in: components) ?? "")
                ?? .auto
            return .ask(text: text, brain: brain)
        case hostLens:
            guard let text = query("text", in: components),
                  !text.isEmpty else { return nil }
            return .lens(text: text, speak: query("speak", in: components) == "1")
        case hostBriefing:
            return .briefing
        default:
            return nil
        }
    }

    private static func query(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }
}

// MARK: - 执行抽象（测试注入 Mock）

protocol AgentURLCommandExecuting {
    func dispatchTrigger(_ gesture: AgentWearableGesture)
    func dispatchAsk(text: String, brain: AgentAskBrainOption) async -> String
    func dispatchLens(text: String, speak: Bool)
    func dispatchBriefing() async -> String
}

/// 真实实现：分发到既有 JARVIS 服务（触发中心 / 单轮问答 / 镜片显示 / 晨报）
@MainActor
struct SystemAgentURLCommandExecutor: AgentURLCommandExecuting {
    static let shared = SystemAgentURLCommandExecutor()
    func dispatchTrigger(_ gesture: AgentWearableGesture) {
        AgentWearableTriggerCenter.shared.dispatch(source: .urlScheme, gesture: gesture)
    }

    func dispatchAsk(text: String, brain: AgentAskBrainOption) async -> String {
        let outcome = await AgentAskIntentHandler.ask(message: text, brain: brain.agentBrain)
        let dialog = AgentAskIntentFormatter.dialog(for: outcome)
        switch outcome {
        case .replied(let reply):
            AgentDisplayHub.shared.showResult(
                title: "agent.ask.lens.title".localized,
                text: reply,
                fallback: .idle
            )
        default:
            AgentDisplayHub.shared.showResult(
                title: "agent.ask.lens.title".localized,
                text: dialog,
                fallback: .idle
            )
        }
        speakText(dialog)
        return dialog
    }

    func dispatchLens(text: String, speak: Bool) {
        AgentDisplayHub.shared.showResult(
            title: "agent.url.lens.title".localized,
            text: text,
            fallback: .idle
        )
        if speak {
            speakText(text)
        }
    }

    func dispatchBriefing() async -> String {
        let content = await AgentBriefingScheduler.buildContent(
            settings: AgentBriefingStore.current
        )
        let text = content.fullText
        AgentDisplayHub.shared.showResult(
            title: "agent.briefing.section".localized,
            text: text,
            fallback: .idle
        )
        speakText(text)
        return text
    }

    /// TTS 播报：尊重语音回复开关与静默模式（URL 为显式触发，不受专注模式静音）
    private func speakText(_ text: String) {
        guard AgentVoiceSettings.replyEnabled,
              AgentQuietAnnouncementPolicy.shouldSpeak(isProactive: false) else { return }
        TTSService.shared.stop()
        TTSService.shared.speak(text)
    }
}

// MARK: - 路由（纯分发，可测）

@MainActor
enum AgentURLCommandRouter {
    /// 解析并执行；非 JARVIS 命令返回 nil（调用方继续兜底处理）
    @discardableResult
    static func dispatch(
        url: URL,
        executor: AgentURLCommandExecuting = SystemAgentURLCommandExecutor.shared
    ) async -> AgentURLCommand? {
        guard let command = AgentURLCommandParser.parse(url: url) else { return nil }
        await dispatch(command, executor: executor)
        return command
    }

    static func dispatch(
        _ command: AgentURLCommand,
        executor: AgentURLCommandExecuting
    ) async {
        switch command {
        case .trigger(let gesture):
            executor.dispatchTrigger(gesture)
        case .ask(let text, let brain):
            _ = await executor.dispatchAsk(text: text, brain: brain)
        case .lens(let text, let speak):
            executor.dispatchLens(text: text, speak: speak)
        case .briefing:
            _ = await executor.dispatchBriefing()
        }
    }
}
