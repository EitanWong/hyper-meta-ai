/*
 * RTMP Stream Recorder
 * 推流中本地录制（视频轨）：把进入推流的帧写入 MP4（H.264）。
 * 采集帧尺寸固定（DAT 504×504），不受自适应编码档位影响；
 * 帧率档位节流后的实际帧率变化由时间戳自然表达。
 */

import AVFoundation
import CoreVideo
import Foundation

/// 推流中本地录制器（AVAssetWriter 实时编码；线程安全）
final class RTMPStreamRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: Date?
    private var basePTS: CMTime?
    private var framesWritten = 0
    private var timeline = RTMPMarkerTimeline()

    private let directory: URL

    init(directory: URL = RTMPStreamRecorder.defaultDirectory()) {
        self.directory = directory
    }

    /// 录制文件目录（Documents/RTMPRecordings）
    static func defaultDirectory() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("RTMPRecordings", isDirectory: true)
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writer != nil
    }

    /// 开始录制；目录不可写或 writer 启动失败返回 false
    func start(dimensions: CGSize) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil else { return false }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                RTMPRecordingNaming.fileName(startedAt: Date())
            )
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height)
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.videoInput = input
            self.pixelAdaptor = adaptor
            self.startedAt = Date()
            self.basePTS = nil
            self.framesWritten = 0
            self.timeline.clear()
            return true
        } catch {
            return false
        }
    }

    /// 追加一帧（start 后调用；时间戳自动归零基准）
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let writer, let videoInput, let pixelAdaptor,
              writer.status == .writing,
              videoInput.isReadyForMoreMediaData,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let valid = sourcePTS.isValid && sourcePTS.seconds.isFinite
        let pts: CMTime
        if valid {
            if let basePTS {
                pts = CMTimeSubtract(sourcePTS, basePTS)
            } else {
                basePTS = sourcePTS
                pts = .zero
            }
        } else {
            pts = CMTime(value: CMTimeValue(framesWritten), timescale: 30)
        }

        guard pixelAdaptor.append(pixelBuffer, withPresentationTime: pts) else { return }
        framesWritten += 1
    }

    /// 添加一个事件标记（相对录制开始的时间自动计算）
    @discardableResult
    func addMarker(label: String) -> RTMPRecordingMarker? {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt else { return nil }
        return timeline.add(label: label, at: Date().timeIntervalSince(startedAt))
    }

    /// 结束录制：写入尾部并返回记录；未在录制中返回 nil
    func finish() async -> RTMPRecordingRecord? {
        // 同步段：取出状态快照并清空录制器（锁只在同步上下文使用）
        let writerToFinish: AVAssetWriter
        let inputToFinish: AVAssetWriterInput
        let startedAtValue: Date
        let markersSnapshot: [RTMPRecordingMarker]
        let url: URL

        lock.lock()
        guard let writer, let videoInput, let startedAt else {
            lock.unlock()
            return nil
        }
        writerToFinish = writer
        inputToFinish = videoInput
        startedAtValue = startedAt
        markersSnapshot = timeline.markers
        url = writer.outputURL
        self.writer = nil
        self.videoInput = nil
        self.pixelAdaptor = nil
        self.startedAt = nil
        self.basePTS = nil
        self.framesWritten = 0
        lock.unlock()

        inputToFinish.markAsFinished()
        await writerToFinish.finishWriting()

        guard writerToFinish.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 ?? 0
        let duration = Date().timeIntervalSince(startedAtValue)
        return RTMPRecordingRecord(
            fileName: url.lastPathComponent,
            startedAt: startedAtValue,
            duration: duration,
            fileSize: size,
            markers: markersSnapshot
        )
    }
}
