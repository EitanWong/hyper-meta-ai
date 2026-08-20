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

                // 唤醒词开关不在这里：它需要在切换时立刻重启/停止监听，
                // 而这个 sheet 只在按「保存」时才写回，无法及时联动。
                // 唯一入口在设置页与语音页的开关上。
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
