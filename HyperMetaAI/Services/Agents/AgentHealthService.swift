/*
 * Agent Health（健康数据，HealthKit）
 * JARVIS 式健康管家：语音 / 聊天直接读写系统健康数据——「记录体重65公斤」
 * 「今天走了8000步」「记录跑步5公里」写入，「今天走了多少步」「最近体重」
 * 「昨晚睡了多久」查询；权限按需请求，HKHealthStore 走协议注入（测试用 Mock）。
 */

import Foundation
import HealthKit

/// 健康授权状态（映射 HKAuthorizationStatus，纯枚举可测）
enum AgentHealthAuthorization: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// 健康能力提供者（HKHealthStore 封装，可注入 Mock 测试）
protocol AgentHealthProviding {
    var authorization: AgentHealthAuthorization { get }
    func requestAuthorization() async -> AgentHealthAuthorization
    func recordSteps(_ count: Int, date: Date) async throws
    func recordBodyMass(kilograms: Double, date: Date) async throws
    func recordRun(kilometers: Double, date: Date) async throws
    func steps(from start: Date, to end: Date) async throws -> Int
    func latestBodyMass() async throws -> (kilograms: Double, date: Date)?
    func sleepHours(from start: Date, to end: Date) async throws -> Double
}

/// HKHealthStore 真实实现
final class HealthKitHealthService: AgentHealthProviding {
    private let store = HKHealthStore()

    private var typesToShare: Set<HKSampleType> {
        [
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
            HKWorkoutType.workoutType(),
        ]
    }

    private var typesToRead: Set<HKObjectType> {
        [
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]
    }

    var authorization: AgentHealthAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        let statuses = typesToShare.map {
            store.authorizationStatus(for: $0)
        }
        if statuses.contains(.sharingDenied) {
            return .denied
        }
        if statuses.contains(.sharingAuthorized) {
            return .authorized
        }
        return .notDetermined
    }

    func requestAuthorization() async -> AgentHealthAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        do {
            try await store.requestAuthorization(toShare: typesToShare, read: typesToRead)
        } catch {
            return authorization
        }
        return authorization
    }

    func recordSteps(_ count: Int, date: Date) async throws {
        let quantity = HKQuantity(unit: .count(), doubleValue: Double(max(count, 0)))
        let sample = HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(1)
        )
        try await store.save(sample)
    }

    func recordBodyMass(kilograms: Double, date: Date) async throws {
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: max(kilograms, 0))
        let sample = HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(1)
        )
        try await store.save(sample)
    }

    func recordRun(kilometers: Double, date: Date) async throws {
        let distance = HKQuantity(unit: .meterUnit(with: .kilo), doubleValue: max(kilometers, 0))
        // 按 10 公里/小时配速估算时长（跑步 5 公里 ≈ 30 分钟）
        let duration = TimeInterval(max(kilometers, 0) / 10.0 * 3600)
        let workout = HKWorkout(
            activityType: .running,
            start: date,
            end: date.addingTimeInterval(max(duration, 60)),
            duration: max(duration, 60),
            totalEnergyBurned: nil,
            totalDistance: distance,
            metadata: nil
        )
        try await store.save(workout)
    }

    func steps(from start: Date, to end: Date) async throws -> Int {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let count = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(count.rounded()))
            }
            store.execute(query)
        }
    }

    func latestBodyMass() async throws -> (kilograms: Double, date: Date)? {
        let type = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let kilograms = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                continuation.resume(returning: (kilograms: kilograms, date: sample.startDate))
            }
            store.execute(query)
        }
    }

    func sleepHours(from start: Date, to end: Date) async throws -> Double {
        let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]
                let seconds = (samples ?? []).compactMap { $0 as? HKCategorySample }
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                continuation.resume(returning: seconds / 3600)
            }
            store.execute(query)
        }
    }
}

/// 应用侧健康能力入口（测试可替换 provider）
enum AgentHealth {
    static var provider: AgentHealthProviding = HealthKitHealthService()
}

// MARK: - Command

/// 健康语音 / 文字指令
enum AgentHealthCommand: Equatable {
    /// 记录步数（日期为记录日）
    case recordSteps(Int, Date)
    /// 记录体重（公斤）
    case recordWeight(Double, Date)
    /// 记录跑步（公里）
    case recordRun(Double, Date)
    /// 查询步数（日期为查询日）
    case querySteps(Date)
    /// 查询最近体重
    case queryWeight
    /// 查询昨晚睡眠时长
    case querySleep
}

/// 健康指令解析（保守匹配：数字 + 明确单位词，避免误吞普通对话）
enum AgentHealthCommandParser {
    static let weightRecordPrefixes = ["记录体重", "记一下体重", "把体重记为"]
    static let stepsRecordPrefixes = ["记录步数", "记一下步数"]
    static let runRecordPrefixes = ["记录跑步", "记一下跑步", "记录跑了", "我跑了", "今天跑了", "跑了"]
    static let stepsQueryMarkers = ["走了多少步", "多少步", "步数多少", "查一下步数"]
    static let weightQueryMarkers = ["体重多少", "体重怎么样", "现在多重", "查一下体重"]
    static let sleepQueryMarkers = ["睡了多久", "睡眠怎么样", "睡眠如何", "昨晚睡得", "查一下睡眠"]
    /// 查询文本长度上限（防止普通对话命中 marker）
    static let queryMaxLength = 14

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AgentHealthCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        // 记录体重：「记录体重65公斤」
        if let prefix = weightRecordPrefixes.first(where: { trimmed.hasPrefix($0) }) {
            let rest = strip(trimmed.dropFirst(prefix.count))
            guard let number = parseNumber(rest) else { return nil }
            let tail = strip(rest.dropFirst(number.consumedCount))
            guard tail.isEmpty || weightUnits.contains(where: { tail.hasPrefix($0) }) else { return nil }
            return .recordWeight(number.value, today)
        }

        // 记录步数：「记录步数8000（步）」
        if let prefix = stepsRecordPrefixes.first(where: { trimmed.hasPrefix($0) }) {
            let rest = strip(trimmed.dropFirst(prefix.count))
            guard let number = parseNumber(rest) else { return nil }
            let tail = strip(rest.dropFirst(number.consumedCount))
            guard tail.isEmpty || tail.hasPrefix("步") else { return nil }
            return .recordSteps(Int(number.value.rounded()), today)
        }

        // 「今天走了8000步」「昨天走了6000步」
        for (prefix, day) in [("今天走了", today), ("昨天走了", yesterday)] where trimmed.hasPrefix(prefix) {
            let rest = strip(trimmed.dropFirst(prefix.count))
            guard let number = parseNumber(rest) else { continue }
            let tail = strip(rest.dropFirst(number.consumedCount))
            guard tail.isEmpty || tail.hasPrefix("步") else { continue }
            return .recordSteps(Int(number.value.rounded()), day)
        }

        // 记录跑步：「记录跑步5公里」「我跑了5公里」
        if let prefix = runRecordPrefixes.first(where: { trimmed.hasPrefix($0) }) {
            let rest = strip(trimmed.dropFirst(prefix.count))
            guard let number = parseNumber(rest) else { return nil }
            let tail = strip(rest.dropFirst(number.consumedCount))
            guard tail.isEmpty || distanceUnits.contains(where: { tail.hasPrefix($0) }) else { return nil }
            return .recordRun(number.value, today)
        }

        // 查询步数（支持「昨天走了多少步」）
        if trimmed.count <= queryMaxLength,
           stepsQueryMarkers.contains(where: { trimmed.contains($0) }) {
            let day = trimmed.contains("昨天") ? yesterday : today
            return .querySteps(day)
        }
        if trimmed.count <= queryMaxLength,
           weightQueryMarkers.contains(where: { trimmed.contains($0) }) {
            return .queryWeight
        }
        if trimmed.count <= queryMaxLength,
           sleepQueryMarkers.contains(where: { trimmed.contains($0) }) {
            return .querySleep
        }
        return nil
    }

    /// 数字解析：阿拉伯数字（支持小数点）或中文「X点Y」小数
    static func parseNumber(_ text: String) -> (value: Double, consumedCount: Int)? {
        var digits = ""
        var hasDot = false
        var consumed = 0
        for character in text {
            // 仅接受 ASCII 数字：CJK 的「千/万」等 isNumber 也为 true，会混入数字串
            if character.isASCII, character.isNumber {
                digits.append(character)
                consumed += 1
            } else if character == "." || character == "点" {
                guard !hasDot, !digits.isEmpty else { break }
                hasDot = true
                digits.append(".")
                consumed += 1
            } else {
                break
            }
        }
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return (value: value, consumedCount: consumed)
    }

    private static let weightUnits = ["公斤", "千克", "kg", "KG", "Kg"]
    private static let distanceUnits = ["公里", "千米", "km", "KM", "Km"]

    private static func strip(_ text: Substring) -> String {
        String(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。！!？?、"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 时间窗

/// 健康查询时间窗（纯逻辑可测）
enum AgentHealthTimeWindow {
    /// 「昨晚」：昨天 22:00 → 今天 10:00
    static func lastNight(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let start = calendar.date(byAdding: .hour, value: 22, to: yesterday) ?? yesterday
        let end = calendar.date(byAdding: .hour, value: 10, to: today) ?? today
        return (start: start, end: end)
    }
}

// MARK: - 文案

/// 健康数值与应答文案（纯逻辑可测）
enum AgentHealthFormatter {
    static func weight(_ kilograms: Double) -> String {
        let value = trimmedNumber(kilograms)
        return LanguageManager.staticIsChinese ? "\(value)公斤" : "\(value) kg"
    }

    static func steps(_ count: Int) -> String {
        LanguageManager.staticIsChinese ? "\(count)步" : "\(count) steps"
    }

    static func run(_ kilometers: Double) -> String {
        let value = trimmedNumber(kilometers)
        return LanguageManager.staticIsChinese ? "\(value)公里" : "\(value) km"
    }

    static func sleepHours(_ hours: Double) -> String {
        let value = trimmedNumber(hours)
        return LanguageManager.staticIsChinese ? "\(value)小时" : "\(value) hours"
    }

    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return LanguageManager.staticIsChinese ? "今天" : "today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return LanguageManager.staticIsChinese ? "昨天" : "yesterday"
        }
        return dateFormatter.string(from: date)
    }

    /// 去除无意义尾零：65.0 → 65；65.50 → 65.5
    private static func trimmedNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        if LanguageManager.staticIsChinese {
            formatter.locale = Locale(identifier: "zh-Hans")
            formatter.dateFormat = "M月d日"
        } else {
            formatter.locale = Locale(identifier: "en")
            formatter.dateFormat = "MMM d"
        }
        return formatter
    }()
}

// MARK: - 执行器

/// 健康指令执行：统一授权 + HKHealthStore 副作用，返回应答文案（可注入 provider 测试）
enum AgentHealthExecutor {
    static func execute(
        _ command: AgentHealthCommand,
        provider: AgentHealthProviding,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> String {
        switch command {
        case .recordSteps(let count, let date):
            guard await authorized(provider) else { return deniedText }
            do {
                try await provider.recordSteps(count, date: date)
                return String(format: "agent.health.recorded.steps".localized, AgentHealthFormatter.steps(count))
            } catch {
                return saveFailedText
            }
        case .recordWeight(let kilograms, let date):
            guard await authorized(provider) else { return deniedText }
            do {
                try await provider.recordBodyMass(kilograms: kilograms, date: date)
                return String(format: "agent.health.recorded.weight".localized, AgentHealthFormatter.weight(kilograms))
            } catch {
                return saveFailedText
            }
        case .recordRun(let kilometers, let date):
            guard await authorized(provider) else { return deniedText }
            do {
                try await provider.recordRun(kilometers: kilometers, date: date)
                return String(format: "agent.health.recorded.run".localized, AgentHealthFormatter.run(kilometers))
            } catch {
                return saveFailedText
            }
        case .querySteps(let date):
            guard await authorized(provider) else { return deniedText }
            do {
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: date)
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let count = try await provider.steps(from: start, to: end)
                let isYesterday = !calendar.isDate(date, inSameDayAs: now)
                if count > 0 {
                    let key = isYesterday
                        ? "agent.health.query.steps.yesterday"
                        : "agent.health.query.steps.today"
                    return String(format: key.localized, AgentHealthFormatter.steps(count))
                }
                let emptyKey = isYesterday
                    ? "agent.health.query.steps.empty.yesterday"
                    : "agent.health.query.steps.empty.today"
                return emptyKey.localized
            } catch {
                return queryFailedText
            }
        case .queryWeight:
            guard await authorized(provider) else { return deniedText }
            do {
                guard let latest = try await provider.latestBodyMass() else {
                    return "agent.health.query.weight.empty".localized
                }
                let date = AgentHealthFormatter.dateLabel(latest.date, now: now, calendar: calendar)
                return String(
                    format: "agent.health.query.weight".localized,
                    AgentHealthFormatter.weight(latest.kilograms),
                    date
                )
            } catch {
                return queryFailedText
            }
        case .querySleep:
            guard await authorized(provider) else { return deniedText }
            do {
                let window = AgentHealthTimeWindow.lastNight(now: now, calendar: calendar)
                let hours = try await provider.sleepHours(from: window.start, to: window.end)
                if hours > 0 {
                    return String(format: "agent.health.query.sleep".localized, AgentHealthFormatter.sleepHours(hours))
                }
                return "agent.health.query.sleep.empty".localized
            } catch {
                return queryFailedText
            }
        }
    }

    private static func authorized(_ provider: AgentHealthProviding) async -> Bool {
        var status = provider.authorization
        if status == .notDetermined {
            status = await provider.requestAuthorization()
        }
        return status == .authorized
    }

    private static var deniedText: String {
        "agent.health.denied".localized
    }

    private static var saveFailedText: String {
        "agent.health.save.failed".localized
    }

    private static var queryFailedText: String {
        "agent.health.query.failed".localized
    }
}
