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
            List {
                Section {
                    LabeledContent {
                        Label(
                            wearablesStatusText,
                            systemImage: streamViewModel.hasActiveDevice
                                ? "checkmark.circle.fill"
                                : "circle.dashed"
                        )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(streamViewModel.hasActiveDevice ? .green : .secondary)
                    } label: {
                        Label("Ray-Ban Meta", systemImage: "eyeglasses")
                    }

                    Toggle("assistant.settings.glasses.vision".localized, isOn: $visionEnabled)
                        .onChange(of: visionEnabled) { _, enabled in
                            AgentVisionSettings.injectionEnabled = enabled
                        }

                    if wearablesViewModel.registrationState == .registered {
                        Button(role: .destructive) {
                            wearablesViewModel.disconnectGlasses()
                        } label: {
                            Label(
                                "assistant.settings.glasses.disconnect".localized,
                                systemImage: "xmark.circle"
                            )
                        }
                    } else {
                        Button {
                            wearablesViewModel.connectGlasses()
                        } label: {
                            Label(
                                "assistant.settings.glasses.connect".localized,
                                systemImage: "link"
                            )
                        }
                        .disabled(wearablesViewModel.isRegistrationActionInFlight)
                    }
                } header: {
                    Text("assistant.settings.glasses".localized)
                }

                Section {
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
                            Label("assistant.settings.voice.service".localized, systemImage: "waveform")
                        }
                    }
                    .foregroundStyle(.primary)

                    Picker("assistant.settings.voice.model".localized, selection: $selectedModelID) {
                        ForEach(QwenRealtimeModelCatalog.all) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .onChange(of: selectedModelID) { _, modelID in
                        QwenRealtimeModelCatalog.setSelected(modelID)
                    }
                    Picker("assistant.settings.agent.brain".localized, selection: $selectedBrain) {
                        ForEach(AgentBrain.allCases) { brain in
                            Label(brain.displayName, systemImage: brain.symbolName).tag(brain)
                        }
                    }
                    .onChange(of: selectedBrain) { _, brain in
                        AgentBrainSettings.selected = brain
                    }
                } header: {
                    Text("assistant.settings.conversation".localized)
                }

                Section {
                    Toggle("assistant.settings.agent.presence".localized, isOn: $presenceEnabled)
                        .onChange(of: presenceEnabled) { _, enabled in
                            AgentPresenceSettings.presenceEnabled = enabled
                            QwenVoiceSession.shared.refreshIdleWatchdog()
                        }

                    Toggle("assistant.settings.agent.wake".localized, isOn: $wakeWordEnabled)
                        .onChange(of: wakeWordEnabled) { _, enabled in
                            QwenVoiceSession.wakeWordEnabled = enabled
                            if enabled {
                                QwenVoiceSession.shared.restartWakeWordListening()
                            } else {
                                QwenVoiceSession.shared.stopWakeWordMonitoring()
                            }
                        }
                } header: {
                    Text("assistant.settings.controls".localized)
                }

                Section {
                    Button {
                        showAgentSettings = true
                    } label: {
                        HStack {
                            Label("assistant.settings.agent.more".localized, systemImage: "gearshape.2")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    LabeledContent("assistant.settings.version".localized, value: "2.0.0")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("assistant.primary.done".localized) { dismiss() }
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
        case .connecting, .waking: return .orange
        case .failed: return .red
        case .disconnected, .sleeping: return .secondary
        }
    }

    private var gatewayStatusText: String {
        if gateway.connectionState == .disconnected {
            return gateway.mode.displayNameKey.localized
        }
        switch gateway.connectionState {
        case .connected: return "assistant.settings.status.online".localized
        case .connecting: return "assistant.settings.status.connecting".localized
        case .waking: return "assistant.settings.status.waking".localized
        case .sleeping: return "qwen.voice.sleeping".localized
        case .failed: return "assistant.settings.status.check".localized
        case .disconnected: return "qwen.voice.disconnected".localized
        }
    }

    private var wearablesStatusText: String {
        if streamViewModel.hasActiveDevice {
            return "qwen.voice.connected".localized
        }
        if wearablesViewModel.registrationState == .registered {
            return "assistant.settings.status.waiting".localized
        }
        return "assistant.settings.status.unpaired".localized
    }
}
