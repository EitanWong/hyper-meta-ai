/*
 * App Session Coordinator
 * Owns one-time bindings between the active camera session and shared services.
 */

import Combine
import Foundation

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
      reconnectOpenClawIfNeeded()
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
    streamViewModel.onDeviceAvailable = { [weak self] in
      Task { @MainActor in
        await AgentConnectGreetingAnnouncer.shared.handleDeviceConnected()
      }
    }
    configuredStreamViewModelID = streamViewModelID
    reconnectOpenClawIfNeeded()
  }

  private func reconnectOpenClawIfNeeded() {
    guard openClawService.isEnabled,
          openClawService.connectionState == .disconnected else {
      return
    }

    openClawService.connect()
  }
}
