import XCTest

@testable import HyperMetaAI

/// 诊断报告：纯逻辑构建 + 敏感信息掩码
final class AgentDiagnosticsTests: XCTestCase {
    private func makeInput() -> AgentDiagnosticsReport.Input {
        AgentDiagnosticsReport.Input(
            appName: "Hyper Meta AI",
            appVersion: "1.3.0",
            buildNumber: "42",
            systemVersion: "18.5",
            deviceModel: "iPhone 15 Pro",
            defaultBrain: "Auto",
            presenceEnabled: true,
            quietModeEnabled: false,
            replyEnabled: true,
            approvalPromptEnabled: true,
            permissionMode: "Always ask",
            memoryEnabled: true,
            memoryCount: 4,
            ruleCount: 2,
            listCount: 1,
            visionInjectionEnabled: true,
            visionFollowUpEnabled: true,
            approvalTimeout: 60,
            thinkingHintDelay: 8,
            qwenGatewayConfigured: true,
            qwenEndpoint: "ws://127.0.0.1:3101",
            openClaw: .init(enabled: true, host: "192.168.1.5", port: 18789, usesTLS: false, tokenConfigured: true),
            hermes: .init(enabled: true, host: "192.168.1.5", port: 8642, usesTLS: false, model: "hermes-agent"),
            customAgents: [
                .init(name: "Local", baseURL: "http://192.168.1.6:8080", model: "llama3", transport: "http", apiKeyConfigured: true),
                .init(name: "WS Agent", baseURL: "ws://192.168.1.7:9000", model: "qwen", transport: "websocket", apiKeyConfigured: false)
            ],
            registeredToolCount: 5,
            sensitiveToolCount: 2,
            revokedToolIDs: ["vision.capture"],
            auditCount: 12,
            reminderCount: 3
        )
    }

    func testReportContainsAllSections() {
        let report = AgentDiagnosticsReport.build(makeInput())
        for section in ["[App]", "[Agent Settings]", "[Connections]", "[Tools & Permissions]", "[Privacy]"] {
            XCTAssertTrue(report.contains(section), "missing section \(section)")
        }
    }

    func testReportContainsKeyFields() {
        let report = AgentDiagnosticsReport.build(makeInput())
        XCTAssertTrue(report.contains("Version: 1.3.0 (42)"))
        XCTAssertTrue(report.contains("iOS 18.5 · iPhone 15 Pro"))
        XCTAssertTrue(report.contains("Default brain: Auto"))
        XCTAssertTrue(report.contains("ws://127.0.0.1:3101"))
        XCTAssertTrue(report.contains("192.168.1.5:18789"))
        XCTAssertTrue(report.contains("model: hermes-agent"))
        XCTAssertTrue(report.contains("Registered tools: 5 (2 sensitive)"))
        XCTAssertTrue(report.contains("Revoked: vision.capture"))
        XCTAssertTrue(report.contains("Audit entries: 12"))
        XCTAssertTrue(report.contains("Memory entries: 4"))
        XCTAssertTrue(report.contains("Named lists: 1"))
        XCTAssertTrue(report.contains("Personal rules: 2"))
        XCTAssertTrue(report.contains("Local reminders: 3"))
    }

    func testSecretsAreMasked() {
        let report = AgentDiagnosticsReport.build(makeInput())
        // 已配置的敏感值只显示掩码
        XCTAssertTrue(report.contains("token: \(AgentDiagnosticsReport.secretMask)"))
        XCTAssertTrue(report.contains("API key: \(AgentDiagnosticsReport.secretMask)"))
        // 未配置的显示 not configured
        XCTAssertTrue(report.contains("API key: not configured"))
        // 报告绝不包含任何疑似密钥原文（输入模型本身不带原文，此断言防回归）
        XCTAssertFalse(report.contains("sk-"))
        XCTAssertFalse(report.contains("Bearer"))
    }

    func testCustomAgentLinesListed() {
        let report = AgentDiagnosticsReport.build(makeInput())
        XCTAssertTrue(report.contains("- Local (http) · http://192.168.1.6:8080 · model: llama3"))
        XCTAssertTrue(report.contains("- WS Agent (websocket) · ws://192.168.1.7:9000"))
    }

    func testEmptyCustomAgentsShowsZero() {
        var input = makeInput()
        input.customAgents = []
        let report = AgentDiagnosticsReport.build(input)
        XCTAssertTrue(report.contains("Custom agents: 0"))
    }
}
