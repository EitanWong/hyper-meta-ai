/*
 * Vision Translation Planner
 * 端侧翻译的纯逻辑规划：判断文本语言方向（CJK → 英文，其余 → 中文），
 * 供 OCR 取词结果一键翻译使用（Apple Translation，iOS 18+，离线可用）。
 */

import Foundation

/// 翻译规划（纯逻辑，可测）
enum VisionTranslationPlanner {
    /// 是否含东亚文字（中文 / 日文假名 / 韩文），用于决定翻译目标语言
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400...0x4DBF).contains(value)     // CJK 扩展 A
                || (0x4E00...0x9FFF).contains(value)     // CJK 统一表意
                || (0xF900...0xFAFF).contains(value)     // CJK 兼容
                || (0x3040...0x30FF).contains(value)     // 日文假名
                || (0xAC00...0xD7AF).contains(value)     // 韩文音节
        }
    }

    /// 目标语言：含东亚文字 → 英文；否则 → 简体中文
    static func targetLanguage(for text: String) -> Locale.Language {
        containsCJK(text)
            ? Locale.Language(identifier: "en")
            : Locale.Language(identifier: "zh-Hans")
    }

    /// 生成发给 Agent 的翻译指令（按语言方向自动选目标语言）
    static func translateInstruction(for text: String) -> String {
        let target = targetLanguage(for: text)
        let displayName = target == Locale.Language(identifier: "zh-Hans") ? "中文" : "English"
        return "agent.vision.translate.instruction".localized(displayName, text)
    }
}
