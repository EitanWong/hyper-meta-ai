/*
 * Home Screen Quick Actions（主屏长按快捷操作）
 * 静态三项（语音会话 / 停止会话 / 快速识图）+ 动态一项（下次提醒）。
 * 全部由代码生成（跟随 App 语言），App 回前台时刷新；
 * 点按经 UIApplicationDelegate 映射到既有路由（语音 Router / 识图 Manager /
 * 提醒播报），identifier → route 映射与项构造为纯逻辑，便于测试。
 */

import UIKit
import CoreSpotlight

/// 主屏快捷操作路由
enum HomeScreenShortcutRoute: Equatable {
    case startVoiceSession
    case stopVoiceSession
    case quickVision
    /// 播报指定提醒（动态项，identifier 携带提醒 id）
    case announceReminder(UUID)
}

/// 主屏快捷操作：标识、构造与处理（@MainActor：副作用走主线程）
@MainActor
enum HomeScreenShortcutActions {
    static let voiceIdentifier = "com.lunflux.hyper-meta-ai.shortcut.voice"
    static let stopIdentifier = "com.lunflux.hyper-meta-ai.shortcut.stop"
    static let visionIdentifier = "com.lunflux.hyper-meta-ai.shortcut.vision"
    static let reminderIdentifierPrefix = "com.lunflux.hyper-meta-ai.shortcut.reminder."

    // MARK: - 映射（纯逻辑，可测）

    static func route(for identifier: String) -> HomeScreenShortcutRoute? {
        switch identifier {
        case voiceIdentifier:
            return .startVoiceSession
        case stopIdentifier:
            return .stopVoiceSession
        case visionIdentifier:
            return .quickVision
        default:
            guard identifier.hasPrefix(reminderIdentifierPrefix) else { return nil }
            let uuidString = String(identifier.dropFirst(reminderIdentifierPrefix.count))
            guard let id = UUID(uuidString: uuidString) else { return nil }
            return .announceReminder(id)
        }
    }

    // MARK: - 项构造（纯逻辑，可测）

    /// 静态三项
    static func staticItems() -> [UIApplicationShortcutItem] {
        [
            UIApplicationShortcutItem(
                type: voiceIdentifier,
                localizedTitle: "shortcut.voice.title".localized,
                localizedSubtitle: "shortcut.voice.subtitle".localized,
                icon: UIApplicationShortcutIcon(systemImageName: "waveform.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: stopIdentifier,
                localizedTitle: "shortcut.stop.title".localized,
                localizedSubtitle: "shortcut.stop.subtitle".localized,
                icon: UIApplicationShortcutIcon(systemImageName: "stop.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: visionIdentifier,
                localizedTitle: "shortcut.vision.title".localized,
                localizedSubtitle: "shortcut.vision.subtitle".localized,
                icon: UIApplicationShortcutIcon(systemImageName: "eye.circle.fill"),
                userInfo: nil
            )
        ]
    }

    /// 动态「下次提醒」项（周期提醒取最近一次触发；无提醒返回 nil）
    static func reminderItem(
        for reminder: AgentReminder,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UIApplicationShortcutItem? {
        guard AgentReminderDisplayMapping.hasActiveReminders([reminder], now: now) else { return nil }
        return UIApplicationShortcutItem(
            type: reminderIdentifierPrefix + reminder.id.uuidString,
            localizedTitle: String(format: "shortcut.reminder.title".localized, reminder.text),
            localizedSubtitle: AgentReminderTimeFormatter.announcementDescription(
                for: reminder, now: now, calendar: calendar
            ),
            icon: UIApplicationShortcutIcon(systemImageName: "bell.fill"),
            userInfo: [reminderIdentifierUserInfoKey: reminder.id.uuidString as NSString]
        )
    }

    /// 完整快捷项列表：静态三项 + 下次提醒（若有）
    static func items(
        reminders: [AgentReminder],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UIApplicationShortcutItem] {
        var items = staticItems()
        if let next = AgentReminderDisplayMapping.upcoming(reminders, now: now, limit: 1).first,
           let item = reminderItem(for: next, now: now, calendar: calendar) {
            items.append(item)
        }
        return items
    }

    /// 刷新主屏快捷操作（App 回前台时调用）
    static func refreshDynamicItems() {
        UIApplication.shared.shortcutItems = items(reminders: AgentReminderStore.reminders)
    }

    // MARK: - 处理（副作用）

    /// 处理一次快捷操作；返回是否被识别
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let route = route(for: item.type) else { return false }
        switch route {
        case .startVoiceSession:
            VoiceAssistantRouter.shared.requestVoiceSession()
        case .stopVoiceSession:
            QwenVoiceSession.shared.stop()
        case .quickVision:
            Task {
                await QuickVisionManager.shared.performQuickVisionWithMode(
                    .standard,
                    deferUntilStreamConfigured: true
                )
            }
        case .announceReminder(let id):
            guard let reminder = AgentReminderStore.reminders.first(where: { $0.id == id }) else {
                return false
            }
            announce(reminder)
        }
        return true
    }

    /// 播报提醒：镜片结果卡 + TTS（与通知前台播报同一套话术与开关约束）
    static func announce(_ reminder: AgentReminder) {
        let text = AgentReminderDisplayMapping.resultText(for: reminder)
        AgentDisplayHub.shared.showResult(
            title: "agent.reminder.notification.title".localized,
            text: text,
            fallback: .idle
        )
        if AgentVoiceSettings.replyEnabled,
           AgentQuietAnnouncementPolicy.shouldSpeakProactive() {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
        }
    }
}

/// 快捷操作 userInfo 中的提醒 id 键
extension HomeScreenShortcutActions {
    static let reminderIdentifierUserInfoKey = "agent.reminder.id"
}

/// UIApplicationDelegate 桥接：冷启动 / 热启动 / 回前台刷新
final class HomeScreenShortcutAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 冷启动经快捷操作进入：系统只把 item 放 launchOptions，不再回调 performActionFor
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            MainActor.assumeIsolated {
                _ = HomeScreenShortcutActions.handle(item)
            }
        }
        // 冷启动经 Spotlight 搜索结果进入：系统把 NSUserActivity 放 launchOptions
        // 顺带重建一次搜索索引，保证冷启动后数据可搜
        MainActor.assumeIsolated {
            _ = handleSpotlightLaunch(launchOptions)
            SpotlightIndexer.update()
            processPendingShares()
            // 注册晨报后台刷新任务，冷启动即刷新一次晨报内容
            AgentBriefingBackgroundTask.register()
            Task { await AgentBriefingScheduler.sync() }
            // 注册后台任务巡检：任务完成 / 失败时系统唤醒推送通知
            AgentTaskBackgroundTask.register()
        }
        return true
    }


    func applicationDidBecomeActive(_ application: UIApplication) {
        MainActor.assumeIsolated {
            HomeScreenShortcutActions.refreshDynamicItems()
            SpotlightIndexer.update()
            processPendingShares()
            // 回前台刷新晨报内容（跨天后保证次日送达的日程/提醒是最新的）
            Task { await AgentBriefingScheduler.sync() }
            // 任务 Live Activity「查看任务」按钮：消费标记并深链 Agent Hub
            if AgentTaskViewRequestStore.consume() {
                AppNavigationRouter.shared.request(.agentHub)
            }
            // 任务 Live Activity 审批按钮：消费标记并提交当前审批决策
            if let decision = AgentApprovalTapStore.consumeDecision() {
                Task { @MainActor in
                    _ = await QwenVoiceSession.shared.respondToPermission(decision)
                }
            }
            // 提醒倒计时卡按钮（稍后提醒 / 完成）：消费标记并应用到当前提醒
            AgentReminderTapCoordinator.consumeIfNeeded()
            // 任务 Live Activity「取消 / 加速」按钮：消费标记并应用到最近的活动任务
            AgentTaskControlCoordinator.consumeIfNeeded()
            // 任务结果 Live Activity「追问」按钮：消费标记并打开语音会话页（携带结果上下文）
            AgentTaskFollowUpCoordinator.consumeIfNeeded()
            // 任务结果 Live Activity「重试」按钮：消费标记并恢复失败任务重试闭环
            AgentTaskRetryCoordinator.consumeIfNeeded()
            // Control Center「播报晨报」：消费标记并立即播报今日晨报
            Task { @MainActor in
                _ = await AgentBriefingControlCoordinator.consumeIfNeeded()
            }
        }
    }


    func applicationDidEnterBackground(_ application: UIApplication) {
        // 用户编辑完大脑数据后进入后台：立即重建索引，保证 Spotlight 可搜到最新数据
        MainActor.assumeIsolated {
            SpotlightIndexer.update()
            // 晨报后台刷新（机会式）：系统许可时重算，保证次日送达内容新鲜
            AgentBriefingBackgroundTask.submitIfNeeded()
            // 后台任务巡检（机会式）：任务终态时推送系统通知
            AgentTaskBackgroundTask.submitIfNeeded()
        }
    }


    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            completionHandler(HomeScreenShortcutActions.handle(shortcutItem))
        }
    }

    /// Spotlight 搜索结果点按（热启动 / 后台继续）
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            handleSpotlight(userActivity)
        }
    }

    // MARK: - Spotlight 入口

    /// 冷启动 launchOptions 中携带的 Spotlight NSUserActivity
    private func handleSpotlightLaunch(
        _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        guard let activityDictionary = launchOptions?[.userActivityDictionary] as? [AnyHashable: Any]
        else { return false }
        // 系统把 NSUserActivity 放在 userActivityDictionary 内；该内部键无 Swift 常量，用原始字符串
        guard let activity = activityDictionary["UIApplicationLaunchOptionsUserActivityKey"] as? NSUserActivity
        else { return false }
        return handleSpotlight(activity)
    }

    /// 处理一次 Spotlight 点按：解析 identifier → 深链到对应 Agent 设置分区
    @discardableResult
    private func handleSpotlight(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let destination = SpotlightIdentifierParser.destination(for: identifier)
        else { return false }
        AppNavigationRouter.shared.request(destination.navigationDestination)
        return true
    }

    // MARK: - 系统分享队列

    /// 消费 Share Extension 写入的分享请求：记忆 / 清单走镜片结果卡确认，
    /// Agent 目标启动语音会话并发送指令（与 Siri / 快捷指令同回合语义）。
    private func processPendingShares() {
        let requests = AgentShareQueue.consume()
        guard !requests.isEmpty else { return }
        var agentText: String?
        for request in requests {
            let outcome = AgentShareProcessor.apply(request)
            if case .sentToAgent(let text) = outcome {
                agentText = text
            }
            if let message = AgentShareConfirmation.message(for: outcome, text: request.text) {
                AgentDisplayHub.shared.showResult(
                    title: "share.processed.title".localized,
                    text: message,
                    fallback: .idle
                )
            }
        }
        if let agentText {
            VoiceAssistantRouter.shared.requestVoiceSession(instruction: agentText)
        }
    }
}
