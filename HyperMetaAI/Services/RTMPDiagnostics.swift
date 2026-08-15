/*
 * RTMP Diagnostics
 * 推流会话性能指标采集（纯逻辑，可测）：连接/重连、质量档位调整、
 * 帧统计、录制标记与场景变化，汇总为可分享的诊断快照与文本报告。
 */

import Foundation

/// 一次推流会话的诊断快照
struct RTMPDiagnosticsSnapshot: Equatable {
    var startedAt: Date?
    var endedAt: Date?
    /// 连接尝试次数（首次 + 每次重连）
    var connectionAttempts = 0
    var reconnectAttempts = 0
    var qualityUpshifts = 0
    var qualityDownshifts = 0
    var recordingMarkers = 0
    var sceneChanges = 0
    var totalFrames: Int64 = 0
    var droppedFrames: Int64 = 0
    /// 质量档位变化历史（shortLabel，如 "504×504@30"）
    var qualityHistory: [String] = []

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// 整体丢帧率 0~1（无帧为 0）
    var dropRate: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(droppedFrames) / Double(totalFrames)
    }
}

/// 推流诊断采集器（纯逻辑，可测）
struct RTMPDiagnosticsCollector {
    private(set) var snapshot = RTMPDiagnosticsSnapshot()

    /// 开始一次会话（重置快照）
    mutating func begin(now: Date = Date()) {
        snapshot = RTMPDiagnosticsSnapshot()
        snapshot.startedAt = now
        snapshot.connectionAttempts = 1
    }

    /// 结束会话
    mutating func end(now: Date = Date()) {
        snapshot.endedAt = now
    }

    /// 记录帧统计（周期采样）
    mutating func recordFrameStats(total: Int64, dropped: Int64) {
        snapshot.totalFrames = max(0, total)
        snapshot.droppedFrames = max(0, dropped)
    }

    /// 记录一次质量档位调整
    mutating func recordQualityChange(upshift: Bool, presetLabel: String) {
        if upshift {
            snapshot.qualityUpshifts += 1
        } else {
            snapshot.qualityDownshifts += 1
        }
        snapshot.qualityHistory.append(presetLabel)
    }

    /// 记录一次重连尝试
    mutating func recordReconnect() {
        snapshot.reconnectAttempts += 1
        snapshot.connectionAttempts += 1
    }

    /// 记录一次录制标记
    mutating func recordRecordingMarker() {
        snapshot.recordingMarkers += 1
    }

    /// 记录一次场景变化
    mutating func recordSceneChange() {
        snapshot.sceneChanges += 1
    }
}

/// 诊断报告文本生成（纯逻辑，可测）
enum RTMPDiagnosticsReport {
    /// 生成可分享的文本报告（本地化文案由调用方注入，保持纯逻辑可测）
    static func text(
        from snapshot: RTMPDiagnosticsSnapshot,
        durationText: (TimeInterval?) -> String,
        numberText: (Int64) -> String
    ) -> String {
        var lines: [String] = []
        lines.append("RTMP Streaming Diagnostics")
        lines.append("Duration: \(durationText(snapshot.duration))")
        lines.append(
            "Connections: \(snapshot.connectionAttempts) (reconnects: \(snapshot.reconnectAttempts))"
        )
        lines.append(
            "Frames: \(numberText(snapshot.totalFrames)) / dropped \(numberText(snapshot.droppedFrames))"
            + String(format: " (%.1f%%)", snapshot.dropRate * 100)
        )
        lines.append(
            "Quality: \(snapshot.qualityUpshifts) up / \(snapshot.qualityDownshifts) down"
            + (snapshot.qualityHistory.isEmpty ? "" : " -> " + snapshot.qualityHistory.joined(separator: " -> "))
        )
        lines.append("Recording markers: \(snapshot.recordingMarkers)")
        lines.append("Scene changes: \(snapshot.sceneChanges)")
        return lines.joined(separator: "\n")
    }
}

/// 一份诊断日志文件（设置页展示用）
struct RTMPDiagnosticsLogEntry: Equatable, Identifiable {
    /// 以文件路径为稳定标识（避免每次列出生成新 UUID 导致列表闪烁）
    var id: String { url.path }
    var url: URL
    var fileName: String
    /// 文件大小（字节）
    var fileSize: Int64
    var createdAt: Date
}

/// 诊断日志文件（纯逻辑，可测）：会话快照落盘 Documents/RTMPDiagnostics/*.log，
/// 按时间倒序列出、滚动保留上限，供设置页查看与分享。
enum RTMPDiagnosticsLog {
    static let filePrefix = "RTMPDiagnostics-"
    /// 日志文件保留上限（超出按时间删除最旧）
    static let maxLogCount = 20

    /// 日志目录（Documents/RTMPDiagnostics）
    static func defaultDirectory() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("RTMPDiagnostics", isDirectory: true)
    }

    /// 日志文件名：RTMPDiagnostics-YYYYMMDD-HHmmss.log（formatter 可注入以便测试）
    static func fileName(
        startedAt: Date,
        formatter: DateFormatter = RTMPRecordingNaming.makeFormatter()
    ) -> String {
        filePrefix + formatter.string(from: startedAt) + ".log"
    }

    /// 完整日志文本（时间行 + 指标报告；格式化器注入保持可测）
    static func text(
        from snapshot: RTMPDiagnosticsSnapshot,
        timestampText: (Date) -> String,
        durationText: (TimeInterval?) -> String,
        numberText: (Int64) -> String
    ) -> String {
        var lines: [String] = []
        lines.append("RTMP Streaming Session Log")
        if let startedAt = snapshot.startedAt {
            lines.append("Started: \(timestampText(startedAt))")
        }
        if let endedAt = snapshot.endedAt {
            lines.append("Ended: \(timestampText(endedAt))")
        }
        lines.append("")
        lines.append(RTMPDiagnosticsReport.text(
            from: snapshot,
            durationText: durationText,
            numberText: numberText
        ))
        return lines.joined(separator: "\n")
    }

    /// 把一次会话快照写入日志文件；目录自动创建，失败返回 nil
    @discardableResult
    static func write(
        snapshot: RTMPDiagnosticsSnapshot,
        directory: URL = defaultDirectory(),
        formatter: DateFormatter = RTMPRecordingNaming.makeFormatter(),
        timestampText: (Date) -> String,
        durationText: (TimeInterval?) -> String,
        numberText: (Int64) -> String
    ) -> URL? {
        let content = text(
            from: snapshot,
            timestampText: timestampText,
            durationText: durationText,
            numberText: numberText
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                fileName(startedAt: snapshot.startedAt ?? Date(), formatter: formatter)
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// 目录下日志文件（按修改时间倒序；目录不存在返回空）
    static func logFiles(in directory: URL = defaultDirectory()) -> [RTMPDiagnosticsLogEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        let entries = urls
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> RTMPDiagnosticsLogEntry? in
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { return nil }
                return RTMPDiagnosticsLogEntry(
                    url: url,
                    fileName: url.lastPathComponent,
                    fileSize: Int64(values.fileSize ?? 0),
                    createdAt: values.contentModificationDate ?? .distantPast
                )
            }
        // 按文件名（内嵌开始时间）倒序，保证同秒写入时顺序也确定
        return entries.sorted { $0.fileName > $1.fileName }
    }

    /// 滚动裁剪：只保留最新 maxCount 份，返回被删除的文件 URL
    @discardableResult
    static func trim(
        directory: URL = defaultDirectory(),
        maxCount: Int = maxLogCount
    ) -> [URL] {
        let files = logFiles(in: directory)
        guard files.count > maxCount else { return [] }
        let removed = files.suffix(files.count - maxCount)
        for entry in removed {
            try? FileManager.default.removeItem(at: entry.url)
        }
        return removed.map(\.url)
    }

    /// 删除一份日志文件（返回是否删掉）
    @discardableResult
    static func delete(url: URL) -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }
}
