import CoreMedia
import Foundation
import XCTest

@testable import HyperMetaAI

@MainActor
final class DouyinLiveCoordinatorTests: XCTestCase {
    func testStartsAndStopsUsingTheVerifiedRoomLifecycleOrder() async throws {
        let calls = CallRecorder()
        let account = DouyinAccount(id: "ACCOUNT", nickname: "主播")
        let room = DouyinLiveRoom(
            id: "ROOM",
            streamID: "STREAM",
            publishURL: URL(string: "rtmp://push.example/live/DYNAMIC_KEY")!,
            accountID: account.id
        )
        let api = FakeDouyinAPI(account: account, room: room, calls: calls)
        let login = FakeLoginSession(calls: calls)
        let messages = FakeMessages(calls: calls)
        let publisher = FakePublisher(calls: calls)
        let frameSource = FakeFrameSource(calls: calls)
        let configuration = DouyinLiveConfiguration(
            heartbeatInterval: 60,
            metricsInterval: 60,
            messagePollInterval: 60
        )
        let coordinator = DouyinLiveCoordinator(
            configuration: configuration,
            loginSession: login,
            accountReader: api,
            roomPreparer: api,
            roomLifecycle: api,
            metricsReader: api,
            messages: messages,
            publisher: publisher,
            frameSource: frameSource
        )

        let restoredSession = await coordinator.restoreSession(reportFailure: true)
        XCTAssertTrue(restoredSession)
        await coordinator.startLive()

        guard case .live(let activeRoom) = coordinator.phase else {
            return XCTFail("Coordinator should enter the live phase")
        }
        XCTAssertEqual(activeRoom, room)
        XCTAssertEqual(publisher.startedURL, room.publishURL)
        XCTAssertEqual(publisher.startedBitrate, configuration.videoBitrate)

        await coordinator.stopLive()

        guard case .ready(let restoredAccount) = coordinator.phase else {
            return XCTFail("Coordinator should return to ready after an idle-room check")
        }
        XCTAssertEqual(restoredAccount, account)
        XCTAssertOrdered(
            calls.values,
            [
                "prepare",
                "frame.start",
                "room.create",
                "publisher.start",
                "heartbeat.2",
                "messages.start",
                "messages.stop",
                "finish.signal",
                "publisher.stop",
                "frame.stop",
                "finish.complete",
                "room.idle",
            ]
        )
    }

    func testShutdownCancelsAnInFlightStartBeforeRoomCreation() async {
        let calls = CallRecorder()
        let account = DouyinAccount(id: "ACCOUNT", nickname: "主播")
        let room = DouyinLiveRoom(
            id: "ROOM",
            streamID: "STREAM",
            publishURL: URL(string: "rtmp://push.example/live/DYNAMIC_KEY")!,
            accountID: account.id
        )
        let api = FakeDouyinAPI(
            account: account,
            room: room,
            calls: calls,
            prepareDelay: .seconds(30)
        )
        let coordinator = DouyinLiveCoordinator(
            configuration: DouyinLiveConfiguration(
                heartbeatInterval: 60,
                metricsInterval: 60,
                messagePollInterval: 60
            ),
            loginSession: FakeLoginSession(calls: calls),
            accountReader: api,
            roomPreparer: api,
            roomLifecycle: api,
            metricsReader: api,
            messages: FakeMessages(calls: calls),
            publisher: FakePublisher(calls: calls),
            frameSource: FakeFrameSource(calls: calls)
        )

        let restoredSession = await coordinator.restoreSession(reportFailure: true)
        XCTAssertTrue(restoredSession)
        let startTask = Task { await coordinator.startLive() }
        for _ in 0..<100 where !calls.values.contains("prepare") {
            await Task.yield()
        }
        XCTAssertTrue(calls.values.contains("prepare"))

        await coordinator.shutdown()
        await startTask.value

        XCTAssertFalse(calls.values.contains("room.create"))
        guard case .ready(let restoredAccount) = coordinator.phase else {
            return XCTFail("Cancelled startup should return to the ready phase")
        }
        XCTAssertEqual(restoredAccount, account)
    }

    func testStopRetriesTransientRemoteFailuresUntilTheRoomIsIdle() async {
        let calls = CallRecorder()
        let account = DouyinAccount(id: "ACCOUNT", nickname: "主播")
        let room = DouyinLiveRoom(
            id: "ROOM",
            streamID: "STREAM",
            publishURL: URL(string: "rtmp://push.example/live/DYNAMIC_KEY")!,
            accountID: account.id
        )
        let api = FakeDouyinAPI(
            account: account,
            room: room,
            calls: calls,
            signalFinishFailures: 1,
            idleResults: [false, true]
        )
        let coordinator = DouyinLiveCoordinator(
            configuration: DouyinLiveConfiguration(
                heartbeatInterval: 60,
                metricsInterval: 60,
                messagePollInterval: 60
            ),
            loginSession: FakeLoginSession(calls: calls),
            accountReader: api,
            roomPreparer: api,
            roomLifecycle: api,
            metricsReader: api,
            messages: FakeMessages(calls: calls),
            publisher: FakePublisher(calls: calls),
            frameSource: FakeFrameSource(calls: calls)
        )

        let restoredSession = await coordinator.restoreSession(reportFailure: true)
        XCTAssertTrue(restoredSession)
        await coordinator.startLive()
        await coordinator.stopLive()

        XCTAssertEqual(calls.values.filter { $0 == "finish.signal" }.count, 2)
        XCTAssertEqual(calls.values.filter { $0 == "room.idle" }.count, 2)
        XCTAssertFalse(coordinator.hasActiveRoom)
        guard case .ready = coordinator.phase else {
            return XCTFail("A verified idle room should complete stop successfully")
        }
    }

    func testLogoutClearsSessionAndAccountAfterShutdown() async {
        let calls = CallRecorder()
        let account = DouyinAccount(id: "ACCOUNT", nickname: "主播")
        let room = DouyinLiveRoom(
            id: "ROOM",
            streamID: "STREAM",
            publishURL: URL(string: "rtmp://push.example/live/DYNAMIC_KEY")!,
            accountID: account.id
        )
        let api = FakeDouyinAPI(account: account, room: room, calls: calls)
        let coordinator = DouyinLiveCoordinator(
            configuration: DouyinLiveConfiguration(),
            loginSession: FakeLoginSession(calls: calls),
            accountReader: api,
            roomPreparer: api,
            roomLifecycle: api,
            metricsReader: api,
            messages: FakeMessages(calls: calls),
            publisher: FakePublisher(calls: calls),
            frameSource: FakeFrameSource(calls: calls)
        )

        let restoredSession = await coordinator.restoreSession(reportFailure: true)
        XCTAssertTrue(restoredSession)
        await coordinator.logout()

        XCTAssertNil(coordinator.account)
        XCTAssertEqual(coordinator.phase, .signedOut)
        XCTAssertEqual(calls.values.filter { $0 == "login.clear" }.count, 1)
    }

    func testLogoutPreservesSessionWhenRemoteRoomIsStillActive() async {
        let calls = CallRecorder()
        let account = DouyinAccount(id: "ACCOUNT", nickname: "主播")
        let room = DouyinLiveRoom(
            id: "ROOM",
            streamID: "STREAM",
            publishURL: URL(string: "rtmp://push.example/live/DYNAMIC_KEY")!,
            accountID: account.id
        )
        let api = FakeDouyinAPI(
            account: account,
            room: room,
            calls: calls,
            idleResults: Array(repeating: false, count: 5)
        )
        let coordinator = DouyinLiveCoordinator(
            configuration: DouyinLiveConfiguration(
                heartbeatInterval: 60,
                metricsInterval: 60,
                messagePollInterval: 60
            ),
            loginSession: FakeLoginSession(calls: calls),
            accountReader: api,
            roomPreparer: api,
            roomLifecycle: api,
            metricsReader: api,
            messages: FakeMessages(calls: calls),
            publisher: FakePublisher(calls: calls),
            frameSource: FakeFrameSource(calls: calls)
        )

        let restoredSession = await coordinator.restoreSession(reportFailure: true)
        XCTAssertTrue(restoredSession)
        await coordinator.startLive()
        await coordinator.logout()

        XCTAssertEqual(coordinator.account, account)
        XCTAssertTrue(coordinator.hasActiveRoom)
        XCTAssertFalse(calls.values.contains("login.clear"))
        guard case .failed = coordinator.phase else {
            return XCTFail("Logout should surface the failed room shutdown")
        }
    }

    private func XCTAssertOrdered(
        _ actual: [String],
        _ expectedSubsequence: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = actual.startIndex
        for expected in expectedSubsequence {
            guard let index = actual[cursor...].firstIndex(of: expected) else {
                return XCTFail(
                    "Missing ordered call \(expected). Actual calls: \(actual)",
                    file: file,
                    line: line
                )
            }
            cursor = actual.index(after: index)
        }
    }
}

@MainActor
private final class CallRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class FakeLoginSession: DouyinLoginSession {
    private let calls: CallRecorder

    init(calls: CallRecorder) {
        self.calls = calls
    }

    func prepareLogin() {
        calls.append("login.prepare")
    }

    func clearSession() async {
        calls.append("login.clear")
    }
}

@MainActor
private final class FakeDouyinAPI:
    DouyinAccountReading,
    DouyinRoomPreparing,
    DouyinRoomLifecycle,
    DouyinRoomMetricsReading
{
    private let account: DouyinAccount
    private let room: DouyinLiveRoom
    private let calls: CallRecorder
    private let prepareDelay: Duration?
    private var signalFinishFailures: Int
    private var idleResults: [Bool]

    init(
        account: DouyinAccount,
        room: DouyinLiveRoom,
        calls: CallRecorder,
        prepareDelay: Duration? = nil,
        signalFinishFailures: Int = 0,
        idleResults: [Bool] = [true]
    ) {
        self.account = account
        self.room = room
        self.calls = calls
        self.prepareDelay = prepareDelay
        self.signalFinishFailures = signalFinishFailures
        self.idleResults = idleResults
    }

    func currentAccount() async throws -> DouyinAccount {
        calls.append("account")
        return account
    }

    func prepareRoom(orientation: DouyinLiveOrientation) async throws -> DouyinRoomPreparation {
        calls.append("prepare")
        if let prepareDelay {
            try await Task.sleep(for: prepareDelay)
        }
        return DouyinRoomPreparation(account: account, orientation: orientation)
    }

    func createRoom(
        title: String,
        orientation: DouyinLiveOrientation
    ) async throws -> DouyinLiveRoom {
        calls.append("room.create")
        return room
    }

    func heartbeat(room: DouyinLiveRoom, status: Int) async throws {
        calls.append("heartbeat.\(status)")
    }

    func signalFinish(room: DouyinLiveRoom) async throws {
        calls.append("finish.signal")
        if signalFinishFailures > 0 {
            signalFinishFailures -= 1
            throw DouyinLiveError.platform("transient finish failure")
        }
    }

    func completeFinish(room: DouyinLiveRoom) async throws {
        calls.append("finish.complete")
    }

    func verifyRoomIdle() async throws -> Bool {
        calls.append("room.idle")
        return idleResults.isEmpty ? true : idleResults.removeFirst()
    }

    func metrics(for room: DouyinLiveRoom) async throws -> DouyinLiveMetrics {
        calls.append("metrics")
        return DouyinLiveMetrics(viewerCount: 12)
    }
}

@MainActor
private final class FakeMessages: DouyinMessageReceiving {
    var onError: ((String) -> Void)?
    private let calls: CallRecorder

    init(calls: CallRecorder) {
        self.calls = calls
    }

    func start(
        room: DouyinLiveRoom,
        account: DouyinAccount,
        onEvent: @escaping (DouyinLiveEvent) -> Void
    ) {
        calls.append("messages.start")
    }

    func stop() {
        calls.append("messages.stop")
    }
}

@MainActor
private final class FakePublisher: DouyinVideoPublishing {
    var onStateChange: ((DouyinVideoPublisherState) -> Void)?
    var onStatsChange: ((DouyinPublishStats) -> Void)?
    private let calls: CallRecorder
    private(set) var startedURL: URL?
    private(set) var startedBitrate: Int?

    init(calls: CallRecorder) {
        self.calls = calls
    }

    func start(publishURL: URL, videoSize: CGSize, bitrate: Int) async throws {
        calls.append("publisher.start")
        startedURL = publishURL
        startedBitrate = bitrate
        onStateChange?(.streaming)
    }

    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {}

    func stop() {
        calls.append("publisher.stop")
        onStateChange?(.idle)
    }
}

@MainActor
private final class FakeFrameSource: DouyinVideoFrameSource {
    private let calls: CallRecorder

    init(calls: CallRecorder) {
        self.calls = calls
    }

    func start(onFrame: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        calls.append("frame.start")
    }

    func stop() async {
        calls.append("frame.stop")
    }
}
