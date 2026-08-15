/*
 * RTMP Stream Scenario
 * 直播场景预设：把目的地（平台 / RTMP URL）与推流参数（码率、自适应质量、
 * 自动重连、自适应音频）打包为一个可保存、可一键应用的命名场景。
 * UserDefaults JSON 持久化，上限 10 个，纯逻辑便于测试。
 */

import Foundation

/// 一个直播场景预设
struct RTMPStreamScenario: Codable, Equatable, Identifiable {
    var id: UUID
    /// 场景名称（建议 ≤ 16 字符）
    var name: String
    /// 平台标识（RTMPStreamingViewModel.StreamingPlatform.rawValue）
    var platform: String
    /// 目的地 RTMP 地址（含推流名；streamKey 不落盘，保持 Keychain 语义）
    var rtmpUrl: String
    var bitrate: Int
    var adaptiveQualityEnabled: Bool
    var autoReconnectEnabled: Bool
    var adaptiveAudioEnabled: Bool
    /// 最近保存 / 更新时间（列表按此降序）
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        platform: String,
        rtmpUrl: String,
        bitrate: Int,
        adaptiveQualityEnabled: Bool,
        autoReconnectEnabled: Bool,
        adaptiveAudioEnabled: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.rtmpUrl = rtmpUrl
        self.bitrate = bitrate
        self.adaptiveQualityEnabled = adaptiveQualityEnabled
        self.autoReconnectEnabled = autoReconnectEnabled
        self.adaptiveAudioEnabled = adaptiveAudioEnabled
        self.updatedAt = updatedAt
    }
}

/// 直播场景存储（UserDefaults JSON 持久化）
enum RTMPScenarioStore {
    static let key = "rtmp.scenarios"
    /// 上限：避免列表过长
    static let maxCount = 10

    static var scenarios: [RTMPStreamScenario] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            let decoded = (try? JSONDecoder().decode([RTMPStreamScenario].self, from: data)) ?? []
            return decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增或按 id 更新一个场景；名称去首尾空白后为空、或已达上限返回 false。
    /// 更新同名场景时沿用原 id（列表去重）。
    @discardableResult
    static func save(_ scenario: RTMPStreamScenario) -> Bool {
        let name = scenario.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        var items = scenarios
        var merged = scenario
        merged.name = name

        if let index = items.firstIndex(where: { $0.id == merged.id }) {
            items[index] = merged
        } else {
            guard items.count < maxCount else { return false }
            items.append(merged)
        }
        scenarios = items
        return true
    }

    static func delete(id: UUID) {
        scenarios = scenarios.filter { $0.id != id }
    }

    /// 重命名；空名或与已有场景重名返回 false
    @discardableResult
    static func rename(id: UUID, to newName: String) -> Bool {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return false }
        var items = scenarios
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard !items.contains(where: { $0.id != id && $0.name == newName }) else { return false }
        items[index].name = newName
        items[index].updatedAt = Date()
        scenarios = items
        return true
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
