/*
 * Qwen Realtime Model Catalog
 * 镜像 qwen-audio-agent shared/realtime-provider-catalog.mjs（v1.8.3）的
 * DashScope Realtime 语音前端模型档案：
 *   - audio 系列：纯语音前端（低延迟、省流量），默认 qwen-audio-3.0-realtime-plus
 *   - omni 系列：多模态前端（文本/音频/图像），qwen3.5-omni-*-realtime
 * 未知模型 ID 一律回退到默认档案，避免旧配置失效。
 */

import Foundation

/// Qwen Realtime 语音前端模型档案
struct QwenRealtimeModelProfile: Equatable, Identifiable, Sendable {
    enum Family: String, Sendable, CaseIterable {
        /// 纯语音前端：低延迟、省流量，适合眼镜/纯语音场景
        case audio
        /// 多模态前端：文本/音频/图像输入，适合传图/多模态场景
        case omni

        var displayName: String {
            switch self {
            case .audio: return "Audio"
            case .omni: return "Omni"
            }
        }
    }

    let id: String
    let family: Family
    let displayName: String
    let inputSampleRate: Double
    let outputSampleRate: Double
    let supportsImageInput: Bool
    let supportsFunctionCalling: Bool
    let isDefault: Bool
}

/// Qwen Realtime 模型档案目录（纯逻辑，可测）
enum QwenRealtimeModelCatalog {
    /// 最新默认模型：qwen-audio-agent v1.8.3 的 DEFAULT_DASHSCOPE_REALTIME_MODEL
    static let defaultModelID = "qwen-audio-3.0-realtime-plus"

    static let all: [QwenRealtimeModelProfile] = [
        QwenRealtimeModelProfile(
            id: "qwen-audio-3.0-realtime-plus",
            family: .audio,
            displayName: "Qwen Audio 3.0 Plus",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: false,
            supportsFunctionCalling: true,
            isDefault: true
        ),
        QwenRealtimeModelProfile(
            id: "qwen-audio-3.0-realtime-flash",
            family: .audio,
            displayName: "Qwen Audio 3.0 Flash",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: false,
            supportsFunctionCalling: true,
            isDefault: false
        ),
        QwenRealtimeModelProfile(
            id: "qwen3.5-omni-flash-realtime",
            family: .omni,
            displayName: "Qwen3.5 Omni Flash",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: true,
            supportsFunctionCalling: true,
            isDefault: false
        ),
        QwenRealtimeModelProfile(
            id: "qwen3.5-omni-plus-realtime",
            family: .omni,
            displayName: "Qwen3.5 Omni Plus",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: true,
            supportsFunctionCalling: true,
            isDefault: false
        ),
        // 旧版模型：仅保留兼容（历史配置/直连客户端），不推荐新会话使用
        QwenRealtimeModelProfile(
            id: "qwen3-omni-flash-realtime",
            family: .omni,
            displayName: "Qwen3 Omni Flash (旧)",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: true,
            supportsFunctionCalling: true,
            isDefault: false
        ),
    ]

    /// 按模型 ID 解析档案；未知 ID 回退默认档案（保证任何旧配置可用）
    static func resolve(_ id: String?) -> QwenRealtimeModelProfile {
        guard let id, !id.isEmpty else { return defaultProfile }
        return all.first(where: { $0.id == id }) ?? defaultProfile
    }

    static var defaultProfile: QwenRealtimeModelProfile {
        all.first(where: { $0.isDefault }) ?? all[0]
    }

    /// 当前用户选择的模型（UserDefaults 持久化），未知则回退默认
    static var selected: QwenRealtimeModelProfile {
        resolve(UserDefaults.standard.string(forKey: userDefaultsKey))
    }

    static func setSelected(_ modelID: String) {
        UserDefaults.standard.set(modelID, forKey: userDefaultsKey)
    }

    static let userDefaultsKey = "qwen_realtime_model"

    /// 指定家族（audio/omni）的可用模型，用于界面分组
    static func profiles(family: QwenRealtimeModelProfile.Family) -> [QwenRealtimeModelProfile] {
        all.filter { $0.family == family }
    }

    /// 为指定家族解析模型：用户选择同家族时用用户选择，否则用该家族首个（非旧版）档案
    static func resolveForFamily(_ family: QwenRealtimeModelProfile.Family) -> QwenRealtimeModelProfile {
        let familyProfiles = profiles(family: family)
        let selected = selected
        if selected.family == family {
            return selected
        }
        return familyProfiles.first(where: { !$0.id.contains("(旧)") && !$0.isDefault || $0.family == family })
            ?? familyProfiles[0]
    }
}
