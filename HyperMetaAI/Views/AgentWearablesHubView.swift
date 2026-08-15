/*
 * Agent Wearables Hub View
 * JARVIS 触发中心：眼镜状态、演示触发、Apple 原生触发源引导、触发日志。
 * 演示触发与真实触发（镜腿 / 背部轻点 / 操作按钮 / 快捷指令）走同一路由与审计。
 */

import SwiftUI

struct AgentWearablesHubView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var center = AgentWearableTriggerCenter.shared
    @State private var previewUnreadCount = 0
    @State private var previewStatusLines: [String] = []

    var body: some View {
        List {
            statusSection
            homePreviewSection
            demoSection
            sourceSection
            logSection
        }
        .navigationTitle("agent.wearable.hub.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let state = await AgentDisplayHomeLoader.state()
            previewUnreadCount = state.unreadCount
            previewStatusLines = state.statusLines
        }
    }

    // MARK: - 眼镜状态

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "eyeglasses")
                    .font(.title3)
                    .foregroundColor(statusColor)
                    .frame(width: 36, height: 36)
                    .background(statusColor.opacity(0.12))
                    .cornerRadius(9)

                VStack(alignment: .leading, spacing: 3) {
                    Text("agent.wearable.status.title".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    Text(statusText)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }

                Spacer()

                if streamViewModel.hasActiveDevice {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }
            }
        } header: {
            Text("agent.wearable.status.header".localized)
        }
    }

    private var statusColor: Color {
        streamViewModel.hasActiveDevice ? AppColors.primary : AppColors.textTertiary
    }

    private var statusText: String {
        if streamViewModel.hasActiveDevice {
            let label = streamViewModel.availableDevices.first
                ?? streamViewModel.activeDeviceID
                ?? "agent.wearable.status.connected".localized
            return "agent.wearable.status.connected".localized(label)
        }
        return "agent.wearable.status.unregistered".localized
    }

    // MARK: - 镜片主页预览

    private var homePreviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AgentDisplayHomeMapping.timeText(context.date))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(AgentDisplayHomeMapping.dateText(context.date))
                                .font(.system(size: 13, weight: .medium))
                                .opacity(0.75)
                        }
                    }
                    Spacer()
                    Image(systemName: "eyeglasses")
                        .font(.title2)
                        .opacity(0.55)
                }

                Text(AgentDisplayHomeMapping.unreadText(count: previewUnreadCount))
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.9)

                ForEach(previewStatusLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13))
                        .opacity(0.85)
                }

                HStack(spacing: 14) {
                    ForEach(AgentDisplayHomeMapping.hudActions(), id: \.self) { action in
                        Image(systemName: AgentDisplayMenuMapping.iconName(for: action))
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .padding(.top, 2)
            }
            .foregroundColor(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.11, blue: 0.16),
                                Color(red: 0.17, green: 0.18, blue: 0.27)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
            )

            Button {
                Task { @MainActor in
                    let state = await AgentDisplayHomeLoader.state()
                    AgentDisplayHub.shared.showHome(state: state) { _ in }
                }
            } label: {
                Label(
                    "agent.wearable.home.show".localized,
                    systemImage: "eyeglasses"
                )
            }
        } header: {
            Text("agent.display.hub.home.title".localized)
        } footer: {
            Text("agent.display.hub.home.detail".localized)
        }
    }

    // MARK: - 演示触发

    private var demoSection: some View {
        Section {
            demoRow(gesture: .wake, source: .inApp, icon: "waveform.circle.fill")
            demoRow(gesture: .interrupt, source: .inApp, icon: "pause.circle.fill")
            demoRow(gesture: .resume, source: .inApp, icon: "play.circle.fill")
            demoRow(gesture: .endTurn, source: .inApp, icon: "stop.circle.fill")
            demoRow(gesture: .captureVision, source: .inApp, icon: "eye.circle.fill")
            demoRow(gesture: .repeatLastReply, source: .inApp, icon: "arrow.counterclockwise")
            demoRow(gesture: .mockTap, source: .mockCaptouch, icon: "hand.tap.fill")
            demoRow(gesture: .mockTapAndHold, source: .mockCaptouch, icon: "hand.tap.fill")
        } header: {
            Text("agent.wearable.demo.header".localized)
        } footer: {
            Text("agent.wearable.demo.footer".localized)
        }
    }

    private func demoRow(
        gesture: AgentWearableGesture,
        source: AgentWearableSource,
        icon: String
    ) -> some View {
        Button {
            center.dispatch(source: source, gesture: gesture)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.displayName)
                        .foregroundColor(AppColors.textPrimary)
                    Text(source.displayName)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundColor(AppColors.primary)
            }
        }
    }

    // MARK: - Apple 原生触发源引导

    private var sourceSection: some View {
        Section {
            guideRow(
                icon: "hand.tap.fill",
                title: "agent.wearable.guide.backtap.title".localized,
                detail: "agent.wearable.guide.backtap.detail".localized
            )
            guideRow(
                icon: "button.programmable",
                title: "agent.wearable.guide.actionbutton.title".localized,
                detail: "agent.wearable.guide.actionbutton.detail".localized
            )
            guideRow(
                icon: "mic.fill",
                title: "agent.wearable.guide.siri.title".localized,
                detail: "agent.wearable.guide.siri.detail".localized
            )
            guideRow(
                icon: "square.grid.2x2",
                title: "agent.wearable.guide.shortcut.title".localized,
                detail: "agent.wearable.guide.shortcut.detail".localized
            )
        } header: {
            Text("agent.wearable.sources.header".localized)
        } footer: {
            Text("agent.wearable.sources.footer".localized)
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(AppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 触发日志

    private var logSection: some View {
        Section {
            if center.entries.isEmpty {
                Text("agent.wearable.log.empty".localized)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            } else {
                ForEach(center.entries.prefix(20)) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.source.iconName)
                            .foregroundColor(AppColors.textSecondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AgentWearableLogFormatter.rowTitle(entry))
                                .font(.system(size: 15))
                                .foregroundColor(AppColors.textPrimary)
                            Text(AgentWearableLogFormatter.rowDetail(entry))
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }

                        Spacer()

                        Text(AgentWearableLogFormatter.relativeTime(entry.timestamp))
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .padding(.vertical, 2)
                }

                Button(role: .destructive) {
                    center.clearLog()
                } label: {
                    Text("agent.wearable.log.clear".localized)
                }
            }
        } header: {
            Text("agent.wearable.log.header".localized)
        }
    }
}
