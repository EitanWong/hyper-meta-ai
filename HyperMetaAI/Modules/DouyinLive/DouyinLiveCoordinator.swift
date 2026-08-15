import Foundation
import os.log

private let douyinCoordinatorLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "DouyinLiveCoordinator"
)

@MainActor
final class DouyinLiveCoordinator: ObservableObject {
    @Published private(set) var phase: DouyinLivePhase = .signedOut
    @Published private(set) var account: DouyinAccount?
    @Published private(set) var metrics = DouyinLiveMetrics()
    @Published private(set) var publishStats = DouyinPublishStats()
    @Published private(set) var publisherState: DouyinVideoPublisherState = .idle
    @Published private(set) var events: [DouyinLiveEvent] = []
    @Published private(set) var runtimeWarning: String?
    @Published var errorMessage: String?
    @Published var title = "douyin.default.title".localized

    var hasActiveRoom: Bool { activeRoom != nil }

    private let configuration: DouyinLiveConfiguration
    private let loginSession: any DouyinLoginSession
    private let accountReader: any DouyinAccountReading
    private let roomPreparer: any DouyinRoomPreparing
    private let roomLifecycle: any DouyinRoomLifecycle
    private let metricsReader: any DouyinRoomMetricsReading
    private let messages: any DouyinMessageReceiving
    private let publisher: any DouyinVideoPublishing
    private let frameSource: any DouyinVideoFrameSource

    private var activeRoom: DouyinLiveRoom?
    private var startOperation: (id: UUID, task: Task<Void, Never>)?
    private var heartbeatTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(
        configuration: DouyinLiveConfiguration,
        loginSession: any DouyinLoginSession,
        accountReader: any DouyinAccountReading,
        roomPreparer: any DouyinRoomPreparing,
        roomLifecycle: any DouyinRoomLifecycle,
        metricsReader: any DouyinRoomMetricsReading,
        messages: any DouyinMessageReceiving,
        publisher: any DouyinVideoPublishing,
        frameSource: any DouyinVideoFrameSource
    ) {
        self.configuration = configuration
        self.loginSession = loginSession
        self.accountReader = accountReader
        self.roomPreparer = roomPreparer
        self.roomLifecycle = roomLifecycle
        self.metricsReader = metricsReader
        self.messages = messages
        self.publisher = publisher
        self.frameSource = frameSource
        configureCallbacks()
    }

    func prepareLogin() {
        loginSession.prepareLogin()
    }

    @discardableResult
    func restoreSession(reportFailure: Bool) async -> Bool {
        douyinCoordinatorLogger.info("Restoring Douyin account session")
        phase = .checkingSession
        errorMessage = nil
        do {
            let account = try await accountReader.currentAccount()
            self.account = account
            phase = .ready(account)
            douyinCoordinatorLogger.info("Douyin account session ready")
            return true
        } catch {
            account = nil
            phase = .signedOut
            if reportFailure {
                errorMessage = error.localizedDescription
            }
            douyinCoordinatorLogger.error(
                "Douyin account session restore failed error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func logout() async {
        await shutdown()
        guard activeRoom == nil else { return }

        await loginSession.clearSession()
        account = nil
        metrics = DouyinLiveMetrics()
        publishStats = DouyinPublishStats()
        publisherState = .idle
        events.removeAll()
        runtimeWarning = nil
        errorMessage = nil
        phase = .signedOut
    }

    func startLive() async {
        guard startOperation == nil, !phase.isBusy, !phase.isLive else { return }
        guard activeRoom == nil else {
            phase = .failed("douyin.error.roomactive".localized)
            errorMessage = "douyin.error.roomactive".localized
            return
        }
        guard account != nil else {
            phase = .signedOut
            errorMessage = DouyinLiveError.sessionUnavailable.localizedDescription
            return
        }

        phase = .starting
        douyinCoordinatorLogger.info("Douyin live start requested")
        errorMessage = nil
        runtimeWarning = nil
        metrics = DouyinLiveMetrics()
        publishStats = DouyinPublishStats()
        events.removeAll(keepingCapacity: true)

        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartLive()
        }
        startOperation = (operationID, operation)
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        if startOperation?.id == operationID {
            startOperation = nil
        }
    }

    private func performStartLive() async {
        var createdRoom: DouyinLiveRoom?

        do {
            try Task.checkCancellation()
            let preparation = try await roomPreparer.prepareRoom(orientation: .portrait)
            try Task.checkCancellation()
            account = preparation.account

            let publisher = self.publisher
            try await frameSource.start { sampleBuffer in
                publisher.append(sampleBuffer)
            }
            try Task.checkCancellation()

            let room = try await roomLifecycle.createRoom(
                title: title,
                orientation: preparation.orientation
            )
            createdRoom = room
            activeRoom = room
            try Task.checkCancellation()

            try await publisher.start(
                publishURL: room.publishURL,
                videoSize: configuration.videoSize,
                bitrate: configuration.videoBitrate
            )
            try Task.checkCancellation()

            try await roomLifecycle.heartbeat(room: room, status: 2)
            try Task.checkCancellation()
            phase = .live(room)
            douyinCoordinatorLogger.info("Douyin live room entered streaming state")
            startRuntimeTasks(room: room, account: preparation.account)
        } catch is CancellationError {
            let cleanup = Task { @MainActor [weak self] in
                await self?.cleanupAfterFailedStart(room: createdRoom)
            }
            await cleanup.value
            if let activeRoom {
                phase = .live(activeRoom)
            } else if let account {
                phase = .ready(account)
            } else {
                phase = .signedOut
            }
            douyinCoordinatorLogger.info("Douyin live start cancelled and cleaned up")
        } catch {
            await cleanupAfterFailedStart(room: createdRoom)
            phase = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            douyinCoordinatorLogger.error(
                "Douyin live start failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func stopLive() async {
        guard !isShuttingDown else { return }

        if let operation = startOperation {
            operation.task.cancel()
            await operation.task.value
            if startOperation?.id == operation.id {
                startOperation = nil
            }
        }

        guard let room = activeRoom else {
            stopRuntimeTasks()
            messages.stop()
            publisher.stop()
            await frameSource.stop()
            if let account { phase = .ready(account) } else { phase = .signedOut }
            return
        }

        isShuttingDown = true
        defer { isShuttingDown = false }
        phase = .stopping
        douyinCoordinatorLogger.info("Douyin live stop requested")
        stopRuntimeTasks()
        messages.stop()

        let signalError = await retryRemoteOperation {
            try await roomLifecycle.signalFinish(room: room)
        }

        publisher.stop()
        await frameSource.stop()

        let completionError = await retryRemoteOperation {
            try await roomLifecycle.completeFinish(room: room)
        }
        let idleResult = await waitUntilRoomIdle()

        if idleResult.isIdle {
            activeRoom = nil
            if let account {
                phase = .ready(account)
                douyinCoordinatorLogger.info("Douyin live stopped and room returned idle")
            } else {
                phase = .signedOut
            }
        } else {
            let stopError = idleResult.error
                ?? completionError
                ?? signalError
                ?? DouyinLiveError.invalidResponse("room did not return to idle")
            phase = .failed(stopError.localizedDescription)
            errorMessage = stopError.localizedDescription
            douyinCoordinatorLogger.error(
                "Douyin live stop failed error=\(stopError.localizedDescription, privacy: .public)"
            )
        }
    }

    func shutdown() async {
        if activeRoom != nil || startOperation != nil || phase == .starting {
            await stopLive()
        } else {
            stopRuntimeTasks()
            messages.stop()
            publisher.stop()
            await frameSource.stop()
        }
    }

    func dismissError() {
        errorMessage = nil
        if case .failed = phase {
            if let activeRoom {
                phase = .live(activeRoom)
            } else if let account {
                phase = .ready(account)
            } else {
                phase = .signedOut
            }
        }
    }

    private func configureCallbacks() {
        publisher.onStateChange = { [weak self] state in
            guard let self else { return }
            self.publisherState = state
            if case .failed(let message) = state, self.phase.isLive {
                self.errorMessage = message
                Task { await self.stopLive() }
            }
        }
        publisher.onStatsChange = { [weak self] stats in
            self?.publishStats = stats
        }
        messages.onError = { [weak self] message in
            self?.runtimeWarning = message
        }
    }

    private func startRuntimeTasks(room: DouyinLiveRoom, account: DouyinAccount) {
        messages.start(room: room, account: account) { [weak self] event in
            self?.receive(event)
        }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(configuration.heartbeatInterval))
                    try Task.checkCancellation()
                    try await roomLifecycle.heartbeat(room: room, status: 2)
                } catch is CancellationError {
                    return
                } catch {
                    runtimeWarning = error.localizedDescription
                }
            }
        }

        metricsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let snapshot = try await metricsReader.metrics(for: room)
                    metrics.merge(snapshot)
                } catch is CancellationError {
                    return
                } catch {
                    runtimeWarning = error.localizedDescription
                }
                do {
                    try await Task.sleep(for: .seconds(configuration.metricsInterval))
                } catch {
                    return
                }
            }
        }
    }

    private func stopRuntimeTasks() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        metricsTask?.cancel()
        metricsTask = nil
    }

    private func receive(_ event: DouyinLiveEvent) {
        metrics.record(event)
        events.insert(event, at: 0)
        if events.count > 300 {
            events.removeLast(events.count - 300)
        }
    }

    private func cleanupAfterFailedStart(room: DouyinLiveRoom?) async {
        stopRuntimeTasks()
        messages.stop()
        if let room {
            _ = await retryRemoteOperation {
                try await roomLifecycle.signalFinish(room: room)
            }
        }
        publisher.stop()
        await frameSource.stop()
        if let room {
            _ = await retryRemoteOperation {
                try await roomLifecycle.completeFinish(room: room)
            }
            let idleResult = await waitUntilRoomIdle()
            activeRoom = idleResult.isIdle ? nil : room
        } else {
            activeRoom = nil
        }
    }

    private func retryRemoteOperation(
        attempts: Int = 3,
        operation: () async throws -> Void
    ) async -> Error? {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try await operation()
                return nil
            } catch {
                lastError = error
            }

            guard attempt + 1 < attempts else { break }
            do {
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            } catch {
                break
            }
        }
        return lastError
    }

    private func waitUntilRoomIdle(attempts: Int = 5) async -> (isIdle: Bool, error: Error?) {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                if try await roomLifecycle.verifyRoomIdle() {
                    return (true, nil)
                }
            } catch {
                lastError = error
            }

            guard attempt + 1 < attempts else { break }
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                break
            }
        }
        return (false, lastError)
    }
}
