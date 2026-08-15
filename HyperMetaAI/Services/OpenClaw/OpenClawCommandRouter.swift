/*
 * OpenClaw Command Router
 * 将 Gateway 的 invoke 命令路由到 DAT SDK
 * 支持: camera.snap, camera.list, device.status, device.info
 */

import Foundation
import UIKit
import MWDATCore

@MainActor
class OpenClawCommandRouter {
    private weak var streamViewModel: StreamSessionViewModel?
    private let nodeId: String
    private var isCapturingCamera = false

    init(streamViewModel: StreamSessionViewModel, nodeId: String) {
        self.streamViewModel = streamViewModel
        self.nodeId = nodeId
    }

    // MARK: - Command Dispatch

    func handleCommand(_ request: OpenClawNodeInvokeRequest) async -> OpenClawNodeInvokeResult {
        switch request.command {
        case "camera.snap":
            return await handleCameraSnap(request)
        case "camera.list":
            return handleCameraList(request)
        case "device.status":
            return handleDeviceStatus(request)
        case "device.info":
            return handleDeviceInfo(request)
        case "vision.ocr":
            return await handleVisionOCR(request)
        case "vision.scene":
            return await handleVisionScene(request)
        case "vision.objects":
            return await handleVisionObjects(request)
        default:
            return makeError(id: request.id, code: "UNKNOWN_COMMAND",
                           message: "Unsupported command: \(request.command)")
        }
    }

    // MARK: - vision.ocr / vision.scene

    /// 端侧取词（Apple Vision OCR，离线免费）：抓一帧眼镜画面并识别文字
    private func handleVisionOCR(_ request: OpenClawNodeInvokeRequest) async -> OpenClawNodeInvokeResult {
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            return makeError(id: request.id, code: "REVOKED",
                           message: "Vision capture is revoked by the user")
        }
        guard let frame = await captureVisionFrame() else {
            return makeError(id: request.id, code: "NO_FRAME",
                           message: "No video frame available")
        }
        let outcome = await OpenClawVisionCommandRunner.run(kind: .ocr, frame: frame)
        switch outcome {
        case .success(let text):
            return OpenClawNodeInvokeResult(
                id: request.id,
                nodeId: nodeId,
                ok: true,
                payload: ["text": .string(text)],
                error: nil
            )
        case .failure(.noResult):
            return makeError(id: request.id, code: "NO_TEXT",
                           message: "No text recognized in the view")
        }
    }

    /// 端侧场景识别（Apple Vision 分类 + 动物识别，离线免费）：抓一帧眼镜画面并理解场景
    private func handleVisionScene(_ request: OpenClawNodeInvokeRequest) async -> OpenClawNodeInvokeResult {
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            return makeError(id: request.id, code: "REVOKED",
                           message: "Vision capture is revoked by the user")
        }
        guard let frame = await captureVisionFrame() else {
            return makeError(id: request.id, code: "NO_FRAME",
                           message: "No video frame available")
        }
        let outcome = await OpenClawVisionCommandRunner.run(kind: .scene, frame: frame)
        switch outcome {
        case .success(let text):
            return OpenClawNodeInvokeResult(
                id: request.id,
                nodeId: nodeId,
                ok: true,
                payload: ["text": .string(text)],
                error: nil
            )
        case .failure(.noResult):
            return makeError(id: request.id, code: "NO_RESULT",
                           message: "Could not recognize the scene")
        }
    }

    /// 端侧物体识别（Apple Vision 物体检测，离线免费）：抓一帧眼镜画面并列出具体物体
    private func handleVisionObjects(_ request: OpenClawNodeInvokeRequest) async -> OpenClawNodeInvokeResult {
        guard !AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id) else {
            return makeError(id: request.id, code: "REVOKED",
                           message: "Vision capture is revoked by the user")
        }
        guard let frame = await captureVisionFrame() else {
            return makeError(id: request.id, code: "NO_FRAME",
                           message: "No video frame available")
        }
        let outcome = await OpenClawVisionCommandRunner.run(kind: .objects, frame: frame)
        switch outcome {
        case .success(let text):
            return OpenClawNodeInvokeResult(
                id: request.id,
                nodeId: nodeId,
                ok: true,
                payload: ["text": .string(text)],
                error: nil
            )
        case .failure(.noResult):
            return makeError(id: request.id, code: "NO_RESULT",
                           message: "Could not recognize objects in the view")
        }
    }

    /// 抓取一帧眼镜画面（vision 命令共用；与 camera.snap 同源）
    private func captureVisionFrame() async -> UIImage? {
        guard let vm = streamViewModel else { return nil }
        let streamReady = await vm.acquireStream(for: .openClawRemote)
        guard streamReady else {
            await vm.releaseStream(for: .openClawRemote)
            return nil
        }
        defer {
            Task { @MainActor in
                await vm.releaseStream(for: .openClawRemote)
            }
        }
        let frameDeadline = Date().addingTimeInterval(2)
        while vm.currentVideoFrame == nil, Date() < frameDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return vm.currentVideoFrame
    }

    // MARK: - camera.snap

    private func handleCameraSnap(_ request: OpenClawNodeInvokeRequest) async -> OpenClawNodeInvokeResult {
        guard !isCapturingCamera else {
            return makeError(id: request.id, code: "BUSY", message: "A camera capture is already in progress")
        }
        isCapturingCamera = true
        defer { isCapturingCamera = false }

        guard let vm = streamViewModel else {
            return makeError(id: request.id, code: "NOT_READY", message: "Stream not initialized")
        }

        let streamReady = await vm.acquireStream(for: .openClawRemote)
        guard streamReady else {
            await vm.releaseStream(for: .openClawRemote)
            return makeError(id: request.id, code: "STREAM_FAILED",
                           message: "Could not start camera stream")
        }
        defer {
            Task { @MainActor in
                await vm.releaseStream(for: .openClawRemote)
            }
        }

        // A stream may report ready just before its first decoded frame arrives.
        // Wait briefly so a newly acquired camera does not produce a spurious
        // NO_FRAME response.
        let frameDeadline = Date().addingTimeInterval(2)
        while vm.currentVideoFrame == nil, Date() < frameDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Grab current frame
        guard let frame = vm.currentVideoFrame else {
            return makeError(id: request.id, code: "NO_FRAME",
                           message: "No video frame available")
        }

        // Parse params
        let params = CameraSnapParams(from: request.params)

        // Resize if needed
        let image: UIImage
        if let maxWidth = Optional(params.maxWidth), maxWidth > 0,
           frame.size.width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / frame.size.width
            let newSize = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in frame.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            image = frame
        }

        // JPEG encode
        let quality = max(0.1, min(1.0, params.quality))
        guard let jpegData = image.jpegData(compressionQuality: quality) else {
            return makeError(id: request.id, code: "ENCODE_FAILED",
                           message: "Failed to encode JPEG")
        }

        let base64 = jpegData.base64EncodedString()

        print("[OpenClaw] camera.snap: \(Int(image.size.width))x\(Int(image.size.height)), \(jpegData.count) bytes")

        return OpenClawNodeInvokeResult(
            id: request.id,
            nodeId: nodeId,
            ok: true,
            payload: [
                "format": .string("jpg"),
                "base64": .string(base64),
                "width": .int(Int(image.size.width)),
                "height": .int(Int(image.size.height))
            ],
            error: nil
        )
    }

    // MARK: - camera.list

    private func handleCameraList(_ request: OpenClawNodeInvokeRequest) -> OpenClawNodeInvokeResult {
        let hasDevice = streamViewModel?.hasActiveDevice ?? false

        let cameras: [[String: AnyCodableValue]] = hasDevice ? [
            [
                "id": .string("rayban-main"),
                "name": .string("Ray-Ban Meta Camera"),
                "facing": .string("front"),
                "available": .bool(true)
            ]
        ] : []

        return OpenClawNodeInvokeResult(
            id: request.id,
            nodeId: nodeId,
            ok: true,
            payload: ["cameras": .array(cameras.map { .dictionary($0) })],
            error: nil
        )
    }

    // MARK: - device.status

    private func handleDeviceStatus(_ request: OpenClawNodeInvokeRequest) -> OpenClawNodeInvokeResult {
        let vm = streamViewModel

        var status: [String: AnyCodableValue] = [
            "deviceConnected": .bool(vm?.hasActiveDevice ?? false),
            "isStreaming": .bool(vm?.isStreaming ?? false),
            "streamStatus": .string("\(vm?.streamingStatus ?? .stopped)")
        ]

        if vm?.isStreaming == true {
            status["hasVideoFrame"] = .bool(vm?.currentVideoFrame != nil)
        }

        return OpenClawNodeInvokeResult(
            id: request.id,
            nodeId: nodeId,
            ok: true,
            payload: status,
            error: nil
        )
    }

    // MARK: - device.info

    private func handleDeviceInfo(_ request: OpenClawNodeInvokeRequest) -> OpenClawNodeInvokeResult {
        return OpenClawNodeInvokeResult(
            id: request.id,
            nodeId: nodeId,
            ok: true,
            payload: [
                "deviceType": .string("Ray-Ban Meta"),
                "appName": .string(AppIdentity.displayName),
                "appVersion": .string(appVersion),
                "sdkVersion": .string("0.8.0"),
                "platform": .string("iOS"),
                "osVersion": .string(UIDevice.current.systemVersion)
            ],
            error: nil
        )
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private func makeError(id: String, code: String, message: String) -> OpenClawNodeInvokeResult {
        return OpenClawNodeInvokeResult(
            id: id,
            nodeId: nodeId,
            ok: false,
            payload: nil,
            error: OpenClawError(code: code, message: message)
        )
    }
}

/// OpenClaw vision 命令的端侧执行（纯逻辑 + Apple Vision，可测）：
/// 在给定帧上运行取词 / 场景识别，结果文本回传网关并存入跨页复用存储。
enum OpenClawVisionCommandRunner {
    enum Kind {
        case ocr
        case scene
        case objects
    }

    enum Failure: Error, Equatable {
        case noResult
    }

    static func run(kind: Kind, frame: UIImage?) async -> Result<String, Failure> {
        guard let frame else { return .failure(.noResult) }
        switch kind {
        case .ocr:
            let text = await VisionOCRService.recognizedText(in: frame)
            guard !text.isEmpty else { return .failure(.noResult) }
            AgentVisionOCRStore.set(text)
            return .success(text)
        case .scene:
            let result = await VisionSceneService.analyze(frame)
            let summary = VisionSceneTextProcessor.summaryText(from: result)
            guard !summary.isEmpty else { return .failure(.noResult) }
            AgentVisionSceneStore.set(summary)
            return .success(summary)
        case .objects:
            let result = await VisionSceneService.analyze(frame)
            let summary = VisionSceneTextProcessor.objectSummary(from: result)
            guard !summary.isEmpty else { return .failure(.noResult) }
            return .success(summary)
        }
    }
}
