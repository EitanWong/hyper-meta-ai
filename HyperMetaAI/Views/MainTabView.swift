/*
 * Main Tab View
 * 主 Tab 导航视图
 */

import SwiftUI

struct MainTabView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel

    @ObservedObject private var voiceAssistantRouter = VoiceAssistantRouter.shared
    @ObservedObject private var navigationRouter = AppNavigationRouter.shared
    @State private var voiceAssistantRequest: VoiceAssistantRequest?
    @State private var requestGeneration = UUID()
    @State private var showAgentHub = false

    var body: some View {
        QwenVoiceView(
            streamViewModel: streamViewModel,
            wearablesViewModel: wearablesViewModel,
            initialBrain: voiceAssistantRequest?.brain,
            initialInstruction: voiceAssistantRequest?.instruction,
            initialFollowUpContext: voiceAssistantRequest?.followUpContext,
            isPrimaryExperience: true,
            startImmediately: voiceAssistantRequest != nil
        )
        .id(requestGeneration)
        .onAppear {
            consumeVoiceRequest()
            consumeNavigationRequest()
        }
        .onChange(of: voiceAssistantRouter.isVoiceSessionRequested) { _, _ in
            consumeVoiceRequest()
        }
        .onChange(of: navigationRouter.pendingDestination) { _, _ in
            consumeNavigationRequest()
        }
        .fullScreenCover(isPresented: $showAgentHub) {
            AgentHubView(streamViewModel: streamViewModel)
        }
    }

    private func consumeVoiceRequest() {
        guard let request = voiceAssistantRouter.consumeVoiceSessionRequest() else { return }
        voiceAssistantRequest = request
        requestGeneration = UUID()
    }

    private func consumeNavigationRequest() {
        guard let destination = navigationRouter.pendingDestination else { return }
        switch destination {
        case .agentHub, .conversation:
            showAgentHub = true
            navigationRouter.consume()
        case .agentSettings, .gallery:
            break
        }
  }
}

#if DEBUG
@MainActor
private struct MainTabPreview: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    MainTabView(
      streamViewModel: dependencies.streamViewModel,
      wearablesViewModel: dependencies.wearablesViewModel
    )
  }
}

#Preview("Main Navigation") {
  MainTabPreview()
}
#endif
