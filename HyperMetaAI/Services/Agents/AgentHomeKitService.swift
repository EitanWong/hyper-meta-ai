/*
 * Agent HomeKit（智能家居，HomeKit）
 * JARVIS 式家居管家：语音 / 聊天直接控制系统家庭配件——「打开客厅灯」
 * 「把空调调到26度」「关掉所有灯」「现在家里有什么设备」「客厅灯什么状态」。
 * HomeKit 自 iOS 11 起无需 entitlement（仅需 NSHomeKitUsageDescription），
 * 配件读写走协议注入（测试用 Mock），纯逻辑解析 / 匹配 / 文案可测。
 */

import Foundation
import HomeKit

/// 家居授权状态（HomeKit 无显式运行时授权 API，首次访问家庭数据自动弹窗）
enum AgentHomeKitAuthorization: Equatable {
    case unavailable
    case authorized
}

/// 家居配件（HMService 的扁平快照，供匹配与 UI 展示）
struct AgentHomeKitDevice: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case light
        case outlet
        case thermostat
        case lock
        case fan
        case `switch`
        case unknown
    }

    let id: String
    let name: String
    let roomName: String?
    let kind: Kind
    let isOn: Bool?
    let brightness: Int?
    let currentTemperature: Double?
    let targetTemperature: Double?
    let isLocked: Bool?
}

/// 家居能力提供者（HMHomeManager 封装，可注入 Mock 测试）
protocol AgentHomeKitProviding {
    var authorization: AgentHomeKitAuthorization { get }
    func devices() async -> [AgentHomeKitDevice]
    func setPower(deviceID: String, on: Bool) async throws
    func setBrightness(deviceID: String, percent: Int) async throws
    func setTemperature(deviceID: String, celsius: Double) async throws
}

/// HMHomeManager 真实实现（模拟器可编译运行，无家庭数据时设备列表为空）
final class HomeKitHomeService: NSObject, AgentHomeKitProviding, HMHomeManagerDelegate {
    private let manager = HMHomeManager()

    var authorization: AgentHomeKitAuthorization {
        .authorized
    }

    func devices() async -> [AgentHomeKitDevice] {
        let home = await MainActor.run { manager.homes.first }
        guard let home else { return [] }
        return home.accessories.flatMap { accessory in
            accessory.services.compactMap { service in
                Self.device(from: service, roomName: accessory.room?.name)
            }
        }
    }

    func setPower(deviceID: String, on: Bool) async throws {
        guard let characteristic = await characteristic(deviceID: deviceID, type: HMCharacteristicTypePowerState) else {
            throw AgentHomeKitError.characteristicMissing
        }
        try await write(characteristic, value: on)
    }

    func setBrightness(deviceID: String, percent: Int) async throws {
        guard let characteristic = await characteristic(deviceID: deviceID, type: HMCharacteristicTypeBrightness) else {
            throw AgentHomeKitError.characteristicMissing
        }
        try await write(characteristic, value: min(max(percent, 0), 100))
    }

    func setTemperature(deviceID: String, celsius: Double) async throws {
        guard let characteristic = await characteristic(deviceID: deviceID, type: HMCharacteristicTypeTargetTemperature) else {
            throw AgentHomeKitError.characteristicMissing
        }
        try await write(characteristic, value: celsius)
    }

    private func characteristic(
        deviceID: String,
        type: String
    ) async -> HMCharacteristic? {
        let home = await MainActor.run { manager.homes.first }
        guard let home else { return nil }
        for accessory in home.accessories {
            for service in accessory.services
            where service.uniqueIdentifier.uuidString == deviceID {
                return service.characteristics.first { $0.characteristicType == type }
            }
        }
        return nil
    }

    private func write(_ characteristic: HMCharacteristic, value: Any) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func device(from service: HMService, roomName: String?) -> AgentHomeKitDevice? {
        guard service.serviceType != HMServiceTypeAccessoryInformation else { return nil }
        let kind: AgentHomeKitDevice.Kind
        switch service.serviceType {
        case HMServiceTypeLightbulb: kind = .light
        case HMServiceTypeOutlet: kind = .outlet
        case HMServiceTypeThermostat: kind = .thermostat
        case HMServiceTypeLockMechanism: kind = .lock
        case HMServiceTypeFan: kind = .fan
        case HMServiceTypeSwitch: kind = .switch
        default: kind = .unknown
        }
        let characteristics = Dictionary(
            service.characteristics.map { ($0.characteristicType, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return AgentHomeKitDevice(
            id: service.uniqueIdentifier.uuidString,
            name: service.name,
            roomName: roomName,
            kind: kind,
            isOn: (characteristics[HMCharacteristicTypePowerState]?.value as? Bool),
            brightness: (characteristics[HMCharacteristicTypeBrightness]?.value as? NSNumber)?.intValue,
            currentTemperature: Self.celsius(
                characteristics[HMCharacteristicTypeCurrentTemperature]?.value
            ),
            targetTemperature: Self.celsius(
                characteristics[HMCharacteristicTypeTargetTemperature]?.value
            ),
            isLocked: (characteristics[HMCharacteristicTypeCurrentLockMechanismState]?.value as? NSNumber)
                .flatMap { $0.intValue == HMCharacteristicValueLockMechanismState.secured.rawValue }
        )
    }

    private static func celsius(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}

enum AgentHomeKitError: LocalizedError {
    case characteristicMissing

    var errorDescription: String? {
        "agent.homekit.control.failed".localized
    }
}

// MARK: - 命令模型

/// 家居动作
enum AgentHomeKitAction: Equatable {
    case turnOn
    case turnOff
    /// 调亮：当前亮度 +20，无亮度时设为 100
    case brighten
    /// 调暗：当前亮度 -20，无亮度时设为 30
    case dim
    case setBrightness(Int)
    case setTemperature(Double)
}

/// 家居指令
enum AgentHomeKitCommand: Equatable {
    /// 控制单个设备 / 房间（「打开客厅灯」「把空调调到26度」）
    case control(target: String, action: AgentHomeKitAction)
    /// 全屋动作（「关掉所有灯」；category 为空 = 全部可开关设备）
    case controlAll(category: String?, action: AgentHomeKitAction)
    /// 查询单个设备 / 房间状态（「客厅灯什么状态」「空调温度多少」）
    case query(target: String)
    /// 列出设备（「家里有什么设备」）
    case listDevices
}

// MARK: - 指令解析

/// 家居指令解析（保守匹配：动作词 + 明确目标，避免误吞普通对话）
enum AgentHomeKitCommandParser {
    static let listMarkers = ["有什么设备", "有哪些设备", "有什么智能设备", "有哪些智能设备", "家里有什么智能设备"]
    static let queryMarkers = ["什么状态", "开着吗", "关着吗", "亮不亮", "温度多少", "亮度多少", "多少度", "状态怎么样"]
    /// 目标名称长度上限（设备 / 房间名，防误吞长句）
    static let targetMaxLength = 8
    /// 查询文本长度上限
    static let queryMaxLength = 16

    static func parse(_ text: String) -> AgentHomeKitCommand? {
        let trimmed = trim(text)
        guard !trimmed.isEmpty else { return nil }

        // 列出设备（短句）
        if trimmed.count <= queryMaxLength,
           listMarkers.contains(where: { trimmed.contains($0) }) {
            return .listDevices
        }

        // 全屋动作：「关掉所有灯」「把所有灯关掉」「全屋的灯打开」「全部灯都关掉」
        if let command = parseAll(trimmed) {
            return command
        }

        // 查询状态：「客厅灯什么状态」「空调温度多少」
        if let command = parseQuery(trimmed) {
            return command
        }

        // 控制：「打开客厅灯」「把客厅灯打开」「把空调调到26度」
        return parseControl(trimmed)
    }

    /// 全屋动作：「关掉所有灯」「把所有灯关掉」「所有灯都打开」「全屋的灯打开」
    private static func parseAll(_ text: String) -> AgentHomeKitCommand? {
        for category in ["灯", "开关"] {
            guard let range = text.range(of: category) else { continue }
            let before = String(text[..<range.lowerBound])
            let after = String(text[range.upperBound...])
            // 必须带「所有 / 全部 / 全屋」限定词，避免误吞「打开客厅灯」
            guard ["所有", "全部", "全屋"].contains(where: { before.contains($0) }) else { continue }
            var action: AgentHomeKitAction?
            // after 里的动作词（「把所有灯关掉」「所有灯都打开」）
            for (word, candidate) in openWords + closeWords
            where after.contains(word) || after.hasPrefix("都") {
                action = candidate
                break
            }
            // before 里的动作词（「关掉所有灯」「打开所有灯」）
            if action == nil {
                for (word, candidate) in openWords + closeWords where before.contains(word) {
                    action = candidate
                    break
                }
            }
            guard let action else { return nil }
            return .controlAll(category: category, action: action)
        }
        return nil
    }

    /// 查询状态
    private static func parseQuery(_ text: String) -> AgentHomeKitCommand? {
        guard text.count <= queryMaxLength else { return nil }
        guard let marker = queryMarkers.first(where: { text.contains($0) }) else { return nil }
        let target = trim(text.replacingOccurrences(of: marker, with: ""))
        guard validTarget(target) else { return nil }
        return .query(target: target)
    }

    /// 控制动作
    private static func parseControl(_ text: String) -> AgentHomeKitCommand? {
        // 1. 「把X打开 / 把X关掉 / 把X调到N / 把X调亮」
        if text.hasPrefix("把") {
            let rest = trim(String(text.dropFirst("把".count)))
            guard let split = splitAction(from: rest) else { return nil }
            let target = trim(split.target)
            guard validTarget(target) else { return nil }
            return .control(target: target, action: split.action)
        }

        // 2. 「打开X / 关掉X」：动作词开头
        for (prefix, action) in openPrefixes where text.hasPrefix(prefix) {
            let target = trim(String(text.dropFirst(prefix.count)))
            guard validTarget(target) else { return nil }
            return .control(target: target, action: action)
        }
        for (prefix, action) in closePrefixes where text.hasPrefix(prefix) {
            let target = trim(String(text.dropFirst(prefix.count)))
            guard validTarget(target) else { return nil }
            return .control(target: target, action: action)
        }

        // 3. 「X亮度调到N」「X温度调到N度」
        if let brightness = parseBrightnessSuffix(text) { return brightness }
        if let temperature = parseTemperatureSuffix(text) { return temperature }

        return nil
    }

    /// 在「把」结构中切出 目标 + 动作
    private static func splitAction(from text: String) -> (target: String, action: AgentHomeKitAction)? {
        // 调亮度 / 调温度：「客厅灯调到50%」「空调调到26度」
        if let range = text.range(of: "调到") {
            let target = trim(String(text[..<range.lowerBound]))
            let valueText = trim(String(text[range.upperBound...]))
            if let percent = parsePercent(valueText) {
                return (target, .setBrightness(percent))
            }
            if let celsius = parseDegrees(valueText) {
                return (target, .setTemperature(celsius))
            }
            return nil
        }
        if let range = text.range(of: "调亮") {
            return (trim(String(text[..<range.lowerBound])), .brighten)
        }
        if let range = text.range(of: "调暗") {
            return (trim(String(text[..<range.lowerBound])), .dim)
        }
        if let range = text.range(of: "温度设为") {
            let target = trim(String(text[..<range.lowerBound]))
            let valueText = trim(String(text[range.upperBound...]))
            guard let celsius = parseDegrees(valueText) else { return nil }
            return (target, .setTemperature(celsius))
        }
        // 开 / 关
        for (marker, action) in openMarkers where text.hasSuffix(marker) {
            let target = trim(String(text.dropLast(marker.count)))
            guard !target.isEmpty else { continue }
            return (target, action)
        }
        for (marker, action) in closeMarkers where text.hasSuffix(marker) {
            let target = trim(String(text.dropLast(marker.count)))
            guard !target.isEmpty else { continue }
            return (target, action)
        }
        return nil
    }

    /// 「X亮度调到50」后缀结构
    private static func parseBrightnessSuffix(_ text: String) -> AgentHomeKitCommand? {
        guard let range = text.range(of: "亮度调到") else { return nil }
        let target = trim(String(text[..<range.lowerBound]))
        let valueText = trim(String(text[range.upperBound...]))
        guard validTarget(target), let percent = parsePercent(valueText) else { return nil }
        return .control(target: target, action: .setBrightness(percent))
    }

    /// 「X温度调到26度」后缀结构
    private static func parseTemperatureSuffix(_ text: String) -> AgentHomeKitCommand? {
        guard let range = text.range(of: "温度调到") else { return nil }
        let target = trim(String(text[..<range.lowerBound]))
        let valueText = trim(String(text[range.upperBound...]))
        guard validTarget(target), let celsius = parseDegrees(valueText) else { return nil }
        return .control(target: target, action: .setTemperature(celsius))
    }

    /// 数字 + 可选百分号
    static func parsePercent(_ text: String) -> Int? {
        let digits = String(text.prefix { $0.isASCII && $0.isNumber })
        guard let value = Int(digits), !digits.isEmpty else { return nil }
        let tail = trim(String(text.dropFirst(digits.count)))
        guard tail.isEmpty || tail == "%" || tail == "％" else { return nil }
        return min(max(value, 0), 100)
    }

    /// 数字 + 度（摄氏度）
    static func parseDegrees(_ text: String) -> Double? {
        var digits = ""
        var hasDot = false
        for character in text {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if character == "." || character == "点" {
                guard !hasDot, !digits.isEmpty else { break }
                hasDot = true
                digits.append(".")
            } else {
                break
            }
        }
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        let tail = trim(String(text.dropFirst(digits.count)))
        guard tail.isEmpty || tail.hasPrefix("度") || tail.hasPrefix("℃") || tail.hasPrefix("°") else { return nil }
        return value
    }

    private static var openPrefixes: [(String, AgentHomeKitAction)] {
        [("打开", .turnOn), ("开启", .turnOn), ("开一下", .turnOn)]
    }

    private static var closePrefixes: [(String, AgentHomeKitAction)] {
        [("关掉", .turnOff), ("关闭", .turnOff), ("关上", .turnOff)]
    }

    private static var openMarkers: [(String, AgentHomeKitAction)] {
        [("打开", .turnOn), ("开启", .turnOn)]
    }

    private static var closeMarkers: [(String, AgentHomeKitAction)] {
        [("关掉", .turnOff), ("关闭", .turnOff), ("关上", .turnOff)]
    }

    private static var openWords: [(String, AgentHomeKitAction)] {
        [("打开", .turnOn), ("开启", .turnOn)]
    }

    private static var closeWords: [(String, AgentHomeKitAction)] {
        [("关掉", .turnOff), ("关闭", .turnOff), ("关上", .turnOff)]
    }

    /// 家居类别尾缀词（目标必须含其一，防止「打开App」类误吞）
    static let homeKeywords = [
        "灯", "开关", "空调", "风扇", "插座", "锁", "窗帘",
        "暖气", "加湿器", "净化器", "热水器", "电视", "音响", "投影",
        "客厅", "卧室", "厨房", "书房", "餐厅", "卫生间", "阳台",
        "主卧", "次卧", "玄关", "走廊",
    ]

    /// 目标名称有效性：非空、长度受限、含家居关键词、无动作残留
    private static func validTarget(_ target: String) -> Bool {
        guard !target.isEmpty, target.count <= targetMaxLength else { return false }
        let actionResidue = ["打开", "关掉", "关闭", "关上", "开启", "调到", "调亮", "调暗", "什么", "吗", "呢"]
        guard !actionResidue.contains(where: { target.hasPrefix($0) }) else { return false }
        return homeKeywords.contains { target.contains($0) }
    }

    private static func trim(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。！!？?、的"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 目标匹配

/// 设备 / 房间名匹配（纯逻辑可测）
enum AgentHomeKitTargetMatcher {
    /// 设备名尾缀词（匹配时忽略）
    static let kindSuffixes = ["灯", "开关", "空调", "风扇", "插座", "门锁", "窗帘"]

    /// 返回与目标匹配的设备（可多个：房间名匹配到多设备）
    static func match(target: String, devices: [AgentHomeKitDevice]) -> [AgentHomeKitDevice] {
        let normalizedTarget = normalize(target)
        guard !normalizedTarget.isEmpty else { return [] }

        var exact: [AgentHomeKitDevice] = []
        var contained: [AgentHomeKitDevice] = []
        var room: [AgentHomeKitDevice] = []

        for device in devices {
            let deviceName = normalize(device.name)
            let roomName = normalize(device.roomName ?? "")
            if deviceName == normalizedTarget || stripped(deviceName) == normalizedTarget {
                exact.append(device)
            } else if deviceName.contains(normalizedTarget) || normalizedTarget.contains(deviceName) {
                contained.append(device)
            } else if !roomName.isEmpty,
                      roomName == normalizedTarget || roomName.contains(normalizedTarget) {
                room.append(device)
            }
        }
        var result = exact
        for device in contained where !result.contains(where: { $0.id == device.id }) {
            result.append(device)
        }
        for device in room where !result.contains(where: { $0.id == device.id }) {
            result.append(device)
        }
        return result
    }

    /// 归一化：去空白、去标点、去尾缀
    static func normalize(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !"：:，,。！!？?、的".contains($0) })
    }

    static func stripped(_ name: String) -> String {
        var result = normalize(name)
        for suffix in kindSuffixes where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        return result
    }
}

// MARK: - 文案

/// 家居状态与应答文案（纯逻辑可测）
enum AgentHomeKitFormatter {
    static func deviceStatus(_ device: AgentHomeKitDevice) -> String {
        switch device.kind {
        case .thermostat:
            if let target = device.targetTemperature {
                return String(
                    format: "agent.homekit.status.temperature".localized,
                    device.name,
                    trimmedNumber(target)
                )
            }
            return String(format: "agent.homekit.status.off".localized, device.name)
        case .lock:
            let key = device.isLocked == true
                ? "agent.homekit.status.locked"
                : "agent.homekit.status.unlocked"
            return String(format: key.localized, device.name)
        default:
            guard let isOn = device.isOn else {
                return String(format: "agent.homekit.status.unknown".localized, device.name)
            }
            if isOn {
                if let brightness = device.brightness {
                    return String(
                        format: "agent.homekit.status.on.brightness".localized,
                        device.name,
                        trimmedNumber(Double(brightness))
                    )
                }
                return String(format: "agent.homekit.status.on".localized, device.name)
            }
            return String(format: "agent.homekit.status.off".localized, device.name)
        }
    }

    static func controlled(_ device: AgentHomeKitDevice, action: AgentHomeKitAction) -> String {
        switch action {
        case .turnOn:
            return String(format: "agent.homekit.controlled.on".localized, device.name)
        case .turnOff:
            return String(format: "agent.homekit.controlled.off".localized, device.name)
        case .setBrightness(let percent):
            return String(
                format: "agent.homekit.controlled.brightness".localized,
                device.name,
                trimmedNumber(Double(percent))
            )
        case .setTemperature(let celsius):
            return String(
                format: "agent.homekit.controlled.temperature".localized,
                device.name,
                trimmedNumber(celsius)
            )
        case .brighten:
            return String(format: "agent.homekit.controlled.brighten".localized, device.name)
        case .dim:
            return String(format: "agent.homekit.controlled.dim".localized, device.name)
        }
    }

    static func controlledAll(count: Int, action: AgentHomeKitAction) -> String {
        switch action {
        case .turnOn:
            return String(format: "agent.homekit.controlled.all.on".localized, count)
        case .turnOff:
            return String(format: "agent.homekit.controlled.all.off".localized, count)
        case .setBrightness(let percent):
            return String(format: "agent.homekit.controlled.all.brightness".localized, count, percent)
        case .setTemperature(let celsius):
            return String(format: "agent.homekit.controlled.all.temperature".localized, count, trimmedNumber(celsius))
        case .brighten:
            return String(format: "agent.homekit.controlled.all.brighten".localized, count)
        case .dim:
            return String(format: "agent.homekit.controlled.all.dim".localized, count)
        }
    }

    static func deviceList(_ devices: [AgentHomeKitDevice]) -> String {
        guard !devices.isEmpty else { return "agent.homekit.list.empty".localized }
        let names = devices.map { $0.name }.joined(separator: "、")
        return String(format: "agent.homekit.list".localized, names)
    }

    /// 去除无意义尾零
    static func trimmedNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - 执行器

/// 家居指令执行：HomeKit 副作用 + 应答文案（可注入 provider 测试）
enum AgentHomeKitExecutor {
    static func execute(
        _ command: AgentHomeKitCommand,
        provider: AgentHomeKitProviding
    ) async -> String {
        guard provider.authorization == .authorized else {
            return "agent.homekit.unavailable".localized
        }
        let devices = await provider.devices()

        switch command {
        case .listDevices:
            return AgentHomeKitFormatter.deviceList(devices)

        case .query(let target):
            let matched = AgentHomeKitTargetMatcher.match(target: target, devices: devices)
            guard !matched.isEmpty else {
                return String(format: "agent.homekit.notfound".localized, target)
            }
            if matched.count == 1 {
                return AgentHomeKitFormatter.deviceStatus(matched[0])
            }
            let statuses = matched.map(AgentHomeKitFormatter.deviceStatus)
            return statuses.joined(separator: "；")

        case .control(let target, let action):
            let matched = AgentHomeKitTargetMatcher.match(target: target, devices: devices)
            guard !matched.isEmpty else {
                return String(format: "agent.homekit.notfound".localized, target)
            }
            do {
                var replies: [String] = []
                for device in matched {
                    try await apply(action, to: device, provider: provider)
                    replies.append(AgentHomeKitFormatter.controlled(device, action: action))
                }
                return replies.joined(separator: "；")
            } catch {
                return "agent.homekit.control.failed".localized
            }

        case .controlAll(let category, let action):
            var targets = devices
            if let category {
                targets = devices.filter { Self.matchesCategory($0, category) }
            } else {
                targets = devices.filter { $0.kind != .lock && $0.kind != .unknown }
            }
            guard !targets.isEmpty else {
                return "agent.homekit.list.empty".localized
            }
            do {
                for device in targets {
                    try await apply(action, to: device, provider: provider)
                }
                return AgentHomeKitFormatter.controlledAll(count: targets.count, action: action)
            } catch {
                return "agent.homekit.control.failed".localized
            }
        }
    }

    private static func apply(
        _ action: AgentHomeKitAction,
        to device: AgentHomeKitDevice,
        provider: AgentHomeKitProviding
    ) async throws {
        switch action {
        case .turnOn:
            try await provider.setPower(deviceID: device.id, on: true)
        case .turnOff:
            try await provider.setPower(deviceID: device.id, on: false)
        case .setBrightness(let percent):
            try await provider.setBrightness(deviceID: device.id, percent: percent)
        case .setTemperature(let celsius):
            try await provider.setTemperature(deviceID: device.id, celsius: celsius)
        case .brighten:
            let current = device.brightness ?? 80
            let target = min(current + 20, 100)
            try await provider.setBrightness(deviceID: device.id, percent: target)
        case .dim:
            let current = device.brightness ?? 50
            let target = max(current - 20, 0)
            try await provider.setBrightness(deviceID: device.id, percent: target)
        }
    }

    private static func matchesCategory(_ device: AgentHomeKitDevice, _ category: String) -> Bool {
        switch category {
        case "灯": return device.kind == .light
        case "开关": return device.kind == .switch || device.kind == .outlet
        case "空调": return device.kind == .thermostat
        case "风扇": return device.kind == .fan
        default: return true
        }
    }
}

// MARK: - 静态容器

enum AgentHomeKit {
    static var provider: AgentHomeKitProviding = HomeKitHomeService()
}
