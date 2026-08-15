/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// NonStreamView.swift
//
// Default screen to show getting started tips after app connection
// Initiates streaming
//

import MWDATCore
import SwiftUI

struct NonStreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var sheetHeight: CGFloat = 300
  @State private var wasDeviceAvailable = false
  @State private var isClosing = false

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      VStack {
        HStack {
          Spacer()
          Menu {
            Button("Disconnect", role: .destructive) {
              wearablesVM.disconnectGlasses()
            }
            .disabled(
              wearablesVM.registrationState != .registered ||
              wearablesVM.isRegistrationActionInFlight
            )
          } label: {
            Image(systemName: "gearshape")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .foregroundColor(.white)
              .frame(width: 24, height: 24)
          }
        }

        Spacer()

        VStack(spacing: 12) {
          Image(.hyperMetaAIIcon)
            .resizable()
            .renderingMode(.template)
            .foregroundColor(.white)
            .aspectRatio(contentMode: .fit)
            .frame(width: 120)

          Text("nonstream.title".localized)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)

          Text("nonstream.hint".localized)
            .font(.system(size: 15))
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
        }
        .padding(.horizontal, 12)

        Spacer()

        HStack(spacing: 8) {
          Image(systemName: "hourglass")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.white.opacity(0.7))
            .frame(width: 16, height: 16)

          Text("nonstream.waiting".localized)
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(.bottom, 12)
        .opacity(viewModel.cameraCaptureState.isUnavailable ? 1 : 0)

        Button {
          Task {
            await viewModel.handleStartStreaming()
          }
        } label: {
          Label("stream.start".localized, systemImage: "video.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .disabled(viewModel.cameraCaptureState.isBusy || viewModel.cameraCaptureState.isUnavailable)
      }
      .padding(.all, 24)
    }
    .onAppear {
      wasDeviceAvailable = viewModel.hasActiveDevice
      if !wasDeviceAvailable {
        isClosing = true
        dismiss()
      }
    }
    .onChange(of: viewModel.cameraCaptureState) { _, state in
      guard state.isUnavailable || state.isFailed else { return }
      guard wasDeviceAvailable || state.isFailed else { return }
      guard !isClosing else { return }
      isClosing = true
      Task { @MainActor in
        await viewModel.releaseStream(for: .manual)
        dismiss()
      }
    }
    .sheet(isPresented: $wearablesVM.showGettingStartedSheet) {
      if #available(iOS 16.0, *) {
        GettingStartedSheetView(height: $sheetHeight)
          .presentationDetents([.height(sheetHeight)])
          .presentationDragIndicator(.visible)
      } else {
        GettingStartedSheetView(height: $sheetHeight)
      }
    }
  }
}

struct GettingStartedSheetView: View {
  @Environment(\.dismiss) var dismiss
  @Binding var height: CGFloat

  var body: some View {
    VStack(spacing: 24) {
      Text("nonstream.gettingStarted".localized)
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.primary)

      VStack(spacing: 12) {
        TipItemView(
          resource: .videoIcon,
          text: "First, Hyper Meta AI needs permission to use your glasses camera."
        )
        TipItemView(
          resource: .tapIcon,
          text: "Capture photos by tapping the camera button."
        )
        TipItemView(
          resource: .smartGlassesIcon,
          text: "The capture LED lets others know when you're capturing content or going live."
        )
      }
      .padding(.bottom, 16)

      CustomButton(
        title: "Continue",
        style: .primary,
        isDisabled: false
      ) {
        dismiss()
      }
    }
    .padding(.all, 24)
    .background(
      GeometryReader { geo -> Color in
        DispatchQueue.main.async {
          height = geo.size.height
        }
        return Color.clear
      }
    )
  }
}

struct TipItemView: View {
  let resource: ImageResource
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(.primary)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, 4)
        .padding(.top, 4)

      Text(text)
        .font(.system(size: 15))
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#if DEBUG
@MainActor
private struct NonStreamPreview: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    NonStreamView(
      viewModel: dependencies.streamViewModel,
      wearablesVM: dependencies.wearablesViewModel
    )
  }
}

#Preview("Ready to Stream") {
  NonStreamPreview()
}
#endif
