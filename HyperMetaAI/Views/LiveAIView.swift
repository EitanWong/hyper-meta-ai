/*
 * Live AI View
 * 自动启动的实时 AI 对话界面
 */

import SwiftUI

struct LiveAIView: View {
    @StateObject private var viewModel: OmniRealtimeViewModel
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var liveAIManager = LiveAIManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showConversation = true // 控制对话内容显示/隐藏
    @State private var wasDeviceAvailable = false
    @State private var isClosing = false

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        // Use the Live AI API key based on selected provider
        let liveAIApiKey = APIProviderManager.staticLiveAIAPIKey
        self._viewModel = StateObject(wrappedValue: OmniRealtimeViewModel(apiKey: liveAIApiKey.isEmpty ? apiKey : liveAIApiKey))
    }

    var body: some View {
        ZStack {
            // Black background
            Color.black
                .ignoresSafeArea()

            // 未连接设备提醒
            if streamViewModel.cameraCaptureState.isUnavailable {
                deviceNotConnectedView
            } else {
                // The direct DAT preview stays outside SwiftUI's UIImage update
                // loop. `currentVideoFrame` is reserved for the AI snapshot.
                if streamViewModel.usesDirectSampleBufferPreview,
                   streamViewModel.cameraCaptureState.isStreaming {
                    DirectSampleBufferPreview(streamViewModel: streamViewModel)
                        .ignoresSafeArea()
                } else if let videoFrame = streamViewModel.currentVideoFrame,
                          streamViewModel.cameraCaptureState.isStreaming {
                    GeometryReader { geometry in
                        Image(uiImage: videoFrame)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                // Header (紧贴状态栏)
                headerView
                    .padding(.top, 8) // 状态栏下方一点点

                // Conversation history (可隐藏)
                if showConversation {
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer()
                }

                // Status and stop button
                controlsView
                }
            }
        }
        .onAppear {
            guard !AppIdentity.isRunningPreview else { return }
            wasDeviceAvailable = streamViewModel.hasActiveDevice

            // 只有设备连接时才启动功能
            guard streamViewModel.hasActiveDevice else {
                print("⚠️ LiveAIView: 未连接RayBan Meta眼镜，跳过启动")
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

            // 停止 AI 对话和视频流
            print("🎥 LiveAIView: 停止 AI 对话和视频流")
            Task {
                await liveAIManager.stopSession(for: viewModel)
            }
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if isConnected, !viewModel.isRecording {
                viewModel.startRecording()
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
        .alert("error".localized, isPresented: $viewModel.showError) {
            Button("ok".localized) {
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
            Text("liveai.title".localized)
                .font(AppTypography.headline)
                .foregroundColor(.white)

            Spacer()

            // Hide/show conversation button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showConversation.toggle()
                }
            } label: {
                Image(systemName: showConversation ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
            }

            // Connection status
            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isConnected ? "liveai.connected".localized : "liveai.connecting".localized)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
            }

            CameraCaptureStatusView(state: streamViewModel.cameraCaptureState)

            // Speaking indicator
            if viewModel.isSpeaking {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("liveai.speaking".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: AppSpacing.md) {
            // Recording status
            HStack(spacing: AppSpacing.sm) {
                if viewModel.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("liveai.listening".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("liveai.stop".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.black.opacity(0.6))
            .cornerRadius(AppCornerRadius.xl)

            // Stop button (only button)
            Button(role: .destructive) {
                closeAndRelease()
            } label: {
                Label("liveai.stop".localized, systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isClosing)
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.bottom, AppSpacing.lg)
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

    // MARK: - Device Not Connected View

    private var deviceNotConnectedView: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 80))
                    .foregroundColor(AppColors.liveAI.opacity(0.6))

                Text("liveai.device.notconnected.title".localized)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("liveai.device.notconnected.message".localized)
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)
            }

            Spacer()

            // Back button
            Button {
                dismiss()
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "chevron.left")
                    Text("liveai.device.backtohome".localized)
                        .font(AppTypography.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(AppColors.primary)
                .foregroundColor(.white)
                .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
    }
}

#if DEBUG
@MainActor
private struct LiveAIPreview: View {
    @StateObject private var dependencies = PreviewDependencies()

    var body: some View {
        LiveAIView(
            streamViewModel: dependencies.streamViewModel,
            apiKey: ""
        )
    }
}

#Preview("Live AI") {
    LiveAIPreview()
}
#endif
