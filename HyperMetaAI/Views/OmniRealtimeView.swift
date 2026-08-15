/*
 * Omni Realtime View
 * Real-time multimodal conversation interface
 */

import SwiftUI

struct OmniRealtimeView: View {
    @StateObject private var viewModel: OmniRealtimeViewModel
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var liveAIManager = LiveAIManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var wasDeviceAvailable = false
    @State private var isClosing = false

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        self._viewModel = StateObject(wrappedValue: OmniRealtimeViewModel(apiKey: apiKey))
    }

    var body: some View {
        ZStack {
            // Live AI frames bypass SwiftUI Image and its UIImage update loop.
            // The snapshot path remains available to the provider only.
            if streamViewModel.usesDirectSampleBufferPreview,
               streamViewModel.cameraCaptureState.isStreaming {
                DirectSampleBufferPreview(streamViewModel: streamViewModel)
                    .ignoresSafeArea()
                    .opacity(0.3)
            } else if let videoFrame = streamViewModel.currentVideoFrame,
                      streamViewModel.cameraCaptureState.isStreaming {
                Image(uiImage: videoFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .opacity(0.3)
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Header
                headerView

                // Conversation history
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.conversationHistory) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            // Current AI response (streaming)
                            if !viewModel.currentTranscript.isEmpty {
                                MessageBubble(
                                    message: ConversationMessage(
                                        role: .assistant,
                                        content: viewModel.currentTranscript
                                    )
                                )
                                .id("current")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.conversationHistory.count) { _, _ in
                        if let lastMessage = viewModel.conversationHistory.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.currentTranscript) { _, _ in
                        proxy.scrollTo("current", anchor: .bottom)
                    }
                }

                // Status and controls
                controlsView
            }
        }
        .onAppear {
            guard !AppIdentity.isRunningPreview else { return }
            wasDeviceAvailable = streamViewModel.hasActiveDevice
            guard wasDeviceAvailable else {
                closeAndRelease()
                return
            }

            Task {
                let started = await liveAIManager.startSession(
                    viewModel: viewModel,
                    streamViewModel: streamViewModel
                )
                if started {
                    if let frame = streamViewModel.currentVideoFrame {
                        viewModel.updateVideoFrame(frame)
                    }
                }
            }
        }
        .onDisappear {
            guard !AppIdentity.isRunningPreview else { return }

            Task {
                await liveAIManager.stopSession(for: viewModel)
            }
        }
        .onChange(of: streamViewModel.cameraCaptureState) { _, state in
            guard !AppIdentity.isRunningPreview else { return }
            guard state.isUnavailable || state.isFailed else { return }
            guard wasDeviceAvailable || state.isFailed else { return }
            closeAndRelease()
        }
        .onChange(of: streamViewModel.currentVideoFrame) { _, frame in
            guard streamViewModel.cameraCaptureState.isStreaming,
                  let frame else { return }
            viewModel.updateVideoFrame(frame)
        }
        .alert("vision.errorTitle".localized, isPresented: $viewModel.showError) {
            Button("common.confirm".localized) {
                viewModel.dismissError()
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("omni.realtime.title".localized)
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isConnected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundColor(.white)
            }

            CameraCaptureStatusView(state: streamViewModel.cameraCaptureState)

            Button {
                closeAndRelease()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.title2)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: 12) {
            // Speaking indicator
            if viewModel.isSpeaking {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("omni.speaking".localized)
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.2))
                .cornerRadius(20)
            }

            // Recording status
            HStack(spacing: 8) {
                if viewModel.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("omni.recording".localized)
                        .font(.caption)
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("omni.notRecording".localized)
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(20)

            // Control buttons
            HStack(spacing: 20) {
                // Start/Stop Recording
                Button {
                    if viewModel.isRecording {
                        viewModel.stopRecording()
                    } else {
                        viewModel.startRecording()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: viewModel.isRecording ? "mic.fill" : "mic.slash.fill")
                            .font(.title)
                        Text(viewModel.isRecording ? "停止" : "开始")
                            .font(.caption)
                    }
                    .frame(width: 80, height: 80)
                    .background(viewModel.isRecording ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
                .disabled(!viewModel.isConnected)
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isRecording ? .red : .blue)
            }
            .padding()
        }
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func closeAndRelease() {
        guard !isClosing else { return }
        isClosing = true
        Task { @MainActor in
            await liveAIManager.stopSession(for: viewModel)
            dismiss()
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.blue : Color.gray.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(18)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 4)
            }

            if message.role == .assistant {
                Spacer()
            }
        }
    }
}

#if DEBUG
@MainActor
private struct OmniRealtimePreview: View {
    @StateObject private var dependencies = PreviewDependencies()

    var body: some View {
        OmniRealtimeView(
            streamViewModel: dependencies.streamViewModel,
            apiKey: ""
        )
    }
}

#Preview("Omni Realtime") {
    OmniRealtimePreview()
}
#endif
