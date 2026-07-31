/*
 * Simple Live Stream View
 * 简化的直播视图 - 用于抖音/快手等平台
 */

import SwiftUI

struct SimpleLiveStreamView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUI = true // 控制 UI 显示/隐藏
    @State private var wasDeviceAvailable = false
    @State private var isClosing = false

    var body: some View {
        ZStack {
            // Black background
            Color.black
                .edgesIgnoringSafeArea(.all)

            // Video feed
            if let videoFrame = streamViewModel.currentVideoFrame,
               streamViewModel.cameraCaptureState.isStreaming {
                GeometryReader { geometry in
                    Image(uiImage: videoFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .edgesIgnoringSafeArea(.all)
            } else {
                VStack(spacing: AppSpacing.lg) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .foregroundColor(.white)
                    Text("正在连接视频流...")
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                }
            }

            // UI 元素 - 点击屏幕可隐藏
            if showUI {
                VStack {
                    HStack {
                            Button {
                            closeAndRelease()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("close".localized)

                        Spacer()

                        CameraCaptureStatusView(state: streamViewModel.cameraCaptureState)
                            .padding(AppSpacing.md)
                    }

                    Spacer()

                    // Instructions
                    VStack(spacing: AppSpacing.md) {
                        Text("直播提示")
                            .font(AppTypography.headline)
                            .foregroundColor(.white)

                        Text("1. 打开抖音/快手等直播平台")
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.8))

                        Text("2. 选择屏幕录制功能")
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.8))

                        Text("3. 开始录制此画面即可直播")
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(AppSpacing.lg)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(AppCornerRadius.lg)
                    .padding(.bottom, AppSpacing.xl)
                }
                .transition(.opacity)
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showUI.toggle()
            }
        }
        .onAppear {
            guard !AppIdentity.isRunningPreview else { return }
            wasDeviceAvailable = streamViewModel.hasActiveDevice
            guard wasDeviceAvailable else {
                closeAndRelease()
                return
            }

            // 启动视频流
            Task {
                print("🎥 SimpleLiveStreamView: 启动视频流")
                _ = await streamViewModel.acquireStream(for: .simpleLiveStream)
            }
        }
        .onDisappear {
            guard !AppIdentity.isRunningPreview else { return }

            // 停止视频流
            Task {
                print("🎥 SimpleLiveStreamView: 停止视频流")
                await streamViewModel.releaseStream(for: .simpleLiveStream)
            }
        }
        .onChange(of: streamViewModel.cameraCaptureState) { _, state in
            guard !AppIdentity.isRunningPreview else { return }
            guard state.isUnavailable || state.isFailed else { return }
            guard wasDeviceAvailable || state.isFailed else { return }
            closeAndRelease()
        }
    }

    private func closeAndRelease() {
        guard !isClosing else { return }
        isClosing = true
        Task { @MainActor in
            await streamViewModel.releaseStream(for: .simpleLiveStream)
            dismiss()
        }
    }
}

#if DEBUG
@MainActor
private struct SimpleLiveStreamPreview: View {
    @StateObject private var dependencies = PreviewDependencies()

    var body: some View {
        SimpleLiveStreamView(streamViewModel: dependencies.streamViewModel)
    }
}

#Preview("Simple Live Stream") {
    SimpleLiveStreamPreview()
}
#endif
