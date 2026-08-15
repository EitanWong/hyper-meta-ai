/*
 * Custom Agent Config Sheet
 * 自定义 HTTP Agent 的添加/编辑表单：名称、服务地址、API Key、模型 + 连接测试。
 * 保存到 CustomAgentStore（UserDefaults JSON），供 Agent Hub 与聊天页使用。
 */

import SwiftUI

struct CustomAgentConfigSheetView: View {
    @Environment(\.dismiss) private var dismiss

    /// 编辑已有配置时传入；nil 表示新建
    let config: CustomAgentConfig?
    let onSave: () -> Void

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var toolsJSON = ""
    @State private var transport: CustomAgentTransport = .http
    @State private var healthState: HealthState = .idle

    enum HealthState: Equatable {
        case idle
        case checking
        case ok
        case failed
    }

    /// 表单草稿（编辑时沿用原 ID，保存即覆盖）
    private var draft: CustomAgentConfig {
        CustomAgentConfig(
            id: config?.id ?? UUID(),
            name: name,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            toolsJSON: toolsJSON.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: transport
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("custom.agent.transport.title".localized, selection: $transport) {
                        Text("custom.agent.transport.http".localized).tag(CustomAgentTransport.http)
                        Text("custom.agent.transport.websocket".localized).tag(CustomAgentTransport.websocket)
                    }
                    .pickerStyle(.segmented)
                    TextField("custom.agent.name".localized, text: $name)
                    TextField("custom.agent.baseurl".localized, text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("custom.agent.apikey".localized, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("custom.agent.model".localized, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("custom.agent.transport.footer".localized)
                        if transport == .websocket {
                            Text("custom.agent.ws.baseurl.hint".localized)
                        }
                    }
                }

                Section {
                    TextEditor(text: $toolsJSON)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 110)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("custom.agent.tools.title".localized)
                } footer: {
                    Text("custom.agent.tools.footer".localized)
                }

                Section {
                    Button {
                        Task { await runHealthCheck() }
                    } label: {
                        HStack {
                            Text("custom.agent.health.check".localized)
                            Spacer()
                            switch healthState {
                            case .idle:
                                EmptyView()
                            case .checking:
                                ProgressView().scaleEffect(0.8)
                            case .ok:
                                Label("custom.agent.health.ok".localized, systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .failed:
                                Label("custom.agent.health.fail".localized, systemImage: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .disabled(!draft.isValid || healthState == .checking)
                } footer: {
                    Text("custom.agent.health.hint".localized)
                }
            }
            .navigationTitle(
                config == nil
                    ? "custom.agent.add.title".localized
                    : "custom.agent.edit.title".localized
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("custom.agent.save".localized) {
                        save()
                    }
                    .disabled(!draft.isValid)
                }
            }
            .onAppear {
                guard let config else { return }
                name = config.name
                baseURL = config.baseURL
                apiKey = config.apiKey
                model = config.model
                toolsJSON = config.toolsJSON
                transport = config.transport
            }
        }
    }

    private func save() {
        CustomAgentStore.add(draft)
        onSave()
        dismiss()
    }

    @MainActor
    private func runHealthCheck() async {
        healthState = .checking
        let ok: Bool
        if transport == .websocket {
            ok = await CustomWebSocketAgentService.shared.checkHealth(config: draft)
        } else {
            ok = await CustomAgentService.shared.checkHealth(config: draft)
        }
        healthState = ok ? .ok : .failed
    }
}

#if DEBUG
#Preview("Custom Agent Config") {
    CustomAgentConfigSheetView(config: nil, onSave: {})
}
#endif
