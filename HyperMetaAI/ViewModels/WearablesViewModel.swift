/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// WearablesViewModel.swift
//
// Primary view model for the Hyper Meta AI app that manages DAT SDK integration.
// Demonstrates how to listen to device availability changes using the DAT SDK's
// device stream functionality and handle permission requests.
//

import MWDATCore
import SwiftUI

@MainActor
class WearablesViewModel: ObservableObject {
  @Published var devices: [DeviceIdentifier]
  @Published var registrationState: RegistrationState
  @Published var showGettingStartedSheet: Bool = false
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published private(set) var requiresFirmwareUpdate = false
  @Published private(set) var isRegistrationActionInFlight = false

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState

    registrationTask = Task { @MainActor [weak self, wearables] in
      for await registrationState in wearables.registrationStateStream() {
        guard !Task.isCancelled, let self else { break }
        let previousState = self.registrationState
        self.registrationState = registrationState
        if registrationState != .registering {
          self.isRegistrationActionInFlight = false
        }
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
        if registrationState == .registered {
          await setupDeviceStream()
        }
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }

    let wearables = self.wearables
    deviceStreamTask = Task { @MainActor [weak self, wearables] in
      for await devices in wearables.devicesStream() {
        guard !Task.isCancelled, let self else { break }
        self.devices = devices
        // Monitor compatibility for each device
        monitorDeviceCompatibility(devices: devices)
      }
    }
  }

  private func monitorDeviceCompatibility(devices: [DeviceIdentifier]) {
    // Remove listeners for devices that are no longer present
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }

    // Add listeners for new devices
    for deviceId in devices {
      guard compatibilityListenerTokens[deviceId] == nil else { continue }
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }

      // Capture device name before the closure to avoid Sendable issues
      let deviceName = device.nameOrId()
      let token = device.addCompatibilityListener { [weak self] compatibility in
        guard let self else { return }
        switch compatibility {
        case .deviceUpdateRequired:
          Task { @MainActor in
            self.showError(
              "Device '\(deviceName)' requires an update to work with this app",
              requiresFirmwareUpdate: true
            )
          }
        case .sdkUpdateRequired:
          Task { @MainActor in
            self.showError("This app's Meta Wearables SDK needs an update for '\(deviceName)'.")
          }
        case .undefined, .compatible:
          break
        @unknown default:
          break
        }
      }
      compatibilityListenerTokens[deviceId] = token
    }
  }

  func connectGlasses() {
    guard registrationState == .available, !isRegistrationActionInFlight else { return }
    isRegistrationActionInFlight = true
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        isRegistrationActionInFlight = false
        let msg = "Registration failed: \(error) | \(error.localizedDescription)"
        print("❌ [WearablesVM] \(msg)")
        showError(msg)
      }
    }
  }

  func disconnectGlasses() {
    guard registrationState == .registered, !isRegistrationActionInFlight else { return }
    isRegistrationActionInFlight = true
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        isRegistrationActionInFlight = false
        showError(error.localizedDescription)
      }
    }
  }

  func showError(_ error: String, requiresFirmwareUpdate: Bool = false) {
    errorMessage = error
    self.requiresFirmwareUpdate = requiresFirmwareUpdate
    showError = true
  }

  func dismissError() {
    showError = false
    requiresFirmwareUpdate = false
  }

  func openFirmwareUpdate() {
    guard requiresFirmwareUpdate else { return }

    showError = false
    Task { @MainActor [weak self, wearables] in
      do {
        try await wearables.openFirmwareUpdate()
        self?.requiresFirmwareUpdate = false
      } catch {
        self?.requiresFirmwareUpdate = false
        self?.showError("Unable to open the glasses update: \(error.localizedDescription)")
      }
    }
  }
}
