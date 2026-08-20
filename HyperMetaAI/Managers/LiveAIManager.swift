/*
 * Live AI Session Coordinator
 * Owns the single active Live AI session shared by UI and App Intents.
 */

import AVFoundation
import Combine
import Foundation
import os.log

private let liveAIManagerLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "LiveAITransport"
)

@MainActor
final class LiveAIManager: ObservableObject {
    static let shared = LiveAIManager()

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPresentationRequested = false

    private weak var streamViewModel: StreamSessionViewModel?
    private var activeViewModel: OmniRealtimeViewModel?
    private var activeStreamViewModel: StreamSessionViewModel?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var isStarting = false
    private var lifecycleGeneration = 0

    private let connectionTimeout: TimeInterval = 12
    private let audioRouteSettleNanoseconds: UInt64 = 750_000_000

    private init() {}

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        streamViewModel = viewModel
    }

    func requestPresentation() {
        isPresentationRequested = true
    }

    func consumePresentationRequest() {
        isPresentationRequested = false
    }

    /// Starts the one permitted realtime conversation. The caller supplies the
    /// UI-owned model so the visible session and the intent-controlled session
    /// are always the same object.
    @discardableResult
    func startSession(
        viewModel: OmniRealtimeViewModel,
        streamViewModel: StreamSessionViewModel? = nil
    ) async -> Bool {
        guard !isStarting else {
            errorMessage = "Live AI is already starting."
            return false
        }

        if isRunning {
            if activeViewModel === viewModel {
                return true
            }

            errorMessage = "A Live AI session is already active."
            return false
        }

        let stream = streamViewModel ?? self.streamViewModel
        guard let stream else {
            errorMessage = "Live AI is not initialized yet."
            return false
        }

        isStarting = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        self.streamViewModel = stream
        defer {
            if lifecycleGeneration == generation {
                isStarting = false
            }
        }

        guard await prepareFullDuplexAudioRoute(generation: generation) else {
            return false
        }

        guard await stream.acquireStream(for: .liveAI) else {
            await stream.releaseStream(for: .liveAI)
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            errorMessage = stream.errorMessage.isEmpty
                ? "Could not start the glasses camera stream."
                : stream.errorMessage
            return false
        }

        guard lifecycleGeneration == generation else {
            await stream.releaseStream(for: .liveAI)
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            return false
        }

        self.streamViewModel = stream
        activeViewModel = viewModel
        activeStreamViewModel = stream
        errorMessage = nil
        isRunning = true
        viewModel.connect()
        startConnectionTimeout(for: viewModel)
        return true
    }

    /// Stops the active session. This is intentionally idempotent because a
    /// close button and `onDisappear` can fire as part of the same dismissal.
    func stopSession() async {
        guard let activeViewModel else {
            guard isStarting else {
                isRunning = false
                return
            }

            lifecycleGeneration &+= 1
            isStarting = false
            await streamViewModel?.releaseStream(for: .liveAI)
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            isRunning = false
            return
        }

        await stopSession(for: activeViewModel)
    }

    func stopSession(for viewModel: OmniRealtimeViewModel) async {
        guard activeViewModel === viewModel else {
            guard isStarting else { return }
            lifecycleGeneration &+= 1
            isStarting = false
            await streamViewModel?.releaseStream(for: .liveAI)
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            return
        }

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil

        // Clear ownership before awaiting SDK shutdown so a second tap or an
        // onDisappear callback observes an already-stopped manager.
        let stream = activeStreamViewModel
        activeViewModel = nil
        activeStreamViewModel = nil
        isRunning = false
        isStarting = false
        lifecycleGeneration &+= 1
        viewModel.disconnect()
        await stream?.releaseStream(for: .liveAI)
        AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
        errorMessage = nil
    }

    private func startConnectionTimeout(for viewModel: OmniRealtimeViewModel) {
        connectionTimeoutTask?.cancel()
        let timeout = connectionTimeout
        connectionTimeoutTask = Task { @MainActor [weak self, weak viewModel] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self,
                  let viewModel,
                  !Task.isCancelled,
                  self.activeViewModel === viewModel,
                  !viewModel.isConnected else {
                return
            }

            let message = viewModel.errorMessage ?? "Live AI connection timed out."
            viewModel.disconnect()
            viewModel.errorMessage = message
            viewModel.showError = true
            let stream = self.activeStreamViewModel
            self.activeViewModel = nil
            self.activeStreamViewModel = nil
            self.isRunning = false
            self.isStarting = false
            self.lifecycleGeneration &+= 1
            await stream?.releaseStream(for: .liveAI)
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            self.errorMessage = message
            self.connectionTimeoutTask = nil
        }
    }

    private func prepareFullDuplexAudioRoute(generation: Int) async -> Bool {
        do {
            try await AudioSessionCoordinator.shared.activateAsync(.liveAI, profile: .voiceChat)

            let initialRoute = AVAudioSession.sharedInstance().currentRoute
            liveAIManagerLogger.info(
                "Preparing audio before DAT camera input=\(initialRoute.inputs.first?.portType.rawValue ?? "none", privacy: .public) output=\(initialRoute.outputs.first?.portType.rawValue ?? "none", privacy: .public)"
            )

            try await Task.sleep(nanoseconds: audioRouteSettleNanoseconds)
            guard !Task.isCancelled, lifecycleGeneration == generation else {
                AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
                return false
            }

            let stableRoute = AVAudioSession.sharedInstance().currentRoute
            liveAIManagerLogger.info(
                "Audio route stable before DAT camera input=\(stableRoute.inputs.first?.portType.rawValue ?? "none", privacy: .public) output=\(stableRoute.outputs.first?.portType.rawValue ?? "none", privacy: .public)"
            )
            return true
        } catch is CancellationError {
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            return false
        } catch {
            AudioSessionCoordinator.shared.deactivateAsync(.liveAI)
            errorMessage = "Could not prepare Live AI audio: \(error.localizedDescription)"
            liveAIManagerLogger.error(
                "Audio route preparation failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
