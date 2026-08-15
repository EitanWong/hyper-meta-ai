/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var wasDeviceAvailable = false
  @State private var isClosing = false

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // 未连接设备提醒
      if viewModel.cameraCaptureState.isUnavailable {
        deviceNotConnectedView
      } else {
        // Video backdrop
        if let videoFrame = viewModel.currentVideoFrame,
           viewModel.cameraCaptureState.isStreaming,
           viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Bottom controls layer

      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, onStop: closeAndRelease)
      }
      .padding(.all, 24)
      // Timer display area with fixed height
      VStack {
        Spacer()
        if viewModel.activeTimeLimit.isTimeLimited && viewModel.remainingTime > 0 {
          Text(String(format: "stream.endingIn".localized, viewModel.remainingTime.formattedCountdown))
            .font(.system(size: 15))
            .foregroundColor(.white)
        }
      }
      }
    }
    .onAppear {
      guard !AppIdentity.isRunningPreview else { return }

      wasDeviceAvailable = viewModel.hasActiveDevice
      guard wasDeviceAvailable else {
        closeAndRelease()
        return
      }

      // Register the preview even while device selection is still settling.
      // The shared session model starts it when the glasses become available.
      Task {
        print("🎥 StreamView: 启动视频流")
        _ = await viewModel.acquireStream(for: .cameraPreview)
      }
    }
    .onDisappear {
      guard !AppIdentity.isRunningPreview else { return }

      Task {
        await viewModel.releaseStream(for: .cameraPreview)
      }
    }
    .onChange(of: viewModel.cameraCaptureState) { _, state in
      guard !AppIdentity.isRunningPreview else { return }
      guard state.isUnavailable || state.isFailed else { return }
      guard wasDeviceAvailable || state.isFailed else { return }
      closeAndRelease()
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          },
          onAIRecognition: {
            viewModel.showPhotoPreview = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
              viewModel.showVisionRecognition = true
            }
          },
          onLeanEat: {
            viewModel.showPhotoPreview = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
              viewModel.showLeanEat = true
            }
          }
        )
      }
    }
    // Show AI Vision Recognition view
    .sheet(isPresented: $viewModel.showVisionRecognition) {
      if let photo = viewModel.capturedPhoto {
        VisionRecognitionView(
          photo: photo,
          apiKey: VisionAPIConfig.apiKey
        )
      }
    }
    // Show LeanEat nutrition analysis view
    .sheet(isPresented: $viewModel.showLeanEat) {
      if let photo = viewModel.capturedPhoto {
        LeanEatView(
          photo: photo,
          apiKey: VisionAPIConfig.apiKey
        )
      }
    }
    // Show Omni Realtime Chat view
    .fullScreenCover(isPresented: $viewModel.showOmniRealtime) {
      OmniRealtimeView(
        streamViewModel: viewModel,
        apiKey: VisionAPIConfig.apiKey
      )
    }
  }

  // MARK: - Device Not Connected View

  private var deviceNotConnectedView: some View {
    VStack(spacing: AppSpacing.xl) {
      Spacer()

      VStack(spacing: AppSpacing.lg) {
        Image(systemName: "eyeglasses")
          .font(.system(size: 80))
          .foregroundColor(.white.opacity(0.6))

        Text("stream.notConnected".localized)
          .font(AppTypography.title2)
          .foregroundColor(.white)

        Text("stream.notConnectedHint".localized)
          .font(AppTypography.body)
          .foregroundColor(.white.opacity(0.8))
          .multilineTextAlignment(.center)
          .padding(.horizontal, AppSpacing.xl)
      }

      Spacer()

      // 返回按钮
      Button {
        closeAndRelease()
      } label: {
        HStack(spacing: AppSpacing.sm) {
          Image(systemName: "chevron.left")
          Text("stream.backToHome".localized)
            .font(AppTypography.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.md)
        .background(.white)
        .foregroundColor(.black)
        .cornerRadius(AppCornerRadius.lg)
      }
      .padding(.horizontal, AppSpacing.xl)
      .padding(.bottom, AppSpacing.xl)
    }
  }

  private func closeAndRelease() {
    guard !isClosing else { return }
    isClosing = true
    Task { @MainActor in
      await viewModel.releaseStream(for: .cameraPreview)
      dismiss()
    }
  }
}

#if DEBUG
@MainActor
private struct StreamPreview: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    StreamView(
      viewModel: dependencies.streamViewModel,
      wearablesVM: dependencies.wearablesViewModel
    )
  }
}

#Preview("Live Camera") {
  StreamPreview()
}
#endif

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  let onStop: () -> Void

  init(viewModel: StreamSessionViewModel, onStop: @escaping () -> Void = {}) {
    self.viewModel = viewModel
    self.onStop = onStop
  }

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      Button(role: .destructive) {
        onStop()
      } label: {
        Label("stream.stop".localized, systemImage: "stop.fill")
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .disabled(viewModel.cameraCaptureState.isBusy)

      // Timer button
      CircleButton(
        icon: "timer",
        text: viewModel.activeTimeLimit != .noLimit ? viewModel.activeTimeLimit.displayText : nil
      ) {
        let nextTimeLimit = viewModel.activeTimeLimit.next
        viewModel.setTimeLimit(nextTimeLimit)
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }
      .disabled(!viewModel.cameraCaptureState.isStreaming)

      // AI Realtime Chat button
      CircleButton(icon: "brain.head.profile", text: nil) {
        viewModel.showOmniRealtime = true
      }
      .disabled(!viewModel.cameraCaptureState.isStreaming)
    }
  }
}
