/*
 * Control Center 晨报控制
 * 「播报晨报」一键触发今日晨报（iOS 18+ Control，与语音会话控制同一模式）：
 * 扩展进程只写 App Group 请求标记，App 消费后经既有晨报播报路径朗读 + 上镜片。
 */

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct BriefingControl: ControlWidget {
    static let kind = "com.lunflux.hyper-meta-ai.control.briefing"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: BriefingControlIntent()) {
                Label("播报晨报", systemImage: "sunrise.fill")
            }
        }
        .displayName("播报晨报")
        .description("立即播报今日晨报（日程 / 提醒 / 任务 / 未读通知摘要）")
    }
}

struct BriefingControlIntent: AppIntent {
    static var title: LocalizedStringResource = "播报晨报"
    static var description = IntentDescription("立即播报今日晨报")

    func perform() async throws -> some IntentResult {
        BriefingRequestStore.request()
        return .result()
    }
}

/// 晨报请求标记（App Group 跨进程通道，与语音会话控制同一模式）
enum BriefingRequestStore {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let requestKey = "agent.briefing.request"

    static func request() {
        (UserDefaults(suiteName: suiteName) ?? .standard).set(true, forKey: requestKey)
    }
}
