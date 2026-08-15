import Foundation
import XCTest

@testable import HyperMetaAI

@MainActor
final class DouyinLiveProtocolTests: XCTestCase {
    func testDefaultConfigurationMatchesOfficialAnchorWebRuntime() {
        let configuration = DouyinLiveConfiguration()

        XCTAssertEqual(configuration.apiOrigin.absoluteString, "https://webcast.amemv.com")
        XCTAssertEqual(configuration.commonQuery, [
            "aid": "477650",
            "device_platform": "web",
            "device_type": "web",
            "version_name": "10000",
        ])
        XCTAssertEqual(configuration.requestProfile.webProtection.appID, 477650)
        XCTAssertEqual(configuration.requestProfile.webProtection.pageID, 32057)
        XCTAssertFalse(configuration.requestProfile.webProtection.reusesLoadedPageRuntime)
        XCTAssertTrue(configuration.requestProfile.webProtection.capturesPageMsToken)
    }

    func testDefaultConfigurationDoesNotImpersonateAnotherClient() {
        let profile = DouyinLiveConfiguration().requestProfile

        XCTAssertEqual(profile.commonQuery["aid"], "477650")
        XCTAssertEqual(profile.commonQuery["device_platform"], "web")
        XCTAssertNil(profile.commonQuery["app_name"])
        XCTAssertNil(profile.commonQuery["device_id"])
        XCTAssertNil(profile.commonQuery["did"])
        XCTAssertNil(profile.commonQuery["iid"])
    }

    func testAccountRequestUsesWebcastOriginWithAnchorWebIdentity() async throws {
        let executor = RecordingDouyinRequestExecutor(payload: [
            "status_code": 0,
            "data": ["user_id": "ACCOUNT", "nickname": "主播"],
        ])
        let client = DouyinWebcastAPIClient(
            configuration: DouyinLiveConfiguration(),
            executor: executor
        )

        _ = try await client.currentAccount()

        let request = try XCTUnwrap(executor.requests.first)
        let query = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(request.url.host, "webcast.amemv.com")
        XCTAssertEqual(request.url.path, "/webcast/user/me")
        XCTAssertEqual(values["aid"], "477650")
        XCTAssertEqual(values["device_platform"], "web")
        XCTAssertEqual(values["version_name"], "10000")
        XCTAssertNil(values["did"])
        XCTAssertNil(values["iid"])
        XCTAssertNil(values["app_name"])
        XCTAssertEqual(request.headers["Referer"], "https://webcast.amemv.com/")
    }

    func testAuthenticatedPageDetectionRejectsLoginAndForeignPages() {
        let loginURL = URL(
            string: "https://anchor.douyin.com/login?login_after_redirect=/anchor/dashboard"
        )!

        XCTAssertFalse(DouyinWebRuntime.isAuthenticatedPageURL(loginURL, loginURL: loginURL))
        XCTAssertFalse(
            DouyinWebRuntime.isAuthenticatedPageURL(
                URL(string: "https://example.com/anchor/dashboard")!,
                loginURL: loginURL
            )
        )
        XCTAssertTrue(
            DouyinWebRuntime.isAuthenticatedPageURL(
                URL(string: "https://anchor.douyin.com/anchor/dashboard")!,
                loginURL: loginURL
            )
        )
    }

    func testSelectsDirectRTMPPublishURLWithoutManualStreamKeyInput() {
        let selected = DouyinWebcastAPIClient.selectPushURL(from: [
            "rtmp_push_url": "rtmp://push.example/live/STREAM_KEY",
            "push_urls": [
                "srt://push.example:9000?streamid=STREAM_KEY",
                "rtmps://push.example/live/FALLBACK_KEY",
            ],
        ])

        XCTAssertEqual(selected?.absoluteString, "rtmp://push.example/live/STREAM_KEY")
    }

    func testFallsBackToRTMPSAndRejectsUnsupportedOnlyProtocols() {
        XCTAssertEqual(
            DouyinWebcastAPIClient.selectPushURL(from: [
                "push_urls": ["srt://push.example:9000", "rtmps://push.example/live/KEY"],
            ])?.absoluteString,
            "rtmps://push.example/live/KEY"
        )
        XCTAssertNil(
            DouyinWebcastAPIClient.selectPushURL(from: [
                "push_urls": ["srt://push.example:9000"],
            ])
        )
    }

    func testDecodesRealtimeChatGiftLikeMemberAndRoomStatsMessages() throws {
        let chat = envelope(
            method: "WebcastChatMessage",
            payload: bytesField(3, Data("测试弹幕".utf8)),
            messageID: 101
        )

        let giftDetails = varintField(12, 66) + bytesField(16, Data("小心心".utf8))
        let giftPayload = varintField(2, 88)
            + varintField(5, 3)
            + bytesField(15, giftDetails)
        let gift = envelope(
            method: "WebcastGiftMessage",
            payload: giftPayload,
            messageID: 102
        )

        let like = envelope(
            method: "WebcastLikeMessage",
            payload: varintField(2, 5) + varintField(3, 23),
            messageID: 103
        )
        let member = envelope(
            method: "WebcastMemberMessage",
            payload: varintField(3, 188) + bytesField(11, Data("进入直播间".utf8)),
            messageID: 104
        )
        let roomStats = envelope(
            method: "WebcastRoomStatsMessage",
            payload: bytesField(2, Data("15人在线".utf8)) + varintField(9, 15),
            messageID: 105
        )

        let responseData = [chat, gift, like, member, roomStats]
            .reduce(Data()) { $0 + bytesField(1, $1) }
            + bytesField(2, Data("CURSOR".utf8))
            + varintField(3, 1_000)
            + bytesField(5, Data("INTERNAL_EXT".utf8))
        let response = try DouyinMessageDecoder.decodeResponse(responseData)
        let events = try response.messages.map(DouyinMessageDecoder.event(from:))

        XCTAssertEqual(response.cursor, "CURSOR")
        XCTAssertEqual(response.internalExtension, "INTERNAL_EXT")
        XCTAssertEqual(response.fetchIntervalMilliseconds, 1_000)
        XCTAssertEqual(events.map(\.kind), [.chat, .gift, .like, .member, .roomStats])
        XCTAssertEqual(events[0].detail, "测试弹幕")
        XCTAssertEqual(events[1].count, 3)
        XCTAssertTrue(events[1].detail.contains("小心心"))
        XCTAssertEqual(events[2].count, 5)
        XCTAssertEqual(events[2].total, 23)
        XCTAssertEqual(events[3].total, 188)
        XCTAssertEqual(events[4].total, 15)
    }

    func testEventMetricsUseTotalsWithoutDoubleCountingSnapshots() {
        var metrics = DouyinLiveMetrics()
        metrics.record(
            DouyinLiveEvent(
                id: "like-1",
                kind: .like,
                title: "Like",
                detail: "+5",
                count: 5,
                total: 23
            )
        )
        metrics.record(
            DouyinLiveEvent(
                id: "stats-1",
                kind: .roomStats,
                title: "Stats",
                detail: "15",
                count: 15,
                total: 15
            )
        )

        XCTAssertEqual(metrics.likeCount, 23)
        XCTAssertEqual(metrics.viewerCount, 15)
        XCTAssertEqual(metrics.peakViewerCount, 15)
    }

    func testMetricsSnapshotCanLowerCurrentViewersWithoutLoweringThePeak() {
        var metrics = DouyinLiveMetrics(viewerCount: 50, peakViewerCount: 50)

        metrics.merge(DouyinLiveMetrics(viewerCount: 12, peakViewerCount: 40))

        XCTAssertEqual(metrics.viewerCount, 12)
        XCTAssertEqual(metrics.peakViewerCount, 50)
    }

    private func envelope(method: String, payload: Data, messageID: UInt64) -> Data {
        bytesField(1, Data(method.utf8))
            + bytesField(2, payload)
            + varintField(3, messageID)
    }

    private func varintField(_ number: Int, _ value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    private func bytesField(_ number: Int, _ value: Data) -> Data {
        varint(UInt64((number << 3) | 2)) + varint(UInt64(value.count)) + value
    }

    private func varint(_ value: UInt64) -> Data {
        var remainder = value
        var output = Data()
        repeat {
            var byte = UInt8(remainder & 0x7F)
            remainder >>= 7
            if remainder != 0 { byte |= 0x80 }
            output.append(byte)
        } while remainder != 0
        return output
    }
}

@MainActor
private final class RecordingDouyinRequestExecutor: DouyinRequestExecuting {
    private(set) var requests: [DouyinHTTPRequest] = []
    private let payload: [String: Any]

    init(payload: [String: Any]) {
        self.payload = payload
    }

    func execute(_ request: DouyinHTTPRequest) async throws -> DouyinHTTPResponse {
        requests.append(request)
        return DouyinHTTPResponse(
            statusCode: 200,
            finalURL: request.url,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: payload)
        )
    }
}
