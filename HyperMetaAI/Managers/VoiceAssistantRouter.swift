/*
 * Voice Assistant Router
 * 统一输入入口：Siri / 快捷指令 / Control Center 等系统触发与 App 内呈现之间的桥梁。
 * 与 LiveAIManager.requestPresentation 同模式：系统入口只置请求标记，
 * App 前台消费请求后呈现语音会话页。
 */

import Combine
import Foundation

/// 一次语音会话启动请求（来自 Siri / 快捷指令等系统入口）
struct VoiceAssistantRequest {
    /// 指定的大脑；nil 表示沿用用户当前选择
    let brain: AgentBrain?
    /// 会话启动后立即发送的直接指令（如「帮我查一下航班」）
    let instruction: String?
    /// 结果追问上下文（任务结果通知「追问」深链带入，会话启动后注入）
    let followUpContext: String?
}

@MainActor
final class VoiceAssistantRouter: ObservableObject {
    static let shared = VoiceAssistantRouter()

    @Published private(set) var pendingRequest: VoiceAssistantRequest?
    private var controlObserver: NSObjectProtocol?

    var isVoiceSessionRequested: Bool {
        pendingRequest != nil
    }

    /// 唤醒执行器（默认走共享会话；测试注入避免真实网关副作用）
    var wakeExecutor: () -> Void = { QwenVoiceSession.shared.wake() }

    private init() {}

    /// 注册 Control Center 请求监听（App Group UserDefaults，跨进程）。
    /// 幂等：重复调用不会重复注册。
    func startObservingControlRequests() {
        guard controlObserver == nil else {
            consumeControlRequestIfNeeded()
            return
        }
        controlObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.consumeControlRequestIfNeeded()
        }
        consumeControlRequestIfNeeded()
    }

    /// 消费 App Group 中的 Control Center 请求
    /// （start → 启动语音会话；stop → 停止；wake → 唤醒休眠会话并呈现语音页）。
    func consumeControlRequestIfNeeded() {
        guard let action = VoiceControlRequestStore.consume() else { return }
        switch action {
        case .start:
            requestVoiceSession()
        case .stop:
            QwenVoiceSession.shared.stop()
        case .wake:
            wakeExecutor()
            requestVoiceSession()
        }
    }

    func requestVoiceSession(
        brain: AgentBrain? = nil,
        instruction: String? = nil,
        followUpContext: String? = nil
    ) {
        pendingRequest = VoiceAssistantRequest(
            brain: brain,
            instruction: instruction,
            followUpContext: followUpContext
        )
    }

    @discardableResult
    func consumeVoiceSessionRequest() -> VoiceAssistantRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}
