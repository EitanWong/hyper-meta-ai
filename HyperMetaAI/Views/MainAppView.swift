/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var viewModel: WearablesViewModel
  @StateObject private var streamViewModel: StreamSessionViewModel
  @StateObject private var sessionCoordinator = AppSessionCoordinator()
  @State private var permissionsGranted = false
  @State private var hasCheckedPermissions = false

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
    self._streamViewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    Group {
      if viewModel.registrationState == .registered {
        // 已注册/连接设备
        if !hasCheckedPermissions {
          // 首次启动，请求权限
          PermissionsRequestView { granted in
            permissionsGranted = granted
            hasCheckedPermissions = true
          }
        } else {
          // 权限已检查，显示主界面
          MainTabView(streamViewModel: streamViewModel, wearablesViewModel: viewModel)
            .onAppear {
              sessionCoordinator.configure(streamViewModel: streamViewModel)
            }
            .onChange(of: scenePhase) { _, phase in
              Task { @MainActor in
                switch phase {
                case .background:
                  await streamViewModel.suspendForBackground()
                case .active:
                  streamViewModel.resumeAfterForeground()
                case .inactive:
                  break
                @unknown default:
                  break
                }
              }
            }
        }
      } else {
        // 未注册 - 显示注册/引导流程
        HomeScreenView(viewModel: viewModel)
      }
    }
    .alert(
      streamViewModel.requiresDATGlassesAppUpdate
        ? DATGlassesAppUpdateGuidance.alertTitle
        : "error".localized,
      isPresented: Binding(
        get: { streamViewModel.showError },
        set: { isPresented in
          if !isPresented {
            streamViewModel.dismissError()
          }
        }
      )
    ) {
      if streamViewModel.requiresDATGlassesAppUpdate {
        Button(DATGlassesAppUpdateGuidance.openUpdateActionTitle) {
          streamViewModel.openDATGlassesAppUpdate()
        }
      }
      Button("ok".localized) {
        streamViewModel.dismissError()
      }
    } message: {
      Text(streamViewModel.errorMessage)
    }
  }
}

#if DEBUG
@MainActor
private struct MainAppPreview: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    MainAppView(
      wearables: dependencies.wearables,
      viewModel: dependencies.wearablesViewModel
    )
  }
}

#Preview("App Entry") {
  MainAppPreview()
}
#endif
