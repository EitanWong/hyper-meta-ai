/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StatusText.swift
//
// Reusable UI component for displaying conditional status text throughout the Hyper Meta AI app.
//

import SwiftUI

struct StatusText: View {
  let isActive: Bool
  let activeText: String
  let inactiveText: String
  let activeColor: Color
  let inactiveColor: Color

  init(
    isActive: Bool,
    activeText: String,
    inactiveText: String,
    activeColor: Color = .green,
    inactiveColor: Color = .secondary
  ) {
    self.isActive = isActive
    self.activeText = activeText
    self.inactiveText = inactiveText
    self.activeColor = activeColor
    self.inactiveColor = inactiveColor
  }

  var body: some View {
    Text(isActive ? activeText : inactiveText)
      .foregroundColor(isActive ? activeColor : inactiveColor)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Shared camera state indicator used by all screens that consume the glasses
/// camera. Keeping this component tied to `CameraCaptureState` prevents each
/// feature from presenting a different interpretation of the same hardware.
struct CameraCaptureStatusView: View {
  let state: CameraCaptureState

  private var tint: Color {
    switch state {
    case .unavailable, .failed:
      return .orange
    case .idle:
      return .secondary
    case .starting, .stopping:
      return .yellow
    case .streaming:
      return .green
    case .paused:
      return .yellow
    }
  }

  var body: some View {
    Label {
      Text(state.localizedText)
    } icon: {
      if state.isBusy {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: state.symbolName)
      }
    }
    .font(.footnote.weight(.medium))
    .foregroundStyle(tint)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(state.localizedText)
  }
}

#Preview("Connected Status") {
  StatusText(
    isActive: true,
    activeText: "Glasses connected",
    inactiveText: "Glasses disconnected"
  )
  .padding()
}
