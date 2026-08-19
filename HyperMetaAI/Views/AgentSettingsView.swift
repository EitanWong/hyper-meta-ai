/*
 * Agent Settings View
 * 统一的 Agent 设置页: 在 OpenClaw / Hermes 之间切换，配置各自连接
 */

import SwiftUI
import UIKit

/// Agent 设置页内的可定位分区（深链用）
enum AgentSettingsSection: String {
    case memory
    case rules
    case lists
    case reminders
    case calendar
}

struct AgentSettingsView: View {
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @ObservedObject private var hermesService = HermesService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selectedKind: AgentKind
    /// 首次出现时滚动定位的分区（深链；定位后清空，只生效一次）
    @State private var initialSection: AgentSettingsSection?
    @State private var showSaveSuccess = false

    // OpenClaw fields
    @State private var openClawHost = ""
    @State private var openClawPortText = ""
    @State private var openClawToken = ""
    @State private var openClawUsesTLS = false

    // Hermes fields
    @State private var hermesHost = ""
    @State private var hermesPortText = ""
    @State private var hermesAPIKey = ""
    @State private var hermesModel = ""
    @State private var hermesConversation = ""
    @State private var hermesUsesTLS = false
    @State private var voiceReplyEnabled = AgentVoiceSettings.replyEnabled
    @State private var approvalPromptEnabled = AgentVoiceSettings.approvalPromptEnabled
    @State private var quietModeEnabled = AgentVoiceSettings.quietModeEnabled
    @State private var liveActivityEnabled = AgentLiveActivityManager.isEnabled
    @State private var permissionMode = AgentPermissionSettings.mode
    @State private var shortcuts = AgentShortcutStore.shortcuts
    @State private var showAddShortcut = false
    @State private var shortcutTitle = ""
    @State private var shortcutPrompt = ""
    @State private var memoryEnabled = AgentMemorySettings.enabled
    @State private var memoryEntries = AgentMemoryStore.entries
    @State private var memoryCandidates = AgentMemoryCandidateStore.candidates
    @State private var showAddMemory = false
    @State private var memoryInput = ""
    @State private var persona = AgentPersonaStore.current
    @State private var ruleEntries = AgentRuleStore.entries
    @State private var showAddRule = false
    @State private var ruleInput = ""
    @State private var lists = AgentListStore.lists
    @State private var showNewList = false
    @State private var newListName = ""
    @State private var showAddItem = false
    @State private var itemInput = ""
    @State private var listForItemID: UUID?
    @State private var showRenameList = false
    @State private var renameInput = ""
    @State private var renamingListID: UUID?
    @State private var showRenameError = false
    @State private var calendarAuthorization: AgentCalendarAuthorization = .notDetermined
    @State private var calendarEventAlertsEnabled = AgentCalendarNotificationSettings.enabled
    @State private var calendarEventLeadMinutes = AgentCalendarNotificationSettings.leadTimeMinutes
    @State private var calendarOverviewRows: [AgentCalendarOverviewMapping.GroupedEvents] = []
    @State private var calendarOverviewLoaded = false
    @State private var selectedCalendarEvent: AgentCalendarEvent?
    @State private var showCalendarDetail = false
    @State private var reminders = AgentReminderStore.reminders
    /// 「稍后提醒」成功触觉反馈触发器（每次执行递增）
    @State private var snoozeFeedbackTicks = 0
    /// 「完成」过渡中的提醒 id（划线 → 自动移除，窗口内可撤销）
    @State private var completingIDs: Set<UUID> = []
    /// 「完成」自动移除任务（撤销时取消）
    @State private var completionTasks: [UUID: Task<Void, Never>] = [:]
    /// 「完成」成功触觉反馈触发器（每次执行递增）
    @State private var completionFeedbackTicks = 0
    @State private var briefingEnabled = AgentBriefingStore.current.enabled
    @State private var briefingTime: Date = {
        let settings = AgentBriefingStore.current
        return Calendar.current.date(
            bySettingHour: settings.hour,
            minute: settings.minute,
            second: 0,
            of: Date()
        ) ?? Date()
    }()
    @State private var briefingIncludeSchedule = AgentBriefingStore.current.includeSchedule
    @State private var briefingIncludeReminders = AgentBriefingStore.current.includeReminders
    @State private var briefingIncludeTasks = AgentBriefingStore.current.includeTasks
    @State private var showBriefingPreview = false
    @State private var briefingPreviewText = ""

    // Qwen Gateway：表单由 QwenGatewayConfigurationSections 渲染，这里只持有草稿与保存反馈
    @State private var qwenDraft = QwenGatewayDraft()
    @State private var qwenSaved = false
    @State private var visionInjectionEnabled = AgentVisionSettings.injectionEnabled
    @State private var visionFollowUpEnabled = AgentVisionSettings.followUpEnabled
    @State private var brainDefault = AgentBrainSettings.selected
    @State private var askResultNotifyEnabled = AgentAskResultSettings.enabled()
    @State private var customBrainConfigID = AgentBrainSettings.selectedCustomAgentID
    @State private var customTaskKeywords = AgentRoutingSettings.customTaskKeywords
    @State private var customChatKeywords = AgentRoutingSettings.customChatKeywords
    @State private var taskKeywordInput = ""
    @State private var chatKeywordInput = ""
    @State private var approvalTimeout = AgentTimingSettings.approvalTimeout
    @State private var thinkingHintDelay = AgentTimingSettings.thinkingHintDelay
    @State private var auditEntries: [AgentAuditEntry] = []
    @State private var revokedToolIDs: Set<String> = AgentRevokeStore.revokedToolIDs
    @State private var voiceHistoryEnabled = AgentMemorySettings.voiceHistoryEnabled
    @State private var chatHistoryEnabled = AgentMemorySettings.chatHistoryEnabled
    @State private var showClearVoiceHistoryConfirm = false
    @State private var showClearVisionDataConfirm = false

    @ObservedObject private var qwenGateway = QwenGatewayService.shared

    init(initialKind: AgentKind = .openclaw, initialSection: AgentSettingsSection? = nil) {
        _selectedKind = State(initialValue: initialKind)
        _initialSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("agents.settings.agent".localized, selection: $selectedKind) {
                        ForEach(AgentKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("agent.voice.reply.toggle".localized, isOn: $voiceReplyEnabled)
                        .onChange(of: voiceReplyEnabled) { _, newValue in
                            AgentVoiceSettings.replyEnabled = newValue
                        }
                } footer: {
                    Text("agent.voice.reply.footer".localized)
                }

                Section {
                    Toggle("agent.voice.approval.prompt.toggle".localized, isOn: $approvalPromptEnabled)
                        .onChange(of: approvalPromptEnabled) { _, newValue in
                            AgentVoiceSettings.approvalPromptEnabled = newValue
                        }
                } footer: {
                    Text("agent.voice.approval.prompt.footer".localized)
                }

                Section {
                    Toggle("agent.voice.quiet.toggle".localized, isOn: $quietModeEnabled)
                        .onChange(of: quietModeEnabled) { _, newValue in
                            AgentVoiceSettings.quietModeEnabled = newValue
                        }
                } footer: {
                    Text("agent.voice.quiet.footer".localized)
                }

                Section {
                    Toggle("agent.liveactivity.toggle".localized, isOn: $liveActivityEnabled)
                        .onChange(of: liveActivityEnabled) { _, newValue in
                            AgentLiveActivityManager.isEnabled = newValue
                            if !newValue {
                                AgentLiveActivityManager.end()
                            }
                        }
                } footer: {
                    Text("agent.liveactivity.footer".localized)
                }

                Section {
                    Picker("agent.permission.mode.title".localized, selection: $permissionMode) {
                        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: permissionMode) { _, newValue in
                        AgentPermissionSettings.mode = newValue
                    }
                } footer: {
                    Text(permissionMode.detail)
                }

                Section {
                    if shortcuts.isEmpty {
                        Text("agent.shortcuts.empty".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    ForEach(shortcuts) { shortcut in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.title)
                                .font(.system(size: 14, weight: .medium))
                            Text(shortcut.prompt)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            AgentShortcutStore.remove(id: shortcuts[index].id)
                        }
                        shortcuts = AgentShortcutStore.shortcuts
                    }
                    Button("agent.shortcuts.add".localized) {
                        showAddShortcut = true
                    }
                } header: {
                    Text("agent.shortcuts.section".localized)
                } footer: {
                    Text("agent.shortcuts.footer".localized)
                }
                .sheet(isPresented: $showAddShortcut) {
                    NavigationView {
                        Form {
                            Section {
                                TextField("agent.shortcuts.title.label".localized, text: $shortcutTitle)
                                TextField("agent.shortcuts.prompt.label".localized, text: $shortcutPrompt)
                            } footer: {
                                Text("agent.shortcuts.limit".localized)
                            }
                        }
                        .navigationTitle("agent.shortcuts.add".localized)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("agent.shortcuts.cancel".localized) {
                                    showAddShortcut = false
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("agent.shortcuts.save".localized) {
                                    if AgentShortcutStore.add(title: shortcutTitle, prompt: shortcutPrompt) {
                                        shortcuts = AgentShortcutStore.shortcuts
                                        shortcutTitle = ""
                                        shortcutPrompt = ""
                                        showAddShortcut = false
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("agent.persona.toggle".localized, isOn: $persona.enabled)
                        .onChange(of: persona.enabled) { _, newValue in
                            AgentPersonaStore.save(
                                name: persona.name,
                                role: persona.role,
                                style: persona.style,
                                enabled: newValue
                            )
                            persona = AgentPersonaStore.current
                        }
                    TextField("agent.persona.name.placeholder".localized, text: $persona.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(savePersona)
                    TextField("agent.persona.role.placeholder".localized, text: $persona.role)
                        .onSubmit(savePersona)
                    TextField("agent.persona.style.placeholder".localized, text: $persona.style)
                        .onSubmit(savePersona)
                    Button("agent.persona.reset".localized) {
                        AgentPersonaStore.reset()
                        persona = AgentPersonaStore.current
                    }
                } header: {
                    Text("agent.persona.section".localized)
                } footer: {
                    Text("agent.persona.footer".localized)
                }

                Section {
                    Toggle("agent.memory.toggle".localized, isOn: $memoryEnabled)
                        .onChange(of: memoryEnabled) { _, newValue in
                            AgentMemorySettings.enabled = newValue
                        }
                    if memoryEntries.isEmpty {
                        Text("agent.memory.empty".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    ForEach(memoryEntries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .font(.system(size: 13))
                            Text(AgentTaskTimeFormatter.relativeTime(from: entry.date))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            AgentMemoryStore.remove(id: memoryEntries[index].id)
                        }
                        memoryEntries = AgentMemoryStore.entries
                    }
                    if !memoryCandidates.isEmpty {
                        Text("agent.memory.candidates.title".localized)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        ForEach(memoryCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.text)
                                    .font(.system(size: 13))
                                Text(AgentTaskTimeFormatter.relativeTime(from: candidate.date))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("agent.memory.candidates.accept".localized) {
                                    AgentMemoryCandidateStore.accept(id: candidate.id)
                                    memoryCandidates = AgentMemoryCandidateStore.candidates
                                    memoryEntries = AgentMemoryStore.entries
                                }
                                .tint(.green)
                                Button("agent.memory.candidates.ignore".localized, role: .destructive) {
                                    AgentMemoryCandidateStore.ignore(id: candidate.id)
                                    memoryCandidates = AgentMemoryCandidateStore.candidates
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                AgentMemoryCandidateStore.ignore(id: memoryCandidates[index].id)
                            }
                            memoryCandidates = AgentMemoryCandidateStore.candidates
                        }
                    }
                    Button("agent.memory.add".localized) {
                        memoryInput = ""
                        showAddMemory = true
                    }
                    if !memoryEntries.isEmpty {
                        Button("agent.memory.clear".localized, role: .destructive) {
                            AgentMemoryStore.clear()
                            memoryEntries = []
                        }
                    }
                } header: {
                    Text("agent.memory.section".localized)
                } footer: {
                    Text("agent.memory.footer".localized)
                }
                .id(AgentSettingsSection.memory.rawValue)
                .onAppear {
                    memoryCandidates = AgentMemoryCandidateStore.candidates
                }
                .alert("agent.memory.add".localized, isPresented: $showAddMemory) {
                    TextField("agent.memory.input.placeholder".localized, text: $memoryInput)
                    Button("agent.memory.save".localized) {
                        if AgentMemoryStore.add(text: memoryInput) {
                            memoryEntries = AgentMemoryStore.entries
                        }
                        memoryInput = ""
                    }
                    Button("agent.memory.cancel".localized, role: .cancel) {
                        memoryInput = ""
                    }
                } message: {
                    Text("agent.memory.add.message".localized)
                }

                Section {
                    if ruleEntries.isEmpty {
                        Text("agent.rules.empty".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    ForEach(ruleEntries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .font(.system(size: 13))
                            Text(AgentTaskTimeFormatter.relativeTime(from: entry.date))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            AgentRuleStore.remove(id: ruleEntries[index].id)
                        }
                        ruleEntries = AgentRuleStore.entries
                    }
                    Button("agent.rules.add".localized) {
                        ruleInput = ""
                        showAddRule = true
                    }
                    if !ruleEntries.isEmpty {
                        Button("agent.rules.clear".localized, role: .destructive) {
                            AgentRuleStore.clear()
                            ruleEntries = []
                        }
                    }
                } header: {
                    Text("agent.rules.section".localized)
                } footer: {
                    Text("agent.rules.footer".localized)
                }
                .id(AgentSettingsSection.rules.rawValue)
                .alert("agent.rules.add".localized, isPresented: $showAddRule) {
                    TextField("agent.rules.input.placeholder".localized, text: $ruleInput)
                    Button("agent.rules.save".localized) {
                        if AgentRuleStore.add(text: ruleInput) {
                            ruleEntries = AgentRuleStore.entries
                        }
                        ruleInput = ""
                    }
                    Button("agent.rules.cancel".localized, role: .cancel) {
                        ruleInput = ""
                    }
                } message: {
                    Text("agent.rules.add.message".localized)
                }

                Section {
                    if lists.isEmpty {
                        Text("agent.list.empty".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    ForEach(lists) { list in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(list.name)
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Button {
                                    renamingListID = list.id
                                    renameInput = list.name
                                    showRenameList = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                                Text("\(list.items.count)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            if list.items.isEmpty {
                                Text("agent.list.empty".localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            ForEach(list.items, id: \.self) { item in
                                HStack {
                                    Text(item)
                                        .font(.system(size: 13))
                                    Spacer()
                                    Button {
                                        AgentListStore.removeItem(item, from: list.name)
                                        lists = AgentListStore.lists
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            Button("agent.list.add.item".localized) {
                                listForItemID = list.id
                                itemInput = ""
                                showAddItem = true
                            }
                            .font(.system(size: 13))
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            AgentListStore.removeList(id: lists[index].id)
                        }
                        lists = AgentListStore.lists
                    }
                    Button("agent.list.new".localized) {
                        newListName = ""
                        showNewList = true
                    }
                } header: {
                    Text("agent.list.section".localized)
                } footer: {
                    Text("agent.list.footer".localized)
                }
                .id(AgentSettingsSection.lists.rawValue)
                .alert("agent.list.new".localized, isPresented: $showNewList) {
                    TextField("agent.list.new.prompt".localized, text: $newListName)
                    Button("agent.memory.save".localized) {
                        _ = AgentListStore.createList(named: newListName)
                        newListName = ""
                        lists = AgentListStore.lists
                    }
                    Button("agent.memory.cancel".localized, role: .cancel) {
                        newListName = ""
                    }
                }
                .alert("agent.list.add.item".localized, isPresented: $showAddItem) {
                    TextField("agent.list.add.item.prompt".localized, text: $itemInput)
                    Button("agent.memory.save".localized) {
                        if let id = listForItemID,
                           let list = lists.first(where: { $0.id == id }) {
                            _ = AgentListStore.addItem(itemInput, to: list.name)
                        }
                        itemInput = ""
                        listForItemID = nil
                        lists = AgentListStore.lists
                    }
                    Button("agent.memory.cancel".localized, role: .cancel) {
                        itemInput = ""
                        listForItemID = nil
                    }
                }
                .alert("agent.list.rename".localized, isPresented: $showRenameList) {
                    TextField("agent.list.rename.prompt".localized, text: $renameInput)
                    Button("agent.memory.save".localized) {
                        if let id = renamingListID {
                            if AgentListStore.renameList(id: id, to: renameInput) == nil {
                                showRenameError = true
                            }
                        }
                        renamingListID = nil
                        renameInput = ""
                        lists = AgentListStore.lists
                    }
                    Button("agent.memory.cancel".localized, role: .cancel) {
                        renamingListID = nil
                        renameInput = ""
                    }
                }
                .alert("agent.list.rename.failed".localized, isPresented: $showRenameError) {
                    Button("agent.memory.ok".localized, role: .cancel) {}
                }

                Section {
                    if reminders.isEmpty {
                        Text("agent.reminder.empty".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    ForEach(reminders) { reminder in
                        let isCompleting = completingIDs.contains(reminder.id)
                        HStack(spacing: 10) {
                            Button {
                                if isCompleting {
                                    undoReminderCompletion(reminder)
                                } else {
                                    completeReminder(reminder)
                                }
                            } label: {
                                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundColor(isCompleting ? .green : Color(.tertiaryLabel))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                isCompleting
                                    ? "agent.reminder.undo".localized
                                    : "agent.reminder.action.complete".localized
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(reminder.text)
                                        .font(.system(size: 13))
                                        .strikethrough(isCompleting)
                                    if reminder.repeatRule != .none {
                                        Text(AgentReminderTimeFormatter.repeatBadge(reminder.repeatRule))
                                            .font(.system(size: 10))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(Capsule())
                                            .opacity(isCompleting ? 0.5 : 1)
                                    }
                                }
                                Text(AgentReminderTimeFormatter.announcementDescription(for: reminder))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .strikethrough(isCompleting)
                                    .opacity(isCompleting ? 0.5 : 1)
                            }
                            .foregroundColor(isCompleting ? .secondary : .primary)
                            Spacer()
                            if isCompleting {
                                Button("agent.reminder.undo".localized) {
                                    undoReminderCompletion(reminder)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            // 已到点单次提醒：与锁屏通知 Action 一致的「稍后提醒」重排
                            if AgentReminderSnoozePolicy.canSnooze(reminder, now: Date()) {
                                Button {
                                    snoozeReminder(reminder)
                                } label: {
                                    Label(
                                        "agent.reminder.action.snooze".localized,
                                        systemImage: "alarm"
                                    )
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let reminder = reminders[index]
                            AgentReminderScheduler.cancel(id: reminder.id)
                            AgentReminderStore.remove(id: reminder.id)
                        }
                        reminders = AgentReminderStore.reminders
                    }
                    if !reminders.isEmpty {
                        Button("agent.reminder.clear".localized, role: .destructive) {
                            AgentReminderScheduler.cancelAll()
                            AgentReminderStore.clear()
                            reminders = []
                        }
                    }
                } header: {
                    Text("agent.reminder.section".localized)
                } footer: {
                    Text("agent.reminder.footer".localized)
                }
                .onAppear {
                    reminders = AgentReminderStore.reminders
                }
                .sensoryFeedback(.success, trigger: snoozeFeedbackTicks)
                .sensoryFeedback(.success, trigger: completionFeedbackTicks)
                .onDisappear {
                    completionTasks.values.forEach { $0.cancel() }
                    completionTasks.removeAll()
                    completingIDs.removeAll()
                }
                .id(AgentSettingsSection.reminders.rawValue)

                Section {
                    HStack(spacing: 8) {
                        Label("agent.settings.calendar.title".localized, systemImage: "calendar")
                            .font(.system(size: 15))
                        Spacer()
                        Text(AgentCalendarSettings.statusText(for: calendarAuthorization))
                            .font(.system(size: 13))
                            .foregroundColor(calendarStatusColor)
                    }
                    switch AgentCalendarSettings.action(for: calendarAuthorization) {
                    case .request:
                        Button("agent.settings.calendar.action.request".localized) {
                            Task {
                                let result = await AgentCalendar.provider.requestAuthorization()
                                calendarAuthorization = result
                                await loadCalendarOverview()
                            }
                        }
                    case .openSettings:
                        Button("agent.settings.calendar.action.settings".localized) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    case .none:
                        EmptyView()
                    }
                    Toggle("agent.calendar.notify.toggle".localized, isOn: $calendarEventAlertsEnabled)
                        .onChange(of: calendarEventAlertsEnabled) { _, newValue in
                            AgentCalendarNotificationSettings.enabled = newValue
                            if newValue {
                                Task {
                                    let center = UNUserNotificationCenter.current()
                                    let settings = await center.notificationSettings()
                                    if settings.authorizationStatus == .notDetermined {
                                        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                                    }
                                    await AgentCalendarCountdownCoordinator.sync()
                                }
                            } else {
                                AgentCalendarNotificationScheduler.cancelAll()
                            }
                        }
                    if calendarEventAlertsEnabled {
                        Picker("agent.calendar.notify.lead".localized, selection: $calendarEventLeadMinutes) {
                            ForEach(AgentCalendarNotificationSettings.leadOptions, id: \.self) { minutes in
                                Text(String(format: "agent.calendar.notify.lead.minutes".localized, minutes))
                                    .tag(minutes)
                            }
                        }
                        .onChange(of: calendarEventLeadMinutes) { _, newValue in
                            AgentCalendarNotificationSettings.leadTimeMinutes = newValue
                            Task { await AgentCalendarCountdownCoordinator.sync() }
                        }
                    }
                } header: {
                    Text("agent.settings.calendar.title".localized)
                } footer: {
                    Text(calendarEventAlertsEnabled
                        ? "agent.settings.calendar.footer.alertsOn".localized
                        : "agent.settings.calendar.footer".localized)
                }
                .onAppear {
                    calendarAuthorization = AgentCalendar.provider.authorization
                    Task { await loadCalendarOverview() }
                }
                .id(AgentSettingsSection.calendar.rawValue)

                Section {
                    switch calendarAuthorization {
                    case .authorized:
                        if calendarOverviewLoaded {
                            if calendarOverviewRows.isEmpty {
                                Label(
                                    "agent.settings.calendar.events.empty".localized,
                                    systemImage: "calendar.badge.exclamationmark"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            } else {
                                ForEach(calendarOverviewRows, id: \.group) { dayGroup in
                                    Text(dayGroup.group.titleKey.localized)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    ForEach(Array(dayGroup.events.enumerated()), id: \.offset) { _, event in
                                        let row = AgentCalendarOverviewMapping.row(for: event)
                                        Button {
                                            selectedCalendarEvent = event
                                            showCalendarDetail = true
                                        } label: {
                                            HStack(spacing: 10) {
                                                Text(row.timeText)
                                                    .font(.subheadline.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                    .frame(minWidth: 52, alignment: .leading)
                                                Text(row.title)
                                                    .lineLimit(1)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(row.timeText) \(row.title)")
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("agent.settings.calendar.events.loading".localized)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    default:
                        Label(
                            "agent.settings.calendar.events.unauthorized".localized,
                            systemImage: "lock"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("agent.settings.calendar.events.section".localized)
                } footer: {
                    Text("agent.settings.calendar.events.footer".localized)
                }

                Section {
                    Toggle("agent.briefing.toggle".localized, isOn: $briefingEnabled)
                        .onChange(of: briefingEnabled) { _, newValue in
                            AgentBriefingStore.update { $0.enabled = newValue }
                            Task { await AgentBriefingScheduler.sync() }
                        }
                    if briefingEnabled {
                        DatePicker(
                            "agent.briefing.time".localized,
                            selection: $briefingTime,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: briefingTime) { _, newValue in
                            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            AgentBriefingStore.update {
                                $0.hour = components.hour ?? 8
                                $0.minute = components.minute ?? 0
                            }
                            Task { await AgentBriefingScheduler.sync() }
                        }
                        Toggle("agent.briefing.include.schedule".localized, isOn: $briefingIncludeSchedule)
                            .onChange(of: briefingIncludeSchedule) { _, newValue in
                                AgentBriefingStore.update { $0.includeSchedule = newValue }
                                Task { await AgentBriefingScheduler.sync() }
                            }
                        Toggle("agent.briefing.include.reminders".localized, isOn: $briefingIncludeReminders)
                            .onChange(of: briefingIncludeReminders) { _, newValue in
                                AgentBriefingStore.update { $0.includeReminders = newValue }
                                Task { await AgentBriefingScheduler.sync() }
                            }
                        Toggle("agent.briefing.include.tasks".localized, isOn: $briefingIncludeTasks)
                            .onChange(of: briefingIncludeTasks) { _, newValue in
                                AgentBriefingStore.update { $0.includeTasks = newValue }
                                Task { await AgentBriefingScheduler.sync() }
                            }
                        Button {
                            Task {
                                let content = await AgentBriefingScheduler.buildContent(
                                    settings: AgentBriefingStore.current
                                )
                                briefingPreviewText = content.fullText
                                showBriefingPreview = true
                            }
                        } label: {
                            Label("agent.briefing.preview".localized, systemImage: "sunrise.fill")
                        }
                    }
                } header: {
                    Text("agent.briefing.section".localized)
                } footer: {
                    Text("agent.briefing.footer".localized)
                }
                .alert("agent.briefing.preview.title".localized, isPresented: $showBriefingPreview) {
                    Button("agent.memory.ok".localized, role: .cancel) {}
                } message: {
                    Text(briefingPreviewText)
                }

                Section {
                    Toggle("agent.vision.injection.toggle".localized, isOn: $visionInjectionEnabled)
                        .onChange(of: visionInjectionEnabled) { _, newValue in
                            AgentVisionSettings.injectionEnabled = newValue
                        }
                    Toggle("agent.vision.followup.toggle".localized, isOn: $visionFollowUpEnabled)
                        .onChange(of: visionFollowUpEnabled) { _, newValue in
                            AgentVisionSettings.followUpEnabled = newValue
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("agent.vision.injection.footer".localized)
                        Text("agent.vision.followup.footer".localized)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showClearVisionDataConfirm = true
                    } label: {
                        Label("agent.vision.privacy.clear".localized, systemImage: "trash")
                    }
                } header: {
                    Text("agent.vision.privacy.header".localized)
                } footer: {
                    Text("agent.vision.privacy.footer".localized)
                }
                .confirmationDialog(
                    "agent.vision.privacy.confirm".localized,
                    isPresented: $showClearVisionDataConfirm,
                    titleVisibility: .visible
                ) {
                    Button("agent.vision.privacy.confirm.button".localized, role: .destructive) {
                        AgentVisionDataPrivacy.clearAll()
                    }
                    Button("cancel".localized, role: .cancel) {}
                }

                Section {
                    Picker("agent.brain.default.toggle".localized, selection: $brainDefault) {
                        ForEach(AgentBrain.allCases) { brain in
                            Text(brain.displayName).tag(brain)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: brainDefault) { _, newValue in
                        AgentBrainSettings.selected = newValue
                    }
                    .onChange(of: customBrainConfigID) { _, newValue in
                        AgentBrainSettings.selectedCustomAgentID = newValue
                    }
                    if brainDefault == .custom {
                        Picker("custom.agent.brain.config".localized, selection: $customBrainConfigID) {
                            ForEach(CustomAgentStore.configs) { config in
                                Text(config.name).tag(Optional(config.id))
                            }
                        }
                        if CustomAgentStore.configs.isEmpty {
                            Text("custom.agent.brain.noconfig.hint".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                } footer: {
                    Text("agent.brain.default.footer".localized)
                }

                Section {
                    Toggle("agent.ask.notify.result".localized, isOn: $askResultNotifyEnabled)
                        .onChange(of: askResultNotifyEnabled) { _, newValue in
                            AgentAskResultSettings.setEnabled(newValue)
                        }
                } footer: {
                    Text("agent.ask.notify.result.footer".localized)
                }

                Section {
                    Picker("agent.timing.approval.picker".localized, selection: $approvalTimeout) {
                        Text("agent.timing.30s".localized).tag(TimeInterval(30))
                        Text("agent.timing.60s".localized).tag(TimeInterval(60))
                        Text("agent.timing.120s".localized).tag(TimeInterval(120))
                        Text("agent.timing.never".localized).tag(TimeInterval(0))
                    }
                    .onChange(of: approvalTimeout) { _, newValue in
                        AgentTimingSettings.approvalTimeout = newValue
                    }
                    Picker("agent.timing.hint.picker".localized, selection: $thinkingHintDelay) {
                        Text("agent.timing.5s".localized).tag(TimeInterval(5))
                        Text("agent.timing.8s".localized).tag(TimeInterval(8))
                        Text("agent.timing.12s".localized).tag(TimeInterval(12))
                        Text("agent.timing.15s".localized).tag(TimeInterval(15))
                    }
                    .onChange(of: thinkingHintDelay) { _, newValue in
                        AgentTimingSettings.thinkingHintDelay = newValue
                    }
                } header: {
                    Text("agent.timing.section".localized)
                } footer: {
                    Text("agent.timing.footer".localized)
                }

                Section {
                    ForEach(AgentToolRegistry.allTools) { tool in
                        HStack(spacing: 12) {
                            Image(systemName: tool.category.iconName)
                                .font(.system(size: 15))
                                .foregroundColor(.blue)
                                .frame(width: 32, height: 32)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.nameKey.localized)
                                    .font(.system(size: 14, weight: .medium))
                                Text(tool.summaryKey.localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if revokedToolIDs.contains(tool.id) {
                                Text("agent.tools.revoked".localized)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Button("agent.tools.restore".localized) {
                                    AgentRevokeStore.restore(tool.id)
                                    AgentAuditStore.append(toolID: tool.id, action: .restored)
                                    revokedToolIDs = AgentRevokeStore.revokedToolIDs
                                }
                                .font(.system(size: 12))
                                .buttonStyle(.borderless)
                            } else {
                                if tool.requiresPermission {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                }
                                Button("agent.tools.revoke".localized) {
                                    AgentRevokeStore.revoke(tool.id)
                                    AgentAuditStore.append(toolID: tool.id, action: .revoked)
                                    revokedToolIDs = AgentRevokeStore.revokedToolIDs
                                }
                                .font(.system(size: 12))
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("agent.tools.section".localized)
                } footer: {
                    Text("agent.tools.footer".localized)
                }

                Section {
                    if auditEntries.isEmpty {
                        Text("agent.audit.empty".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(auditEntries) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: AgentAuditDisplayMapping.iconName(for: entry.action))
                                    .font(.system(size: 15))
                                    .foregroundColor(auditTint(for: entry.action))
                                    .frame(width: 32, height: 32)
                                    .background(auditTint(for: entry.action).opacity(0.12))
                                    .cornerRadius(8)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(AgentAuditDisplayMapping.toolName(for: entry))
                                            .font(.system(size: 14, weight: .medium))
                                        Text(AgentAuditDisplayMapping.titleKey(for: entry.action).localized)
                                            .font(.system(size: 12))
                                            .foregroundColor(auditTint(for: entry.action))
                                    }
                                    let time = AgentTaskTimeFormatter.relativeTime(from: entry.date)
                                    Text(entry.detail.isEmpty
                                        ? time
                                        : entry.detail + " · " + time)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("agent.audit.section".localized)
                } footer: {
                    if !auditEntries.isEmpty {
                        Button("agent.audit.clear".localized, role: .destructive) {
                            AgentAuditStore.clear()
                            auditEntries = []
                        }
                        .font(.system(size: 13))
                    }
                }
                .onAppear {
                    auditEntries = AgentAuditStore.entries
                }

                Section {
                    Toggle("agent.memory.voice.history.toggle".localized, isOn: $voiceHistoryEnabled)
                        .onChange(of: voiceHistoryEnabled) { _, newValue in
                            AgentMemorySettings.voiceHistoryEnabled = newValue
                        }
                    Toggle("agent.memory.chat.history.toggle".localized, isOn: $chatHistoryEnabled)
                        .onChange(of: chatHistoryEnabled) { _, newValue in
                            AgentMemorySettings.chatHistoryEnabled = newValue
                        }
                    Button("agent.memory.voice.clear".localized, role: .destructive) {
                        showClearVoiceHistoryConfirm = true
                    }
                } header: {
                    Text("agent.memory.section".localized)
                } footer: {
                    Text("agent.memory.footer".localized)
                }
                .alert("agent.memory.voice.clear.confirm.title".localized, isPresented: $showClearVoiceHistoryConfirm) {
                    Button("agent.memory.voice.clear.confirm.button".localized, role: .destructive) {
                        ConversationStorage.shared.deleteConversations(for: "qwen-audio-agent")
                    }
                    Button("cancel".localized, role: .cancel) {}
                } message: {
                    Text("agent.memory.voice.clear.confirm.message".localized)
                }

                Section {
                    keywordEditor(
                        input: $taskKeywordInput,
                        keywords: $customTaskKeywords,
                        placeholder: "agent.routing.task.placeholder".localized,
                        add: { keyword in
                            AgentRoutingSettings.addTaskKeyword(keyword)
                        },
                        remove: { keyword in
                            AgentRoutingSettings.removeTaskKeyword(keyword)
                        }
                    )
                } header: {
                    Text("agent.routing.task.header".localized)
                }

                Section {
                    keywordEditor(
                        input: $chatKeywordInput,
                        keywords: $customChatKeywords,
                        placeholder: "agent.routing.chat.placeholder".localized,
                        add: { keyword in
                            AgentRoutingSettings.addChatKeyword(keyword)
                        },
                        remove: { keyword in
                            AgentRoutingSettings.removeChatKeyword(keyword)
                        }
                    )
                } header: {
                    Text("agent.routing.chat.header".localized)
                } footer: {
                    Text("agent.routing.footer".localized)
                }

                QwenGatewayConfigurationSections(draft: $qwenDraft)

                Section {
                    Button {
                        saveQwenSettings()
                    } label: {
                        HStack {
                            Image(systemName: qwenSaved ? "checkmark.circle.fill" : "arrow.down.circle")
                            Text(qwenSaved ? "qwen.settings.saved".localized : "qwen.settings.save".localized)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!qwenDraft.isSavable)
                }

                switch selectedKind {
                case .openclaw:
                    openClawForm
                case .hermes:
                    hermesForm
                }
            }
            .navigationTitle("agents.settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                openClawHost = openClawService.gatewayHost
                openClawPortText = "\(openClawService.gatewayPort)"
                openClawToken = openClawService.loadGatewayToken() ?? ""
                openClawUsesTLS = openClawService.usesTLS

                hermesHost = hermesService.gatewayHost
                hermesPortText = "\(hermesService.gatewayPort)"
                hermesAPIKey = hermesService.apiKey
                hermesModel = hermesService.modelName
                hermesConversation = hermesService.conversationName
                hermesUsesTLS = hermesService.usesTLS

                qwenDraft = .loaded(from: qwenGateway)
                scrollToInitialSectionIfNeeded(proxy)
            }
            }
            .sheet(isPresented: $showCalendarDetail) {
                if let event = selectedCalendarEvent {
                    CalendarEventDetailSheet(event: event, provider: AgentCalendar.provider) {
                        Task { await loadCalendarOverview() }
                    }
                }
            }
        }
    }

    /// 「稍后提醒」滑动动作：与锁屏通知 Action 一致的重排 + 重新调度 + 即时刷新
    private func snoozeReminder(_ reminder: AgentReminder) {
        let updated = AgentReminderSnoozePolicy.snoozed(reminder, now: Date())
        guard AgentReminderStore.update(updated) != nil else { return }
        AgentReminderScheduler.schedule(updated)
        reminders = AgentReminderStore.reminders
        snoozeFeedbackTicks += 1
    }

    /// 标记提醒完成：行内划线过渡，短暂窗口内可撤销；到时移除存储并取消通知调度。
    /// 与锁屏通知 Action complete 语义一致（完成 = 移除），主页双卡经刷新信号同步。
    private func completeReminder(_ reminder: AgentReminder) {
        withAnimation(.snappy(duration: 0.25)) {
            completingIDs.insert(reminder.id)
        }
        completionFeedbackTicks += 1
        completionTasks[reminder.id]?.cancel()
        completionTasks[reminder.id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            AgentReminderScheduler.cancel(id: reminder.id)
            AgentReminderStore.remove(id: reminder.id)
            withAnimation(.snappy(duration: 0.25)) {
                completingIDs.remove(reminder.id)
                completionTasks[reminder.id] = nil
            }
            reminders = AgentReminderStore.reminders
        }
    }

    /// 撤销刚标记的完成（过渡窗口内）
    private func undoReminderCompletion(_ reminder: AgentReminder) {
        completionTasks[reminder.id]?.cancel()
        completionTasks[reminder.id] = nil
        withAnimation(.snappy(duration: 0.25)) {
            completingIDs.remove(reminder.id)
        }
    }

    /// 深链定位：滚动到目标分区（只在首次出现时执行一次）
    /// 拉取未来 7 天日程并映射为「近期日程」列表；未授权清空并回到加载态
    private func loadCalendarOverview() async {
        guard AgentCalendar.provider.authorization == .authorized else {
            calendarOverviewLoaded = false
            calendarOverviewRows = []
            return
        }
        let now = Date()
        let events = await AgentCalendar.provider.fetchEvents(
            from: now,
            to: now.addingTimeInterval(AgentCalendarOverviewMapping.lookahead)
        )
        calendarOverviewRows = AgentCalendarOverviewMapping.groupedEvents(events, now: now)
        calendarOverviewLoaded = true
    }

    private func scrollToInitialSectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let section = initialSection else { return }
        initialSection = nil
        DispatchQueue.main.async {
            proxy.scrollTo(section.rawValue, anchor: .top)
        }
    }

    /// 日历授权状态颜色（绿=已授权，红=未授权，橙=受限，灰=尚未请求）
    private var calendarStatusColor: Color {
        switch calendarAuthorization {
        case .authorized:
            return .green
        case .denied:
            return .red
        case .restricted:
            return .orange
        case .notDetermined:
            return .secondary
        }
    }

    // MARK: - Qwen Gateway

    /// 审计动作强调色（与图标一致）
    private func auditTint(for action: AgentAuditAction) -> Color {
        switch action {
        case .granted: return .green
        case .denied: return .red
        case .later: return .orange
        case .skipped: return .gray
        case .requested, .invoked: return .blue
        case .revoked: return .red
        case .restored: return .green
        }
    }

    /// 保存助手画像（名称回退默认；角色与风格均空时回退默认画像）
    private func savePersona() {
        AgentPersonaStore.save(
            name: persona.name,
            role: persona.role,
            style: persona.style,
            enabled: persona.enabled
        )
        persona = AgentPersonaStore.current
    }

    private func saveQwenSettings() {
        qwenDraft.apply(to: qwenGateway)
        qwenSaved = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            qwenSaved = false
        }
    }

    /// 关键词编辑器：输入行 + 已存关键词列表（可删除）
    private func keywordEditor(
        input: Binding<String>,
        keywords: Binding<[String]>,
        placeholder: String,
        add: @escaping (String) -> Bool,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(placeholder, text: input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        commitKeyword(input: input, keywords: keywords, add: add)
                    }
                Button {
                    commitKeyword(input: input, keywords: keywords, add: add)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if keywords.wrappedValue.isEmpty {
                Text("agent.routing.empty".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(keywords.wrappedValue, id: \.self) { keyword in
                    HStack(spacing: 8) {
                        Text(keyword)
                            .font(.system(size: 13))
                        Spacer()
                        Button {
                            remove(keyword)
                            keywords.wrappedValue = keywords.wrappedValue.filter { $0 != keyword }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func commitKeyword(
        input: Binding<String>,
        keywords: Binding<[String]>,
        add: (String) -> Bool
    ) {
        let trimmed = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard add(trimmed) else { return }
        keywords.wrappedValue.append(trimmed)
        input.wrappedValue = ""
    }

    // MARK: - OpenClaw Form

    private var openClawForm: some View {
        Group {
            Section {
                HStack {
                    Text("agent.form.status".localized)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(openClawStatusColor)
                            .frame(width: 10, height: 10)
                        Text(openClawStatusText)
                            .font(AppTypography.caption)
                            .foregroundColor(openClawStatusColor)
                    }
                }

                if openClawService.connectionState == .waitingForPairing {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("openclaw.pairing.hint".localized)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            } header: {
                Text("OpenClaw")
            }

            Section {
                HStack {
                    Text("agent.form.host".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("127.0.0.1", text: $openClawHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                HStack {
                    Text("agent.form.port".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("18789", text: $openClawPortText)
                        .keyboardType(.numberPad)
                }

                SecureField("Gateway Token", text: $openClawToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle("Use TLS", isOn: $openClawUsesTLS)
            } header: {
                Text("agent.form.gateway".localized)
            } footer: {
                Text("openclaw.gateway.help".localized)
            }

            Section {
                if openClawService.connectionState == .connected {
                    Button(role: .destructive) {
                        openClawService.disconnect()
                    } label: {
                        HStack {
                            Image(systemName: "wifi.slash")
                            Text("openclaw.disconnect".localized)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        saveOpenClawAndConnect()
                    } label: {
                        HStack {
                            Image(systemName: "wifi")
                            Text("openclaw.connect".localized)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(openClawHost.isEmpty)
                }
            }

            Section {
                InfoRow(
                    title: "Node ID",
                    value: openClawService.connectionState == .connected ? openClawService.nodeIdentifier : "-"
                )
                InfoRow(title: "Commands", value: "camera.snap, device.status, device.info")
            } header: {
                Text("openclaw.capabilities".localized)
            } footer: {
                Text("openclaw.capabilities.desc".localized)
            }
        }
    }

    // MARK: - Hermes Form

    private var hermesForm: some View {
        Group {
            Section {
                HStack {
                    Text("agent.form.status".localized)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hermesStatusColor)
                            .frame(width: 10, height: 10)
                        Text(hermesStatusText)
                            .font(AppTypography.caption)
                            .foregroundColor(hermesStatusColor)
                    }
                }

                if case .offline = hermesService.connectionState {
                    Text("hermes.status.offline.hint".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            } header: {
                Text("Hermes")
            }

            Section {
                HStack {
                    Text("agent.form.host".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("127.0.0.1", text: $hermesHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                HStack {
                    Text("agent.form.port".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("8642", text: $hermesPortText)
                        .keyboardType(.numberPad)
                }

                SecureField("API Server Key", text: $hermesAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle("Use TLS", isOn: $hermesUsesTLS)
            } header: {
                Text("hermes.gateway".localized)
            } footer: {
                Text("hermes.gateway.help".localized)
            }

            Section {
                HStack {
                    Text("agent.form.model".localized)
                        .frame(width: 50, alignment: .leading)
                    TextField("hermes-agent", text: $hermesModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                HStack {
                    Text("agent.form.conversation".localized)
                        .frame(width: 90, alignment: .leading)
                    TextField("hyper-meta-ios", text: $hermesConversation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("hermes.options".localized)
            } footer: {
                Text("hermes.options.help".localized)
            }

            Section {
                if hermesService.connectionState.isOnline {
                    Button {
                        hermesService.connectionState = .unknown
                    } label: {
                        HStack {
                            Image(systemName: "wifi.slash")
                            Text("openclaw.disconnect".localized)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        saveHermesAndConnect()
                    } label: {
                        HStack {
                            Image(systemName: "wifi")
                            Text("hermes.connect".localized)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(hermesHost.isEmpty)
                }
            }

            Section {
                InfoRow(title: "Protocol", value: "OpenAI Responses API")
                InfoRow(title: "Endpoint", value: "\(hermesService.baseURLString)/v1/responses")
            } header: {
                Text("hermes.capabilities".localized)
            } footer: {
                Text("hermes.capabilities.desc".localized)
            }
        }
    }

    // MARK: - OpenClaw Helpers

    private var openClawStatusColor: Color {
        switch openClawService.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .waitingForPairing: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var openClawStatusText: String {
        switch openClawService.connectionState {
        case .connected: return "openclaw.status.connected".localized
        case .connecting: return "openclaw.status.connecting".localized
        case .waitingForPairing: return "openclaw.status.pairing".localized
        case .disconnected: return "openclaw.status.disconnected".localized
        case .error(let msg): return msg
        }
    }

    private func saveOpenClawAndConnect() {
        openClawService.gatewayHost = openClawHost
        openClawService.gatewayPort = Int(openClawPortText) ?? 18789
        openClawService.usesTLS = openClawUsesTLS
        openClawService.saveGatewayToken(openClawToken)
        openClawService.connect()
    }

    // MARK: - Hermes Helpers

    private var hermesStatusColor: Color {
        switch hermesService.connectionState {
        case .online: return .green
        case .checking: return .orange
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    private var hermesStatusText: String {
        switch hermesService.connectionState {
        case .online: return "hermes.status.connected".localized
        case .checking: return "hermes.status.checking".localized
        case .offline(let msg): return msg.isEmpty ? "hermes.status.notconnected".localized : msg
        case .unknown: return "hermes.status.notconnected".localized
        }
    }

    private func saveHermesAndConnect() {
        hermesService.gatewayHost = hermesHost
        hermesService.gatewayPort = Int(hermesPortText) ?? 8642
        hermesService.usesTLS = hermesUsesTLS
        hermesService.modelName = trimmedOrDefault(hermesModel, fallback: "hermes-agent")
        hermesService.conversationName = trimmedOrDefault(hermesConversation, fallback: "hyper-meta-ios")
        hermesService.saveAPIKey(hermesAPIKey)
        hermesService.saveSettings()
        Task { await hermesService.checkHealth() }
    }

    private func trimmedOrDefault(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

#Preview("Agent Settings") {
    AgentSettingsView(initialKind: .hermes)
}

/// 近期日程行点按弹出的日程详情卡（原生 Sheet，半高 detent + 拖动指示器）
struct CalendarEventDetailSheet: View {
    let event: AgentCalendarEvent
    let provider: AgentCalendarProviding
    var onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reminderSet: Bool
    @State private var reminderError: CalendarReminderError?
    @State private var showDeleteConfirm = false
    @State private var deleteError = false
    @State private var deleting = false

    init(
        event: AgentCalendarEvent,
        provider: AgentCalendarProviding,
        onDeleted: @escaping () -> Void
    ) {
        self.event = event
        self.provider = provider
        self.onDeleted = onDeleted
        _reminderSet = State(
            initialValue: AgentCalendarReminderBridge.hasReminder(
                for: event,
                in: AgentReminderStore.reminders
            )
        )
    }

    private var detail: AgentCalendarDetailMapping.Detail {
        AgentCalendarDetailMapping.detail(for: event)
    }

    private func setReminder(leadMinutes: Int) {
        guard let reminder = AgentCalendarReminderBridge.reminder(
            for: event,
            leadMinutes: leadMinutes,
            now: Date()
        ) else {
            reminderError = .tooLate
            return
        }
        guard let added = AgentReminderStore.add(text: reminder.text, fireDate: reminder.fireDate) else {
            reminderError = .full
            return
        }
        AgentReminderScheduler.schedule(added)
        reminderSet = true
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(detail.title)
                    .font(.title2.weight(.bold))
                Label(detail.timeText, systemImage: "calendar")
                    .font(.body)
                if let status = detail.status {
                    Label(
                        AgentCalendarDetailMapping.statusText(for: status),
                        systemImage: AgentCalendarDetailMapping.statusSymbol(for: status)
                    )
                    .font(.body)
                    .foregroundStyle(statusColor(status))
                }
                if let name = detail.calendarName, !name.isEmpty {
                    Label(name, systemImage: "calendar.badge")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    ForEach(AgentCalendarReminderBridge.leadOptions, id: \.self) { minutes in
                        Button {
                            setReminder(leadMinutes: minutes)
                        } label: {
                            Text(String(
                                format: "agent.calendar.detail.reminder.lead".localized,
                                minutes
                            ))
                        }
                    }
                } label: {
                    Label(
                        reminderSet
                            ? "agent.calendar.detail.reminder.set".localized
                            : "agent.calendar.detail.reminder.button".localized,
                        systemImage: reminderSet ? "alarm.fill" : "alarm"
                    )
                    .font(.body)
                }
                .disabled(reminderSet)
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(
                        AgentCalendarDetailDeleteAction.buttonTitle(),
                        systemImage: "trash"
                    )
                    .font(.body)
                }
                .disabled(deleting)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("agent.settings.calendar.events.section".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .alert(item: $reminderError) { error in
            Alert(
                title: Text("agent.calendar.detail.reminder.error.title".localized),
                message: Text(error.messageKey.localized),
                dismissButton: .default(Text("common.done".localized))
            )
        }
        .confirmationDialog(
            AgentCalendarDetailDeleteAction.confirmTitle(),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(AgentCalendarDetailDeleteAction.confirmActionTitle(), role: .destructive) {
                performDelete()
            }
            Button(AgentCalendarDetailDeleteAction.cancelTitle(), role: .cancel) {}
        } message: {
            Text(AgentCalendarDetailDeleteAction.confirmMessage(for: event))
        }
        .alert(AgentCalendarDetailDeleteAction.errorTitle(), isPresented: $deleteError) {
            Button("common.done".localized) {}
        } message: {
            Text(AgentCalendarDetailDeleteAction.failureMessage())
        }
    }

    /// 确认后执行删除：成功关闭并回调刷新，失败明确提示
    private func performDelete() {
        deleting = true
        Task {
            let deleted = await AgentCalendarDetailDeleteAction.performDelete(
                event: event,
                provider: provider
            )
            deleting = false
            if deleted {
                onDeleted()
                dismiss()
            } else {
                deleteError = true
            }
        }
    }

    private func statusColor(_ status: AgentCalendarDetailMapping.Status) -> Color {
        switch status {
        case .upcoming, .ended: return .secondary
        case .inProgress: return .orange
        }
    }
}

/// 日程详情卡「设为提醒」的错误反馈
private enum CalendarReminderError: String, Identifiable {
    case full
    case tooLate

    var id: String { rawValue }

    var messageKey: String {
        switch self {
        case .full: return "agent.calendar.detail.reminder.full"
        case .tooLate: return "agent.calendar.detail.reminder.tooLate"
        }
    }
}
