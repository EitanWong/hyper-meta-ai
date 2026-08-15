/*
 * Agent Diagnostics Report
 * 一键生成设备 / App / Agent 连接与权限的诊断文本报告（设置页 → 诊断报告）。
 * build(_:) 为纯逻辑、可注入输入，便于单元测试；current() 汇总真实状态。
 * 安全约束：API Key / Token 只输出「已配置 / 未配置」，绝不写入原文。
 */

import Foundation
import UIKit

/// 诊断报告构建器（纯逻辑，可测）
enum AgentDiagnosticsReport {
    /// 敏感值的掩码展示
    static let secretMask = "••••••"

    struct OpenClawInfo {
        var enabled: Bool
        var host: String
        var port: Int
        var usesTLS: Bool
        var tokenConfigured: Bool
    }

    struct HermesInfo {
        var enabled: Bool
        var host: String
        var port: Int
        var usesTLS: Bool
        var model: String
    }

    struct CustomAgentInfo {
        var name: String
        var baseURL: String
        var model: String
        var transport: String
        var apiKeyConfigured: Bool
    }

    struct Input {
        var appName: String
        var appVersion: String
        var buildNumber: String
        var systemVersion: String
        var deviceModel: String
        var defaultBrain: String
        var presenceEnabled: Bool
        var quietModeEnabled: Bool
        var replyEnabled: Bool
        var approvalPromptEnabled: Bool
        var permissionMode: String
        var memoryEnabled: Bool
        var memoryCount: Int
        var ruleCount: Int
        var listCount: Int
        var visionInjectionEnabled: Bool
        var visionFollowUpEnabled: Bool
        var approvalTimeout: TimeInterval
        var thinkingHintDelay: TimeInterval
        var qwenGatewayConfigured: Bool
        var qwenEndpoint: String
        var openClaw: OpenClawInfo
        var hermes: HermesInfo
        var customAgents: [CustomAgentInfo]
        var registeredToolCount: Int
        var sensitiveToolCount: Int
        var revokedToolIDs: Set<String>
        var auditCount: Int
        var reminderCount: Int
    }

    /// 汇总当前真实状态（App 侧取值入口；服务配置为主线程隔离的 @Published 属性）
    @MainActor
    static func current() -> Input {
        let customAgents = CustomAgentStore.configs.map { config in
            CustomAgentInfo(
                name: config.name,
                baseURL: config.baseURL,
                model: config.model,
                transport: config.transport == .websocket ? "websocket" : "http",
                apiKeyConfigured: !config.apiKey.isEmpty
            )
        }
        let openClaw = OpenClawNodeService.shared
        let hermes = HermesService.shared
        let qwen = QwenGatewayService.shared
        return Input(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Hyper Meta AI",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            defaultBrain: AgentBrainSettings.selected.displayName,
            presenceEnabled: AgentPresenceSettings.presenceEnabled,
            quietModeEnabled: AgentVoiceSettings.quietModeEnabled,
            replyEnabled: AgentVoiceSettings.replyEnabled,
            approvalPromptEnabled: AgentVoiceSettings.approvalPromptEnabled,
            permissionMode: AgentPermissionSettings.mode.displayName,
            memoryEnabled: AgentMemorySettings.enabled,
            memoryCount: AgentMemoryStore.entries.count,
            ruleCount: AgentRuleStore.entries.count,
            listCount: AgentListStore.lists.count,
            visionInjectionEnabled: AgentVisionSettings.injectionEnabled,
            visionFollowUpEnabled: AgentVisionSettings.followUpEnabled,
            approvalTimeout: AgentTimingSettings.approvalTimeout,
            thinkingHintDelay: AgentTimingSettings.thinkingHintDelay,
            qwenGatewayConfigured: qwen.mode == .builtIn
                ? qwen.isBuiltInAPIKeyConfigured
                : !qwen.gatewayHost.isEmpty,
            qwenEndpoint: qwen.endpointDisplay,
            openClaw: OpenClawInfo(
                enabled: openClaw.isEnabled,
                host: openClaw.gatewayHost,
                port: openClaw.gatewayPort,
                usesTLS: openClaw.usesTLS,
                tokenConfigured: openClaw.loadGatewayToken() != nil
            ),
            hermes: HermesInfo(
                enabled: hermes.isEnabled,
                host: hermes.gatewayHost,
                port: hermes.gatewayPort,
                usesTLS: hermes.usesTLS,
                model: hermes.modelName
            ),
            customAgents: customAgents,
            registeredToolCount: AgentToolRegistry.allTools.count,
            sensitiveToolCount: AgentToolRegistry.allTools.filter(\.requiresPermission).count,
            revokedToolIDs: AgentRevokeStore.revokedToolIDs,
            auditCount: AgentAuditStore.entries.count,
            reminderCount: AgentReminderStore.reminders.count
        )
    }

    /// 构建诊断文本（纯逻辑）
    static func build(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("\(input.appName) Diagnostics")
        lines.append(String(repeating: "=", count: 24))
        lines.append("")

        lines.append("[App]")
        lines.append("Version: \(input.appVersion) (\(input.buildNumber))")
        lines.append("System: iOS \(input.systemVersion) · \(input.deviceModel)")
        lines.append("")

        lines.append("[Agent Settings]")
        lines.append("Default brain: \(input.defaultBrain)")
        lines.append("Presence: \(onOff(input.presenceEnabled))")
        lines.append("Quiet mode: \(onOff(input.quietModeEnabled))")
        lines.append("Speak replies: \(onOff(input.replyEnabled))")
        lines.append("Approval voice alert: \(onOff(input.approvalPromptEnabled))")
        lines.append("Permission mode: \(input.permissionMode)")
        lines.append("Long-term memory: \(onOff(input.memoryEnabled))")
        lines.append("Memory entries: \(input.memoryCount)")
        lines.append("Personal rules: \(input.ruleCount)")
        lines.append("Named lists: \(input.listCount)")
        lines.append("Vision injection: \(onOff(input.visionInjectionEnabled))")
        lines.append("Vision follow-up: \(onOff(input.visionFollowUpEnabled))")
        lines.append("Approval timeout: \(Int(input.approvalTimeout))s")
        lines.append("Thinking hint delay: \(Int(input.thinkingHintDelay))s")
        lines.append("")

        lines.append("[Connections]")
        lines.append("Qwen gateway: \(input.qwenGatewayConfigured ? input.qwenEndpoint : "not configured")")
        lines.append("OpenClaw: \(input.openClaw.enabled ? "on" : "off") · \(input.openClaw.host):\(input.openClaw.port)\(input.openClaw.usesTLS ? " (tls)" : "") · token: \(configured(input.openClaw.tokenConfigured))")
        lines.append("Hermes: \(input.hermes.enabled ? "on" : "off") · \(input.hermes.host):\(input.hermes.port)\(input.hermes.usesTLS ? " (tls)" : "") · model: \(input.hermes.model)")
        lines.append("Custom agents: \(input.customAgents.count)")
        for agent in input.customAgents {
            lines.append("  - \(agent.name) (\(agent.transport)) · \(agent.baseURL) · model: \(agent.model) · API key: \(configured(agent.apiKeyConfigured))")
        }
        lines.append("")

        lines.append("[Tools & Permissions]")
        lines.append("Registered tools: \(input.registeredToolCount) (\(input.sensitiveToolCount) sensitive)")
        lines.append("Revoked: \(input.revokedToolIDs.isEmpty ? "none" : input.revokedToolIDs.sorted().joined(separator: ", "))")
        lines.append("Audit entries: \(input.auditCount)")
        lines.append("Local reminders: \(input.reminderCount)")
        lines.append("")

        lines.append("[Privacy]")
        lines.append("Captured frames are memory-only; chat history never stores photos.")
        return lines.joined(separator: "\n")
    }

    private static func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    private static func configured(_ value: Bool) -> String {
        value ? secretMask : "not configured"
    }
}
