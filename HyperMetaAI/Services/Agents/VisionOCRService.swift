/*
 * Vision OCR Service
 * 端侧视野取词：基于 Apple Vision 的离线文字识别（免费、无网络、无 API Key），
 * 拍照即取词，识别文字可发给 Agent 继续追问（翻译 / 总结）或复制。
 */

import Foundation
import UIKit
import Vision

/// 一行 OCR 识别结果
struct VisionOCRLine: Identifiable, Equatable {
    let id: UUID
    let text: String
    /// 归一化包围盒（Vision 坐标系，左上原点）
    let boundingBox: CGRect

    init(id: UUID = UUID(), text: String, boundingBox: CGRect = .zero) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// OCR 文本清洗（纯逻辑，可测）：去空白、去空行、去连续重复、限长
enum VisionOCRTextProcessor {
    static let maxResultLength = 2_000

    /// 单行清洗：折叠空白并去首尾
    static func normalizeLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 多行清洗：空行丢弃、连续重复行去重（同帧噪声）、结果限长
    static func normalizedText(
        from lines: [String],
        maxLength: Int = maxResultLength
    ) -> String {
        var cleaned: [String] = []
        for raw in lines {
            let line = normalizeLine(raw)
            guard !line.isEmpty else { continue }
            if cleaned.last == line { continue }
            cleaned.append(line)
            if cleaned.joined(separator: "\n").count >= maxLength { break }
        }
        let joined = cleaned.joined(separator: "\n")
        if joined.count <= maxLength { return joined }
        return String(joined.prefix(maxLength))
    }

    /// 镜片展示用单段文本：换行压成空格，超长截断加省略号（眼镜单屏约 120 字符）
    static func displayText(from text: String, maxLength: Int = 120) -> String {
        let cleaned = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if cleaned.count <= maxLength { return cleaned }
        return String(cleaned.prefix(maxLength)) + "…"
    }
}

/// 端侧 OCR 服务（Apple Vision，离线可用）
enum VisionOCRService {
    /// 对图像执行准确模式识别，返回按阅读顺序排列的文本行
    static func recognizeText(in image: UIImage) async -> [VisionOCRLine] {
        guard let cgImage = image.cgImage else { return [] }
        return await recognizeText(in: cgImage)
    }

    static func recognizeText(in cgImage: CGImage) async -> [VisionOCRLine] {
        await Task.detached(priority: .userInitiated) { () -> [VisionOCRLine] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return VisionOCRLine(
                    text: candidate.string,
                    boundingBox: observation.boundingBox
                )
            }
        }.value
    }

    /// 识别并清洗为单段文本；无文字返回空串
    static func recognizedText(in image: UIImage) async -> String {
        let lines = await recognizeText(in: image)
        return VisionOCRTextProcessor.normalizedText(from: lines.map(\.text))
    }
}

/// 最近一次取词结果（内存态，供镜片「翻译」动作与跨页复用）
enum AgentVisionOCRStore {
    static private(set) var lastText: String?
    static private(set) var lastDate: Date?

    /// 最近一次取词结果（只读，供跨页复用 / 清理验证）
    static var latestText: String? { lastText }

    static func set(_ text: String) {
        lastText = text
        lastDate = Date()
    }

    static func clear() {
        lastText = nil
        lastDate = nil
    }
}
