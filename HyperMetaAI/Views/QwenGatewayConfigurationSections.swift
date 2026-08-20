/*
 * Qwen Gateway Configuration Sections
 * 网关连接设置的唯一实现：模式选择 + 内置 API Key 状态 + 外部地址表单。
 *
 * 语音页的快速配置 sheet 和「更多设置」页都渲染这里，两处此前是逐字复制的两份，
 * 各自持有一份 @State，改完同一个设置会互相覆盖。现在共用同一份草稿与同一条保存路径。
 */

import SwiftUI

// MARK: - Draft

/// 网关连接设置的可编辑草稿。
///
/// 表单编辑的是草稿而不是 `QwenGatewayService` 本身，这样「取消」能真正丢弃改动，
/// 端口这类需要解析的字段也可以在用户输入过程中保持非法中间态（空串、半个数字）。
struct QwenGatewayDraft: Equatable {
    var mode: QwenGatewayMode = .builtIn
    var host = ""
    var portText = ""
    var sessionName = ""
    var usesTLS = false

    /// 外部模式缺少主机名时无法保存；内置模式没有需要校验的字段。
    var isSavable: Bool {
        mode != .external || !host.isEmpty
    }

    static func loaded(from gateway: QwenGatewayService) -> Self {
        Self(
            mode: gateway.mode,
            host: gateway.gatewayHost,
            portText: "\(gateway.gatewayPort)",
            sessionName: gateway.sessionName,
            usesTLS: gateway.usesTLS
        )
    }

    /// 写回并持久化。端口与会话名在此处兜底，保证两个入口的兜底值一致。
    func apply(to gateway: QwenGatewayService) {
        gateway.mode = mode
        gateway.gatewayHost = host
        gateway.gatewayPort = Int(portText) ?? Self.defaultPort
        gateway.sessionName = sessionName.isEmpty ? Self.defaultSessionName : sessionName
        gateway.usesTLS = usesTLS
        gateway.saveSettings()
    }

    static let defaultPort = 3101
    static let defaultSessionName = "main"
}

// MARK: - Sections

/// 网关设置的两个 Section。调用方负责把它放进自己的 `Form` / `List` 并提供保存动作。
struct QwenGatewayConfigurationSections: View {
    @Binding var draft: QwenGatewayDraft
    @ObservedObject private var gateway = QwenGatewayService.shared
    @State private var showAPIKeySettings = false

    var body: some View {
        Section {
            Picker("qwen.settings.mode".localized, selection: $draft.mode) {
                ForEach(QwenGatewayMode.allCases) { option in
                    Text(option.displayNameKey.localized).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if draft.mode == .builtIn {
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
                // sheet 挂在 Button 而非 Section 上：修饰 Section 会让它在 Form 里
                // 退化成普通行，丢掉 header / footer。
                .sheet(isPresented: $showAPIKeySettings) {
                    APIKeySettingsView(
                        provider: .alibaba,
                        endpoint: APIProviderManager.staticAlibabaEndpoint
                    )
                }
            }
        } header: {
            Text("qwen.settings.section".localized)
        } footer: {
            Text(draft.mode == .builtIn
                ? "qwen.settings.mode.builtin.footer".localized
                : "qwen.settings.mode.external.footer".localized)
        }

        if draft.mode == .external {
            Section {
                HStack {
                    Text("agent.form.host".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("127.0.0.1", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                HStack {
                    Text("agent.form.port".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("\(QwenGatewayDraft.defaultPort)", text: $draft.portText)
                        .keyboardType(.numberPad)
                }

                HStack {
                    Text("agent.form.session".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField(QwenGatewayDraft.defaultSessionName, text: $draft.sessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Toggle("qwen.settings.tls".localized, isOn: $draft.usesTLS)
            } header: {
                Text("qwen.settings.external.section".localized)
            } footer: {
                Text("qwen.settings.footer".localized)
            }
        }
    }
}
