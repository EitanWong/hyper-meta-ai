/*
 * Agent Home Widget（桌面小组件）
 * 展示下次提醒 + 语音会话快捷入口（iOS 17+ 交互按钮）。
 * 数据快照由 App 侧生成（agent.widget.snapshot，App Group），扩展只读渲染，
 * 与 Live Activity 同一模式：文案跟随 App 语言，扩展不重复本地化。
 */

import AppIntents
import SwiftUI
import WidgetKit

/// App 侧 `AgentWidgetSnapshot` 的镜像（字段必须一致，Codable 解码）
struct AgentHomeWidgetSnapshot: Codable {
    var nextReminderText: String
    var nextReminderDetail: String
    var reminderCount: Int
    var isVoiceSessionActive: Bool
    var voiceButtonTitle: String
    var taskSummary: String
    /// 下次日程字段（optional 兼容旧快照）
    var nextCalendarText: String?
    var nextCalendarDetail: String?
    /// 锁屏配件字段（optional 兼容旧快照）
    var accessoryTitle: String?
    var accessoryBody: String?
    var accessoryDetail: String?
    var accessoryInlineText: String?

    var hasReminder: Bool { !nextReminderDetail.isEmpty }

    var hasCalendar: Bool { !(nextCalendarDetail?.isEmpty ?? true) }

    /// 「14:30 评审」组合行（无日程为空）
    var calendarLine: String? {
        guard hasCalendar, let detail = nextCalendarDetail, let text = nextCalendarText, !text.isEmpty else {
            return nil
        }
        return "\(detail) \(text)"
    }
}

// MARK: - Entry & Provider

struct AgentHomeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentHomeWidgetSnapshot?
}

struct AgentHomeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentHomeWidgetEntry {
        AgentHomeWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentHomeWidgetEntry) -> Void) {
        completion(AgentHomeWidgetEntry(date: Date(), snapshot: Self.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentHomeWidgetEntry>) -> Void) {
        let entry = AgentHomeWidgetEntry(date: Date(), snapshot: Self.readSnapshot())
        // 常规刷新由 App 侧 reloadTimelines 触发；这里给一个兜底周期
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private static func readSnapshot() -> AgentHomeWidgetSnapshot? {
        let defaults = UserDefaults(suiteName: "group.com.lunflux.hyper-meta-ai") ?? .standard
        guard let data = defaults.data(forKey: "agent.widget.snapshot") else { return nil }
        return try? JSONDecoder().decode(AgentHomeWidgetSnapshot.self, from: data)
    }
}

// MARK: - Widget

struct AgentHomeWidget: Widget {
    static let kind = "agentHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: AgentHomeWidgetProvider()) { entry in
            AgentHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("下次提醒")
        .description("查看最近的提醒，一键进入语音会话")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

// MARK: - View

struct AgentHomeWidgetView: View {
    let entry: AgentHomeWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: AgentHomeWidgetSnapshot? { entry.snapshot }

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .accessoryRectangular: accessoryRectangularView
        case .accessoryCircular: accessoryCircularView
        case .accessoryInline: accessoryInlineView
        default: mediumView
        }
    }

    /// 锁屏 / 灵动岛矩形配件：任务进行中显示任务摘要，否则显示下次提醒
    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot?.accessoryTitle ?? "—")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(snapshot?.accessoryBody ?? "—")
                .font(.body)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let detail = snapshot?.accessoryDetail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    /// 锁屏圆形配件：提醒总数环形进度（上限 20）
    private var accessoryCircularView: some View {
        ZStack {
            ProgressView(
                value: Double(min(snapshot?.reminderCount ?? 0, 20)),
                total: 20
            )
            .progressViewStyle(.circular)
            .tint(snapshot?.hasReminder == true ? .green : .secondary)
            VStack(spacing: 0) {
                Image(systemName: snapshot?.hasReminder == true ? "bell.fill" : "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(snapshot?.reminderCount ?? 0)")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }

    /// 锁屏单行配件：任务摘要或「下次：内容」
    private var accessoryInlineView: some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot?.hasReminder == true ? "bell.fill" : "waveform")
            Text(snapshot?.accessoryInlineText ?? "—")
                .lineLimit(1)
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: smallIcon)
                    .font(.title3)
                    .foregroundStyle(smallIconTint)
                Spacer()
                if snapshot?.isVoiceSessionActive == true {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
            if snapshot?.hasReminder == true {
                Text(snapshot?.nextReminderText ?? "—")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail = snapshot?.nextReminderDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if snapshot?.hasCalendar == true {
                Text(snapshot?.calendarLine ?? "—")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text(snapshot?.nextReminderText ?? "—")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if let summary = snapshot?.taskSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // 语音会话快捷入口（iOS 17+ 交互按钮，小尺寸用紧凑图标）
            if snapshot?.isVoiceSessionActive == true {
                compactVoiceButton(
                    intent: StopVoiceSessionControlIntent(),
                    icon: "stop.circle.fill",
                    color: .red
                )
            } else {
                compactVoiceButton(
                    intent: StartVoiceSessionControlIntent(),
                    icon: "waveform.circle.fill",
                    color: .green
                )
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private var smallIcon: String {
        if snapshot?.hasReminder == true { return "bell.badge.fill" }
        if snapshot?.hasCalendar == true { return "calendar" }
        return "bell.slash.fill"
    }

    private var smallIconTint: AnyShapeStyle {
        snapshot?.hasReminder == true || snapshot?.hasCalendar == true
            ? AnyShapeStyle(.tint)
            : AnyShapeStyle(.secondary)
    }

    /// 小尺寸语音按钮（图标 + 无障碍标签，不占正文空间）
    private func compactVoiceButton<Intent: AppIntent>(
        intent: Intent,
        icon: String,
        color: Color
    ) -> some View {
        HStack {
            Spacer()
            Button(intent: intent) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot?.voiceButtonTitle ?? "Voice session")
        }
    }

    private var mediumView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: snapshot?.hasReminder == true ? "bell.badge.fill" : "bell.slash.fill")
                        .foregroundStyle(snapshot?.hasReminder == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    if let count = snapshot?.reminderCount, count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snapshot?.nextReminderText ?? "—")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail = snapshot?.nextReminderDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let line = snapshot?.calendarLine {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let summary = snapshot?.taskSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if snapshot?.isVoiceSessionActive == true {
                voiceButton(intent: StopVoiceSessionControlIntent(), icon: "stop.circle.fill", color: .red)
            } else {
                voiceButton(intent: StartVoiceSessionControlIntent(), icon: "waveform.circle.fill", color: .green)
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private func voiceButton<Intent: AppIntent>(
        intent: Intent,
        icon: String,
        color: Color
    ) -> some View {
        Button(intent: intent) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(color)
                Text(snapshot?.voiceButtonTitle ?? "Voice")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot?.voiceButtonTitle ?? "Voice session")
    }
}
