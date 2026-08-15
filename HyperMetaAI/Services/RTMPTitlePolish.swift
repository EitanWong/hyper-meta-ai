/*
 * RTMP Title Polish
 * 直播标题 AI 润色（纯逻辑，可测）：
 * 场景模板标题 → 构造润色提示词 → 解析 Agent 返回的标题变体。
 */

import Foundation

/// 直播标题 AI 润色提示词构造（纯逻辑，可测）：
/// 携带原标题与场景上下文（标签 / 摘要 / 平台），要求只输出标题行。
enum RTMPTitlePolishPrompt {
    /// 输出格式要求（写进提示词，约束 Agent 只回标题行）
    static let formatRequirement = "只输出润色后的标题，每行一条，最多 3 条，不要编号、不要额外说明。"

    /// 构造润色提示词；场景信息为空的行自动省略
    static func message(
        draftTitle: String,
        sceneLabel: String?,
        summary: String,
        platformName: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("请把以下直播标题润色得更吸引人、更贴合当前场景，保持简洁自然，避免夸张营销话术。")
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
        lines.append("原标题：\(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append(formatRequirement)
        return lines.joined(separator: "\n")
    }
}

/// 直播标题润色结果解析（纯逻辑，可测）：
/// 按行拆分，去掉编号 / 项目符号 / Markdown 包裹与说明行，去重、长度封顶。
enum RTMPTitlePolishParser {
    /// 疑似说明/引导行的关键词（Agent 偶发夹杂，安全跳过）
    static let scaffoldingKeywords = ["以下", "如上", "要求：", "说明：", "注意：", "这是润色"]

    /// 解析 Agent 返回文本为标题变体列表（最多 limit 条，单条最长 maxLength）
    static func parse(
        _ text: String,
        limit: Int = 3,
        maxLength: Int = 40
    ) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var seen = Set<String>()
        var result: [String] = []

        for raw in lines {
            guard result.count < limit else { break }
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard !scaffoldingKeywords.contains(where: { line.contains($0) }) else { continue }

            line = stripListPrefix(line)
            line = stripQuotes(line)

            let clipped = String(line.prefix(maxLength))
            guard !clipped.isEmpty, seen.insert(clipped).inserted else { continue }
            result.append(clipped)
        }
        return result
    }

    /// 去掉列表前缀：Markdown 粗体、项目符号、数字编号（1. / 1、 / 1)）
    private static func stripListPrefix(_ line: String) -> String {
        var s = line
        if s.hasPrefix("**"), s.hasSuffix("**"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["- ", "– ", "• ", "· "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if let first = s.first, first.isNumber {
            var index = s.startIndex
            while index < s.endIndex, s[index].isNumber {
                index = s.index(after: index)
            }
            let rest = s[index...]
            if rest.hasPrefix(". ") {
                s = String(rest.dropFirst(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if rest.hasPrefix("、") {
                s = String(rest.dropFirst(1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if rest.hasPrefix(") ") {
                s = String(rest.dropFirst(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    /// 去掉首尾成对引号（“ ” “” 与英文引号）
    private static func stripQuotes(_ line: String) -> String {
        var s = line
        for pair in [("\"", "\""), ("“", "”"), ("「", "」")] {
            if s.hasPrefix(pair.0), s.hasSuffix(pair.1), s.count >= pair.0.count + pair.1.count {
                s = String(s.dropFirst(pair.0.count).dropLast(pair.1.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }
}
