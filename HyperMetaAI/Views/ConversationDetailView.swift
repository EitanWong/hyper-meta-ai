/*
 * Conversation Detail View
 * 对话详情页面
 */

import SwiftUI

struct ConversationDetailView: View {
    let conversation: ConversationRecord
    /// 打开聊天页继续追问所需的会话状态（记录来自 Hub / 记录页 / 系统深链）
    let streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showChatContinue = false

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.secondaryBackground
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(conversation.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("conversation.detail.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: ConversationExportBuilder.exportText(conversation: conversation)) {
                        Label("conversation.export".localized, systemImage: "square.and.arrow.up")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("common.done".localized) {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $showChatContinue) {
                let resolved = ConversationChatKindResolver.resolve(record: conversation)
                AgentChatView(
                    kind: resolved.kind,
                    streamViewModel: streamViewModel,
                    initialRecordID: conversation.id,
                    customConfig: resolved.customConfig
                )
            }
            .safeAreaInset(edge: .bottom) {
                // Continue asking: open voice assistant with this conversation's last reply as context
                VStack(spacing: AppSpacing.md) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        AgentTaskFollowUpCoordinator.requestFollowUp(
                            sessionContext: conversation.followUpContext
                        )
                    } label: {
                        Label("conversation.followup".localized, systemImage: "mic.fill")
                            .font(AppTypography.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(AppColors.primary)
                    .accessibilityHint("conversation.followup.hint".localized)

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showChatContinue = true
                    } label: {
                        Label("conversation.continueInChat".localized, systemImage: "text.bubble")
                            .font(AppTypography.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(AppColors.primary)
                    .accessibilityHint("conversation.continueInChat.hint".localized)

                    // Conversation info
                    HStack {
                        Image(systemName: "clock")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                        Text(conversation.formattedDate)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)

                        Spacer()

                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                        Text(String(format: "conversation.messageCount".localized, conversation.messageCount))
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                .padding(AppSpacing.md)
                .background(AppColors.tertiaryBackground.opacity(0.95))
            }
        }
    }
}

#Preview("Conversation Detail") {
    ConversationDetailView(
        conversation: ConversationRecord(
            messages: [
                ConversationMessage(role: .user, content: "这是什么植物？"),
                ConversationMessage(role: .assistant, content: "这是一株健康的室内观叶植物。")
            ]
        ),
        streamViewModel: PreviewDependencies().streamViewModel
    )
}
