import SwiftUI

/// 诊断报告展示页：只读文本 + 复制 + 系统分享
struct AgentDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(report)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("settings.diagnostics.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                    } label: {
                        Label(
                            copied
                                ? "settings.diagnostics.copied".localized
                                : "settings.diagnostics.copy".localized,
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    Spacer()
                    ShareLink(item: report) {
                        Label("settings.diagnostics.share".localized, systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            report = AgentDiagnosticsReport.build(AgentDiagnosticsReport.current())
        }
    }
}
