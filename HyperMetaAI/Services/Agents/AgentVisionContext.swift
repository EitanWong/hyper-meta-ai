/*
 * Agent Vision Context
 * 视野连续追问：聊天页发送照片后保留为当前会话的「视野上下文」，
 * 后续文本追问自动携带同一帧（无需重拍），关闭开关或手动清除后不再携带。
 * 对齐「为不同 Agent 建立统一的视觉上下文」设计：所有 Agent 走同一套携带策略。
 */

import Foundation
import UIKit

/// 视野连续追问策略（纯逻辑，可测）
enum AgentVisionContextPolicy {
    /// 当前轮是否携带视野：
    /// - 用户显式发送图片 → 必然携带（显式意图优先）；
    /// - 未发送图片但有活跃视野上下文且开启连续追问 → 自动携带。
    static func shouldAttach(
        sendingImage: Bool,
        hasActiveContext: Bool,
        followUpEnabled: Bool
    ) -> Bool {
        sendingImage || (hasActiveContext && followUpEnabled)
    }
}

// MARK: - 视觉数据隐私与本地清理

/// 视觉数据已清除事件：App 内共享的「清除全部视觉数据」广播。
/// 各视图监听后丢弃持有的画面帧与视野上下文（帧只存在于内存 @State）。
extension Notification.Name {
    static let agentVisionDataCleared = Notification.Name("agent.vision.dataCleared")
}

/// 视觉数据生命周期（纯逻辑，可测）：
/// - 画面帧仅保存在内存（视图 @State），不落盘；对话历史不保存图片。
/// - 取词 / 场景识别结果仅内存保存，下次启动自动消失。
/// - `clearAll()` 清空共享内存态，并广播事件让视图丢弃当前持有的帧。
enum AgentVisionDataPrivacy {
    static func clearAll() {
        AgentVisionOCRStore.clear()
        AgentVisionSceneStore.clear()
        NotificationCenter.default.post(name: .agentVisionDataCleared, object: nil)
    }
}
