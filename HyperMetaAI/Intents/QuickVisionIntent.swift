/*
 * Quick Vision Intent
 * App Intent - 支持 Siri 和快捷指令触发快速识图
 *
 * 支持的模式：
 * - 默认模式：通用图像描述
 * - 健康识图：分析食品健康程度
 * - 盲人模式：为视障用户描述环境
 * - 阅读模式：识别并朗读文字
 * - 翻译模式：识别并翻译文字
 * - 百科模式：百科知识介绍
 * - 自定义：使用自定义提示词
 */

import AppIntents
import UIKit
import SwiftUI

// MARK: - Quick Vision Intent (Default Mode)

@available(iOS 16.0, *)
struct QuickVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "快速识图"
    static var description = IntentDescription("使用 Ray-Ban Meta 眼镜拍照并识别图像内容")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "自定义提示")
    var customPrompt: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(
            .standard,
            customPrompt: customPrompt,
            deferUntilStreamConfigured: true
        )
        return formatResult(manager)
    }
}

// MARK: - Health Mode Intent

@available(iOS 16.0, *)
struct QuickVisionHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "健康识图"
    static var description = IntentDescription("分析食品/饮料的健康程度")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.health, deferUntilStreamConfigured: true)
        return formatResult(manager)
    }
}

// MARK: - Blind Mode Intent

@available(iOS 16.0, *)
struct QuickVisionBlindIntent: AppIntent {
    static var title: LocalizedStringResource = "环境描述"
    static var description = IntentDescription("为视障用户详细描述眼前的环境")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.blind, deferUntilStreamConfigured: true)
        return formatResult(manager)
    }
}

// MARK: - Reading Mode Intent

@available(iOS 16.0, *)
struct QuickVisionReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "朗读文字"
    static var description = IntentDescription("识别并朗读图片中的文字内容")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.reading, deferUntilStreamConfigured: true)
        return formatResult(manager)
    }
}

// MARK: - Translation Mode Intent

@available(iOS 16.0, *)
struct QuickVisionTranslateIntent: AppIntent {
    static var title: LocalizedStringResource = "翻译文字"
    static var description = IntentDescription("识别并翻译图片中的外语文字")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.translate, deferUntilStreamConfigured: true)
        return formatResult(manager)
    }
}

// MARK: - Encyclopedia Mode Intent

@available(iOS 16.0, *)
struct QuickVisionEncyclopediaIntent: AppIntent {
    static var title: LocalizedStringResource = "百科识别"
    static var description = IntentDescription("识别物体并提供百科知识介绍")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.encyclopedia, deferUntilStreamConfigured: true)
        return formatResult(manager)
    }
}

// MARK: - Helper Function

@available(iOS 16.0, *)
@MainActor
private func formatResult(_ manager: QuickVisionManager) -> some IntentResult & ProvidesDialog {
    if manager.hasPendingRequest {
        return .result(dialog: "正在打开应用并准备识图")
    } else if let result = manager.lastResult {
        return .result(dialog: "识别完成：\(result)")
    } else if let error = manager.errorMessage {
        return .result(dialog: "识别失败：\(error)")
    } else {
        return .result(dialog: "识别完成")
    }
}

// MARK: - App Shortcuts Provider

@available(iOS 16.0, *)
struct HyperMetaAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 默认识图
        AppShortcut(
            intent: QuickVisionIntent(),
            phrases: [
                "用 \(.applicationName) 识图",
                "用 \(.applicationName) 看看这是什么",
                "\(.applicationName) 快速识图",
                "\(.applicationName) 拍照识别"
            ],
            shortTitle: "快速识图",
            systemImageName: "eye.circle.fill"
        )

        // 健康识图
        AppShortcut(
            intent: QuickVisionHealthIntent(),
            phrases: [
                "用 \(.applicationName) 分析健康",
                "\(.applicationName) 健康识图",
                "\(.applicationName) 这个食物健康吗"
            ],
            shortTitle: "健康识图",
            systemImageName: "heart.circle.fill"
        )

        // 盲人模式
        AppShortcut(
            intent: QuickVisionBlindIntent(),
            phrases: [
                "用 \(.applicationName) 描述环境",
                "\(.applicationName) 看看周围有什么",
                "\(.applicationName) 帮我看看前面"
            ],
            shortTitle: "环境描述",
            systemImageName: "figure.walk.circle.fill"
        )

        // 阅读模式
        AppShortcut(
            intent: QuickVisionReadingIntent(),
            phrases: [
                "用 \(.applicationName) 朗读文字",
                "\(.applicationName) 读一下这个",
                "\(.applicationName) 帮我读文字"
            ],
            shortTitle: "朗读文字",
            systemImageName: "text.viewfinder"
        )

        // 翻译模式
        AppShortcut(
            intent: QuickVisionTranslateIntent(),
            phrases: [
                "用 \(.applicationName) 翻译",
                "\(.applicationName) 翻译这个",
                "\(.applicationName) 这个是什么意思"
            ],
            shortTitle: "翻译文字",
            systemImageName: "character.bubble.fill"
        )

        // 实时对话
        AppShortcut(
            intent: LiveAIIntent(),
            phrases: [
                "用 \(.applicationName) 实时对话",
                "\(.applicationName) 实时对话",
                "开始 \(.applicationName) 实时对话",
                "\(.applicationName) 开始对话"
            ],
            shortTitle: "实时对话",
            systemImageName: "brain.head.profile"
        )

        // 语音对话（Agent 统一输入入口）
        AppShortcut(
            intent: VoiceAssistantAppIntent(),
            phrases: [
                "跟 \(.applicationName) 说话",
                "用 \(.applicationName) 开始语音对话",
                "Talk to \(.applicationName)",
                "Start a voice conversation with \(.applicationName)"
            ],
            shortTitle: "语音对话",
            systemImageName: "waveform.circle.fill"
        )

        // 问 JARVIS（后台单轮问答，Siri 直接说即可，无需配置快捷指令）
        AppShortcut(
            intent: AgentAskAppIntent(),
            phrases: [
                "问 \(.applicationName)",
                "Ask \(.applicationName)",
                "问 \(.applicationName) 个问题",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "问 JARVIS",
            systemImageName: "sparkles"
        )

        // 查询任务进度
        AppShortcut(
            intent: VoiceTaskStatusIntent(),
            phrases: [
                "查一下 \(.applicationName) 的任务进度",
                "Check task progress with \(.applicationName)"
            ],
            shortTitle: "任务进度",
            systemImageName: "checklist"
        )

        // 停止实时对话
        AppShortcut(
            intent: StopLiveAIIntent(),
            phrases: [
                "\(.applicationName) 停止实时对话",
                "停止 \(.applicationName) 实时对话",
                "\(.applicationName) 结束对话"
            ],
            shortTitle: "停止实时对话",
            systemImageName: "stop.circle.fill"
        )

    }
}

// MARK: - Quick Vision Manager

@MainActor
class QuickVisionManager: ObservableObject {
    static let shared = QuickVisionManager()

    @Published var isProcessing = false
    @Published var lastResult: String?
    @Published var errorMessage: String?
    @Published var lastImage: UIImage?
    @Published var lastMode: QuickVisionMode = .standard

    private(set) weak var streamViewModel: StreamSessionViewModel?
    private let tts = TTSService.shared
    private var pendingRequest: PendingRequest?
    private var processingGeneration = 0
    private var activeLeaseOwners: Set<StreamSessionOwner> = []

    var hasPendingRequest: Bool {
        pendingRequest != nil
    }

    private struct PendingRequest {
        let mode: QuickVisionMode
        let customPrompt: String?
    }

    private init() {}

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        streamViewModel = viewModel
        resumePendingRequestIfNeeded()
    }

    /// 使用指定模式执行快速识图
    func performQuickVisionWithMode(
        _ mode: QuickVisionMode,
        customPrompt: String? = nil,
        deferUntilStreamConfigured: Bool = false
    ) async {
        guard !isProcessing else {
            print("⚠️ [QuickVision] Already processing")
            return
        }

        guard let streamViewModel = streamViewModel else {
            if deferUntilStreamConfigured {
                pendingRequest = PendingRequest(mode: mode, customPrompt: customPrompt)
                print("[QuickVision] Queued request until the shared stream is configured")
                return
            }
            print("❌ [QuickVision] StreamViewModel not set")
            tts.speak("识图功能未初始化，请先打开应用")
            return
        }

        pendingRequest = nil
        processingGeneration &+= 1
        let generation = processingGeneration
        let leaseOwner = StreamSessionOwner.quickVisionRequest(UUID())
        isProcessing = true
        defer {
            if processingGeneration == generation {
                isProcessing = false
            }
        }
        errorMessage = nil
        lastResult = nil
        lastImage = nil
        lastMode = mode

        // 获取 API Key
        guard let apiKey = APIKeyManager.shared.getAPIKey(), !apiKey.isEmpty else {
            errorMessage = "请先在设置中配置 API Key"
            tts.speak("请先在设置中配置 API Key")
            return
        }

        // 播报开始
        tts.speak("正在识别", apiKey: apiKey)

        // 获取提示词
        let prompt = customPrompt ?? QuickVisionModeManager.shared.getPrompt(for: mode)
        var holdsCameraLease = false

        do {
            guard isCurrentProcessing(generation) else { return }

            // The shared session coordinator owns startup, permission checks,
            // readiness waiting, and recovery. Quick Vision only holds its own
            // lease while capturing a frame.
            activeLeaseOwners.insert(leaseOwner)
            let streamReady = await streamViewModel.acquireStream(for: leaseOwner)
            holdsCameraLease = true
            guard streamReady else {
                throw QuickVisionError.streamNotReady
            }
            guard isCurrentProcessing(generation) else {
                await releaseCameraLease(leaseOwner, from: streamViewModel)
                holdsCameraLease = false
                return
            }

            // 2. 等待流稳定
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            guard isCurrentProcessing(generation) else {
                await releaseCameraLease(leaseOwner, from: streamViewModel)
                holdsCameraLease = false
                return
            }

            // 3. 清除之前的照片，然后拍照
            streamViewModel.dismissPhotoPreview()
            print("📸 [QuickVision] Capturing photo...")
            streamViewModel.capturePhoto()

            // 4. 等待照片捕获完成（最多 3 秒）
            var photoWait = 0
            while streamViewModel.capturedPhoto == nil && photoWait < 30 {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                guard isCurrentProcessing(generation) else {
                    await releaseCameraLease(leaseOwner, from: streamViewModel)
                    holdsCameraLease = false
                    return
                }
                photoWait += 1
            }

            // A disconnect can arrive between capture requests. Never use a
            // queued frame from the prior glasses session as a fallback.
            guard isCurrentProcessing(generation), streamViewModel.cameraCaptureState.isStreaming else {
                await releaseCameraLease(leaseOwner, from: streamViewModel)
                holdsCameraLease = false
                return
            }

            // 如果 SDK capturePhoto 失败，使用当前视频帧作为备选
            let photo: UIImage
            if let capturedPhoto = streamViewModel.capturedPhoto {
                photo = capturedPhoto
                print("📸 [QuickVision] Using SDK captured photo")
            } else if let videoFrame = streamViewModel.currentVideoFrame {
                photo = videoFrame
                print("📸 [QuickVision] SDK capturePhoto failed, using video frame as fallback")
            } else {
                print("❌ [QuickVision] No photo or video frame available")
                throw QuickVisionError.frameTimeout
            }

            print("📸 [QuickVision] Photo captured: \(photo.size.width)x\(photo.size.height)")

            // 保存图片用于历史记录
            guard isCurrentProcessing(generation) else {
                await releaseCameraLease(leaseOwner, from: streamViewModel)
                holdsCameraLease = false
                return
            }
            lastImage = photo

            // Release just this feature's lease before network inference and
            // TTS. Other active features keep the glasses stream alive.
            await releaseCameraLease(leaseOwner, from: streamViewModel)
            holdsCameraLease = false
            guard isCurrentProcessing(generation) else { return }

            // 5. 调用识图 API
            let service = QuickVisionService(apiKey: apiKey)
            let result = try await service.analyzeImage(photo, customPrompt: prompt)
            guard isCurrentProcessing(generation) else { return }

            // 6. 保存结果
            lastResult = result

            // 7. 保存到历史记录
            saveToHistory(mode: mode, prompt: prompt, result: result, image: photo)

            // 8. TTS 播报结果
            tts.speak(result, apiKey: apiKey)

            print("✅ [QuickVision] Complete: \(result)")

        } catch let error as QuickVisionError {
            if isCurrentProcessing(generation) {
                errorMessage = error.localizedDescription
                print("❌ [QuickVision] QuickVisionError: \(error)")
                tts.speak(error.localizedDescription, apiKey: apiKey)
            }
        } catch {
            if isCurrentProcessing(generation) {
                errorMessage = error.localizedDescription
                print("❌ [QuickVision] Error: \(error)")
                tts.speak("识别失败，\(error.localizedDescription)", apiKey: apiKey)
            }
        }

        if holdsCameraLease {
            await releaseCameraLease(leaseOwner, from: streamViewModel)
        }
    }

    /// 执行快速识图（使用当前设置的模式）
    func performQuickVision(customPrompt: String? = nil) async {
        await performQuickVisionWithMode(QuickVisionModeManager.staticCurrentMode, customPrompt: customPrompt)
    }

    /// 执行快速识图（从快捷指令/Siri 触发）
    func performQuickVisionFromIntent(customPrompt: String? = nil) async {
        await performQuickVisionWithMode(
            QuickVisionModeManager.staticCurrentMode,
            customPrompt: customPrompt,
            deferUntilStreamConfigured: true
        )
    }

    /// 保存识图结果到历史记录
    private func saveToHistory(mode: QuickVisionMode, prompt: String, result: String, image: UIImage) {
        let record = QuickVisionRecord(
            mode: mode,
            prompt: prompt,
            result: result,
            thumbnail: image
        )
        QuickVisionStorage.shared.saveRecord(record)
        print("💾 [QuickVision] Record saved to history")
    }

    /// 停止视频流（在页面关闭时调用）
    func stopStream() async {
        let leaseOwners = activeLeaseOwners
        activeLeaseOwners.removeAll()

        guard let streamViewModel else { return }
        for owner in leaseOwners {
            await streamViewModel.releaseStream(for: owner)
        }
    }

    /// Invalidates an in-flight recognition when its owning screen disappears.
    /// Network completion can still arrive, but it can no longer update state,
    /// speak a result, or acquire/release another camera session.
    func cancelCurrentRequest() {
        processingGeneration &+= 1
        pendingRequest = nil
        isProcessing = false
        tts.stop()
    }

    /// 手动触发快速识图（从 UI 调用）
    func triggerQuickVision(customPrompt: String? = nil) {
        let generation = processingGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentProcessing(generation) else { return }
            await self.performQuickVision(customPrompt: customPrompt)
        }
    }

    /// 手动触发指定模式的快速识图（从 UI 调用）
    func triggerQuickVisionWithMode(_ mode: QuickVisionMode) {
        let generation = processingGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentProcessing(generation) else { return }
            await self.performQuickVisionWithMode(mode)
        }
    }

    private func resumePendingRequestIfNeeded() {
        guard let pendingRequest, streamViewModel != nil, !isProcessing else { return }

        self.pendingRequest = nil
        let generation = processingGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isCurrentProcessing(generation) else { return }
            await self.performQuickVisionWithMode(
                pendingRequest.mode,
                customPrompt: pendingRequest.customPrompt
            )
        }
    }

    private func releaseCameraLease(
        _ owner: StreamSessionOwner,
        from streamViewModel: StreamSessionViewModel
    ) async {
        activeLeaseOwners.remove(owner)
        await streamViewModel.releaseStream(for: owner)
    }

    private func isCurrentProcessing(_ generation: Int) -> Bool {
        processingGeneration == generation
    }
}
