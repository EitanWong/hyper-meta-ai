/*
 * Qwen Gateway Models
 * qwen-audio-agent 网关 WebSocket 协议的事件模型与解析。
 * 协议参考 shared/realtime-events.mjs：
 *   客户端事件: connect / audio.append / image.append / text.message / input.mute / input.unmute / interrupt / playback.*
 *   服务端事件: gateway.* / voice.* / turn.started / audio.delta / audio.done / transcript.* / task.* / timeline.inline / error
 */

import Foundation

// MARK: - 客户端事件构建

enum QwenGatewayClientEvent {
    static func connect(
        timeZone: String,
        locale: String,
        voiceEnabled: Bool = true,
        inputEnabled: Bool = true,
        outputEnabled: Bool = true,
        clientType: String,
        clientLabel: String,
        clientInstanceId: String,
        takeover: Bool = false,
        provider: String? = nil,
        wakeWordOnly: Bool = false
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "connect",
            "timeZone": timeZone,
            "locale": locale,
            "voiceEnabled": voiceEnabled,
            "inputEnabled": inputEnabled,
            "outputEnabled": outputEnabled,
            "clientType": clientType,
            "clientLabel": clientLabel,
            "clientInstanceId": clientInstanceId,
            "takeover": takeover
        ]
        // 会话级语音前端选择（qwen-audio-agent v1.10.1：未知 provider 名会被网关拒绝而非静默回退）
        if let provider {
            payload["provider"] = provider
        }
        // 仅唤醒模式：连接后立即进入休眠，等待唤醒词（网关侧再发起真实语音连接）
        if wakeWordOnly {
            payload["wakeWordOnly"] = true
        }
        return payload
    }

    static func audioAppend(pcmBase64: String) -> [String: Any] {
        ["type": "audio.append", "audio": pcmBase64]
    }

    static func imageAppend(jpegBase64: String) -> [String: Any] {
        ["type": "image.append", "image": jpegBase64, "mimeType": "image/jpeg"]
    }

    static func textMessage(_ text: String) -> [String: Any] {
        ["type": "text.message", "text": text]
    }

    static func inputMute() -> [String: Any] {
        ["type": "input.mute"]
    }

    static func inputUnmute() -> [String: Any] {
        ["type": "input.unmute"]
    }

    /// 打断当前回复。`playedMs` 是用户实际听到的音频毫秒数，网关据此发出
    /// `conversation.item.truncate`，让服务端上下文与用户听到的内容保持一致。
    /// 传 nil 表示无法确定播放进度（此时退化为仅取消，不截断）。
    static func interrupt(playedMs: Int? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "interrupt"]
        if let playedMs, playedMs >= 0 {
            payload["playedMs"] = playedMs
        }
        return payload
    }

    static func playbackStarted(responseId: String?) -> [String: Any] {
        ["type": "playback.started", "responseId": responseId ?? ""]
    }

    static func playbackEnded(responseId: String?) -> [String: Any] {
        ["type": "playback.ended", "responseId": responseId ?? ""]
    }

    static func playbackCancelled(
        responseId: String?,
        reason: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "playback.cancelled",
            "responseId": responseId ?? ""
        ]
        if let reason, !reason.isEmpty {
            payload["reason"] = reason
        }
        return payload
    }

    /// 请求网关进入休眠（qwen-audio-agent v1.5+：唤醒词/自动休眠协议）
    static func sleep() -> [String: Any] {
        ["type": "sleep"]
    }

    /// 请求网关唤醒（与唤醒词检测后同一套重连与退避路径）
    static func wake() -> [String: Any] {
        ["type": "wake"]
    }
}

// MARK: - 服务端事件

/// 网关任务权限（task.permission.* 事件与 /api/permissions/:id 响应携带的对象）
struct QwenPermission: Equatable {
    enum Status: String, Equatable {
        case pending
        case approved
        case denied
        case cancelled
        case unknown
    }

    let id: String
    let workId: String?
    let status: Status
    let category: String
    let summary: String
}

enum QwenGatewayEvent: Equatable {
    case gatewayConnected
    case gatewayDisconnected
    /// 意外断线后正在自动重连（第 n 次 / 最多 max 次）
    case gatewayReconnecting(attempt: Int, maxAttempts: Int)
    /// 重连达到上限，已放弃
    case gatewayReconnectFailed
    case voiceReady(inputSampleRate: Double)
    case voiceConnection(state: String, message: String?)
    case voiceState(state: String)
    case voiceOwnership(state: String, holder: String?)
    case voiceDeactivated
    case voiceSleep(state: String)
    /// 网关请求客户端进入指定状态（如 sleeping：客户端应停止输入并转入唤醒词监听）
    case clientState(state: String)
    case turnStarted(turnId: String?)
    case playbackClear(reason: String?)
    case audioChunk(
        pcmData: Data,
        sampleRate: Double?,
        responseId: String?,
        receivedAt: TimeInterval
    )
    case audioDone(responseId: String?)
    case responseStarted(responseId: String?)
    case responseInterrupted(responseId: String?)
    case transcriptDelta(role: String, text: String)
    case transcriptFinal(role: String, text: String)
    case transcriptDiscard
    case timelineInline(taskId: String?, content: String?)
    case task(type: String, taskId: String?, title: String?)
    /// 后台任务请求执行权限（等待用户在手机端确认）
    case permissionRequested(taskId: String?, permission: QwenPermission)
    /// 后台任务权限已处理（授权/拒绝/取消）
    case permissionResolved(taskId: String?, permission: QwenPermission)
    case error(message: String)
    case unknown(type: String)
}

extension QwenGatewayEvent {
    static func audioDelta(
        audioBase64: String,
        sampleRate: Double?,
        responseId: String?,
        receivedAt: TimeInterval = 0
    ) -> Self {
        .audioChunk(
            pcmData: Data(base64Encoded: audioBase64) ?? Data(),
            sampleRate: sampleRate,
            responseId: responseId,
            receivedAt: receivedAt
        )
    }
}

// MARK: - 解析器

enum QwenGatewayEventParser {
    static func parse(
        _ json: [String: Any],
        receivedAt: TimeInterval = 0
    ) -> QwenGatewayEvent? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "gateway.connected":
            return .gatewayConnected
        case "gateway.disconnected":
            return .gatewayDisconnected
        case "voice.ready":
            return .voiceReady(inputSampleRate: double(json["inputSampleRate"]) ?? 16_000)
        case "voice.connection":
            return .voiceConnection(
                state: json["state"] as? String ?? "",
                message: json["message"] as? String
            )
        case "voice.state":
            return .voiceState(state: json["state"] as? String ?? "")
        case "voice.ownership":
            return .voiceOwnership(
                state: json["state"] as? String ?? "",
                holder: json["holder"] as? String
            )
        case "voice.deactivated":
            return .voiceDeactivated
        case "voice.sleep":
            return .voiceSleep(state: json["state"] as? String ?? "")
        case "client.state":
            return .clientState(state: json["state"] as? String ?? "")
        case "turn.started":
            return .turnStarted(turnId: json["turnId"] as? String)
        case "playback.clear":
            return .playbackClear(reason: json["reason"] as? String)
        case "audio.delta":
            guard let audioBase64 = json["audio"] as? String,
                  let pcmData = Data(base64Encoded: audioBase64),
                  !pcmData.isEmpty else {
                return nil
            }
            return .audioChunk(
                pcmData: pcmData,
                sampleRate: double(json["sampleRate"]),
                responseId: json["responseId"] as? String,
                receivedAt: receivedAt
            )
        case "audio.done":
            return .audioDone(responseId: json["responseId"] as? String)
        case "response.started":
            return .responseStarted(responseId: json["responseId"] as? String)
        case "response.interrupted":
            return .responseInterrupted(responseId: json["responseId"] as? String)
        case "transcript.delta":
            return .transcriptDelta(
                role: json["role"] as? String ?? "",
                text: transcriptText(json)
            )
        case "transcript.final":
            return .transcriptFinal(
                role: json["role"] as? String ?? "",
                text: transcriptText(json)
            )
        case "transcript.discard":
            return .transcriptDiscard
        case "timeline.inline":
            let item = json["item"] as? [String: Any]
            return .timelineInline(
                taskId: item?["taskId"] as? String,
                content: item?["content"] as? String
            )
        case "error":
            return .error(message: json["message"] as? String ?? "")
        default:
            if type.hasPrefix("task.") {
                if let permission = parsePermission(json) {
                    let taskId = (json["task"] as? [String: Any])?["id"] as? String
                    if type == "task.permission.requested" {
                        return .permissionRequested(taskId: taskId, permission: permission)
                    }
                    if type == "task.permission.resolved" {
                        return .permissionResolved(taskId: taskId, permission: permission)
                    }
                }
                let task = json["task"] as? [String: Any]
                return .task(
                    type: type,
                    taskId: task?["id"] as? String,
                    title: taskTitle(task)
                )
            }
            return .unknown(type: type)
        }
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? Double)
    }

    private static func transcriptText(_ json: [String: Any]) -> String {
        (json["content"] as? String) ?? (json["text"] as? String) ?? ""
    }

    /// 尽力从 task 对象提取一句话摘要，拿不到返回 nil。
    private static func taskTitle(_ task: [String: Any]?) -> String? {
        guard let task else { return nil }
        if let summary = task["summary"] as? String, !summary.isEmpty { return summary }
        if let message = task["message"] as? String, !message.isEmpty { return message }
        if let delegation = task["delegation"] as? [String: Any],
           let presentation = delegation["presentation"] as? [String: Any],
           let speech = presentation["speech"] as? String, !speech.isEmpty {
            return speech
        }
        if let metadata = task["resultMetadata"] as? [String: Any],
           let presentation = metadata["presentation"] as? [String: Any],
           let inline = presentation["inline"] as? [String: Any],
           let content = inline["content"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }

    /// 从网关事件或 HTTP 响应中解析权限对象。
    /// 事件携带顶层 permission 字段（回退 task.authorization），HTTP 响应为裸对象。
    static func parsePermission(_ json: [String: Any]) -> QwenPermission? {
        let task = json["task"] as? [String: Any]
        let permission = (json["permission"] as? [String: Any])
            ?? (task?["authorization"] as? [String: Any])
            ?? json
        guard let id = permission["id"] as? String, !id.isEmpty else { return nil }
        return QwenPermission(
            id: id,
            workId: permission["workId"] as? String,
            status: QwenPermission.Status(rawValue: permission["status"] as? String ?? "") ?? .unknown,
            category: permission["category"] as? String ?? "",
            summary: permission["summary"] as? String ?? ""
        )
    }
}
