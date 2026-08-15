/*
 * Records View
 * 记录页面 - 包含各类记录的 Tab
 */

import SwiftUI

struct RecordsView: View {
    let streamViewModel: StreamSessionViewModel
    @State private var selectedTab = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Custom Tab Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.lg) {
                        RecordTabButton(title: "records.tab.liveai".localized, isSelected: selectedTab == 0) {
                            selectedTab = 0
                        }

                        RecordTabButton(title: "records.tab.translate".localized, isSelected: selectedTab == 1) {
                            selectedTab = 1
                        }

                        RecordTabButton(title: "records.tab.leaneat".localized, isSelected: selectedTab == 2) {
                            selectedTab = 2
                        }

                        RecordTabButton(title: "records.tab.wordlearn".localized, isSelected: selectedTab == 3) {
                            selectedTab = 3
                        }

                        RecordTabButton(title: "quickvision.tab".localized, isSelected: selectedTab == 4) {
                            selectedTab = 4
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.md)
                }
                .background(AppColors.tertiaryBackground)

                // Content
                TabView(selection: $selectedTab) {
                    LiveAIRecordsView(streamViewModel: streamViewModel)
                        .tag(0)

                    TranslationRecordsView()
                        .tag(1)

                    LeanEatRecordsView()
                        .tag(2)

                    WordLearnRecordsView()
                        .tag(3)

                    QuickVisionRecordsView()
                        .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("tab.records".localized)
        }
    }
}

// MARK: - Record Tab Button

struct RecordTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.sm) {
                Text(title)
                    .font(AppTypography.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? AppColors.primary : AppColors.textSecondary)

                if isSelected {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [AppColors.primary, AppColors.secondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 3)
                        .cornerRadius(1.5)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 3)
                }
            }
        }
    }
}

// MARK: - Live AI Records

struct LiveAIRecordsView: View {
    let streamViewModel: StreamSessionViewModel
    @StateObject private var viewModel = ConversationListViewModel()
    @State private var selectedConversation: ConversationRecord?
    @State private var showDetail = false

    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            if viewModel.conversations.isEmpty {
                // Empty state
                VStack(spacing: AppSpacing.lg) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 64))
                        .foregroundColor(AppColors.liveAI.opacity(0.6))

                    Text("records.empty.liveai".localized)
                        .font(AppTypography.title2)
                        .foregroundColor(AppColors.textPrimary)

                    Text("records.empty.liveaiHint".localized)
                        .font(AppTypography.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                }
            } else {
                // 按 Agent 筛选
                Picker("", selection: $viewModel.selectedFilter) {
                    ForEach(ConversationAgentFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.sm)

                if viewModel.filteredConversations.isEmpty {
                    VStack(spacing: AppSpacing.md) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 40))
                            .foregroundColor(AppColors.textTertiary)
                        Text("records.filter.empty".localized)
                            .font(AppTypography.subheadline)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Conversation list
                    ScrollView {
                        LazyVStack(spacing: AppSpacing.md) {
                            ForEach(viewModel.filteredConversations) { conversation in
                                ConversationCell(conversation: conversation)
                                    .onTapGesture {
                                        selectedConversation = conversation
                                        showDetail = true
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            viewModel.deleteConversation(conversation.id)
                                        } label: {
                                            Label("common.delete".localized, systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(AppSpacing.md)
                    }
                    .refreshable {
                        viewModel.loadConversations()
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadConversations()
        }
        .sheet(isPresented: $showDetail) {
            if let conversation = selectedConversation {
                ConversationDetailView(conversation: conversation, streamViewModel: streamViewModel)
            }
        }
    }
}

// MARK: - Conversation List ViewModel

@MainActor
class ConversationListViewModel: ObservableObject {
    @Published var conversations: [ConversationRecord] = []
    @Published var selectedFilter: ConversationAgentFilter = .all

    /// 按当前 Agent 筛选后的会话列表
    var filteredConversations: [ConversationRecord] {
        ConversationAgentFilter.filter(conversations, by: selectedFilter)
    }

    func loadConversations() {
        conversations = ConversationStorage.shared.loadAllConversations()
        print("📱 [RecordsView] 加载对话: \(conversations.count) 条")
    }

    func deleteConversation(_ id: UUID) {
        ConversationStorage.shared.deleteConversation(id)
        loadConversations()
    }
}

// MARK: - Conversation Agent Filter

/// 按 Agent 筛选对话记录（纯逻辑，可测）
enum ConversationAgentFilter: String, CaseIterable, Identifiable {
    case all
    case openclaw
    case hermes
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "records.filter.all".localized
        case .openclaw: return AgentKind.openclaw.displayName
        case .hermes: return AgentKind.hermes.displayName
        case .qwen: return "Qwen"
        }
    }

    /// 记录是否属于该筛选
    static func matches(_ record: ConversationRecord, filter: ConversationAgentFilter) -> Bool {
        switch filter {
        case .all: return true
        case .openclaw: return record.aiModel == AgentKind.openclaw.displayName
        case .hermes: return record.aiModel == AgentKind.hermes.displayName
        case .qwen: return record.aiModel == "qwen-audio-agent"
        }
    }

    static func filter(
        _ records: [ConversationRecord],
        by filter: ConversationAgentFilter
    ) -> [ConversationRecord] {
        records.filter { matches($0, filter: filter) }
    }

    /// 会话对应的 Agent 图标（列表展示用）
    static func iconName(for record: ConversationRecord) -> String {
        if record.aiModel == AgentKind.openclaw.displayName { return "link.circle.fill" }
        if record.aiModel == AgentKind.hermes.displayName { return "wand.and.stars" }
        if record.aiModel == AgentAskArchiver.aiModel { return "sparkles" }
        return "waveform"
    }
}

// MARK: - Conversation Cell

struct ConversationCell: View {
    let conversation: ConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            // Header
            HStack {
                Image(systemName: ConversationAgentFilter.iconName(for: conversation))
                    .foregroundColor(
                        conversation.aiModel == AgentKind.openclaw.displayName
                            ? Color.purple
                            : conversation.aiModel == AgentKind.hermes.displayName
                                ? Color.teal
                                : conversation.aiModel == AgentAskArchiver.aiModel
                                    ? Color.orange
                                    : AppColors.liveAI
                    )
                    .font(AppTypography.headline)

                Text(conversation.title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            // Summary
            if !conversation.summary.isEmpty {
                Text(conversation.summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)
            }

            // Footer
            HStack(spacing: AppSpacing.md) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "clock")
                        .font(AppTypography.caption)
                    Text(conversation.formattedDate)
                        .font(AppTypography.caption)
                }
                .foregroundColor(AppColors.textSecondary)

                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(AppTypography.caption)
                    Text(String(format: "conversation.messageCount".localized, conversation.messageCount))
                        .font(AppTypography.caption)
                }
                .foregroundColor(AppColors.textSecondary)

                Spacer()
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Translation Records

struct TranslationRecordsView: View {
    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 64))
                    .foregroundColor(AppColors.translate.opacity(0.6))

                Text("records.empty.translate".localized)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("records.comingSoon".localized)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }
}

// MARK: - LeanEat Records

struct LeanEatRecordsView: View {
    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 64))
                    .foregroundColor(AppColors.leanEat.opacity(0.6))

                Text("records.empty.calories".localized)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("records.comingSoon".localized)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }
}

// MARK: - WordLearn Records

struct WordLearnRecordsView: View {
    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 64))
                    .foregroundColor(AppColors.wordLearn.opacity(0.6))

                Text("records.empty.vocabulary".localized)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("records.comingSoon".localized)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }
}

// MARK: - Quick Vision Records

struct QuickVisionRecordsView: View {
    @State private var records: [QuickVisionRecord] = []
    @State private var selectedRecord: QuickVisionRecord?

    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            if records.isEmpty {
                // Empty state
                VStack(spacing: AppSpacing.lg) {
                    Image(systemName: "eye.circle")
                        .font(.system(size: 64))
                        .foregroundColor(AppColors.quickVision.opacity(0.6))

                    Text("quickvision.records.empty".localized)
                        .font(AppTypography.title2)
                        .foregroundColor(AppColors.textPrimary)

                    Text("quickvision.records.empty.hint".localized)
                        .font(AppTypography.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                }
            } else {
                // Records list
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(records) { record in
                            QuickVisionRecordCell(record: record)
                                .onTapGesture {
                                    selectedRecord = record
                                }
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .refreshable {
                    loadRecords()
                }
            }
        }
        .onAppear {
            loadRecords()
        }
        .sheet(item: $selectedRecord) { record in
            QuickVisionRecordDetailView(record: record)
        }
    }

    private func loadRecords() {
        records = QuickVisionStorage.shared.loadAllRecords()
    }
}

// MARK: - Quick Vision Record Cell

struct QuickVisionRecordCell: View {
    let record: QuickVisionRecord

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            // Thumbnail
            if let thumbnail = record.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
            } else {
                RoundedRectangle(cornerRadius: AppCornerRadius.md)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 70, height: 70)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
  }
}

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                // Header
                HStack {
                    Image(systemName: record.mode.icon)
                        .foregroundColor(AppColors.quickVision)
                        .font(AppTypography.subheadline)

                    Text(record.mode.displayName)
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textTertiary)
                }

                // Result summary
                Text(record.summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)

                // Footer
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "clock")
                        .font(AppTypography.caption)
                    Text(record.formattedDate)
                        .font(AppTypography.caption)
                }
                .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }
}

#Preview("Records") {
  RecordsView(streamViewModel: PreviewDependencies().streamViewModel)
}
