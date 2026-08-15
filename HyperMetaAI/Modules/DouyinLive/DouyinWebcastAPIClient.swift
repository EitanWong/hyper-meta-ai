import Foundation
import os.log

private let douyinAPILogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "DouyinWebcastAPI"
)

@MainActor
final class DouyinWebcastAPIClient:
    DouyinAccountReading,
    DouyinRoomPreparing,
    DouyinRoomLifecycle,
    DouyinRoomMetricsReading
{
    private struct PreparedContext {
        let account: DouyinAccount
        let orientation: DouyinLiveOrientation
        let latestRoomData: [String: Any]
        let createInfoData: [String: Any]
    }

    private struct PlatformResponse {
        let httpStatus: Int
        let businessStatus: Int?
        let payload: [String: Any]

        var data: [String: Any] {
            payload["data"] as? [String: Any] ?? [:]
        }
    }

    private let configuration: DouyinLiveConfiguration
    private let executor: any DouyinRequestExecuting
    private var preparedContext: PreparedContext?

    init(configuration: DouyinLiveConfiguration, executor: any DouyinRequestExecuting) {
        self.configuration = configuration
        self.executor = executor
    }

    func currentAccount() async throws -> DouyinAccount {
        let response = try await request(path: "/webcast/user/me/")
        guard response.businessStatus == 0 else {
            throw DouyinLiveError.sessionUnavailable
        }

        let data = response.data
        let accountID = Self.firstString(
            in: data,
            keys: ["user_id", "id_str", "id", "webcast_uid"]
        )
        guard let accountID, !accountID.isEmpty else {
            throw DouyinLiveError.sessionUnavailable
        }

        let nickname = Self.firstString(
            in: data,
            keys: ["nickname", "nick_name", "display_name", "name"]
        ) ?? "douyin.account.default".localized
        return DouyinAccount(id: accountID, nickname: nickname)
    }

    func prepareRoom(orientation: DouyinLiveOrientation) async throws -> DouyinRoomPreparation {
        let account = try await currentAccount()
        let room = try await request(path: "/webcast/room/check_exist/")
        let idleStatuses: Set<Int> = [30001, 30003]
        guard room.businessStatus.map(idleStatuses.contains) == true else {
            throw DouyinLiveError.platform("douyin.error.roomactive".localized)
        }

        let permissionVersion: String
        if let versionResponse = try? await request(path: "/webcast/anchor/pc_live/get_pc_version/"),
           versionResponse.businessStatus == 0,
           let version = versionResponse.data["version"] as? String,
           !version.isEmpty {
            permissionVersion = version
        } else {
            permissionVersion = "version_3"
        }

        async let permission = request(
            path: "/webcast/anchor/permission/status/",
            query: [
                "permission_name": "pc_live",
                "version": permissionVersion,
                "need_apply_detail": "1",
                "uid": account.id,
            ]
        )
        async let certification = request(
            path: "/webcast/anchor/permission/creator_certification_chk/"
        )
        async let latestRoom = request(
            method: .post,
            path: "/webcast/room/get_latest_room/",
            form: [:]
        )
        async let createInfo = request(
            path: "/webcast/room/create_info/",
            query: [
                "orientation": String(orientation.rawValue),
                "live_room_mode": "0",
                "enable_preview_stream": "true",
            ]
        )

        let responses = try await (permission, certification, latestRoom, createInfo)
        let permissionData = responses.0.data
        let certificationData = responses.1.data
        let applyStatus = Self.intValue(permissionData["apply_status"]) ?? 0
        let isGovernment = Self.intValue(permissionData["is_government"]) ?? 0
        let needsCertification = Self.boolValue(certificationData["need_certification"]) ?? true

        let permissionReady = responses.0.businessStatus == 0
            && responses.1.businessStatus == 0
            && ![1, 2, 3].contains(applyStatus)
            && isGovernment != 1
            && !needsCertification
        guard permissionReady else {
            throw DouyinLiveError.platform("douyin.error.permission".localized)
        }
        guard responses.2.businessStatus == 0, responses.3.businessStatus == 0 else {
            throw DouyinLiveError.platform("douyin.error.metadata".localized)
        }

        preparedContext = PreparedContext(
            account: account,
            orientation: orientation,
            latestRoomData: responses.2.data,
            createInfoData: responses.3.data
        )
        return DouyinRoomPreparation(account: account, orientation: orientation)
    }

    func createRoom(
        title: String,
        orientation: DouyinLiveOrientation
    ) async throws -> DouyinLiveRoom {
        guard let context = preparedContext, context.orientation == orientation else {
            throw DouyinLiveError.invalidResponse("preflight context")
        }

        let autoCover = Self.intValue(context.createInfoData["auto_cover"])
            ?? Self.intValue(context.latestRoomData["auto_cover"])
            ?? 2
        let cover = (context.createInfoData["cover"] as? [String: Any])
            ?? (context.latestRoomData["cover"] as? [String: Any])

        var form = [
            "multi_resolution": "true",
            "title": Self.sanitizeTitle(title),
            "orientation": String(orientation.rawValue),
            "has_commerce_goods": "false",
            "disable_location_permission": "1",
            "push_stream_type": "1",
            "auto_cover": String(autoCover),
            "payload": "",
            "third_party": "1",
            "enable_health_score_check": "true",
            "live_agreement": "1",
        ]
        if autoCover != 1,
           let cover,
           let uri = cover["uri"] as? String,
           !uri.isEmpty {
            form["cover_uri"] = uri
            form["thumb_width"] = String(Self.intValue(cover["width"]) ?? 1280)
            form["thumb_height"] = String(Self.intValue(cover["height"]) ?? 720)
        }

        let response = try await request(
            method: .post,
            path: "/webcast/room/create/",
            form: form
        )
        guard response.businessStatus == 0 else {
            if response.businessStatus == 4_003_166 {
                throw DouyinLiveError.platform(
                    "douyin.error.protection.rejected".localized
                )
            }
            throw Self.platformError(from: response)
        }

        let data = response.data
        guard let roomID = Self.firstString(in: data, keys: ["id_str", "id"]),
              let streamID = Self.firstString(in: data, keys: ["stream_id_str", "stream_id"]),
              let streamURL = data["stream_url"] as? [String: Any],
              let publishURL = Self.selectPushURL(from: streamURL) else {
            throw DouyinLiveError.invalidResponse("room id, stream id, or RTMP publish URL")
        }

        return DouyinLiveRoom(
            id: roomID,
            streamID: streamID,
            publishURL: publishURL,
            accountID: context.account.id
        )
    }

    func heartbeat(room: DouyinLiveRoom, status: Int) async throws {
        let response = try await request(
            method: .post,
            path: "/webcast/room/ping/anchor/",
            form: [
                "room_id": room.id,
                "stream_id": room.streamID,
                "status": String(status),
            ]
        )
        guard response.businessStatus == 0 || [30001, 30003].contains(response.businessStatus) else {
            throw Self.platformError(from: response)
        }
    }

    func signalFinish(room: DouyinLiveRoom) async throws {
        try await heartbeat(room: room, status: 4)
    }

    func completeFinish(room: DouyinLiveRoom) async throws {
        try await Task.sleep(for: .milliseconds(1_500))
        let response = try await request(
            method: .post,
            path: "/webcast/room/anchor_finish_info/",
            form: ["room_id": room.id]
        )
        guard response.businessStatus == 0 || [30001, 30003].contains(response.businessStatus) else {
            throw Self.platformError(from: response)
        }
    }

    func verifyRoomIdle() async throws -> Bool {
        let response = try await request(path: "/webcast/room/check_exist/")
        return [30001, 30003].contains(response.businessStatus)
    }

    func metrics(for room: DouyinLiveRoom) async throws -> DouyinLiveMetrics {
        let response = try await request(
            path: "/webcast/data/data_center/room_stats",
            query: ["room_id": room.id]
        )
        guard response.businessStatus == 0 else {
            throw Self.platformError(from: response)
        }
        return Self.parseMetrics(from: response.data)
    }

    static func selectPushURL(from streamURL: [String: Any]) -> URL? {
        var candidates: [String] = []
        if let directRTMP = streamURL["rtmp_push_url"] as? String {
            candidates.append(directRTMP)
        }
        if let pushURLs = streamURL["push_urls"] as? [String] {
            candidates.append(contentsOf: pushURLs)
        }

        let trimmed = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let prioritized = trimmed.filter { $0.lowercased().hasPrefix("rtmp://") }
            + trimmed.filter { $0.lowercased().hasPrefix("rtmps://") }
        return prioritized.lazy.compactMap(URL.init(string:)).first
    }
}

private extension DouyinWebcastAPIClient {
    private func request(
        method: DouyinHTTPMethod = .get,
        path: String,
        query: [String: String] = [:],
        form: [String: String]? = nil
    ) async throws -> PlatformResponse {
        douyinAPILogger.debug(
            "Request started method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public)"
        )
        guard var components = URLComponents(
            url: configuration.apiOrigin.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw DouyinLiveError.invalidResponse("request URL")
        }
        let requestQuery = configuration.commonQuery.merging(query) { _, endpointValue in endpointValue }
        components.queryItems = requestQuery
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw DouyinLiveError.invalidResponse("request URL")
        }

        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Referer": configuration.apiOrigin.absoluteString + "/",
        ]
        let body: Data?
        if let form {
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            body = Self.formBody(form)
        } else {
            body = nil
        }

        let response = try await executor.execute(
            DouyinHTTPRequest(
                method: method,
                url: url,
                headers: headers,
                body: body,
                requiresPlatformProtection: true
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw DouyinLiveError.platform("HTTP \(response.statusCode)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw DouyinLiveError.invalidResponse("JSON body")
        }
        let platformResponse = PlatformResponse(
            httpStatus: response.statusCode,
            businessStatus: Self.intValue(payload["status_code"] ?? payload["code"]),
            payload: payload
        )
        Self.debugTrace(path: path, response: platformResponse)
        douyinAPILogger.debug(
            "Request completed path=\(path, privacy: .public) http=\(response.statusCode) business=\(platformResponse.businessStatus ?? -1)"
        )
        return platformResponse
    }

    static func formBody(_ form: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = form
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?
            .replacingOccurrences(of: "%20", with: "+")
            .data(using: .utf8)
    }

    static func sanitizeTitle(_ title: String) -> String {
        let disallowed = CharacterSet.controlCharacters
        let cleaned = title.unicodeScalars.map { disallowed.contains($0) ? " " : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "douyin.default.title".localized : trimmed).prefix(60))
    }

    private static func platformError(from response: PlatformResponse) -> DouyinLiveError {
        let detail = firstString(
            in: response.payload,
            keys: ["status_msg", "message", "msg", "prompts"]
        ) ?? "status \(response.businessStatus.map(String.init) ?? "unknown")"
        return .platform(detail)
    }

    private static func debugTrace(path: String, response: PlatformResponse) {
        #if DEBUG
        let message = firstString(
            in: response.payload,
            keys: ["status_msg", "message", "msg", "prompts"]
        ) ?? "none"
        let promptSummary = debugJSON(response.data["prompts"])
        let roomMetadataSummary = path == "/webcast/room/create_info/"
            ? debugJSON(roomMetadataDiagnostics(from: response.data))
            : "none"
        print(
            "[DouyinLiveDebug] API response path=\(path) http=\(response.httpStatus) "
                + "business=\(response.businessStatus ?? -1) message=\(message.prefix(160)) "
                + "prompts=\(promptSummary) roomMetadata=\(roomMetadataSummary)"
        )
        #endif
    }

    private static func debugJSON(_ value: Any?) -> String {
        guard let value else { return "none" }
        if let string = value as? String {
            return String(string.prefix(2_000))
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "none"
        }
        let redactedURLs = json.replacingOccurrences(
            of: #"(?:https?|wss?|rtmps?|rtmp|srt):(?:\\/\\/|//)[^\"\s]+"#,
            with: "<URL>",
            options: .regularExpression
        )
        let redactedIDs = redactedURLs.replacingOccurrences(
            of: #"\b\d{6,}\b"#,
            with: "<ID>",
            options: .regularExpression
        )
        return String(redactedIDs.prefix(2_000))
    }

    private static func roomMetadataDiagnostics(from data: [String: Any]) -> [String: Any] {
        let keys = [
            "anchor_prompt_type",
            "block_status",
            "disable_info",
            "go_live_prompt",
            "is_not_block_create_global",
            "live_additional_prompt",
            "live_guide_intercept_strategy",
            "never_go_live_flag",
            "obs_audit_status",
            "pc_live_permission_apply",
            "pc_live_permission_apply_status",
            "trial_live_info",
        ]
        return keys.reduce(into: [:]) { result, key in
            if let value = data[key] {
                result[key] = value
            }
        }
    }

    static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let number = dictionary[key] as? NSNumber { return number.stringValue }
        }
        for child in dictionary.values {
            if let nested = child as? [String: Any],
               let value = firstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }

    static func parseMetrics(from payload: [String: Any]) -> DouyinLiveMetrics {
        var flattened: [String: Int64] = [:]
        flattenNumbers(payload, path: "", output: &flattened)

        func maximum(matching patterns: [String]) -> Int64 {
            flattened
                .filter { path, _ in patterns.contains { path.localizedCaseInsensitiveContains($0) } }
                .map(\.value)
                .max() ?? 0
        }

        return DouyinLiveMetrics(
            viewerCount: maximum(matching: ["online", "viewer", "user_count"]),
            peakViewerCount: maximum(matching: ["peak"]),
            likeCount: maximum(matching: ["like"]),
            giftCount: maximum(matching: ["gift", "fan_ticket"]),
            memberCount: maximum(matching: ["member"]),
            chatCount: maximum(matching: ["comment", "chat"])
        )
    }

    static func flattenNumbers(
        _ value: Any,
        path: String,
        output: inout [String: Int64],
        depth: Int = 0
    ) {
        guard depth <= 5 else { return }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                flattenNumbers(child, path: childPath, output: &output, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.prefix(6).enumerated() {
                flattenNumbers(child, path: "\(path)[\(index)]", output: &output, depth: depth + 1)
            }
        } else if let number = value as? NSNumber {
            output[path] = number.int64Value
        } else if let string = value as? String, let number = Int64(string) {
            output[path] = number
        }
    }
}
