/*
 * Recording Playback View
 * 本地录制回放面板：AVPlayer 播放 MP4 + 标记时间轴，
 * 点击标记跳转到对应时间位置，未找到文件时给出提示。
 */

import AVKit
import SwiftUI

/// 录制回放面板（由 RTMPSettingsView 以 sheet 呈现）
struct RecordingPlaybackView: View {
    @ObservedObject var viewModel: RTMPStreamingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    /// 片段导出中（显示进度遮罩，防重复触发）
    @State private var isExporting = false
    /// 片段导出失败提示
    @State private var exportNotice: String?

    var body: some View {
        NavigationView {
            Group {
                if let url = viewModel.playbackURL {
                    VStack(spacing: 0) {
                        VideoPlayer(player: player)
                            .aspectRatio(1, contentMode: .fit)
                            .background(Color.black)
                            .onAppear {
                                if player == nil {
                                    player = AVPlayer(url: url)
                                }
                                player?.play()
                            }
                            .onDisappear {
                                player?.pause()
                            }

                        recordInfoView

                        Divider()

                        markerTimelineView
                    }
                } else {
                    VStack(spacing: AppSpacing.md) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("rtmp.playback.missing".localized)
                            .font(AppTypography.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(AppSpacing.xl)
                }
            }
            .navigationTitle("rtmp.playback.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done".localized) {
                        viewModel.closePlayback()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = viewModel.playbackURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("rtmp.playback.share".localized)
                    }
                }
            }
            .overlay {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: AppSpacing.sm) {
                            ProgressView()
                                .tint(.white)
                            Text("rtmp.playback.clip.exporting".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(.white)
                        }
                        .padding(AppSpacing.lg)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(AppCornerRadius.md)
                    }
                }
            }
            .alert("error".localized, isPresented: Binding(
                get: { exportNotice != nil },
                set: { if !$0 { exportNotice = nil } }
            )) {
                Button("ok".localized) { exportNotice = nil }
            } message: {
                Text(exportNotice ?? "")
            }
        }
    }

    /// 录制信息（文件名 + 时长）
    private var recordInfoView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.playbackRecord?.fileName ?? "")
                    .font(AppTypography.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(RTMPRecordingNaming.durationText(viewModel.playbackRecord?.duration ?? 0))
                    .font(AppTypography.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
    }

    /// 标记时间轴（点击跳转；无标记时给出提示）
    private var markerTimelineView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                if viewModel.playbackMarkers.isEmpty {
                    Text("rtmp.playback.markers.empty".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(
                        Array(viewModel.playbackMarkers.enumerated()),
                        id: \.offset
                    ) { _, entry in
                        Button {
                            seek(to: entry.timeOffset)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.timeText)
                                    .font(AppTypography.caption.monospacedDigit())
                                    .fontWeight(.semibold)
                                Text(entry.label)
                                    .font(AppTypography.footnote)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                exportClip(marker: entry)
                            } label: {
                                Label("rtmp.playback.clip.export".localized, systemImage: "scissors")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.vertical, AppSpacing.sm)
    }

    /// 导出标记片段：完成后弹系统分享面板
    private func exportClip(marker: RTMPRecordingPlayback.MarkerEntry) {
        guard !isExporting else { return }
        isExporting = true
        let recordMarker = RTMPRecordingMarker(
            timeOffset: marker.timeOffset,
            label: marker.label
        )
        viewModel.exportClip(marker: recordMarker) { result in
            isExporting = false
            switch result {
            case .success(let url):
                shareClip(url)
            case .failure(let error):
                exportNotice = error.message
            }
        }
    }

    /// 用系统分享面板分享片段文件
    private func shareClip(_ url: URL) {
        let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityVC, animated: true)
        }
    }

    /// 跳转到标记对应时间位置
    private func seek(to timeOffset: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: timeOffset, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
