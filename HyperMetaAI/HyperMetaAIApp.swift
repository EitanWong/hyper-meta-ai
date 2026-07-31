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
import MWDATCore
import SwiftUI
import UIKit

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
      state = .failed(message)
      print("[Hyper Meta AI] \(message)")
    }
  }
}

@main
struct HyperMetaAIApp: App {
  @StateObject private var bootstrap: WearablesBootstrap

  init() {
    _bootstrap = StateObject(wrappedValue: WearablesBootstrap())
  }

  var body: some Scene {
    WindowGroup {
      switch bootstrap.state {
      case let .ready(wearables, viewModel):
        // Keep the app's UI and URL callback on the same SDK instance.
        MainAppView(wearables: wearables, viewModel: viewModel)
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

#if DEBUG
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
#endif
