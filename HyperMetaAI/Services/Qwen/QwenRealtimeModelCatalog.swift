/*
 * Qwen Realtime Model Catalog
 * 镜像 qwen-audio-agent shared/realtime-model-catalog.mjs（v1.10.1）的
 * DashScope Realtime 语音前端模型档案：
 *   - audio 系列：纯语音前端（低延迟、省流量），默认 qwen-audio-3.0-realtime-plus
 *   - omni 系列：多模态前端（文本/音频/图像），qwen3.5-omni-*-realtime
 * App 内置传输接入文本/音频/按需单帧图像；外部网关仍按其协议能力降级为视觉摘要文本。
 */

import Foundation

/// 内置实现对齐的上游发布点。Scripts/check-qwen-audio-agent-sync.sh 会在 CI
/// 定期核对最新稳定 tag，发现漂移即失败，避免版本注释长期失真。
enum QwenAudioAgentUpstream {
    static let repositoryURL = "https://github.com/QwenAudio/qwen-audio-agent.git"
    static let releaseTag = "v1.10.1"
    static let commit = "1dea8779e73d9e1aaebfd8c6a847270cce39572f"
}

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
    /// 模型本身是否支持图片。
    let supportsImageInput: Bool
    let transportSupportsImageInput: Bool
    let supportsFunctionCalling: Bool
    let defaultVoice: String
    let turnDetectionType: String
    let isDefault: Bool
}

/// Qwen Realtime 模型档案目录（纯逻辑，可测）
enum QwenRealtimeModelCatalog {
    /// 最新默认模型：qwen-audio-agent v1.10.1 的 DEFAULT_DASHSCOPE_REALTIME_MODEL
    static let defaultModelID = "qwen-audio-3.0-realtime-plus"

    static let all: [QwenRealtimeModelProfile] = [
        QwenRealtimeModelProfile(
            id: "qwen-audio-3.0-realtime-plus",
            family: .audio,
            displayName: "Qwen Audio 3.0 Plus",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: false,
            transportSupportsImageInput: false,
            supportsFunctionCalling: true,
            defaultVoice: "longanqian",
            turnDetectionType: "smart_turn",
            isDefault: true
        ),
        QwenRealtimeModelProfile(
            id: "qwen-audio-3.0-realtime-flash",
            family: .audio,
            displayName: "Qwen Audio 3.0 Flash",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: false,
            transportSupportsImageInput: false,
            supportsFunctionCalling: true,
            defaultVoice: "longanqian",
            turnDetectionType: "smart_turn",
            isDefault: false
        ),
        QwenRealtimeModelProfile(
            id: "qwen3.5-omni-flash-realtime",
            family: .omni,
            displayName: "Qwen3.5 Omni Flash",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: true,
            transportSupportsImageInput: false,
            supportsFunctionCalling: true,
            defaultVoice: "Ethan",
            turnDetectionType: "semantic_vad",
            isDefault: false
        ),
        QwenRealtimeModelProfile(
            id: "qwen3.5-omni-plus-realtime",
            family: .omni,
            displayName: "Qwen3.5 Omni Plus",
            inputSampleRate: 16_000,
            outputSampleRate: 24_000,
            supportsImageInput: true,
            transportSupportsImageInput: false,
            supportsFunctionCalling: true,
            defaultVoice: "Ethan",
            turnDetectionType: "semantic_vad",
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
    static let audioVoiceUserDefaultsKey = "qwen_audio_realtime_voice"
    static let omniVoiceUserDefaultsKey = "qwen_omni_realtime_voice"
    private static let legacyVoiceUserDefaultsKey = "qwen_realtime_voice"

    /// v1.9 起 Audio / Omni 音色覆盖相互独立；未覆盖时使用各模型族默认值。
    static func voice(
        for profile: QwenRealtimeModelProfile,
        preferences: UserDefaults = .standard
    ) -> String {
        let key = profile.family == .audio
            ? audioVoiceUserDefaultsKey
            : omniVoiceUserDefaultsKey
        if let override = nonEmpty(preferences.string(forKey: key)) {
            return override
        }
        if profile.family == .audio,
           let legacy = nonEmpty(preferences.string(forKey: legacyVoiceUserDefaultsKey)) {
            return legacy
        }
        return profile.defaultVoice
    }

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
        return familyProfiles.first ?? defaultProfile
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
