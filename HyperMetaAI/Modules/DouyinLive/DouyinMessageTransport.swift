import Foundation

struct DouyinDecodedMessage: Equatable {
    let method: String
    let payload: Data
    let messageID: String
}

struct DouyinDecodedResponse: Equatable {
    let cursor: String
    let internalExtension: String
    let fetchIntervalMilliseconds: Int64
    let messages: [DouyinDecodedMessage]
}

enum DouyinMessageDecoder {
    static func decodeResponse(_ data: Data) throws -> DouyinDecodedResponse {
        let fields = try DouyinProtobufReader(data: data).readAllFields()
        let messages = try fields
            .filter { $0.number == 1 }
            .compactMap { field -> DouyinDecodedMessage? in
                guard case .bytes(let bytes) = field.value else { return nil }
                return try decodeEnvelopeMessage(bytes)
            }
        return DouyinDecodedResponse(
            cursor: fields.stringValue(for: 2) ?? "",
            internalExtension: fields.stringValue(for: 5) ?? "",
            fetchIntervalMilliseconds: Int64(fields.varintValue(for: 3) ?? 0),
            messages: messages
        )
    }

    static func event(from message: DouyinDecodedMessage) throws -> DouyinLiveEvent {
        let kind = classify(message.method)
        let messageID = message.messageID == "0" ? UUID().uuidString : message.messageID
        let fields = try DouyinProtobufReader(data: message.payload).readAllFields()

        switch kind {
        case .chat:
            let content = fields.stringValue(for: 3) ?? message.method
            return DouyinLiveEvent(
                id: messageID,
                kind: .chat,
                title: "douyin.event.chat".localized,
                detail: content
            )

        case .gift:
            let repeatCount = Int64(fields.varintValue(for: 5) ?? 0)
            let explicitCount = Int64(fields.varintValue(for: 44) ?? 0)
            let totalCount = Int64(fields.varintValue(for: 29) ?? 0)
            let count = [1, explicitCount, repeatCount, totalCount].max() ?? 1
            var giftName = "douyin.event.gift.default".localized
            var diamondCount: Int64 = 0
            if let giftData = fields.bytesValue(for: 15) {
                let giftFields = try DouyinProtobufReader(data: giftData).readAllFields()
                giftName = giftFields.stringValue(for: 16) ?? giftName
                diamondCount = Int64(giftFields.varintValue(for: 12) ?? 0)
            }
            let detail = diamondCount > 0
                ? String(format: "douyin.event.gift.detail.diamond".localized, giftName, count, diamondCount)
                : String(format: "douyin.event.gift.detail".localized, giftName, count)
            return DouyinLiveEvent(
                id: messageID,
                kind: .gift,
                title: "douyin.event.gift".localized,
                detail: detail,
                count: count
            )

        case .like:
            let count = Int64(fields.varintValue(for: 2) ?? 1)
            let total = fields.varintValue(for: 3).map(Int64.init)
            return DouyinLiveEvent(
                id: messageID,
                kind: .like,
                title: "douyin.event.like".localized,
                detail: String(format: "douyin.event.like.detail".localized, count),
                count: max(1, count),
                total: total
            )

        case .member:
            let memberCount = Int64(fields.varintValue(for: 3) ?? 0)
            let actionDescription = fields.stringValue(for: 11)
                ?? "douyin.event.member.detail".localized
            return DouyinLiveEvent(
                id: messageID,
                kind: .member,
                title: "douyin.event.member".localized,
                detail: actionDescription,
                count: 1,
                total: memberCount
            )

        case .roomStats:
            let detail = fields.stringValue(for: 2)
                ?? fields.stringValue(for: 3)
                ?? fields.stringValue(for: 4)
                ?? "douyin.event.stats.detail".localized
            let total = fields.varintValue(for: 9)
                ?? fields.varintValue(for: 5)
                ?? fields.varintValue(for: 3)
                ?? 0
            return DouyinLiveEvent(
                id: messageID,
                kind: .roomStats,
                title: "douyin.event.stats".localized,
                detail: detail,
                count: Int64(total),
                total: Int64(total)
            )

        case .other:
            return DouyinLiveEvent(
                id: messageID,
                kind: .other,
                title: "douyin.event.other".localized,
                detail: message.method
            )
        }
    }

    static func classify(_ method: String) -> DouyinLiveEvent.Kind {
        if method.hasSuffix("GiftMessage")
            || method.hasSuffix("BindingGiftMessage")
            || method.hasSuffix("DoodleGiftMessage")
            || method.hasSuffix("UpdateFanTicketMessage") {
            return .gift
        }
        if method.hasSuffix("ChatMessage")
            || method.hasSuffix("EmojiChatMessage")
            || method.hasSuffix("AudioChatMessage") {
            return .chat
        }
        if method == "WebcastLikeMessage" || method == "WebcastDiggMessage" {
            return .like
        }
        if method == "WebcastMemberMessage" {
            return .member
        }
        if method == "WebcastRoomStatsMessage" || method == "WebcastRoomUserSeqMessage" {
            return .roomStats
        }
        return .other
    }

    private static func decodeEnvelopeMessage(_ data: Data) throws -> DouyinDecodedMessage {
        let fields = try DouyinProtobufReader(data: data).readAllFields()
        return DouyinDecodedMessage(
            method: fields.stringValue(for: 1) ?? "UnknownMessage",
            payload: fields.bytesValue(for: 2) ?? Data(),
            messageID: String(fields.varintValue(for: 3) ?? 0)
        )
    }
}

@MainActor
final class DouyinPollingMessageClient: DouyinMessageReceiving {
    var onError: ((String) -> Void)?

    private let configuration: DouyinLiveConfiguration
    private let executor: any DouyinRequestExecuting
    private var pollingTask: Task<Void, Never>?
    private var cursor = ""
    private var internalExtension = ""
    private var lastRoundTripMilliseconds: Int64 = 0
    private var deliveredMessageIDs: Set<String> = []
    private var deliveredMessageOrder: [String] = []

    init(configuration: DouyinLiveConfiguration, executor: any DouyinRequestExecuting) {
        self.configuration = configuration
        self.executor = executor
    }

    func start(
        room: DouyinLiveRoom,
        account: DouyinAccount,
        onEvent: @escaping (DouyinLiveEvent) -> Void
    ) {
        stop()
        cursor = ""
        internalExtension = ""
        lastRoundTripMilliseconds = 0
        deliveredMessageIDs.removeAll(keepingCapacity: true)
        deliveredMessageOrder.removeAll(keepingCapacity: true)

        pollingTask = Task { [weak self] in
            guard let self else { return }
            var nextDelay = configuration.messagePollInterval
            var reportedError = false
            while !Task.isCancelled {
                do {
                    let response = try await poll(room: room, account: account)
                    for message in response.messages {
                        guard remember(message.messageID) else { continue }
                        do {
                            onEvent(try DouyinMessageDecoder.event(from: message))
                        } catch {
                            onError?(error.localizedDescription)
                        }
                    }
                    if response.fetchIntervalMilliseconds > 0 {
                        nextDelay = min(
                            3,
                            max(0.25, Double(response.fetchIntervalMilliseconds) / 1_000)
                        )
                    }
                    reportedError = false
                } catch is CancellationError {
                    return
                } catch {
                    if !reportedError {
                        onError?(error.localizedDescription)
                        reportedError = true
                    }
                }

                do {
                    try await Task.sleep(for: .seconds(nextDelay))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(
        room: DouyinLiveRoom,
        account: DouyinAccount
    ) async throws -> DouyinDecodedResponse {
        let startedAt = Date()
        guard var components = URLComponents(
            url: configuration.apiOrigin.appending(path: "/webcast/im/fetch/"),
            resolvingAgainstBaseURL: false
        ) else {
            throw DouyinLiveError.invalidResponse("message URL")
        }
        let query = messageQuery(room: room, account: account)
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw DouyinLiveError.invalidResponse("message URL")
        }

        let response = try await executor.execute(
            DouyinHTTPRequest(
                method: .get,
                url: url,
                headers: [
                    "Accept": "application/octet-stream, */*",
                    "Referer": configuration.apiOrigin.absoluteString + "/",
                ],
                body: nil,
                requiresPlatformProtection: true
            )
        )
        lastRoundTripMilliseconds = Int64(Date().timeIntervalSince(startedAt) * 1_000)
        guard (200..<300).contains(response.statusCode), !response.body.isEmpty else {
            throw DouyinLiveError.platform("message HTTP \(response.statusCode)")
        }

        let decoded = try DouyinMessageDecoder.decodeResponse(response.body)
        if !decoded.cursor.isEmpty { cursor = decoded.cursor }
        if !decoded.internalExtension.isEmpty { internalExtension = decoded.internalExtension }
        return decoded
    }

    private func messageQuery(
        room: DouyinLiveRoom,
        account: DouyinAccount
    ) -> [String: String] {
        configuration.requestProfile.messageCommonQuery.merging([
            "cursor": cursor,
            "fetch_rule": "1",
            "identity": "anchor",
            "internal_ext": internalExtension,
            "last_rtt": String(lastRoundTripMilliseconds),
            "live_id": "1",
            "resp_content_type": "protobuf",
            "room_id": room.id,
            "support_wrds": "1",
            "user_unique_id": account.id,
            "whitelist[0]": "WebcastLinkMessage",
            "whitelist[1]": "WebcastLinkMicMethod",
        ]) { _, dynamicValue in dynamicValue }
    }

    private func remember(_ messageID: String) -> Bool {
        guard messageID != "0" else { return true }
        guard deliveredMessageIDs.insert(messageID).inserted else { return false }
        deliveredMessageOrder.append(messageID)
        if deliveredMessageOrder.count > 2_000 {
            let overflow = deliveredMessageOrder.count - 2_000
            let removed = deliveredMessageOrder.prefix(overflow)
            deliveredMessageOrder.removeFirst(overflow)
            deliveredMessageIDs.subtract(removed)
        }
        return true
    }
}

private struct DouyinProtobufField {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
        case fixed64(UInt64)
    }

    let number: Int
    let value: Value
}

private struct DouyinProtobufReader {
    enum DecodeError: LocalizedError {
        case malformed
        case unsupportedWireType(Int)

        var errorDescription: String? {
            switch self {
            case .malformed: return "Malformed protobuf payload"
            case .unsupportedWireType(let type): return "Unsupported protobuf wire type \(type)"
            }
        }
    }

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    func readAllFields() throws -> [DouyinProtobufField] {
        var reader = self
        var fields: [DouyinProtobufField] = []
        while reader.index < reader.bytes.count {
            fields.append(try reader.readField())
        }
        return fields
    }

    private mutating func readField() throws -> DouyinProtobufField {
        let tag = try readVarint()
        let fieldNumber = Int(tag >> 3)
        guard fieldNumber > 0 else { throw DecodeError.malformed }

        let wireType = Int(tag & 0x07)
        let value: DouyinProtobufField.Value
        switch wireType {
        case 0:
            value = .varint(try readVarint())
        case 1:
            value = .fixed64(try readFixed64())
        case 2:
            let length = try readVarint()
            guard length <= UInt64(Int.max) else { throw DecodeError.malformed }
            value = .bytes(try readBytes(count: Int(length)))
        case 5:
            value = .fixed32(try readFixed32())
        default:
            throw DecodeError.unsupportedWireType(wireType)
        }
        return DouyinProtobufField(number: fieldNumber, value: value)
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { throw DecodeError.malformed }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw DecodeError.malformed
    }

    private mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, index <= bytes.count - count else { throw DecodeError.malformed }
        defer { index += count }
        return Data(bytes[index..<(index + count)])
    }

    private mutating func readFixed32() throws -> UInt32 {
        let data = try readBytes(count: 4)
        return data.enumerated().reduce(0) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    private mutating func readFixed64() throws -> UInt64 {
        let data = try readBytes(count: 8)
        return data.enumerated().reduce(0) { result, item in
            result | (UInt64(item.element) << UInt64(item.offset * 8))
        }
    }
}

private extension Array where Element == DouyinProtobufField {
    func varintValue(for number: Int) -> UInt64? {
        for field in reversed() where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    func bytesValue(for number: Int) -> Data? {
        for field in reversed() where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    func stringValue(for number: Int) -> String? {
        bytesValue(for: number).flatMap { String(data: $0, encoding: .utf8) }
    }
}
