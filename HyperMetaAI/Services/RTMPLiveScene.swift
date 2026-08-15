/*
 * RTMP Live Scene Understanding
 * 直播中 AI 场景理解：周期采样眼镜视野帧 → 端侧场景识别 →
 * 场景标签展示与变化自动标记。调度与变化检测为纯逻辑，便于测试。
 */

import Foundation
import Vision

/// 直播场景标签提取（纯逻辑，可测）：最高置信度场景分类
enum RTMPLiveSceneProcessor {
    static func sceneLabel(
        from result: VisionSceneResult,
        minConfidence: Float = 0.25
    ) -> String? {
        result.classifications
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .first?
            .identifier
    }
}

/// 一次直播场景识别快照
struct RTMPLiveSceneSnapshot: Equatable {
    /// 主场景标签（最高置信度场景分类，如 Restaurant）
    var sceneLabel: String?
    /// 场景摘要（前 3 个分类，逗号分隔）
    var summary: String
    /// 是否与上一次识别结果不同（场景变化）
    var isChanged: Bool
    var detectedAt: Date
}

/// 直播场景分析调度（纯逻辑，可测）：
/// 周期采样门控 + 场景变化检测（与上次摘要比较）
struct RTMPLiveSceneScheduler {
    /// 采样间隔（秒）
    var sampleInterval: TimeInterval
    private(set) var lastSampleAt: TimeInterval?
    private(set) var lastSummary: String?

    init(sampleInterval: TimeInterval) {
        self.sampleInterval = sampleInterval
    }

    /// 是否到了采样时刻（每 sampleInterval 秒放行一次；从未采样立即放行）
    mutating func shouldSample(now: TimeInterval) -> Bool {
        if let lastSampleAt {
            guard now - lastSampleAt >= sampleInterval else { return false }
        }
        lastSampleAt = now
        return true
    }

    /// 记录一次识别摘要，返回是否与上次不同（场景变化）
    @discardableResult
    mutating func consume(summary: String) -> Bool {
        let changed = summary != lastSummary
        lastSummary = summary
        return changed
    }

    mutating func reset() {
        lastSampleAt = nil
        lastSummary = nil
    }
}
