/*
 * RTMP Local Recording
 * 推流中本地录制（视频轨）与事件标记：录制文件名、标记时间线与
 * 录制记录存储的纯逻辑部分，便于单元测试；AVAssetWriter 录制器见
 * RTMPStreamRecorder。
 */

import AVFoundation
import Foundation

/// 录制中的一次事件标记（精彩瞬间）
struct RTMPRecordingMarker: Codable, Equatable, Identifiable {
    var id: UUID
    /// 相对录制开始的秒数
    var timeOffset: TimeInterval
    /// 标记标签（用户输入，截断到 16 字符）
    var label: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        timeOffset: TimeInterval,
        label: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.timeOffset = timeOffset
        self.label = label
        self.createdAt = createdAt
    }
}

/// 一次完成的本地录制记录
struct RTMPRecordingRecord: Codable, Equatable, Identifiable {
    var id: UUID
    /// 录制文件名（Documents/RTMPRecordings/ 下）
    var fileName: String
    var startedAt: Date
    /// 录制时长（秒）
    var duration: TimeInterval
    var fileSize: Int64
    var markers: [RTMPRecordingMarker]

    init(
        id: UUID = UUID(),
        fileName: String,
        startedAt: Date,
        duration: TimeInterval,
        fileSize: Int64,
        markers: [RTMPRecordingMarker]
    ) {
        self.id = id
        self.fileName = fileName
        self.startedAt = startedAt
        self.duration = duration
        self.fileSize = fileSize
        self.markers = markers
    }
}

/// 录制文件命名与展示格式（纯逻辑，可测）
enum RTMPRecordingNaming {
    /// 文件名前缀
    static let filePrefix = "HyperMetaAI-"

    /// 文件名：HyperMetaAI-YYYYMMDD-HHmmss.mp4（formatter 可注入以便测试）
    static func fileName(
        startedAt: Date,
        formatter: DateFormatter = RTMPRecordingNaming.makeFormatter()
    ) -> String {
        filePrefix + formatter.string(from: startedAt) + ".mp4"
    }

    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    /// 时长展示：MM:SS；超过 1 小时为 H:MM:SS
    static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// 标记时间展示：MM:SS / H:MM:SS（与 durationText 一致）
    static func markerTimeText(_ offset: TimeInterval) -> String {
        durationText(offset)
    }
}

/// 录制标记时间线（纯逻辑，可测）：标签裁剪、按时间排序
struct RTMPMarkerTimeline {
    /// 标记标签最大长度
    static let maxLabelLength = 16

    private(set) var markers: [RTMPRecordingMarker] = []

    /// 添加一个标记；标签去首尾空白、空标签或负时间返回 nil
    @discardableResult
    mutating func add(
        label: String,
        at offset: TimeInterval,
        now: Date = Date()
    ) -> RTMPRecordingMarker? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, offset >= 0 else { return nil }
        let clipped = String(trimmed.prefix(Self.maxLabelLength))
        let marker = RTMPRecordingMarker(
            timeOffset: offset,
            label: clipped,
            createdAt: now
        )
        markers.append(marker)
        markers.sort { $0.timeOffset < $1.timeOffset }
        return marker
    }

    mutating func clear() {
        markers.removeAll()
    }
}

/// 录制记录存储（UserDefaults JSON 持久化，上限 20 条）
enum RTMPRecordingStore {
    static let key = "rtmp.recordings"
    static let maxCount = 20

    static var records: [RTMPRecordingRecord] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            let decoded = (try? JSONDecoder().decode([RTMPRecordingRecord].self, from: data)) ?? []
            return decoded.sorted { $0.startedAt > $1.startedAt }
        }
        set {
            let trimmed = Array(newValue.prefix(maxCount))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增一条记录（保留最新 maxCount 条）
    static func add(_ record: RTMPRecordingRecord) {
        var items = records
        items.insert(record, at: 0)
        records = items
    }

    static func delete(id: UUID) {
        records = records.filter { $0.id != id }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 录制回放辅助（纯逻辑，可测）：文件定位与标记时间轴
enum RTMPRecordingPlayback {
    /// 标记时间轴条目
    struct MarkerEntry: Equatable {
        let timeOffset: TimeInterval
        let timeText: String
        let label: String
        /// 相对录制时长位置 0~1（时长无效时为 0），供跳转与展示
        let progress: Double
    }

    /// 从文件名构造文件 URL（默认 Documents/RTMPRecordings 目录）
    static func fileURL(
        fileName: String,
        directory: URL = RTMPStreamRecorder.defaultDirectory()
    ) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 录制文件是否存在
    static func fileExists(
        fileName: String,
        directory: URL = RTMPStreamRecorder.defaultDirectory()
    ) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(fileName: fileName, directory: directory).path)
    }

    /// 生成标记时间轴（按时间升序；时长 > 0 时计算进度位置并夹在 0~1）
    static func markerEntries(for record: RTMPRecordingRecord) -> [MarkerEntry] {
        let duration = max(0, record.duration)
        return record.markers
            .sorted { $0.timeOffset < $1.timeOffset }
            .map { marker in
                MarkerEntry(
                    timeOffset: marker.timeOffset,
                    timeText: RTMPRecordingNaming.markerTimeText(marker.timeOffset),
                    label: marker.label,
                    progress: duration > 0
                        ? min(1, max(0, marker.timeOffset / duration))
                        : 0
                )
            }
    }
}

/// 标记片段导出错误（可测）：消息映射到本地化文案
enum ClipExportError: Error, Equatable {
    case noFile
    case invalid
    case failed
    case cancelled

    var message: String {
        switch self {
        case .noFile: return "rtmp.playback.clip.nofile".localized
        case .invalid: return "rtmp.playback.clip.invalid".localized
        case .failed: return "rtmp.playback.clip.failed".localized
        case .cancelled: return "rtmp.playback.clip.cancelled".localized
        }
    }
}

/// 标记片段导出（纯逻辑，可测）：标记前后窗口夹取到录制范围内，
/// 供 AVAssetExportSession 按时间范围裁剪「精彩瞬间」片段。
enum RTMPClipSegment {
    /// 标记前保留秒数
    static let leadSeconds = 10.0
    /// 标记后保留秒数
    static let tailSeconds = 5.0

    /// 由标记位置、录制时长与前后窗口计算导出片段时间范围；无效输入返回 nil
    static func timeRange(
        markerOffset: TimeInterval,
        duration: TimeInterval,
        leadSeconds: TimeInterval = RTMPClipWindowSettings.defaultLead,
        tailSeconds: TimeInterval = RTMPClipWindowSettings.defaultTail
    ) -> CMTimeRange? {
        guard duration > 0, markerOffset >= 0, markerOffset <= duration else { return nil }
        let start = max(0, markerOffset - leadSeconds)
        let end = min(duration, markerOffset + tailSeconds)
        guard end > start else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
    }

    /// 片段文件名：<原文件名>-<标签>-<起始MMSS>.mp4（标签清理，空标签回退 clip）
    static func clipFileName(
        fileName: String,
        label: String,
        startOffset: TimeInterval
    ) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let cleaned = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = cleaned.isEmpty ? "clip" : cleaned
        let minutes = Int(startOffset) / 60
        let seconds = Int(startOffset) % 60
        return "\(base)-\(name)-\(String(format: "%02d%02d", minutes, seconds)).mp4"
    }
}

/// 片段导出窗口设置（纯逻辑，可测）：标记前/后秒数，夹取到 0-60s，UserDefaults 持久化
enum RTMPClipWindowSettings {
    static let minSeconds = 0.0
    static let maxSeconds = 60.0
    static let defaultLead = 10.0
    static let defaultTail = 5.0

    static let leadKey = "rtmp_clip_lead"
    static let tailKey = "rtmp_clip_tail"

    static var leadSeconds: Double {
        get { clamp(UserDefaults.standard.object(forKey: leadKey) as? Double ?? defaultLead) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: leadKey) }
    }

    static var tailSeconds: Double {
        get { clamp(UserDefaults.standard.object(forKey: tailKey) as? Double ?? defaultTail) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: tailKey) }
    }

    /// 夹取到合法区间
    static func clamp(_ value: Double) -> Double {
        min(max(value, minSeconds), maxSeconds)
    }
}
