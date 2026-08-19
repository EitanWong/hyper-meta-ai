/*
 * Agent Gateway Announcement Window
 * 兼容 qwen-audio-agent v1.10.1 server/src/voice/announcement/announcement-window.mjs：
 * 跟踪用户说话 / 回合挂起 / 音频响应队列，判断后台结果公告的安全插入窗口。
 * 纯状态机，可测。
 */

import Foundation

/// 公告安全插入窗口（用户未说话、无挂起回合、无排队音频响应时可公告）
struct AgentGatewayAnnouncementWindow {
    private struct AudioResponseContext {
        let turnId: String
        let origin: String
    }

    /// 用户是否正在说话
    private(set) var userSpeaking = false
    /// 当前活动回合 ID
    private(set) var activeTurnId = ""
    /// 当前回合是否挂起（尚未听到回应的语音/工具确认）
    private(set) var turnPending = false
    private var audioResponses: [String: AudioResponseContext] = [:]
    private var playingResponses: Set<String> = []

    init() {}

    /// 用户回合开始
    mutating func beginTurn(_ turnId: String) {
        userSpeaking = true
        activeTurnId = turnId
        turnPending = true
    }

    /// 用户语音结束
    mutating func endSpeech() {
        userSpeaking = false
    }

    /// 一个响应完成：公告响应 / 非当前回合 / 有音频 / 工具调用未被抑制时不清除挂起
    mutating func responseDone(
        turnId: String,
        origin: String = "model",
        hasAudio: Bool = false,
        hasFunctionCall: Bool = false,
        suppressed: Bool = false,
        failed: Bool = false
    ) {
        if origin == "announcement" { return }
        guard turnId == activeTurnId else { return }
        if hasAudio { return }
        if hasFunctionCall, !suppressed, !failed { return }
        turnPending = false
    }

    /// 音频响应入队（播报前）
    mutating func queueAudio(_ responseId: String, turnId: String = "", origin: String = "model") {
        guard !responseId.isEmpty else { return }
        audioResponses[responseId] = AudioResponseContext(turnId: turnId, origin: origin)
    }

    /// 音频开始播放
    mutating func startPlayback(_ responseId: String) {
        guard !responseId.isEmpty else { return }
        playingResponses.insert(responseId)
    }

    /// 音频播放结束：非公告响应且属于当前回合且无工具调用时解除挂起
    mutating func finishPlayback(_ responseId: String, hasFunctionCall: Bool = false) {
        let context = audioResponses.removeValue(forKey: responseId)
        playingResponses.remove(responseId)
        if let context,
           context.origin != "announcement",
           !context.turnId.isEmpty,
           context.turnId == activeTurnId,
           !hasFunctionCall {
            turnPending = false
        }
    }

    /// 用户打断：回合不再挂起（已提交的工作不受影响）
    mutating func interrupt() {
        turnPending = false
    }

    /// 会话重置
    mutating func reset() {
        userSpeaking = false
        activeTurnId = ""
        turnPending = false
        audioResponses.removeAll()
        playingResponses.removeAll()
    }

    /// 是否阻塞公告（用户说话 / 回合挂起 / 有排队音频）
    func isBlocked() -> Bool {
        userSpeaking || turnPending || !audioResponses.isEmpty
    }

    /// 是否有音频正在播放
    func isPlaying() -> Bool {
        !playingResponses.isEmpty
    }

    /// 排队中的音频响应数量
    var queuedAudioCount: Int {
        audioResponses.count
    }
}
