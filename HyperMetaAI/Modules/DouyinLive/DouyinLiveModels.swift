import CoreGraphics
import CoreMedia
import Foundation

struct DouyinWebProtectionConfiguration: Equatable, Sendable {
    let appID: Int
    let pageID: Int
    let protectedPaths: [String]
    let reusesLoadedPageRuntime: Bool
    let capturesPageMsToken: Bool
}

struct DouyinRequestProfile: Equatable, Sendable {
    let apiOrigin: URL
    let commonQuery: [String: String]
    let messageCommonQuery: [String: String]
    let webProtection: DouyinWebProtectionConfiguration

    static let anchorWeb = DouyinRequestProfile(
        apiOrigin: URL(string: "https://webcast.amemv.com")!,
        commonQuery: [
            "aid": "477650",
            "device_platform": "web",
            "device_type": "web",
            "version_name": "10000",
        ],
        messageCommonQuery: [
            "aid": "477650",
            "device_platform": "web",
            "device_type": "web",
            "version_code": "10000",
            "version_name": "10000",
            "webcast_sdk_version": "10000",
        ],
        webProtection: DouyinWebProtectionConfiguration(
            appID: 477650,
            pageID: 32057,
            protectedPaths: [
                "/passport",
                "^/ark",
                "^/webcast",
                "^/aweme/v1",
                "^/aweme/v2",
                "^/live",
                "/aaaaa",
            ],
            reusesLoadedPageRuntime: false,
            capturesPageMsToken: true
        )
    )
}

struct DouyinLiveConfiguration: Equatable, Sendable {
    let requestProfile: DouyinRequestProfile
    let loginURL: URL
    let heartbeatInterval: TimeInterval
    let metricsInterval: TimeInterval
    let messagePollInterval: TimeInterval
    let videoSize: CGSize
    let videoBitrate: Int

    init(
        requestProfile: DouyinRequestProfile = .anchorWeb,
        loginURL: URL = URL(
            string: "https://anchor.douyin.com/login?from=hypermetaai&login_after_redirect=/anchor/dashboard"
        )!,
        heartbeatInterval: TimeInterval = 5,
        metricsInterval: TimeInterval = 5,
        messagePollInterval: TimeInterval = 1,
        videoSize: CGSize = CGSize(width: 504, height: 504),
        videoBitrate: Int = 2_000_000
    ) {
        self.requestProfile = requestProfile
        self.loginURL = loginURL
        self.heartbeatInterval = heartbeatInterval
        self.metricsInterval = metricsInterval
        self.messagePollInterval = messagePollInterval
        self.videoSize = videoSize
        self.videoBitrate = videoBitrate
    }

    var apiOrigin: URL { requestProfile.apiOrigin }

    var commonQuery: [String: String] {
        requestProfile.commonQuery
    }
}

struct DouyinAccount: Equatable, Sendable {
    let id: String
    let nickname: String
}

enum DouyinLiveOrientation: Int, Equatable, Sendable {
    case landscape = 0
    case portrait = 1
}

struct DouyinLiveRoom: Equatable, Sendable {
    let id: String
    let streamID: String
    let publishURL: URL
    let accountID: String
}

struct DouyinRoomPreparation: Equatable, Sendable {
    let account: DouyinAccount
    let orientation: DouyinLiveOrientation
}

struct DouyinLiveMetrics: Equatable, Sendable {
    var viewerCount: Int64 = 0
    var peakViewerCount: Int64 = 0
    var likeCount: Int64 = 0
    var giftCount: Int64 = 0
    var memberCount: Int64 = 0
    var chatCount: Int64 = 0

    mutating func merge(_ other: DouyinLiveMetrics) {
        viewerCount = max(0, other.viewerCount)
        peakViewerCount = max(peakViewerCount, other.peakViewerCount, viewerCount)
        likeCount = max(likeCount, other.likeCount)
        giftCount = max(giftCount, other.giftCount)
        memberCount = max(memberCount, other.memberCount)
        chatCount = max(chatCount, other.chatCount)
    }

    mutating func record(_ event: DouyinLiveEvent) {
        switch event.kind {
        case .chat:
            chatCount += 1
        case .gift:
            giftCount += max(1, event.count)
        case .like:
            likeCount = max(likeCount + max(1, event.count), event.total ?? 0)
        case .member:
            memberCount = max(memberCount, event.total ?? event.count)
        case .roomStats:
            viewerCount = max(0, event.total ?? event.count)
            peakViewerCount = max(peakViewerCount, viewerCount)
        case .other:
            break
        }
    }
}

struct DouyinPublishStats: Equatable, Sendable {
    var framesSent: Int64 = 0
    var framesDropped: Int64 = 0
    var framesPerSecond: Double = 0
    var duration: TimeInterval = 0
}

struct DouyinLiveEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case chat
        case gift
        case like
        case member
        case roomStats
        case other
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let count: Int64
    let total: Int64?
    let receivedAt: Date

    init(
        id: String,
        kind: Kind,
        title: String,
        detail: String,
        count: Int64 = 1,
        total: Int64? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.count = count
        self.total = total
        self.receivedAt = receivedAt
    }
}

enum DouyinLivePhase: Equatable {
    case signedOut
    case checkingSession
    case ready(DouyinAccount)
    case starting
    case live(DouyinLiveRoom)
    case stopping
    case failed(String)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .checkingSession, .starting, .stopping:
            return true
        case .signedOut, .ready, .live, .failed:
            return false
        }
    }
}

enum DouyinLiveError: LocalizedError {
    case loginPageUnavailable
    case sessionUnavailable
    case requestProtectionUnavailable
    case invalidResponse(String)
    case platform(String)
    case cameraUnavailable
    case publisher(String)

    var errorDescription: String? {
        switch self {
        case .loginPageUnavailable:
            return "douyin.error.loginpage".localized
        case .sessionUnavailable:
            return "douyin.error.session".localized
        case .requestProtectionUnavailable:
            return "douyin.error.protection".localized
        case .invalidResponse(let detail):
            return String(format: "douyin.error.response".localized, detail)
        case .platform(let detail), .publisher(let detail):
            return detail
        case .cameraUnavailable:
            return "douyin.error.camera".localized
        }
    }
}

enum DouyinHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

struct DouyinHTTPRequest: Sendable {
    let method: DouyinHTTPMethod
    let url: URL
    let headers: [String: String]
    let body: Data?
    let requiresPlatformProtection: Bool
}

struct DouyinHTTPResponse: Sendable {
    let statusCode: Int
    let finalURL: URL
    let headers: [String: String]
    let body: Data
}

@MainActor
protocol DouyinLoginSession: AnyObject {
    func prepareLogin()
    func clearSession() async
}

@MainActor
protocol DouyinRequestExecuting: AnyObject {
    func execute(_ request: DouyinHTTPRequest) async throws -> DouyinHTTPResponse
}

@MainActor
protocol DouyinAccountReading: AnyObject {
    func currentAccount() async throws -> DouyinAccount
}

@MainActor
protocol DouyinRoomPreparing: AnyObject {
    func prepareRoom(orientation: DouyinLiveOrientation) async throws -> DouyinRoomPreparation
}

@MainActor
protocol DouyinRoomLifecycle: AnyObject {
    func createRoom(title: String, orientation: DouyinLiveOrientation) async throws -> DouyinLiveRoom
    func heartbeat(room: DouyinLiveRoom, status: Int) async throws
    func signalFinish(room: DouyinLiveRoom) async throws
    func completeFinish(room: DouyinLiveRoom) async throws
    func verifyRoomIdle() async throws -> Bool
}

@MainActor
protocol DouyinRoomMetricsReading: AnyObject {
    func metrics(for room: DouyinLiveRoom) async throws -> DouyinLiveMetrics
}

@MainActor
protocol DouyinMessageReceiving: AnyObject {
    var onError: ((String) -> Void)? { get set }

    func start(
        room: DouyinLiveRoom,
        account: DouyinAccount,
        onEvent: @escaping (DouyinLiveEvent) -> Void
    )
    func stop()
}

enum DouyinVideoPublisherState: Equatable, Sendable {
    case idle
    case connecting
    /// 断线后自动重连等待中（第 attempt 次，delay 秒后重试）
    case reconnecting(attempt: Int, delay: TimeInterval)
    case streaming
    case failed(String)
}

@MainActor
protocol DouyinVideoPublishing: AnyObject, Sendable {
    var onStateChange: ((DouyinVideoPublisherState) -> Void)? { get set }
    var onStatsChange: ((DouyinPublishStats) -> Void)? { get set }

    func start(publishURL: URL, videoSize: CGSize, bitrate: Int) async throws
    nonisolated func append(_ sampleBuffer: CMSampleBuffer)
    func stop()
}

@MainActor
protocol DouyinVideoFrameSource: AnyObject {
    func start(onFrame: @escaping @Sendable (CMSampleBuffer) -> Void) async throws
    func stop() async
}
