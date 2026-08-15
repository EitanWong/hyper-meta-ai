import CoreMedia
import Foundation

@MainActor
final class MetaRaybanDouyinFrameSource: DouyinVideoFrameSource {
    private weak var streamViewModel: StreamSessionViewModel?
    private var sampleBufferRegistrationID: UUID?
    private var holdsStreamLease = false

    init(streamViewModel: StreamSessionViewModel) {
        self.streamViewModel = streamViewModel
    }

    func start(onFrame: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        guard let streamViewModel else {
            throw DouyinLiveError.cameraUnavailable
        }
        if sampleBufferRegistrationID != nil || holdsStreamLease {
            await stop()
        }

        sampleBufferRegistrationID = streamViewModel.attachRTMPSampleBufferConsumer(onFrame)
        holdsStreamLease = true
        let ready = await streamViewModel.acquireStream(for: .rtmp)
        guard ready else {
            let detail = streamViewModel.errorMessage
            streamViewModel.recordDATGlassesAppUpdateRequirement(message: detail)
            await stop()
            if !detail.isEmpty {
                throw DouyinLiveError.platform(detail)
            }
            throw DouyinLiveError.cameraUnavailable
        }
    }

    func stop() async {
        if let streamViewModel, let sampleBufferRegistrationID {
            streamViewModel.detachRTMPSampleBufferConsumer(sampleBufferRegistrationID)
        }
        sampleBufferRegistrationID = nil

        if holdsStreamLease, let streamViewModel {
            holdsStreamLease = false
            await streamViewModel.releaseStream(for: .rtmp)
        } else {
            holdsStreamLease = false
        }
    }
}

@MainActor
final class DouyinRTMPPublisher: DouyinVideoPublishing {
    var onStateChange: ((DouyinVideoPublisherState) -> Void)?
    var onStatsChange: ((DouyinPublishStats) -> Void)?

    private let service: RTMPStreamingService
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?

    init(service: RTMPStreamingService = RTMPStreamingService()) {
        self.service = service
        configureCallbacks()
    }

    deinit {
        startTimeoutTask?.cancel()
        service.stopStreaming()
    }

    func start(publishURL: URL, videoSize: CGSize, bitrate: Int) async throws {
        guard startContinuation == nil else {
            throw DouyinLiveError.publisher("douyin.error.publisherbusy".localized)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                service.startStreaming(
                    url: publishURL.absoluteString,
                    width: Int(videoSize.width),
                    height: Int(videoSize.height),
                    bitrate: bitrate
                )
                startTimeoutTask?.cancel()
                startTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                    guard let self, let continuation = self.startContinuation else { return }
                    self.startContinuation = nil
                    self.service.stopStreaming()
                    continuation.resume(
                        throwing: DouyinLiveError.publisher(
                            "douyin.error.publishertimeout".localized
                        )
                    )
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingStart()
            }
        }
    }

    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        service.feedSampleBuffer(sampleBuffer)
    }

    func stop() {
        cancelPendingStart()
    }

    private func cancelPendingStart() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        service.stopStreaming()
    }

    private func configureCallbacks() {
        service.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handle(state)
            }
        }
        service.onStatsUpdated = { [weak self] stats in
            Task { @MainActor in
                self?.onStatsChange?(
                    DouyinPublishStats(
                        framesSent: stats.framesSent,
                        framesDropped: stats.framesDropped,
                        framesPerSecond: stats.fps,
                        duration: stats.connectionTime
                    )
                )
            }
        }
        service.onError = { [weak self] message in
            Task { @MainActor in
                self?.finishStart(throwing: DouyinLiveError.publisher(message))
                self?.onStateChange?(.failed(message))
            }
        }
    }

    private func handle(_ state: RTMPStreamingState) {
        switch state {
        case .idle, .disconnected:
            onStateChange?(.idle)
        case .connecting:
            onStateChange?(.connecting)
        case .reconnecting(let attempt, let delay):
            onStateChange?(.reconnecting(attempt: attempt, delay: delay))
        case .streaming:
            finishStart()
            onStateChange?(.streaming)
        case .error(let message):
            finishStart(throwing: DouyinLiveError.publisher(message))
            onStateChange?(.failed(message))
        }
    }

    private func finishStart(throwing error: Error? = nil) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
