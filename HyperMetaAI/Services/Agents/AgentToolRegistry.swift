/*
 * Agent Tool Registry & Audit
 * 统一声明 App 内可授权能力（工具），供 Agent 请求与审批；
 * 所有权限决策写入审计日志，保证可控可观察。
 */

import Foundation

/// 工具类别（统一能力分类）
enum AgentToolCategory: String, CaseIterable, Equatable {
    case vision
    case messaging
    case automation
    case audio

    /// 列表图标（SF Symbols）
    var iconName: String {
        switch self {
        case .vision: return "camera.viewfinder"
        case .messaging: return "paperplane.fill"
        case .automation: return "gearshape.2.fill"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

/// App 内可授权工具声明（纯数据，可测）
struct AgentTool: Equatable, Identifiable {
    let id: String
    /// 展示名（本地化 key）
    let nameKey: String
    let category: AgentToolCategory
    /// 是否需要在调用前获得用户明确授权
    let requiresPermission: Bool
    /// 一句话能力描述（本地化 key）
    let summaryKey: String
}

/// 工具注册表：统一登记 App 内能力，供 Agent 请求、审批与展示
enum AgentToolRegistry {
    /// 拍照并注入视野（敏感：需要授权）
    static let visionCapture = AgentTool(
        id: "vision.capture",
        nameKey: "agent.tool.vision.capture",
        category: .vision,
        requiresPermission: true,
        summaryKey: "agent.tool.vision.capture.summary"
    )

    /// 代发消息（敏感：需要授权）
    static let messageSend = AgentTool(
        id: "message.send",
        nameKey: "agent.tool.message.send",
        category: .messaging,
        requiresPermission: true,
        summaryKey: "agent.tool.message.send.summary"
    )

    /// 任务控制（进度查询/取消，用户主动发起，无需授权）
    static let taskControl = AgentTool(
        id: "task.control",
        nameKey: "agent.tool.task.control",
        category: .automation,
        requiresPermission: false,
        summaryKey: "agent.tool.task.control.summary"
    )

    /// 语音播报（TTS 回复，用户可配置关闭）
    static let voiceReply = AgentTool(
        id: "voice.reply",
        nameKey: "agent.tool.voice.reply",
        category: .audio,
        requiresPermission: false,
        summaryKey: "agent.tool.voice.reply.summary"
    )

    /// 本地命名清单（购物单 / 待办）：用户自有数据，本地读写，无需授权
    static let listManage = AgentTool(
        id: "list.manage",
        nameKey: "agent.tool.list.manage",
        category: .automation,
        requiresPermission: false,
        summaryKey: "agent.tool.list.manage.summary"
    )

    /// 端侧取词（Apple Vision OCR，离线免费，无需授权）：识别最近一帧画面的文字
    static let visionOCR = AgentTool(
        id: "vision.ocr",
        nameKey: "agent.tool.vision.ocr",
        category: .vision,
        requiresPermission: false,
        summaryKey: "agent.tool.vision.ocr.summary"
    )

    /// 端侧场景识别（Apple Vision 分类 + 动物 + 物体识别，离线免费，无需授权）：理解最近一帧画面
    static let visionScene = AgentTool(
        id: "vision.scene",
        nameKey: "agent.tool.vision.scene",
        category: .vision,
        requiresPermission: false,
        summaryKey: "agent.tool.vision.scene.summary"
    )

    /// 端侧物体识别（Apple Vision 物体检测，离线免费，无需授权）：识别最近一帧画面的具体物体
    static let visionObjects = AgentTool(
        id: "vision.objects",
        nameKey: "agent.tool.vision.objects",
        category: .vision,
        requiresPermission: false,
        summaryKey: "agent.tool.vision.objects.summary"
    )

    /// 当前注册的全部工具
    static let allTools: [AgentTool] = [
        visionCapture, messageSend, taskControl, voiceReply, listManage, visionOCR, visionScene, visionObjects
    ]

    static func tool(for id: String) -> AgentTool? {
        allTools.first { $0.id == id }
    }

    static func tools(in category: AgentToolCategory) -> [AgentTool] {
        allTools.filter { $0.category == category }
    }

    /// 调用门槛：需要授权的工具必须已获得授权
    static func canInvoke(_ tool: AgentTool, permissionGranted: Bool, revoked: Bool = false) -> Bool {
        !revoked && (!tool.requiresPermission || permissionGranted)
    }
}

/// 工具撤销状态存储：已撤销的工具即使有授权也不能调用（UserDefaults 持久化）
enum AgentRevokeStore {
    static let storageKey = "agent.tools.revoked"

    static var revokedToolIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: storageKey)
        }
    }

    static func isRevoked(_ toolID: String) -> Bool {
        revokedToolIDs.contains(toolID)
    }

    /// 撤销工具；已是撤销状态时返回 false（幂等）
    @discardableResult
    static func revoke(_ toolID: String) -> Bool {
        guard !isRevoked(toolID) else { return false }
        var ids = revokedToolIDs
        ids.insert(toolID)
        revokedToolIDs = ids
        return true
    }

    /// 恢复工具；非撤销状态时返回 false（幂等）
    @discardableResult
    static func restore(_ toolID: String) -> Bool {
        guard isRevoked(toolID) else { return false }
        var ids = revokedToolIDs
        ids.remove(toolID)
        revokedToolIDs = ids
        return true
    }
}

/// 视野能力策略（纯逻辑，可测）：功能开关 + 撤销状态共同决定
enum AgentVisionPolicy {
    static func canCapture(injectionEnabled: Bool, revoked: Bool) -> Bool {
        injectionEnabled && !revoked
    }
}

/// 审计动作（权限决策与工具调用）
enum AgentAuditAction: String, CaseIterable, Codable, Equatable {
    case requested
    case granted
    case denied
    case later
    case skipped
    case invoked
    case revoked
    case restored
}

/// 一条审计记录
struct AgentAuditEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let toolID: String
    let action: AgentAuditAction
    /// 展示用详情（如权限摘要）
    let detail: String
}

/// 操作审计存储：权限决策/工具调用记录，最新在前，最多保留 latestLimit 条（UserDefaults 持久化）
enum AgentAuditStore {
    static let storageKey = "agent.audit.entries"
    static let latestLimit = 50

    static var entries: [AgentAuditEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([AgentAuditEntry].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            let capped = Array(newValue.prefix(latestLimit))
            guard let data = try? JSONEncoder().encode(capped) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 追加一条审计（最新在前，超出上限丢弃最旧）
    @discardableResult
    static func append(
        toolID: String,
        action: AgentAuditAction,
        detail: String = "",
        date: Date = Date()
    ) -> AgentAuditEntry {
        let entry = AgentAuditEntry(id: UUID(), date: date, toolID: toolID, action: action, detail: detail)
        var all = entries
        all.insert(entry, at: 0)
        entries = all
        return entry
    }

    /// 清空全部审计记录
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// 审计记录的展示映射（纯映射，可测）
enum AgentAuditDisplayMapping {
    /// 动作 → 标题（本地化 key）
    static func titleKey(for action: AgentAuditAction) -> String {
        switch action {
        case .requested: return "agent.audit.action.requested"
        case .granted: return "agent.audit.action.granted"
        case .denied: return "agent.audit.action.denied"
        case .later: return "agent.audit.action.later"
        case .skipped: return "agent.audit.action.skipped"
        case .invoked: return "agent.audit.action.invoked"
        case .revoked: return "agent.audit.action.revoked"
        case .restored: return "agent.audit.action.restored"
        }
    }

    /// 动作 → SF Symbol 图标
    static func iconName(for action: AgentAuditAction) -> String {
        switch action {
        case .requested: return "clock.arrow.circlepath"
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .later: return "clock.fill"
        case .skipped: return "timer"
        case .invoked: return "bolt.fill"
        case .revoked: return "xmark.shield.fill"
        case .restored: return "checkmark.shield.fill"
        }
    }

    /// 条目所属工具名：注册表命中返回工具名；网关权限 ID 回退到「权限请求」
    static func toolName(for entry: AgentAuditEntry) -> String {
        if let tool = AgentToolRegistry.tool(for: entry.toolID) {
            return tool.nameKey.localized
        }
        return "agent.audit.permission.fallback".localized
    }
}
