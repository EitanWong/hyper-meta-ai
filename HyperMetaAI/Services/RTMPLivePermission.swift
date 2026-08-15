/*
 * RTMP Live Permission & Privacy
 * 直播权限管理（纯逻辑，可测）：
 * 开播前合规清单（确认后可记住选择，下次直接开播）+
 * 推流中隐私保护盾（一键隐藏画面，不发帧不上传）。
 */

import Foundation

/// 开播清单条目（本地化文案 key 由 UI 解析）
struct RTMPChecklistItem: Codable, Equatable, Identifiable {
    var id: UUID
    /// 本地化文案 key（如 rtmp.checklist.content）
    var titleKey: String
    var isChecked: Bool

    init(id: UUID = UUID(), titleKey: String, isChecked: Bool = false) {
        self.id = id
        self.titleKey = titleKey
        self.isChecked = isChecked
    }
}

/// 开播清单存储（UserDefaults JSON 持久化：条目勾选 + 是否记住选择）
enum RTMPChecklistStore {
    static let itemsKey = "rtmp.checklist.items"
    static let rememberedKey = "rtmp.checklist.remembered"

    /// 默认清单（内容合规 / 评论管理 / 隐私提醒）
    static func defaultItems() -> [RTMPChecklistItem] {
        [
            RTMPChecklistItem(titleKey: "rtmp.checklist.content"),
            RTMPChecklistItem(titleKey: "rtmp.checklist.comments"),
            RTMPChecklistItem(titleKey: "rtmp.checklist.privacy"),
        ]
    }

    static var items: [RTMPChecklistItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: itemsKey) else {
                return defaultItems()
            }
            let decoded = (try? JSONDecoder().decode([RTMPChecklistItem].self, from: data)) ?? []
            return decoded.isEmpty ? defaultItems() : decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: itemsKey)
        }
    }

    /// 是否全部勾选
    static func allConfirmed(_ items: [RTMPChecklistItem]) -> Bool {
        !items.isEmpty && items.allSatisfy(\.isChecked)
    }

    static var remembered: Bool {
        get { UserDefaults.standard.bool(forKey: rememberedKey) }
        set { UserDefaults.standard.set(newValue, forKey: rememberedKey) }
    }

    static func save(items: [RTMPChecklistItem], remembered: Bool) {
        self.items = items
        self.remembered = remembered
    }
}

/// 开播门控（纯逻辑，可测）：未记住选择且清单未确认时需要先过清单
enum RTMPGoLiveGate {
    /// 是否需要展示开播清单
    static func shouldShowChecklist(
        remembered: Bool,
        itemsConfirmed: Bool
    ) -> Bool {
        !remembered && !itemsConfirmed
    }
}

/// 推流隐私保护盾（纯逻辑，可测）：隐藏时服务端不发画面帧
enum RTMPPrivacyShield: Equatable {
    case visible
    case hidden

    var isHidden: Bool { self == .hidden }

    mutating func toggle() {
        self = isHidden ? .visible : .hidden
    }
}
