/*
 * Local Brain Service
 * 端侧离线 AI 兜底（Foundation Models，iOS 26+）：
 * 未配置 Agent 网关时，直播标题润色 / 场景分析改用 Apple Intelligence
 * 端侧模型离线生成（数据不出设备）。协议注入可测；低版本系统与不支持
 * 设备自动降级，UI 保持原有「未配置网关」提示。
 */

import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 端侧 AI 设置（纯逻辑，可测）：总开关默认开启，UserDefaults 持久化
enum LocalBrainSettings {
    static let key = "local_brain.enabled"

    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 端侧模型系统指令（纯逻辑，可测）：中立、简洁、跟随请求语言
enum LocalBrainInstructions {
    static let text = "你是一个直播助手，只输出用户要求的文本，不要寒暄，不要添加编号或额外说明，语言跟随用户请求。"
}

/// 端侧离线 AI 抽象（协议注入，可测）
protocol LocalBrainServicing: Sendable {
    /// 当前设备是否可用（开关开启 + iOS 26+ + Apple Intelligence 就绪 + 语言支持）
    var isAvailable: Bool { get }
    /// 单轮问答；不可用时返回 nil
    func respond(to prompt: String) async throws -> String?
}

/// 本地兜底执行器（纯逻辑，可测）：
/// 超时 / 异常统一按回调解耦，保证 UI 每次请求只收到一次结果。
enum LocalBrainResponder {
    static let defaultTimeoutNanoseconds: UInt64 = 30_000_000_000

    @discardableResult
    static func run(
        brain: any LocalBrainServicing,
        message: String,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
        onComplete: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let fired = finished.withLock { done -> Bool in
                    guard !done else { return true }
                    done = true
                    return false
                }
                guard !fired else { return }
                onError("rtmp.scene.assistant.local.timeout".localized)
            }
            do {
                let text = (try await brain.respond(to: message)) ?? ""
                let fired = finished.withLock { done -> Bool in
                    guard !done else { return true }
                    done = true
                    return false
                }
                guard !fired else { return }
                timeoutTask.cancel()
                onComplete(text)
            } catch {
                let fired = finished.withLock { done -> Bool in
                    guard !done else { return true }
                    done = true
                    return false
                }
                guard !fired else { return }
                timeoutTask.cancel()
                onError("rtmp.scene.assistant.local.error".localized)
            }
        }
    }
}

/// 端侧模型错误（纯逻辑，可测）
enum LocalBrainError: LocalizedError, Equatable {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy:
            return "rtmp.scene.assistant.local.busy".localized
        }
    }
}

/// Foundation Models 端侧模型封装：单会话复用、可用性门控、请求串行
final class LocalBrainService: LocalBrainServicing, @unchecked Sendable {
    static let shared = LocalBrainService()

    #if canImport(FoundationModels)
    private let sessionLock = NSLock()
    private var session: AnyObject?
    #endif

    private init() {}

    var isAvailable: Bool {
        guard LocalBrainSettings.enabled else { return false }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return false }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return false }
        let candidates = [Locale.current] + Locale.preferredLanguages.map { Locale(identifier: $0) }
        return candidates.contains { model.supportsLocale($0) }
        #else
        return false
        #endif
    }

    func respond(to prompt: String) async throws -> String? {
        guard isAvailable else { return nil }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        let session = try currentSession()
        guard !session.isResponding else { throw LocalBrainError.busy }
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(maximumResponseTokens: 512)
        )
        return response.content
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func currentSession() throws -> LanguageModelSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let session = session as? LanguageModelSession { return session }
        let newSession = LanguageModelSession(
            model: .default,
            instructions: LocalBrainInstructions.text
        )
        session = newSession
        return newSession
    }
    #endif
}
