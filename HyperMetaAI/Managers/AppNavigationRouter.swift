/*
 * App Navigation Router
 * 系统入口（通知点按 / 后续扩展）到 App 内导航的桥接：
 * 请求方只置标记（@Published pendingDestination），
 * 持有目标状态的视图消费后呈现，与 LiveAIManager / VoiceAssistantRouter 同一模式。
 */

import Combine
import Foundation

/// App 内导航目标
enum AppNavigationDestination: Equatable {
    /// 打开 Agent 设置并定位到指定分区
    case agentSettings(AgentSettingsSection)
    /// 打开图库并弹出指定照片
    case gallery(UUID)
    /// 打开 Agent Hub（任务通知「查看结果」深链）
    case agentHub
    /// 打开 Agent Hub 并查看对话记录详情（结果通知 / Spotlight 深链）
    case conversation(UUID)
}

@MainActor
final class AppNavigationRouter: ObservableObject {
    static let shared = AppNavigationRouter()

    @Published private(set) var pendingDestination: AppNavigationDestination?

    private init() {}

    func request(_ destination: AppNavigationDestination) {
        pendingDestination = destination
    }

    @discardableResult
    func consume() -> AppNavigationDestination? {
        defer { pendingDestination = nil }
        return pendingDestination
    }

    /// 只消费匹配的请求（未匹配则不取走，留给其他消费者）。
    /// 多个视图共同观察同一路由时按目标归属消费，避免误吞他人请求。
    @discardableResult
    func consume(
        where predicate: (AppNavigationDestination) -> Bool
    ) -> AppNavigationDestination? {
        guard let destination = pendingDestination, predicate(destination) else { return nil }
        pendingDestination = nil
        return destination
    }
}
