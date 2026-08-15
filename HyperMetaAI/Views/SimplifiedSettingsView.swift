/*
 * Simplified Settings
 * The primary experience exposes only connection, agent, and wearable choices.
 */

import SwiftUI

struct SimplifiedSettingsView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @ObservedObject private var gateway = QwenGatewayService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBrain = AgentBrainSettings.selected
    @State private var selectedModelID = QwenRealtimeModelCatalog.selected.id
    @State private var presenceEnabled = AgentPresenceSettings.presenceEnabled
    @State private var visionEnabled = AgentVisionSettings.injectionEnabled
    @State private var wakeWordEnabled = QwenVoiceSession.wakeWordEnabled
    @State private var showGatewayConfig = false
    @State private var showAgentSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    Button {
                        showGatewayConfig = true
                    } label: {
                        LabeledContent {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(gatewayStatusColor)
                                    .frame(width: 7, height: 7)
                                Text(gatewayStatusText)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label("Qwen Audio Gateway", systemImage: "waveform.badge.mic")
                        }
                    }

                    Picker("实时模型", selection: $selectedModelID) {
                        ForEach(QwenRealtimeModelCatalog.all) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .onChange(of: selectedModelID) { _, modelID in
                        QwenRealtimeModelCatalog.setSelected(modelID)
                    }
                }

                Section("Agent") {
                    Picker("任务大脑", selection: $selectedBrain) {
                        ForEach(AgentBrain.allCases) { brain in
                            Label(brain.displayName, systemImage: brain.symbolName).tag(brain)
                        }
                    }
                    .onChange(of: selectedBrain) { _, brain in
                        AgentBrainSettings.selected = brain
                    }

                    Toggle("持续在场", isOn: $presenceEnabled)
                        .onChange(of: presenceEnabled) { _, enabled in
                            AgentPresenceSettings.presenceEnabled = enabled
                            QwenVoiceSession.shared.refreshIdleWatchdog()
                        }

                    Toggle("语音唤醒", isOn: $wakeWordEnabled)
                        .onChange(of: wakeWordEnabled) { _, enabled in
                            QwenVoiceSession.wakeWordEnabled = enabled
                            if enabled {
                                QwenVoiceSession.shared.restartWakeWordListening()
                            } else {
                                QwenVoiceSession.shared.stopWakeWordMonitoring()
                            }
                        }

                    Button {
                        showAgentSettings = true
                    } label: {
                        Label("Agent 与自动化", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }

                Section("眼镜") {
                    LabeledContent {
                        Text(wearablesStatusText)
                            .foregroundStyle(streamViewModel.hasActiveDevice ? .primary : .secondary)
                    } label: {
                        Label("Meta Ray-Ban", systemImage: "eyeglasses")
                    }

                    Toggle("允许视觉上下文", isOn: $visionEnabled)
                        .onChange(of: visionEnabled) { _, enabled in
                            AgentVisionSettings.injectionEnabled = enabled
                        }

                    if wearablesViewModel.registrationState == .registered {
                        Button("断开眼镜", role: .destructive) {
                            wearablesViewModel.disconnectGlasses()
                        }
                    } else {
                        Button("连接眼镜") {
                            wearablesViewModel.connectGlasses()
                        }
                        .disabled(wearablesViewModel.isRegistrationActionInFlight)
                    }
                }

                Section {
                    LabeledContent("版本", value: "2.0.0")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showGatewayConfig) {
                QwenGatewayConfigSheetView {
                    if QwenVoiceSession.shared.isActive {
                        QwenVoiceSession.shared.restart()
                    }
                }
            }
            .sheet(isPresented: $showAgentSettings) {
                AgentSettingsView()
            }
        }
    }

    private var gatewayStatusColor: Color {
        switch gateway.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var gatewayStatusText: String {
        if gateway.connectionState == .disconnected {
            return gateway.mode.displayNameKey.localized
        }
        switch gateway.connectionState {
        case .connected: return "在线"
        case .connecting: return "连接中"
        case .failed: return "需检查"
        case .disconnected: return "未连接"
        }
    }

    private var wearablesStatusText: String {
        if streamViewModel.hasActiveDevice {
            return "已连接"
        }
        if wearablesViewModel.registrationState == .registered {
            return "等待设备"
        }
        return "未配对"
    }
}
