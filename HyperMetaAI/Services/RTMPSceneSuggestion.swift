/*
 * RTMP Scene Suggestion
 * 直播 AI 辅助操作（纯逻辑，可测）：
 * 场景 → 直播标题建议（主题 emoji + 模板）、场景 → Agent 长期记忆文本。
 * 标题供推流页一键复制；记忆文本经 AgentMemoryStore 注入后续 Agent 请求。
 */

import Foundation

/// 场景 → 直播标题建议（纯逻辑，可测）：确定性模板 + 常见场景主题 emoji
enum RTMPSceneTitleSuggester {
    /// 建议数量上限
    static let maxSuggestions = 3
    /// 单条标题长度上限（避免超长影响平台输入框）
    static let maxTitleLength = 40

    /// 常见场景 → 主题 emoji（识别标签来自 Apple Vision，英文标识）
    static let sceneThemes: [String: String] = [
        "Restaurant": "🍽️", "Food": "🍰", "Cafe": "☕", "Coffee": "☕",
        "Street": "🚶", "Outdoor": "🌳", "Nature": "🌲", "Park": "🌳",
        "Office": "💼", "Home": "🏠", "Shopping": "🛍️", "Store": "🛍️",
        "Travel": "🧳", "Mountain": "⛰️", "Beach": "🏖️", "City": "🌆",
        "Gym": "🏃", "Sport": "🏃", "Kitchen": "🍳", "Bar": "🍷",
    ]

    /// 生成直播标题建议（最多 3 条，去重、长度封顶；无场景信息返回空数组）
    static func suggestions(
        sceneLabel: String?,
        summary: String
    ) -> [String] {
        let label = (sceneLabel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [String]
        if !label.isEmpty {
            let theme = sceneThemes[label] ?? ""
            let themePrefix = theme.isEmpty ? "" : theme + " "
            candidates = [
                "\(themePrefix)\(label) 现场直击 · 实时互动",
                summary.isEmpty ? "「\(label)」主题直播" : "「\(label)」主题直播 · \(summary)",
                "沉浸式 \(label) 直播 · 全程陪伴",
            ]
        } else if !summary.isEmpty {
            candidates = [
                "此刻所见 · \(summary)",
                "场景直播 · \(summary)",
            ]
        } else {
            return []
        }

        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let clipped = String(candidate.prefix(maxTitleLength))
            guard !clipped.isEmpty, seen.insert(clipped).inserted else { continue }
            result.append(clipped)
            if result.count >= maxSuggestions { break }
        }
        return result
    }
}

/// 场景 → Agent 长期记忆文本（纯逻辑，可测）：
/// 无场景信息返回 nil（不入记忆）；超长按前缀截断
enum RTMPLiveSceneContextBuilder {
    /// 记忆文本长度上限
    static let maxContextLength = 120

    /// 把当前直播场景构造成 Agent 记忆条目文本
    /// 形如：直播场景：Restaurant（Restaurant, Food）· 抖音
    static func memoryText(
        sceneLabel: String?,
        summary: String,
        platformName: String? = nil
    ) -> String? {
        let label = (sceneLabel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = (platformName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !label.isEmpty || !summary.isEmpty else { return nil }

        var text = "直播场景："
        if !label.isEmpty {
            text += label
        }
        if !summary.isEmpty {
            text += label.isEmpty ? summary : "（\(summary)）"
        }
        if !platform.isEmpty {
            text += " · \(platform)"
        }
        return String(text.prefix(maxContextLength))
    }
}

/// 场景 → Agent 分析提示词（纯逻辑，可测）：
/// 请 Agent 基于当前直播场景给出互动建议（讲什么 / 做什么 / 观众可能问什么）。
enum RTMPSceneAnalysisPrompt {
    /// 构造场景分析提示词；场景信息为空的行自动省略
    static func message(
        sceneLabel: String?,
        summary: String,
        platformName: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("我正在用眼镜直播，请基于当前场景给我 3 条互动建议（讲什么 / 做什么 / 观众可能会问什么），简洁具体。")
        let label = (sceneLabel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = (platformName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !label.isEmpty {
            lines.append("直播场景：\(label)")
        }
        if !summaryText.isEmpty {
            lines.append("场景摘要：\(summaryText)")
        }
        if !platform.isEmpty {
            lines.append("直播平台：\(platform)")
        }
        lines.append("请直接给出建议，不要寒暄。")
        return lines.joined(separator: "\n")
    }
}

/// 场景分析结果 → Agent 长期记忆文本（纯逻辑，可测）：
/// 加「直播互动建议：」前缀，超长截断；空内容返回 nil（不入记忆）。
enum RTMPSceneAnalysisMemory {
    /// 记忆文本长度上限
    static let maxMemoryLength = 200

    static func memoryText(_ analysis: String) -> String? {
        let trimmed = analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(("直播互动建议：" + trimmed).prefix(maxMemoryLength))
    }
}

/// 场景 AI 辅助（润色 / 分析）的大脑分发（纯逻辑，可测）：
/// 优先 Hermes（指令注入最完整），其次 OpenClaw 网关，再次自定义 HTTP/WS Agent，
/// 最后端侧离线模型（Apple Intelligence，iOS 26+，数据不出设备）；
/// 全部不可用时返回 nil（UI 给出「未配置网关」提示）。
enum SceneAssistantBrain {
    enum Provider: String, Equatable {
        case hermes
        case openclaw
        case custom
        case local
    }

    static func resolve(
        hermesAvailable: Bool,
        openClawAvailable: Bool,
        customAvailable: Bool,
        localAvailable: Bool = false
    ) -> Provider? {
        if hermesAvailable { return .hermes }
        if openClawAvailable { return .openclaw }
        if customAvailable { return .custom }
        if localAvailable { return .local }
        return nil
    }
}
