/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HyperMetaAIApp.swift
//
// Main entry point for the Hyper Meta AI app using the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import CoreSpotlight
import MWDATCore
import SwiftUI
import UIKit
import UserNotifications

enum UnitTestRuntime {
  static var isActive: Bool {
    let processInfo = ProcessInfo.processInfo

    return processInfo.environment["XCTestConfigurationFilePath"] != nil
      || processInfo.arguments.contains(where: { $0.contains("XCTestConfigurationFilePath") })
      || NSClassFromString("XCTestCase") != nil
      || Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") })
  }
}

@MainActor
enum WearablesBootstrapState {
  case testing
  case ready(wearables: WearablesInterface, viewModel: WearablesViewModel)
  case failed(String)
}

private struct UnavailableWearablesListenerToken: AnyListenerToken {
  func cancel() async {}
}

/// Keeps the assistant usable when the optional glasses SDK cannot initialize.
private final class UnavailableWearables: WearablesInterface, @unchecked Sendable {
  let registrationState: RegistrationState = .unavailable
  let devices: [DeviceIdentifier] = []

  func addRegistrationStateListener(
    _ listener: @escaping @Sendable (RegistrationState) -> Void
  ) -> any AnyListenerToken {
    listener(registrationState)
    return UnavailableWearablesListenerToken()
  }

  func registrationStateStream() -> AsyncStream<RegistrationState> {
    AsyncStream { continuation in
      continuation.yield(registrationState)
      continuation.finish()
    }
  }

  func startRegistration() async throws(RegistrationError) {
    throw .configurationInvalid
  }

  func handleUrl(_ url: URL) async throws(WearablesHandleURLError) -> Bool {
    false
  }

  func startUnregistration() async throws(UnregistrationError) {
    throw .configurationInvalid
  }

  func openFirmwareUpdate() async throws(NavigationError) {
    throw .notRegistered
  }

  func openDATGlassesAppUpdate() async throws(NavigationError) {
    throw .notRegistered
  }

  func addDevicesListener(
    _ listener: @escaping @Sendable ([DeviceIdentifier]) -> Void
  ) -> any AnyListenerToken {
    listener([])
    return UnavailableWearablesListenerToken()
  }

  func devicesStream() -> AsyncStream<[DeviceIdentifier]> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }

  func deviceForIdentifier(_ identifier: DeviceIdentifier) -> Device? {
    nil
  }

  func checkPermissionStatus(_ permission: Permission) async throws(PermissionError) -> PermissionStatus {
    .denied
  }

  func requestPermission(_ permission: Permission) async throws(PermissionError) -> PermissionStatus {
    throw .noDevice
  }

  func createSession(deviceSelector: any DeviceSelector) throws(DeviceSessionError) -> DeviceSession {
    throw .noEligibleDevice
  }

  func deviceStateStream(for identifier: DeviceIdentifier) -> AsyncStream<DeviceState> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }
}

@MainActor
final class WearablesBootstrap: ObservableObject {
  @Published private(set) var state: WearablesBootstrapState

  private let isRunningUnitTests: Bool

  init(isRunningUnitTests: Bool = UnitTestRuntime.isActive) {
    self.isRunningUnitTests = isRunningUnitTests
    state = .testing

    guard !isRunningUnitTests else { return }
    configure()
  }

  func configure() {
    guard !isRunningUnitTests else { return }

    do {
      do {
        try Wearables.configure()
      } catch WearablesError.alreadyConfigured {
        // SwiftUI may recreate the App value while the process-level SDK remains configured.
      }

      let wearables = Wearables.shared
      state = .ready(
        wearables: wearables,
        viewModel: WearablesViewModel(wearables: wearables)
      )
      print("[Hyper Meta AI] Wearables SDK configured successfully")
    } catch {
      let message = "Wearables SDK configuration failed: \(error.localizedDescription)"
      let wearables = UnavailableWearables()
      state = .ready(
        wearables: wearables,
        viewModel: WearablesViewModel(wearables: wearables)
      )
      print("[Hyper Meta AI] \(message). Continuing without glasses.")
    }
  }
}

@main
struct HyperMetaAIApp: App {
  /// 主屏长按快捷操作（Quick Actions）桥接
  @UIApplicationDelegateAdaptor(HomeScreenShortcutAppDelegate.self) private var shortcutDelegate
  @StateObject private var bootstrap: WearablesBootstrap

  init() {
    _bootstrap = StateObject(wrappedValue: WearablesBootstrap())
    // 提醒通知前台到达时同步到镜片并播报（无权限请求，仅注册代理）
    UNUserNotificationCenter.current().delegate = AgentReminderNotificationDelegate.shared
    // 注册提醒通知的交互 Action（稍后提醒 / 完成）
    AgentReminderNotificationAction.register()
  }

  var body: some Scene {
    WindowGroup {
      switch bootstrap.state {
      case let .ready(wearables, viewModel):
        // Keep the app's UI and URL callback on the same SDK instance.
        MainAppView(wearables: wearables, viewModel: viewModel)
          .onContinueUserActivity(CSSearchableItemActionType) { activity in
            // Spotlight 搜索结果点按（冷 / 热启动均可能经 SwiftUI 场景分发）
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let destination = SpotlightIdentifierParser.destination(for: identifier)
            else { return }
            AppNavigationRouter.shared.request(destination.navigationDestination)
          }
          .alert(
            "Error",
            isPresented: Binding(
              get: { viewModel.showError },
              set: { isPresented in
                if !isPresented {
                  viewModel.dismissError()
                }
              }
            )
          ) {
            if viewModel.requiresFirmwareUpdate {
              Button("Update Glasses") {
                viewModel.openFirmwareUpdate()
              }
            }
            Button("OK") {
              viewModel.dismissError()
            }
          } message: {
            Text(viewModel.errorMessage)
          }
          .onOpenURL { url in
            // JARVIS URL 命令协议：trigger / ask / lens / briefing
            if let command = AgentURLCommandParser.parse(url: url) {
              Task { @MainActor in
                await AgentURLCommandRouter.dispatch(
                  command,
                  executor: SystemAgentURLCommandExecutor.shared
                )
              }
              return
            }
            guard let scheme = url.scheme?.lowercased(), ["hypermetaai", "turbometa"].contains(scheme) else {
              return
            }

            Task { @MainActor in
              do {
                _ = try await wearables.handleUrl(url)
              } catch let error as WearablesHandleURLError {
                viewModel.showError(error.description)
              } catch {
                viewModel.showError("Unknown error: \(error.localizedDescription)")
              }
            }
          }
      case .testing:
        Color.clear.accessibilityIdentifier("HyperMetaAIUnitTestHost")
      case let .failed(message):
        ContentUnavailableView(
          "Unable to Start Wearables",
          systemImage: "eyeglasses",
          description: Text(message)
        )
        .overlay(alignment: .bottom) {
          Button("Retry") {
            bootstrap.configure()
          }
          .padding()
        }
      }
    }
  }
}

@MainActor
final class PreviewDependencies: ObservableObject {
  let wearables: WearablesInterface
  let streamViewModel: StreamSessionViewModel
  let wearablesViewModel: WearablesViewModel

  init() {
    try? Wearables.configure()

    let configuredWearables = Wearables.shared
    wearables = configuredWearables
    streamViewModel = StreamSessionViewModel(wearables: configuredWearables)
    wearablesViewModel = WearablesViewModel(wearables: configuredWearables)
    streamViewModel.hasActiveDevice = true
    streamViewModel.streamingStatus = .streaming
    streamViewModel.currentVideoFrame = UIImage(systemName: "mountain.2.fill")
    streamViewModel.hasReceivedFirstFrame = true
    wearablesViewModel.registrationState = .registered
  }
}
