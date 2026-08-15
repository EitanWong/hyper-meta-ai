/*
 * Agent Hub View
 * 统一入口: 选择要对话的 Agent (OpenClaw / Hermes / 未来更多)
 */

import SwiftUI

struct AgentHubView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @ObservedObject private var hermesService = HermesService.shared
    @ObservedObject private var navigationRouter = AppNavigationRouter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: AgentKind?
    @State private var showQwenVoice = false
    @State private var summaries: [String: String] = [:]
    /// 最近的历史会话（OpenClaw / Hermes / Qwen 统一时间线，供多会话切换）
    @State private var recentItems: [AgentHubRecentSelection] = []
    @State private var selectedRecent: AgentHubRecentSelection?
    /// 对话记录深链（结果通知 / Spotlight）：直接查看记录详情
    @State private var selectedConversation: ConversationRecord?
    /// 时间线过滤（All / OpenClaw / Hermes / Qwen / Custom）
    @State private var recentFilter: AgentHubRecentFilterChoice = .all
    @State private var searchText = ""
    /// 自定义 HTTP Agent 配置列表（OpenAI 兼容 /v1/chat/completions）
    @State private var customConfigs: [CustomAgentConfig] = []
    @State private var selectedCustomConfig: CustomAgentConfig?
    @State private var showCustomAgentSheet = false
    @State private var editingCustomConfig: CustomAgentConfig?

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(AgentKind.allCases) { kind in
                        Button {
                            selectedKind = kind
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: kind.iconName)
                                    .font(.system(size: 22))
                                    .foregroundColor(kind == .openclaw ? .purple : .teal)
                                    .frame(width: 44, height: 44)
                                    .background(kind == .openclaw ? Color.purple.opacity(0.12) : Color.teal.opacity(0.12))
                                    .cornerRadius(10)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(kind.displayName)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(AppColors.textPrimary)
                                    Text(summary(for: kind) ?? kind.subtitle)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(statusColor(for: kind))
                                        .frame(width: 8, height: 8)
                                    Text(statusText(for: kind))
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textTertiary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                } header: {
                    Text("agents.hub.section".localized)
                } footer: {
                    Text("agents.hub.footer".localized)
                }

                if !recentItems.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                            TextField("agents.hub.recent.search".localized, text: $searchText)
                                .font(.system(size: 15))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(AppColors.textTertiary)
                                }
                            }
                        }
                        .padding(.vertical, 2)

                        if filteredRecentItems.isEmpty {
                            Text("agents.hub.recent.empty".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        ForEach(filteredRecentItems) { item in
                            Button {
                                selectedRecent = item
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: item.kind.iconName)
                                        .font(.system(size: 20))
                                        .foregroundColor(item.kind.tintColor)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            item.kind.tintColor.opacity(0.12)
                                        )
                                        .cornerRadius(9)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(AgentHubRecentDisplay.title(for: item, configNames: customConfigNames))
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(AppColors.textPrimary)
                                            .lineLimit(1)
                                        Text(
                                            AgentHubRecentDisplay.subtitle(
                                                for: item,
                                                configNames: customConfigNames,
                                                dateText: item.record.formattedDate
                                            )
                                        )
                                            .font(AppTypography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textTertiary)
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteRecent(item.record)
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("agents.hub.recent.title".localized)
                            Spacer()
                            Menu {
                                ForEach(
                                    [AgentHubRecentFilterChoice.all]
                                        + AgentHubRecentFilter.availableChoices(recentItems)
                                ) { choice in
                                    Button {
                                        recentFilter = choice
                                    } label: {
                                        if recentFilter == choice {
                                            Label(AgentHubRecentFilter.filterLabel(for: choice), systemImage: "checkmark")
                                        } else {
                                            Text(AgentHubRecentFilter.filterLabel(for: choice))
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(AgentHubRecentFilter.filterLabel(for: recentFilter))
                                    Image(systemName: "chevron.down")
                                }
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showQwenVoice = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "waveform")
                                .font(.system(size: 22))
                                .foregroundColor(.blue)
                                .frame(width: 44, height: 44)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(10)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("qwen.voice.title".localized)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(AppColors.textPrimary)
                                Text(summaries["qwen-audio-agent"] ?? "qwen.voice.subtitle".localized)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("qwen.voice.section".localized)
                }

                Section {
                    if customConfigs.isEmpty {
                        Text("custom.agent.empty".localized)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    ForEach(customConfigs) { config in
                        Button {
                            selectedCustomConfig = config
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "globe")
                                    .font(.system(size: 22))
                                    .foregroundColor(.indigo)
                                    .frame(width: 44, height: 44)
                                    .background(Color.indigo.opacity(0.12))
                                    .cornerRadius(10)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(config.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(AppColors.textPrimary)
                                    Text(summaries["custom." + config.id.uuidString] ?? config.baseURL)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Circle()
                                    .fill(config.isValid ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)

                                Image(systemName: "chevron.right")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textTertiary)
                            }
                            .padding(.vertical, 6)
                        }
                        .contextMenu {
                            Button {
                                editingCustomConfig = config
                                showCustomAgentSheet = true
                            } label: {
                                Label("custom.agent.edit".localized, systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                CustomAgentStore.remove(id: config.id)
                                reloadSummaries()
                            } label: {
                                Label("custom.agent.delete".localized, systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        editingCustomConfig = nil
                        showCustomAgentSheet = true
                    } label: {
                        Label("custom.agent.add".localized, systemImage: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                    }
                } header: {
                    Text("custom.agent.section".localized)
                } footer: {
                    Text("custom.agent.section.footer".localized)
                }
            }
            .fullScreenCover(item: $selectedCustomConfig) { config in
                AgentChatView(
                    kind: .hermes,
                    streamViewModel: streamViewModel,
                    customConfig: config
                )
            }
            .fullScreenCover(item: $selectedRecent) { item in
                if case .ask = item.kind {
                    ConversationDetailView(conversation: item.record, streamViewModel: streamViewModel)
                } else if case .custom(let configID) = item.kind,
                   let config = CustomAgentStore.config(for: configID) {
                    AgentChatView(
                        kind: .hermes,
                        streamViewModel: streamViewModel,
                        initialRecordID: item.record.id,
                        customConfig: config
                    )
                } else if let kind = item.kind.agentKind {
                    AgentChatView(
                        kind: kind,
                        streamViewModel: streamViewModel,
                        initialRecordID: item.record.id
                    )
                } else {
                    QwenVoiceView(
                        streamViewModel: streamViewModel,
                        initialHistoryRecordID: item.record.id
                    )
                }
            }
            .fullScreenCover(item: $selectedConversation) { record in
                ConversationDetailView(conversation: record, streamViewModel: streamViewModel)
            }
            .sheet(isPresented: $showCustomAgentSheet, onDismiss: {
                editingCustomConfig = nil
            }) {
                CustomAgentConfigSheetView(config: editingCustomConfig) {
                    reloadSummaries()
                }
            }
            .navigationTitle("agents.hub.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                reloadSummaries()
                presentPendingConversation()
            }
            .onChange(of: navigationRouter.pendingDestination) { _, _ in
                // Hub 已打开时收到对话记录深链：直接呈现详情
                presentPendingConversation()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if streamViewModel.availableDevices.count > 1 {
                        Menu {
                            ForEach(streamViewModel.availableDevices, id: \.self) { deviceID in
                                Button {
                                    streamViewModel.setPreferredDevice(deviceID)
                                } label: {
                                    if DevicePreferenceStore.preferredDeviceID == deviceID {
                                        Label(streamViewModel.deviceDisplayName(deviceID), systemImage: "checkmark")
                                    } else {
                                        Text(streamViewModel.deviceDisplayName(deviceID))
                                    }
                                }
                            }
                            Divider()
                            Button("device.auto".localized) {
                                streamViewModel.setPreferredDevice(nil)
                            }
                        } label: {
                            Image(systemName: "smartglasses")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(item: $selectedKind) { kind in
                AgentChatView(kind: kind, streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showQwenVoice) {
                QwenVoiceView(streamViewModel: streamViewModel)
            }
        }
    }

    // MARK: - Helpers

    /// 最近会话摘要；无记录时回退到固定副标题
    private func summary(for kind: AgentKind) -> String? {
        summaries[kind.displayName]
    }

    /// 时间线展示列表：先按 Agent 过滤，再按关键字搜索（标题 / 摘要）
    private var filteredRecentItems: [AgentHubRecentSelection] {
        AgentHubRecentFilter.search(
            AgentHubRecentFilter.filter(recentItems, choice: recentFilter),
            query: searchText,
            configNames: customConfigNames
        )
    }

    /// 自定义 Agent 配置名索引（时间线显示配置名用）
    private var customConfigNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: customConfigs.map { ($0.id, $0.name) })
    }

    private func reloadSummaries() {
        customConfigs = CustomAgentStore.configs
        let records = ConversationStorage.shared.loadAllConversations()
        var latest: [String: String] = [:]
        for record in records {
            let summary = record.summary
            guard !summary.isEmpty else { continue }
            if latest[record.aiModel] == nil {
                latest[record.aiModel] = summary
            }
        }
        summaries = latest
        recentItems = Array(
            records.compactMap { record in
                AgentHubRecentKind.kind(for: record.aiModel).map {
                    AgentHubRecentSelection(record: record, kind: $0)
                }
            }
            .prefix(8)
        )
    }

    /// 删除一条历史会话并从列表移除
    private func deleteRecent(_ record: ConversationRecord) {
        ConversationStorage.shared.deleteConversation(record.id)
        reloadSummaries()
    }

    /// 对话记录深链（结果通知 / Spotlight）：消费路由请求并呈现对应记录详情
    private func presentPendingConversation() {
        guard case .conversation(let recordID)? = navigationRouter.consume(where: {
            if case .conversation = $0 { return true }
            return false
        }) else { return }
        guard let record = ConversationStorage.shared.getConversation(by: recordID) else { return }
        selectedConversation = record
    }

    private func state(for kind: AgentKind) -> AgentConnectionState {
        switch kind {
        case .openclaw: return AgentConnectionState.map(openClawService.connectionState)
        case .hermes: return AgentConnectionState.map(hermesService.connectionState)
        }
    }

    private func statusColor(for kind: AgentKind) -> Color {
        switch state(for: kind) {
        case .connected: return .green
        case .connecting: return .orange
        case .waitingForPairing: return .yellow
        case .failed: return .red
        case .unknown: return .gray
        }
    }

    private func statusText(for kind: AgentKind) -> String {
        switch state(for: kind) {
        case .connected: return "agents.status.connected".localized
        case .connecting: return "agents.status.connecting".localized
        case .waitingForPairing: return "agents.status.pairing".localized
        case .failed(let message): return message.isEmpty ? "agents.status.disconnected".localized : message
        case .unknown: return "agents.status.disconnected".localized
        }
    }
}

/// Hub 最近会话的 Agent 归类（纯映射，可测）
enum AgentHubRecentKind: Equatable, Hashable {
    case openclaw
    case hermes
    case qwen
    /// 「问 JARVIS」后台单轮问答结果（Hub 时间线独立归类）
    case ask
    /// 自定义 HTTP Agent：携带配置 ID，用于恢复聊天与路由
    case custom(UUID)

    private static let customPrefix = "custom."

    /// 记录 aiModel → Hub 条目；未知 Agent 返回 nil（不进入 Recent 时间线）
    static func kind(for aiModel: String) -> AgentHubRecentKind? {
        switch aiModel {
        case AgentKind.openclaw.displayName: return .openclaw
        case AgentKind.hermes.displayName: return .hermes
        case "qwen-audio-agent": return .qwen
        case AgentAskArchiver.aiModel: return .ask
        default:
            guard aiModel.hasPrefix(customPrefix),
                  let id = UUID(uuidString: String(aiModel.dropFirst(customPrefix.count))) else {
                return nil
            }
            return .custom(id)
        }
    }

    /// 列表图标（与 Agent 统一图标一致）
    var iconName: String {
        switch self {
        case .openclaw: return "link.circle.fill"
        case .hermes: return "wand.and.stars"
        case .qwen: return "waveform"
        case .ask: return "sparkles"
        case .custom: return "globe"
        }
    }

    /// 列表着色
    var tintColor: Color {
        switch self {
        case .openclaw: return .purple
        case .hermes: return .teal
        case .qwen: return .blue
        case .ask: return .orange
        case .custom: return .indigo
        }
    }

    /// 进入聊天页的 Agent；Qwen 走语音页（返回 nil）
    var agentKind: AgentKind? {
        switch self {
        case .openclaw: return .openclaw
        case .hermes: return .hermes
        case .qwen: return nil
        case .ask: return nil
        case .custom: return .hermes
        }
    }
}

/// Hub 最近时间线的过滤选项（稳定类别，避免 custom UUID 作为视图身份）
enum AgentHubRecentFilterChoice: String, CaseIterable, Identifiable, Hashable {
    case all
    case openclaw
    case hermes
    case qwen
    case ask
    case custom

    var id: String { rawValue }
}

/// Hub 最近时间线的过滤 / 搜索纯逻辑（不依赖视图，可测）
enum AgentHubRecentFilter {
    /// 过滤器标签；品牌名不翻译，自定义与全部走本地化
    static func filterLabel(for choice: AgentHubRecentFilterChoice) -> String {
        switch choice {
        case .all: return "agents.hub.recent.filter.all".localized
        case .openclaw: return AgentKind.openclaw.displayName
        case .hermes: return AgentKind.hermes.displayName
        case .qwen: return "Qwen"
        case .ask: return "agents.hub.recent.filter.ask".localized
        case .custom: return "agents.hub.recent.filter.custom".localized
        }
    }

    /// 时间线里实际存在的类别（去重、固定顺序：OpenClaw → Hermes → Qwen → 问 JARVIS → 自定义）
    static func availableChoices(_ items: [AgentHubRecentSelection]) -> [AgentHubRecentFilterChoice] {
        var result: [AgentHubRecentFilterChoice] = []
        if items.contains(where: { $0.kind == .openclaw }) { result.append(.openclaw) }
        if items.contains(where: { $0.kind == .hermes }) { result.append(.hermes) }
        if items.contains(where: { $0.kind == .qwen }) { result.append(.qwen) }
        if items.contains(where: { $0.kind == .ask }) { result.append(.ask) }
        if items.contains(where: { if case .custom = $0.kind { return true }; return false }) {
            result.append(.custom)
        }
        return result
    }

    /// 单条是否命中过滤器；自定义类别统一命中任意 custom 配置
    static func matches(_ item: AgentHubRecentSelection, choice: AgentHubRecentFilterChoice) -> Bool {
        switch (choice, item.kind) {
        case (.all, _): return true
        case (.openclaw, .openclaw): return true
        case (.hermes, .hermes): return true
        case (.qwen, .qwen): return true
        case (.ask, .ask): return true
        case (.custom, .custom): return true
        default: return false
        }
    }

    /// 按 Agent 过滤（All 不过滤）
    static func filter(
        _ items: [AgentHubRecentSelection],
        choice: AgentHubRecentFilterChoice
    ) -> [AgentHubRecentSelection] {
        guard choice != .all else { return items }
        return items.filter { matches($0, choice: choice) }
    }

    /// 按关键字搜索（标题 / 摘要，自定义 Agent 额外命中配置名；大小写不敏感；空查询不过滤）
    static func search(
        _ items: [AgentHubRecentSelection],
        query: String,
        configNames: [UUID: String] = [:]
    ) -> [AgentHubRecentSelection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            if item.record.title.localizedCaseInsensitiveContains(trimmed)
                || item.record.summary.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            guard case .custom(let id) = item.kind, let name = configNames[id] else {
                return false
            }
            return name.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

/// Recent 时间线条目（记录 + 归类，供跳转路由）
struct AgentHubRecentSelection: Identifiable {
    let record: ConversationRecord
    let kind: AgentHubRecentKind
    var id: UUID { record.id }
}

/// Hub 最近时间线的显示文本（纯映射，可测）：
/// 自定义 Agent 会话显示「配置名」（第二行带记录标题），内置 Agent 显示记录标题
enum AgentHubRecentDisplay {
    /// 第一行：自定义 Agent 显示配置名；未找到或空名回退记录标题
    static func title(
        for item: AgentHubRecentSelection,
        configNames: [UUID: String]
    ) -> String {
        if case .custom(let id) = item.kind,
           let name = configNames[id],
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return item.record.title
    }

    /// 第二行：自定义 Agent 显示「记录标题 · 日期」；内置 Agent 直接显示日期
    static func subtitle(
        for item: AgentHubRecentSelection,
        configNames: [UUID: String],
        dateText: String
    ) -> String {
        if case .custom = item.kind {
            return item.record.title + " · " + dateText
        }
        return dateText
    }
}

#Preview("Agent Hub") {
    AgentHubView(streamViewModel: PreviewDependencies().streamViewModel)
}
