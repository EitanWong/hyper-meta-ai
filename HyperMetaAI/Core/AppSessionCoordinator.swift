/*
 * App Session Coordinator
 * Owns one-time bindings between the active camera session and shared services.
 */

import Combine
import Foundation

/// Controls whether the persisted OpenClaw node setting should create a
/// connection during app startup. A phone-only Qwen session must not inherit a
/// stale node connection preference from a glasses session.
enum AgentBackgroundConnectionPolicy {
  static func shouldAutoConnectOpenClaw(
    isEnabled: Bool,
    connectionState: OpenClawConnectionState,
    hasActiveDevice: Bool,
    selectedBrain: AgentBrain
  ) -> Bool {
    guard isEnabled, connectionState == .disconnected else { return false }
    return hasActiveDevice || selectedBrain == .openclaw
  }
}

@MainActor
final class AppSessionCoordinator: ObservableObject {
  private let quickVisionManager: QuickVisionManager
  private let liveAIManager: LiveAIManager
  private let openClawService: OpenClawNodeService
  private var configuredStreamViewModelID: ObjectIdentifier?

  convenience init() {
    self.init(
      quickVisionManager: .shared,
      liveAIManager: .shared,
      openClawService: .shared
    )
  }

  init(
    quickVisionManager: QuickVisionManager,
    liveAIManager: LiveAIManager,
    openClawService: OpenClawNodeService
  ) {
    self.quickVisionManager = quickVisionManager
    self.liveAIManager = liveAIManager
    self.openClawService = openClawService
  }

  func configure(streamViewModel: StreamSessionViewModel) {
    let streamViewModelID = ObjectIdentifier(streamViewModel)

    guard configuredStreamViewModelID != streamViewModelID else {
      reconnectOpenClawIfNeeded(for: streamViewModel)
      return
    }

    quickVisionManager.setStreamViewModel(streamViewModel)
    liveAIManager.setStreamViewModel(streamViewModel)
    openClawService.setCommandRouter(
      OpenClawCommandRouter(
        streamViewModel: streamViewModel,
        nodeId: openClawService.nodeIdentifier
      )
    )
    streamViewModel.onDeviceAvailable = { [weak self, weak streamViewModel] in
      Task { @MainActor [weak self, weak streamViewModel] in
        guard let self, let streamViewModel else { return }
        self.reconnectOpenClawIfNeeded(for: streamViewModel)
        await AgentConnectGreetingAnnouncer.shared.handleDeviceConnected()
      }
    }
    configuredStreamViewModelID = streamViewModelID
    reconnectOpenClawIfNeeded(for: streamViewModel)
  }

  private func reconnectOpenClawIfNeeded(for streamViewModel: StreamSessionViewModel) {
    guard AgentBackgroundConnectionPolicy.shouldAutoConnectOpenClaw(
      isEnabled: openClawService.isEnabled,
      connectionState: openClawService.connectionState,
      hasActiveDevice: streamViewModel.hasActiveDevice,
      selectedBrain: AgentBrainSettings.selected
    ) else {
      return
    }

    openClawService.connect()
  }
}
