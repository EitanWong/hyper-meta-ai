/*
 * Control Center 语音会话 Intent
 * 运行在 Widget 扩展进程：只写入 App Group 请求标记，由 App 消费执行。
 */

import AppIntents

struct StartVoiceSessionControlIntent: AppIntent {
    static var title: LocalizedStringResource = "开始语音会话"
    static var description = IntentDescription("进入与 Agent 的实时语音会话")

    func perform() async throws -> some IntentResult {
        VoiceControlRequestStore.request(.start)
        return .result()
    }
}

struct StopVoiceSessionControlIntent: AppIntent {
    static var title: LocalizedStringResource = "停止语音会话"
    static var description = IntentDescription("停止正在运行的语音会话")

    func perform() async throws -> some IntentResult {
        VoiceControlRequestStore.request(.stop)
        return .result()
    }
}

/// 唤醒休眠中的语音会话（锁屏 Live Activity「唤醒」按钮）
/// 需要打开 App：唤醒由 App 内会话持有麦克风与网关连接，扩展进程无法直接执行。
struct WakeVoiceSessionControlIntent: AppIntent {
    static var title: LocalizedStringResource = "唤醒语音会话"
    static var description = IntentDescription("唤醒休眠中的 JARVIS 语音会话")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        VoiceControlRequestStore.request(.wake)
        return .result()
    }
}
