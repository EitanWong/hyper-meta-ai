/*
 * Vision Scene Service
 * 端侧场景理解：基于 Apple Vision 的离线场景分类 + 动物识别 + 物体识别（免费、无网络、无 API Key），
 * 语音说「看看这是什么 / 识别物体」或镜片「Scene」动作即可识别并播报，结果可作为上下文发给 Agent 追问。
 * 注：iOS Vision 无 VNRecognizeObjectsRequest（该请求仅 macOS 可用），物体识别复用
 * VNClassifyImageRequest 的 ImageNet 分类法（以物体类为主），剔除场景词 / 动物词后即物体名。
 */

import Foundation
import UIKit
import Vision

/// 一条场景 / 物体识别结果
struct VisionSceneItem: Identifiable, Equatable {
    let id: UUID
    /// 识别标签（Vision 英文分类法，如 Restaurant / Cat）
    let identifier: String
    /// 置信度 0~1
    let confidence: Float
    /// 归一化包围盒（场景分类为 .zero；动物识别为检测框）
    let boundingBox: CGRect

    init(id: UUID = UUID(), identifier: String, confidence: Float, boundingBox: CGRect = .zero) {
        self.id = id
        self.identifier = identifier
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// 一帧画面的识别结果
struct VisionSceneResult: Equatable {
    var classifications: [VisionSceneItem] = []
    var animals: [VisionSceneItem] = []
    var objects: [VisionSceneItem] = []

    var isEmpty: Bool {
        classifications.isEmpty && animals.isEmpty && objects.isEmpty
    }
}

/// 场景识别文本整理（纯逻辑，可测）
enum VisionSceneTextProcessor {
    static let maxDisplayLength = 120

    /// 场景标签：按置信度降序过滤并取前 maxCount 个
    static func sceneTokens(
        from result: VisionSceneResult,
        maxCount: Int = 3,
        minConfidence: Float = 0.25
    ) -> [String] {
        result.classifications
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxCount)
            .map(\.identifier)
    }

    /// 动物标签：按置信度降序、去重（同帧多次检出同一种动物只报一次）
    static func animalTokens(
        from result: VisionSceneResult,
        minConfidence: Float = 0.4
    ) -> [String] {
        var seen: Set<String> = []
        return result.animals
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .compactMap { item -> String? in
                guard seen.insert(item.identifier).inserted else { return nil }
                return item.identifier
            }
    }

    /// 场景词排除集：这些标识由场景总结通道报告，不再作为物体重复播报。
    static let objectSceneExclusion: Set<String> = [
        "Restaurant", "Seashore", "Alp", "Volcano", "Cliff", "Lakeside",
        "Valley", "Coral reef", "Geyser", "Promontory"
    ]

    /// 动物类排除集：这些标识由动物识别通道报告，不再作为物体重复播报。
    static let objectAnimalExclusion: Set<String> = [
        "Cat", "Dog", "Bird", "Horse", "Sheep", "Cow",
        "Elephant", "Bear", "Zebra", "Giraffe"
    ]

    /// 从分类观察中推导物体候选：置信度 ≥ minConfidence，
    /// 剔除场景词 / 动物词 / 已入场景总结（sceneTop）的标识（纯逻辑，可测）。
    static func objectCandidates(
        from classifications: [VisionSceneItem],
        sceneTop: [String],
        minConfidence: Float = 0.4
    ) -> [VisionSceneItem] {
        let sceneTopSet = Set(sceneTop)
        return classifications.filter { item in
            guard item.confidence >= minConfidence else { return false }
            let id = item.identifier
            guard !objectSceneExclusion.contains(id) else { return false }
            guard !objectAnimalExclusion.contains(id) else { return false }
            return !sceneTopSet.contains(id)
        }
    }

    /// 物体标签：按置信度降序、去重，取前 maxCount 个
    static func objectTokens(
        from result: VisionSceneResult,
        maxCount: Int = 3,
        minConfidence: Float = 0.4
    ) -> [String] {
        var seen: Set<String> = []
        return result.objects
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .compactMap { item -> String? in
                guard seen.insert(item.identifier).inserted else { return nil }
                return item.identifier
            }
            .prefix(maxCount)
            .map { $0 }
    }

    /// 物体标签纯文本（工具调用用，如 "Mug, Laptop"）
    static func objectSummary(
        from result: VisionSceneResult,
        maxCount: Int = 5,
        minConfidence: Float = 0.4
    ) -> String {
        objectTokens(from: result, maxCount: maxCount, minConfidence: minConfidence)
            .joined(separator: ", ")
    }

    /// 本地化的一句话总结：「像是餐厅，画面里有猫，还看到了水杯」；什么都没认出返回空串
    static func summaryText(from result: VisionSceneResult) -> String {
        let scenes = sceneTokens(from: result).joined(separator: ", ")
        let animals = animalTokens(from: result).joined(separator: ", ")
        let objects = objectTokens(from: result).joined(separator: ", ")
        switch (!scenes.isEmpty, !animals.isEmpty, !objects.isEmpty) {
        case (true, true, true):
            return String(format: "agent.vision.scene.summary.all".localized, scenes, animals, objects)
        case (true, true, false):
            return String(format: "agent.vision.scene.summary".localized, scenes, animals)
        case (true, false, true):
            return String(format: "agent.vision.scene.summary.sceneobjects".localized, scenes, objects)
        case (true, false, false):
            return String(format: "agent.vision.scene.summary.sceneonly".localized, scenes)
        case (false, true, true):
            return String(format: "agent.vision.scene.summary.animalobjects".localized, animals, objects)
        case (false, true, false):
            return String(format: "agent.vision.scene.summary.animalonly".localized, animals)
        case (false, false, true):
            return String(format: "agent.vision.scene.summary.objectsonly".localized, objects)
        case (false, false, false):
            return ""
        }
    }

    /// 镜片单行展示：总结压成一行并截断
    static func displayText(from result: VisionSceneResult) -> String {
        VisionOCRTextProcessor.displayText(from: summaryText(from: result), maxLength: maxDisplayLength)
    }
}

/// 语音指令「看看这是什么 / 识别场景」本地拦截（保守整句匹配，避免误吞普通对话）
enum AgentVisionSceneCommandParser {
    static let phrases = ["看看这是什么", "看看场景", "识别场景", "画面里有什么", "看看", "这是什么",
                          "识别物体", "有什么东西", "画面里有什么东西"]

    /// 整句匹配（允许尾部语气词「呀 / 啊 / 呢 / 吧」），避免「看看这个怎么用」被误判
    static func parse(_ text: String) -> Bool {
        var stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = stripped.last, "呀啊呢吧".contains(last) {
            stripped.removeLast()
        }
        guard !stripped.isEmpty else { return false }
        return phrases.contains(stripped)
    }
}

/// 端侧场景识别服务（Apple Vision，离线可用）
enum VisionSceneService {
    /// 场景分类 + 动物识别，返回结构化结果
    static func analyze(_ image: UIImage) async -> VisionSceneResult {
        guard let cgImage = image.cgImage else { return VisionSceneResult() }
        return await analyze(cgImage)
    }

    /// 直接分析 CVPixelBuffer（避免 CGImage 转换，供实时帧管线使用）
    static func analyze(_ pixelBuffer: CVPixelBuffer) async -> VisionSceneResult {
        await Task.detached(priority: .userInitiated) { () -> VisionSceneResult in
            let classify = VNClassifyImageRequest()
            classify.revision = VNClassifyImageRequestRevision2
            let animals = VNRecognizeAnimalsRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            return Self.runRequests(classify, animals, handler: handler)
        }.value
    }

    static func analyze(_ cgImage: CGImage) async -> VisionSceneResult {
        await Task.detached(priority: .userInitiated) { () -> VisionSceneResult in
            let classify = VNClassifyImageRequest()
            classify.revision = VNClassifyImageRequestRevision2
            let animals = VNRecognizeAnimalsRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            return Self.runRequests(classify, animals, handler: handler)
        }.value
    }

    private static func runRequests(
        _ classify: VNClassifyImageRequest,
        _ animals: VNRecognizeAnimalsRequest,
        handler: VNImageRequestHandler
    ) -> VisionSceneResult {
            do {
                try handler.perform([classify, animals])
            } catch {
                return VisionSceneResult()
            }
            let classifications = (classify.results ?? []).map { observation in
                VisionSceneItem(identifier: observation.identifier, confidence: observation.confidence)
            }
            let detectedAnimals = (animals.results ?? []).compactMap { observation -> VisionSceneItem? in
                guard let observation = observation as? VNRecognizedObjectObservation,
                      let label = observation.labels.first else { return nil }
                return VisionSceneItem(
                    identifier: label.identifier,
                    confidence: label.confidence,
                    boundingBox: observation.boundingBox
                )
            }
            // 物体识别复用同一分类结果：剔除场景词 / 动物词 / 已入场景总结的标识
            let sceneTop = classifications
                .filter { $0.confidence >= 0.25 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(3)
                .map(\.identifier)
            let detectedObjects = VisionSceneTextProcessor.objectCandidates(
                from: classifications,
                sceneTop: sceneTop
            )
            return VisionSceneResult(
                classifications: classifications,
                animals: detectedAnimals,
                objects: detectedObjects
            )
    }
}

/// 最近一次场景识别总结（内存态，供跨页复用与后续追问）
enum AgentVisionSceneStore {
    static private(set) var lastSummary: String?
    static private(set) var lastDate: Date?

    /// 最近一次场景识别总结（只读，供跨页复用 / 清理验证）
    static var latestSummary: String? { lastSummary }

    static func set(_ summary: String) {
        lastSummary = summary
        lastDate = Date()
    }

    static func clear() {
        lastSummary = nil
        lastDate = nil
    }
}
