/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import SwiftUI

struct StreamSessionView: View {
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @ObservedObject private var viewModel: StreamSessionViewModel

  init(viewModel: StreamSessionViewModel, wearablesVM: WearablesViewModel) {
    self.wearablesViewModel = wearablesVM
    self.viewModel = viewModel
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        // Pre-streaming setup view with permissions and start button
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
  }
}

#if DEBUG
@MainActor
private struct StreamSessionPreview: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    StreamSessionView(
      viewModel: dependencies.streamViewModel,
      wearablesVM: dependencies.wearablesViewModel
    )
  }
}

#Preview("Camera Controls") {
  StreamSessionPreview()
}
#endif
