/*
 * Agent Share Queue（系统分享 → Hyper）
 * 任意 App 的内容经 Share Extension 进入待处理队列（App Group UserDefaults），
 * App 前台消费并映射为本地动作：存入长期记忆 / 存入命名清单 / 发给当前大脑。
 * 队列读写与动作应用为纯逻辑（可测），与扩展进程只共享 JSON 格式。
 */

import Foundation

/// 分享目标（rawValue 与 Share Extension 写入的字符串一致）
enum AgentShareDestination: String, Codable, CaseIterable {
    /// 存入长期记忆
    case memory
    /// 存入命名清单（自动创建「分享」清单）
    case list
    /// 发给当前大脑（启动语音会话并发送指令）
    case agent
}

/// 一条待处理的分享请求（字段与 Share Extension 的 payload 镜像一致）
struct AgentShareRequest: Codable, Equatable {
    var id: UUID
    /// 组合文本（标题 / 正文 / URL，扩展侧拼好）
    var text: String
    var destination: AgentShareDestination
    var date: Date

    init(id: UUID = UUID(), text: String, destination: AgentShareDestination, date: Date = Date()) {
        self.id = id
        self.text = text
        self.destination = destination
        self.date = date
    }
}

/// 分享队列（App Group UserDefaults JSON，上限 20 条滚动）
enum AgentShareQueue {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let key = "agent.share.queue"
    static let maxCount = 20

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func pending() -> [AgentShareRequest] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AgentShareRequest].self, from: data)) ?? []
    }

    /// 入队（去首尾空白；空内容不入队；超上限丢最旧）
    @discardableResult
    static func enqueue(_ request: AgentShareRequest) -> Bool {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var items = pending()
        items.append(AgentShareRequest(
            id: request.id,
            text: text,
            destination: request.destination,
            date: request.date
        ))
        let trimmed = Array(items.suffix(maxCount))
        guard let data = try? JSONEncoder().encode(trimmed) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    /// 取走全部待处理请求（消费后清空，幂等）
    static func consume() -> [AgentShareRequest] {
        let items = pending()
        guard !items.isEmpty else { return [] }
        defaults.removeObject(forKey: key)
        return items
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// 一次分享请求的应用结果（纯逻辑，可测）
enum AgentShareOutcome: Equatable {
    /// 已存入长期记忆
    case memoryAdded
    /// 已存入命名清单（携带清单名）
    case listAdded(String)
    /// 已转交语音会话（携带指令文本）
    case sentToAgent(String)
    /// 未生效（内容为空 / 记忆已满等）
    case invalid
}

/// 分享请求应用器：把队列请求落为本地动作（副作用写本地存储）
enum AgentShareProcessor {
    /// 默认清单名（本地化，自动创建）
    static var defaultListName: String {
        "agent.share.list.name".localized
    }

    /// 应用一条分享请求
    static func apply(_ request: AgentShareRequest) -> AgentShareOutcome {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid }
        switch request.destination {
        case .memory:
            return AgentMemoryStore.add(text: text) ? .memoryAdded : .invalid
        case .list:
            let name = defaultListName
            return AgentListStore.addItem(text, to: name) != nil ? .listAdded(name) : .invalid
        case .agent:
            return .sentToAgent(text)
        }
    }
}

/// 分享处理完成后的确认文案（纯逻辑，可测）
enum AgentShareConfirmation {
    /// Agent 目标由语音会话接管（无卡片）；invalid 无确认
    static func message(for outcome: AgentShareOutcome, text: String) -> String? {
        switch outcome {
        case .memoryAdded:
            return String(format: "share.processed.memory".localized, text)
        case .listAdded(let name):
            return String(format: "share.processed.list".localized, name)
        case .sentToAgent, .invalid:
            return nil
        }
    }
}
