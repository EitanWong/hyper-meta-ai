/*
 * Qwen Gateway Config Sheet
 * 语音页内的网关配置引导：首次使用或连接失败时快速配置并重连。
 */

import SwiftUI

struct QwenGatewayConfigSheetView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft = QwenGatewayDraft()
    @State private var idleAutoEnd = QwenVoiceSession.idleAutoEndEnabled
    @State private var realtimeModelID = QwenRealtimeModelCatalog.selected.id
    @State private var wakeWordEnabled = QwenVoiceSession.wakeWordEnabled

    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                QwenGatewayConfigurationSections(draft: $draft)

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
                ToolbarItem(placement: .confirmationAction) {
                    Button("qwen.settings.save".localized) {
                        save()
                    }
                    .disabled(!draft.isSavable)
                }
            }
            .onAppear {
                draft = .loaded(from: QwenGatewayService.shared)
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
        draft.apply(to: QwenGatewayService.shared)
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
