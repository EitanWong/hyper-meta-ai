/*
 * Agent List Store
 * 前端自有工具：用户命名清单（购物单 / 待办）由前台直接维护，
 * 不占后台 Agent 会话（对齐 interaction-design §4.4「前端自有工具」）。
 * UserDefaults JSON 持久化，纯逻辑便于测试。
 */

import Foundation

/// 一个用户命名清单（如「购物单」「待办」）
struct AgentNamedList: Codable, Equatable, Identifiable {
    var id: UUID
    /// 清单名称（如「购物单」），存储时去重键
    var name: String
    /// 条目（保持添加顺序）
    var items: [String]
    var date: Date

    init(id: UUID = UUID(), name: String, items: [String] = [], date: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.date = date
    }
}

/// 命名清单存储（UserDefaults JSON 持久化：最多 10 个清单，每清单最多 50 条）
enum AgentListStore {
    static let key = "agent.lists.data"
    static let maxListCount = 10
    static let maxItemsPerList = 50

    static var lists: [AgentNamedList] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([AgentNamedList].self, from: data)) ?? []
        }
        set {
            let trimmed = Array(newValue.prefix(maxListCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 按名称取清单（名称忽略首尾空白与大小写）
    static func list(named name: String) -> AgentNamedList? {
        let name = normalized(name)
        return lists.first { normalized($0.name) == name }
    }

    /// 新建空清单；nil 表示未生效（名称为空、重名或已达上限）
    @discardableResult
    static func createList(named name: String) -> AgentNamedList? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard list(named: name) == nil else { return nil }
        guard lists.count < maxListCount else { return nil }
        let list = AgentNamedList(name: name)
        var items = lists
        items.append(list)
        lists = items
        return list
    }

    /// 追加条目：清单不存在时自动创建；返回更新后的清单。
    /// nil 表示未生效（条目/名称为空、重复、清单或条目数已达上限）。
    @discardableResult
    static func addItem(_ item: String, to name: String) -> AgentNamedList? {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty, !name.isEmpty else { return nil }
        var items = lists
        var target: AgentNamedList
        if let index = items.firstIndex(where: { normalized($0.name) == normalized(name) }) {
            target = items[index]
        } else {
            guard items.count < maxListCount else { return nil }
            target = AgentNamedList(name: name)
            items.append(target)
        }
        guard !target.items.contains(item) else { return nil }
        guard target.items.count < maxItemsPerList else { return nil }
        target.items.append(item)
        if let index = items.firstIndex(where: { $0.id == target.id }) {
            items[index] = target
        }
        lists = items
        return target
    }

    /// 移除条目（精确匹配，全部移除）；清空后保留空清单
    static func removeItem(_ item: String, from name: String) {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = lists
        guard let index = items.firstIndex(where: { normalized($0.name) == normalized(name) }) else { return }
        items[index].items.removeAll { $0 == item }
        lists = items
    }

    /// 清空清单条目（保留清单本身）
    static func clearItems(named name: String) {
        var items = lists
        guard let index = items.firstIndex(where: { normalized($0.name) == normalized(name) }) else { return }
        items[index].items = []
        lists = items
    }

    static func removeList(id: UUID) {
        lists = lists.filter { $0.id != id }
    }

    static func removeList(named name: String) {
        lists = lists.filter { normalized($0.name) != normalized(name) }
    }

    /// 重命名清单（按 id）；nil 表示未生效（空名、重名或清单不存在）。
    /// 保留 id / 条目 / 更新时间不变。
    @discardableResult
    static func renameList(id: UUID, to newName: String) -> AgentNamedList? {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return nil }
        var items = lists
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        guard !items.contains(where: {
            $0.id != id && normalized($0.name) == normalized(newName)
        }) else { return nil }
        items[index].name = newName
        lists = items
        return items[index]
    }

    /// 重命名清单（按名称，名称忽略首尾空白与大小写）；语义同上
    @discardableResult
    static func renameList(named oldName: String, to newName: String) -> AgentNamedList? {
        guard let target = list(named: oldName) else { return nil }
        return renameList(id: target.id, to: newName)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 命名清单语音指令
enum AgentListCommand: Equatable {
    /// 添加条目（如「把牛奶加到购物单」）
    case add(item: String, list: String)
    /// 移除条目（如「从购物单删掉牛奶」）
    case remove(item: String, list: String)
    /// 查询清单内容（如「购物单里有什么」）
    case query(list: String)
    /// 按序号查询清单（如「第 2 个清单里有什么」；index 0-based）
    case queryIndex(index: Int)
    /// 查询清单单条（如「购物单第 2 条是什么」；index 0-based）
    case queryItem(list: String, index: Int)
    /// 双层组合点名（如「第 2 个清单第 3 条」；listIndex / itemIndex 均 0-based）
    case queryItemByIndexes(listIndex: Int, itemIndex: Int)
    /// 重命名清单（如「把购物单改名为生活清单」）
    case rename(list: String, newName: String)
    /// 清空清单（如「清空购物单」）
    case clear(list: String)
}

/// 命名清单语音指令解析（纯规则，保守匹配避免误吞普通对话）。
/// 命中前提：文本中出现清单关键词（购物单 / 待办 / 清单 / 购物清单 / 任务清单）。
enum AgentListCommandParser {
    static let knownKeywords = ["购物清单", "任务清单", "购物单", "待办", "清单"]
    /// 添加连接词（item 在连接词前，list 在连接词后）
    static let addSeparators = ["添加到", "加到", "添加", "加入"]
    /// 清单在前、动作在后的添加连接词（如「购物单加牛奶」）
    static let addTrailingSeparators = ["里加", "里添加", "加", "添加", "记上"]
    /// 移除连接词（list 在连接词前，item 在连接词后）
    static let removeSeparators = ["删掉", "删除", "移除", "去掉"]
    /// 重命名连接词（list 在连接词前，新名在连接词后）
    static let renameSeparators = ["改名为", "改名成", "更名为", "重命名为", "改成", "改为"]
    /// 查询后缀（list 在连接词前，如「购物单里有什么」）
    static let querySuffixes = ["里有什么", "里有哪些", "有什么内容", "有哪些内容", "里是啥", "里有什么东西", "有什么", "有哪些"]
    /// 查询前缀（如「查一下购物单」）
    static let queryPrefixes = ["查一下", "查查", "看看", "查看"]
    /// 清空前缀（如「清空购物单」）
    static let clearPrefixes = ["清空一下", "清空", "清掉"]
    /// 条目/清单两侧需要剥离的标点
    static let punctuation = CharacterSet(charactersIn: "：:，,。！!？?、")

    static func parse(_ text: String) -> AgentListCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let command = parseClear(trimmed) { return command }
        if let item = parseQueryItemByIndexes(trimmed) { return item }
        if let index = parseQueryIndex(trimmed) { return .queryIndex(index: index) }
        if let item = parseQueryItem(trimmed) { return item }
        if let command = parseQuery(trimmed) { return command }
        if let command = parseRemove(trimmed) { return command }
        if let command = parseRename(trimmed) { return command }
        if let command = parseAdd(trimmed) { return command }
        return nil
    }

    /// 双层组合点名：支持「第2个清单第3条 / 第二个清单第三条」（各 1-19，0-based 返回）。
    /// 整体解析不回溯；任一序号超出支持范围即放弃，避免误命中单层模式。
    static func parseQueryItemByIndexes(_ text: String) -> AgentListCommand? {
        let compact = text.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        let pattern = "第([0-9]+|[一二三四五六七八九十]+)个清单第([0-9]+|[一二三四五六七八九十]+)条"
        guard let range = compact.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(compact[range])
        let parts = matched
            .replacingOccurrences(of: "清单", with: " ")
            .replacingOccurrences(of: "第", with: "")
            .replacingOccurrences(of: "个", with: "")
            .replacingOccurrences(of: "条", with: "")
            .split(separator: " ")
            .map(String.init)
        guard parts.count == 2,
              let listValue = AgentTaskCommandParser.numeralValue(parts[0]), listValue >= 1,
              let itemValue = AgentTaskCommandParser.numeralValue(parts[1]), itemValue >= 1 else {
            return nil
        }
        return .queryItemByIndexes(listIndex: listValue - 1, itemIndex: itemValue - 1)
    }

    /// 重命名：清单名 + 连接词 + 新名（如「把购物单改名为生活清单」）。
    /// 名称须含清单关键词；前导「把/将」剥离。
    static func parseRename(_ text: String) -> AgentListCommand? {
        guard let sep = renameSeparators.first(where: { text.contains($0) }),
              let sepRange = text.range(of: sep) else { return nil }
        var name = String(text[..<sepRange.lowerBound])
        for prefix in ["把", "将"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(1))
        }
        let list = strip(name)
        let newName = strip(text[sepRange.upperBound...])
        guard containsKeyword(list), !newName.isEmpty else { return nil }
        return .rename(list: list, newName: newName)
    }

    /// 单条点名：支持「购物单第2条是什么 / 购物单第二条」（1-19，0-based 返回）。
    /// 「第 X 条」整体解析，X 超出支持范围（如「第二十条」）返回 nil 不回溯；
    /// 名称须含清单关键词，避免「第二条」误吞普通对话。
    static func parseQueryItem(_ text: String) -> AgentListCommand? {
        let compact = text.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        guard let range = compact.range(
            of: "第([0-9]+|[一二三四五六七八九十]+)条",
            options: .regularExpression
        ) else { return nil }
        let digits = String(compact[range])
            .replacingOccurrences(of: "第", with: "")
            .replacingOccurrences(of: "条", with: "")
        guard let value = AgentTaskCommandParser.numeralValue(digits), value >= 1 else { return nil }
        let name = strip(compact[..<range.lowerBound])
        guard containsKeyword(name) else { return nil }
        return .queryItem(list: name, index: value - 1)
    }

    /// 序号点名：支持「第2个清单 / 第二个清单 / 清单三」（1-19，0-based 返回）。
    /// 与任务点名共用中文数字解析；「第 3 个」中的空格先剥离再匹配。
    /// 「第 X 个清单」整体解析，X 超出支持范围（如「第二十个清单」）返回 nil，
    /// 不回溯误命中「十个清单」。
    static func parseQueryIndex(_ text: String) -> Int? {
        let compact = text.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        // 「第 X 个清单」整体（X 不可解析直接放弃，不回溯）
        if let range = compact.range(of: "第([0-9]+|[一二三四五六七八九十]+)(?:个)?清单", options: .regularExpression) {
            let digits = String(compact[range])
                .replacingOccurrences(of: "第", with: "")
                .replacingOccurrences(of: "个", with: "")
                .replacingOccurrences(of: "清单", with: "")
            if let value = AgentTaskCommandParser.numeralValue(digits), value >= 1 {
                return value - 1
            }
            return nil
        }
        // 兼容「清单三 / 清单3」：数字后不接更多中文数字（避免「清单三十」截断成「清单三」）
        if let range = compact.range(
            of: "清单([0-9]+|[一二三四五六七八九十]+)(?![一二三四五六七八九十])",
            options: .regularExpression
        ) {
            let digits = String(compact[range]).replacingOccurrences(of: "清单", with: "")
            if let value = AgentTaskCommandParser.numeralValue(digits), value >= 1 {
                return value - 1
            }
        }
        return nil
    }

    /// 清空：清空 + 清单名
    private static func parseClear(_ text: String) -> AgentListCommand? {
        guard let prefix = clearPrefixes.first(where: { text.hasPrefix($0) }) else { return nil }
        let name = strip(text.dropFirst(prefix.count))
        guard containsKeyword(name) else { return nil }
        return .clear(list: name)
    }

    /// 查询：清单名 + 查询后缀，或查询前缀 + 清单名
    private static func parseQuery(_ text: String) -> AgentListCommand? {
        if let suffix = querySuffixes.first(where: { text.contains($0) }),
           let range = text.range(of: suffix) {
            var name = String(text[..<range.lowerBound])
            if let prefix = queryPrefixes.first(where: { name.hasPrefix($0) }) {
                name = String(name.dropFirst(prefix.count))
            }
            name = strip(name)
            if containsKeyword(name) {
                return .query(list: name)
            }
        }
        if let prefix = queryPrefixes.first(where: { text.hasPrefix($0) }) {
            let name = strip(text.dropFirst(prefix.count))
            if containsKeyword(name) {
                return .query(list: name)
            }
        }
        return nil
    }

    /// 移除：清单名 + 移除连接词 + 条目（如「购物单删掉牛奶」），
    /// 或 从 + 清单名 + 移除连接词 + 条目（如「从购物单删掉牛奶」），
    /// 或 把 + 条目 + 从 + 清单名 + 移除连接词（如「把牛奶从购物单删掉」）
    private static func parseRemove(_ text: String) -> AgentListCommand? {
        if text.hasPrefix("把") {
            guard let fromRange = text.range(of: "从"),
                  let sep = removeSeparators.first(where: { text.contains($0) }),
                  let sepRange = text.range(of: sep) else { return nil }
            let item = strip(text[text.index(after: text.startIndex)..<fromRange.lowerBound])
            let list = strip(text[fromRange.upperBound..<sepRange.lowerBound])
            guard containsKeyword(list) else { return nil }
            return .remove(item: item, list: list)
        }
        var candidate = text
        if candidate.hasPrefix("从") {
            candidate = String(candidate.dropFirst(1))
        }
        guard let sep = removeSeparators.first(where: { candidate.contains($0) }),
              let sepRange = candidate.range(of: sep) else { return nil }
        let list = strip(String(candidate[..<sepRange.lowerBound]))
        let item = strip(candidate[sepRange.upperBound...])
        guard containsKeyword(list) else { return nil }
        return .remove(item: item, list: list)
    }

    /// 添加：条目 + 添加连接词 + 清单名（可带「把」），或 清单名 + 添加连接词 + 条目
    private static func parseAdd(_ text: String) -> AgentListCommand? {
        // 清单在前：购物单加牛奶 / 购物单里加牛奶
        if let sep = addTrailingSeparators.first(where: { text.contains($0) }),
           let sepRange = text.range(of: sep) {
            let list = strip(text[..<sepRange.lowerBound])
            let item = strip(text[sepRange.upperBound...])
            if containsKeyword(list), !item.isEmpty {
                return .add(item: item, list: list)
            }
        }
        // 条目在前：把牛奶加到购物单 / 牛奶添加到购物单
        if let sep = addSeparators.first(where: { text.contains($0) }),
           let sepRange = text.range(of: sep) {
            var item = String(text[..<sepRange.lowerBound])
            if item.hasPrefix("把") {
                item = String(item.dropFirst(1))
            }
            let list = strip(text[sepRange.upperBound...])
            item = strip(item)
            if containsKeyword(list), !item.isEmpty {
                return .add(item: item, list: list)
            }
        }
        return nil
    }

    private static func containsKeyword(_ name: String) -> Bool {
        knownKeywords.contains { name.contains($0) }
    }

    private static func strip(_ text: some StringProtocol) -> String {
        String(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punctuation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 命名清单的镜片展示映射（纯逻辑，可测）
enum AgentListDisplayMapping {
    /// 是否有命名清单（镜片主菜单「Lists」动态出现的依据，空清单也展示以便查看/管理）
    static func hasLists() -> Bool {
        !AgentListStore.lists.isEmpty
    }

    /// 清单按更新时间降序取最近 limit 个
    static func recentLists(limit: Int = 5) -> [AgentNamedList] {
        Array(AgentListStore.lists.sorted { $0.date > $1.date }.prefix(max(0, limit)))
    }

    /// 按钮短标签：清单名截断（超长加省略号），空名回退「List」
    static func menuLabel(for list: AgentNamedList, maxLength: Int = 8) -> String {
        let name = list.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "List" }
        let trimmed = String(name.prefix(maxLength))
        return name.count > maxLength ? trimmed + "…" : trimmed
    }

    /// 播报 / 展示文本：清单名：条目（顿号连接）；空清单回退「名称（空）」
    static func resultText(for list: AgentNamedList) -> String {
        if list.items.isEmpty {
            return String(format: "agent.lists.empty".localized, list.name)
        }
        let separator = "agent.lists.separator".localized
        return String(format: "agent.lists.result".localized, list.name, list.items.joined(separator: separator))
    }

    /// 子菜单按钮图标（MWDATDisplay.IconName 的 rawValue）
    static func iconName() -> String {
        "shopping_bag"
    }

    /// 序号点名播报：越界提示当前数量；命中复用查询话术（空清单 / 内容）
    static func queryIndexMessage(index: Int, lists: [AgentNamedList]) -> String {
        guard index >= 0, index < lists.count else {
            return String(format: "agent.list.query.index.range".localized, index + 1, lists.count)
        }
        let list = lists[index]
        if list.items.isEmpty {
            return String(format: "agent.list.query.empty".localized, list.name)
        }
        return String(
            format: "agent.list.query.content".localized,
            list.name,
            list.items.joined(separator: "agent.lists.separator".localized)
        )
    }

    /// 条目是否多到需要镜片「逐条听」子菜单（>3 条；小清单直接整体播报，低摩擦）
    static func shouldShowItemMenu(for list: AgentNamedList) -> Bool {
        list.items.count > 3
    }

    /// 条目列表（截断到镜片单屏容量）
    static func items(for list: AgentNamedList, limit: Int = 8) -> [String] {
        Array(list.items.prefix(max(0, limit)))
    }

    /// 条目按钮短标签：序号 + 内容截断（如「1 牛奶」）
    static func itemMenuLabel(for item: String, index: Int, maxLength: Int = 10) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = String(trimmed.prefix(maxLength)) + (trimmed.count > maxLength ? "…" : "")
        return "\(index + 1) \(content)"
    }

    /// 单条播报文本：清单名第 N 条：内容
    static func itemResultText(for item: String, index: Int, in list: AgentNamedList) -> String {
        String(format: "agent.list.item.result".localized, list.name, index + 1, item)
    }
}

/// 清单指令 → 语音 / 聊天回复文本（纯构造，可测；副作用由调用方执行后再构造）
enum AgentListResponseText {
    static func added(item: String, to list: String) -> String {
        String(format: "agent.list.added".localized, item, list)
    }

    static func duplicate(item: String, in list: String) -> String {
        String(format: "agent.list.add.dup".localized, item, list)
    }

    static func full(list: String) -> String {
        String(format: "agent.list.add.full".localized, list)
    }

    static func removed(item: String, from list: String) -> String {
        String(format: "agent.list.removed".localized, item, list)
    }

    static func missing(item: String, in list: String) -> String {
        String(format: "agent.list.item.missing".localized, item, list)
    }

    static func query(list: String, items: [String]) -> String {
        if items.isEmpty {
            return String(format: "agent.list.query.empty".localized, list)
        }
        return String(
            format: "agent.list.query.content".localized,
            list,
            items.joined(separator: "agent.lists.separator".localized)
        )
    }

    /// 序号点名：与镜片 Lists 子菜单同一排序基准（由调用方传入排好序的清单）
    static func queryIndex(index: Int, lists: [AgentNamedList]) -> String {
        AgentListDisplayMapping.queryIndexMessage(index: index, lists: lists)
    }

    static func cleared(list: String) -> String {
        String(format: "agent.list.cleared".localized, list)
    }

    /// 单条点名：命中复用镜片逐条播报话术；越界提示当前条目数
    static func queryItem(list: String, index: Int, items: [String]) -> String {
        guard index >= 0, index < items.count else {
            return String(format: "agent.list.query.item.range".localized, list, index + 1, items.count)
        }
        return String(format: "agent.list.item.result".localized, list, index + 1, items[index])
    }

    static func renamed(list: String, to newName: String) -> String {
        String(format: "agent.list.renamed".localized, list, newName)
    }

    static func renameDuplicate(name: String) -> String {
        String(format: "agent.list.rename.dup".localized, name)
    }

    static func renameNotFound(list: String) -> String {
        String(format: "agent.list.rename.notfound".localized, list)
    }

    /// 双层组合点名：清单越界 / 条目越界 / 命中三态；
    /// 排序基准与镜片 Lists 子菜单一致（调用方传入最近更新的清单）
    static func queryItemByIndexes(
        listIndex: Int,
        itemIndex: Int,
        lists: [AgentNamedList]
    ) -> String {
        guard listIndex >= 0, listIndex < lists.count else {
            return String(format: "agent.list.query.index.range".localized, listIndex + 1, lists.count)
        }
        let list = lists[listIndex]
        guard itemIndex >= 0, itemIndex < list.items.count else {
            return String(format: "agent.list.query.item.range".localized, list.name, itemIndex + 1, list.items.count)
        }
        return String(
            format: "agent.list.item.result".localized,
            list.name,
            itemIndex + 1,
            list.items[itemIndex]
        )
    }
}
