/*
 * Qwen Gateway Config Sheet
 * 语音页内的网关配置引导：首次使用或连接失败时快速配置并重连。
 */

import SwiftUI

struct QwenGatewayConfigSheetView: View {
    @ObservedObject private var gateway = QwenGatewayService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var portText = ""
    @State private var sessionName = ""
    @State private var usesTLS = false
    @State private var mode: QwenGatewayMode = QwenGatewayService.shared.mode
    @State private var idleAutoEnd = QwenVoiceSession.idleAutoEndEnabled
    @State private var realtimeModelID = QwenRealtimeModelCatalog.selected.id
    @State private var wakeWordEnabled = QwenVoiceSession.wakeWordEnabled
    @State private var showAPIKeySettings = false

    let onSave: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("qwen.settings.mode".localized, selection: $mode) {
                        ForEach(QwenGatewayMode.allCases) { option in
                            Text(option.displayNameKey.localized).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .builtIn {
                        LabeledContent {
                            Text(gateway.isBuiltInAPIKeyConfigured
                                ? "qwen.settings.api.configured".localized
                                : "qwen.settings.api.missing".localized)
                                .foregroundStyle(gateway.isBuiltInAPIKeyConfigured ? .green : .orange)
                        } label: {
                            Text("qwen.settings.api.status".localized)
                        }

                        Button {
                            showAPIKeySettings = true
                        } label: {
                            Label("settings.apikey.manage".localized, systemImage: "key.fill")
                        }
                    }
                } header: {
                    Text("qwen.settings.section".localized)
                } footer: {
                    Text(mode == .builtIn
                        ? "qwen.settings.mode.builtin.footer".localized
                        : "qwen.settings.mode.external.footer".localized)
                }

                if mode == .external {
                    Section {
                    HStack {
                        Text("agent.form.host".localized)
                            .frame(width: 50, alignment: .leading)
                        TextField("127.0.0.1", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    HStack {
                        Text("agent.form.port".localized)
                            .frame(width: 50, alignment: .leading)
                        TextField("3101", text: $portText)
                            .keyboardType(.numberPad)
                    }

                    HStack {
                        Text("agent.form.session".localized)
                            .frame(width: 50, alignment: .leading)
                        TextField("main", text: $sessionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Toggle("Use TLS", isOn: $usesTLS)
                    } header: {
                        Text("qwen.settings.external.section".localized)
                    } footer: {
                        Text("qwen.voice.config.hint".localized)
                    }
                }

                Section {
                    Toggle("qwen.voice.idle.toggle".localized, isOn: $idleAutoEnd)
                } footer: {
                    Text("qwen.voice.idle.footer".localized)
                }

                Section {
                    Picker("qwen.realtime.model".localized, selection: $realtimeModelID) {
                        ForEach(QwenRealtimeModelCatalog.all) { profile in
                            Text(modelLabel(profile)).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("qwen.realtime.section".localized)
                } footer: {
                    Text("qwen.realtime.footer".localized)
                }

                Section {
                    Toggle("qwen.wakeword.title".localized, isOn: $wakeWordEnabled)
                } footer: {
                    Text("qwen.wakeword.footer".localized)
                }
            }
            .navigationTitle("qwen.voice.config".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("qwen.settings.save".localized) {
                        save()
                    }
                    .disabled(mode == .external && host.isEmpty)
                }
            }
            .onAppear {
                mode = gateway.mode
                host = gateway.gatewayHost
                portText = "\(gateway.gatewayPort)"
                sessionName = gateway.sessionName
                usesTLS = gateway.usesTLS
            }
            .sheet(isPresented: $showAPIKeySettings) {
                APIKeySettingsView(
                    provider: .alibaba,
                    endpoint: APIProviderManager.staticAlibabaEndpoint
                )
            }
        }
    }

    private func modelLabel(_ profile: QwenRealtimeModelProfile) -> String {
        let familyLabel: String
        switch profile.family {
        case .audio: familyLabel = "qwen.realtime.family.audio".localized
        case .omni: familyLabel = "qwen.realtime.family.omni".localized
        }
        return "\(profile.displayName) · \(familyLabel)"
    }

    private func save() {
        QwenRealtimeModelCatalog.setSelected(realtimeModelID)
        QwenVoiceSession.wakeWordEnabled = wakeWordEnabled
        gateway.mode = mode
        gateway.gatewayHost = host
        gateway.gatewayPort = Int(portText) ?? 3101
        gateway.sessionName = sessionName.isEmpty ? "main" : sessionName
        gateway.usesTLS = usesTLS
        gateway.saveSettings()
        QwenVoiceSession.idleAutoEndEnabled = idleAutoEnd
        onSave()
        dismiss()
    }
}

#if DEBUG
#Preview("Qwen Gateway Config") {
    QwenGatewayConfigSheetView(onSave: {})
}
#endif
