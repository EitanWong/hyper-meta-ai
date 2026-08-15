/*
 * Control Center 语音会话控制
 * 「开始语音会话」与「停止语音会话」两个独立 Control（iOS 18+），
 * 与 Siri / 快捷指令 / 眼镜 tap 共用同一套回合语义。
 */

import AppIntents
import SwiftUI
import WidgetKit

@main
struct HyperMetaAIControlsBundle: WidgetBundle {
    var body: some Widget {
        StartVoiceSessionControl()
        StopVoiceSessionControl()
        BriefingControl()
        AgentLiveActivityWidget()
        AgentHomeWidget()
    }
}

struct StartVoiceSessionControl: ControlWidget {
    static let kind = "com.lunflux.hyper-meta-ai.control.start-voice"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartVoiceSessionControlIntent()) {
                Label("开始语音会话", systemImage: "waveform.circle.fill")
            }
        }
        .displayName("开始语音会话")
        .description("进入与 Agent 的实时语音会话")
    }
}

struct StopVoiceSessionControl: ControlWidget {
    static let kind = "com.lunflux.hyper-meta-ai.control.stop-voice"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StopVoiceSessionControlIntent()) {
                Label("停止语音会话", systemImage: "stop.circle.fill")
            }
        }
        .displayName("停止语音会话")
        .description("停止正在运行的语音会话")
    }
}
