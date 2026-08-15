import AVFoundation
import CoreVideo
import XCTest

@testable import HyperMetaAI

final class RTMPStreamingViewLifecyclePolicyTests: XCTestCase {
  func testDisconnectedCameraKeepsRTMPPageAvailableForRecovery() {
    XCTAssertEqual(
      RTMPStreamingViewLifecyclePolicy.transition(for: .unavailable),
      .unavailable
    )
    XCTAssertEqual(
      RTMPStreamingViewLifecyclePolicy.transition(for: .failed("Device disconnected")),
      .unavailable
    )
  }

  func testStreamingCameraStartsFrameFeed() {
    XCTAssertEqual(
      RTMPStreamingViewLifecyclePolicy.transition(for: .streaming),
      .ready
    )
  }

  func testTransientCameraStatesWaitWithoutClosing() {
    XCTAssertEqual(RTMPStreamingViewLifecyclePolicy.transition(for: .idle), .waiting)
    XCTAssertEqual(RTMPStreamingViewLifecyclePolicy.transition(for: .starting), .waiting)
    XCTAssertEqual(RTMPStreamingViewLifecyclePolicy.transition(for: .paused), .waiting)
    XCTAssertEqual(RTMPStreamingViewLifecyclePolicy.transition(for: .stopping), .waiting)
  }
}

final class RTMPStreamEndpointTests: XCTestCase {
  func testParsesRTMPServerURLAndStreamKey() {
    let endpoint = RTMPStreamEndpoint(
      url: "rtmp://live.example.com:1935/app/stream-key"
    )

    XCTAssertEqual(endpoint?.serverURL, "rtmp://live.example.com:1935/app")
    XCTAssertEqual(endpoint?.streamKey, "stream-key")
  }

  func testKeepsAQueryAttachedToThePublishName() {
    let endpoint = RTMPStreamEndpoint(
      url: "rtmps://live.example.com:443/rtmp/stream-key?token=abc"
    )

    XCTAssertEqual(endpoint?.serverURL, "rtmps://live.example.com:443/rtmp")
    XCTAssertEqual(endpoint?.streamKey, "stream-key?token=abc")
  }

  func testRejectsUnsupportedOrIncompleteEndpoints() {
    XCTAssertNil(RTMPStreamEndpoint(url: "https://live.example.com/app/key"))
    XCTAssertNil(RTMPStreamEndpoint(url: "rtmp://live.example.com/app"))
    XCTAssertNil(RTMPStreamEndpoint(url: "rtmp:///app/key"))
  }
}

final class RTMPFrameInputArbiterTests: XCTestCase {
  func testDirectSampleBuffersReplaceTheRenderedImageFallback() {
    var arbiter = RTMPFrameInputArbiter()

    XCTAssertTrue(arbiter.accepts(.renderedImage))
    XCTAssertTrue(arbiter.accepts(.directSampleBuffer))
    XCTAssertTrue(arbiter.usesDirectSampleBuffers)
    XCTAssertFalse(arbiter.accepts(.renderedImage))
  }

  func testResetRestoresTheRenderedImageFallback() {
    var arbiter = RTMPFrameInputArbiter()
    _ = arbiter.accepts(.directSampleBuffer)

    arbiter.reset()

    XCTAssertFalse(arbiter.usesDirectSampleBuffers)
    XCTAssertTrue(arbiter.accepts(.renderedImage))
  }
}

final class RTMPSampleBufferRelayTests: XCTestCase {
  func testDetachingAnOlderRegistrationDoesNotRemoveTheCurrentConsumer() throws {
    let relay = RTMPSampleBufferRelay()
    let firstCounter = LockedCounter()
    let secondCounter = LockedCounter()
    let firstRegistration = relay.attach { _ in firstCounter.increment() }
    let secondRegistration = relay.attach { _ in secondCounter.increment() }

    relay.detach(firstRegistration)
    relay.forward(try makeSampleBuffer())

    XCTAssertEqual(firstCounter.value, 0)
    XCTAssertEqual(secondCounter.value, 1)

    relay.detach(secondRegistration)
    relay.forward(try makeSampleBuffer())
    XCTAssertEqual(secondCounter.value, 1)
  }

  private func makeSampleBuffer() throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        8,
        8,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    let imageBuffer = try XCTUnwrap(pixelBuffer)

    var formatDescription: CMVideoFormatDescription?
    XCTAssertEqual(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &formatDescription
      ),
      noErr
    )
    let format = try XCTUnwrap(formatDescription)

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 24),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      ),
      noErr
    )
    return try XCTUnwrap(sampleBuffer)
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

final class RTMPAdaptiveBitrateControllerTests: XCTestCase {

    func testClampIndexPicksNearestTier() {
        XCTAssertEqual(RTMPAdaptiveBitrateController.clampIndex(for: 2_000_000), 2)
        XCTAssertEqual(RTMPAdaptiveBitrateController.clampIndex(for: 1_200_000), 0)
        XCTAssertEqual(RTMPAdaptiveBitrateController.clampIndex(for: 1_700_000), 1)
        XCTAssertEqual(RTMPAdaptiveBitrateController.clampIndex(for: 1_000_000), 0)
        XCTAssertEqual(RTMPAdaptiveBitrateController.clampIndex(for: 9_000_000), 5)
        XCTAssertEqual(RTMPAdaptiveBitrateController.clampIndex(for: 0), 0)
    }

    func testInitialBitrateClampedToNearestTier() {
        let controller = RTMPAdaptiveBitrateController(initialBitrate: 2_300_000)
        XCTAssertEqual(controller.currentBitrate, 2_500_000)
    }

    func testHoldDuringDownshiftCooldown() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 2_000_000, now: 0)
        let decision = controller.decide(droppedFrames: 10, totalFrames: 100, now: 5)
        XCTAssertEqual(decision.action, .hold)
        XCTAssertEqual(decision.targetBitrate, 2_000_000)
    }

    func testDownshiftOnHighDropRatio() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 2_000_000, now: 0)
        let decision = controller.decide(droppedFrames: 10, totalFrames: 100, now: 9)
        XCTAssertEqual(decision.action, .downshift)
        XCTAssertEqual(decision.targetBitrate, 1_500_000)
        XCTAssertEqual(controller.currentBitrate, 1_500_000)
    }

    func testDownshiftStopsAtLowestTier() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 1_000_000, now: 0)
        let decision = controller.decide(droppedFrames: 50, totalFrames: 100, now: 9)
        XCTAssertEqual(decision.action, .hold)
        XCTAssertEqual(decision.targetBitrate, 1_000_000)
    }

    func testUpshiftAfterQuietPeriod() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 2_000_000, now: 0)
        let decision = controller.decide(droppedFrames: 0, totalFrames: 90, now: 21)
        XCTAssertEqual(decision.action, .upshift)
        XCTAssertEqual(decision.targetBitrate, 2_500_000)
        XCTAssertEqual(controller.currentBitrate, 2_500_000)
    }

    func testUpshiftStopsAtHighestTier() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 4_000_000, now: 0)
        let decision = controller.decide(droppedFrames: 0, totalFrames: 90, now: 21)
        XCTAssertEqual(decision.action, .hold)
        XCTAssertEqual(decision.targetBitrate, 4_000_000)
    }

    func testDecideIgnoresEmptyPeriod() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 2_000_000, now: 0)
        let decision = controller.decide(droppedFrames: 0, totalFrames: 0, now: 21)
        XCTAssertEqual(decision.action, .hold)
    }

    func testDropRatioBelowThresholdDoesNotDownshift() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 2_000_000, now: 0)
        // 恰好 5%（阈值是严格大于）
        let boundary = controller.decide(droppedFrames: 5, totalFrames: 100, now: 9)
        XCTAssertEqual(boundary.action, .hold)
        // 非零丢帧但低于阈值 → 也不满足零丢帧的升档条件
        let below = controller.decide(droppedFrames: 3, totalFrames: 100, now: 30)
        XCTAssertEqual(below.action, .hold)
    }

    func testMultipleDecisionsWalkDownThenRecover() {
        var controller = RTMPAdaptiveBitrateController(initialBitrate: 3_000_000, now: 0)
        _ = controller.decide(droppedFrames: 30, totalFrames: 100, now: 9)
        XCTAssertEqual(controller.currentBitrate, 2_500_000)
        _ = controller.decide(droppedFrames: 30, totalFrames: 100, now: 18)
        XCTAssertEqual(controller.currentBitrate, 2_000_000)
        // 网络恢复：零丢帧并等待升档冷却后回升
        _ = controller.decide(droppedFrames: 0, totalFrames: 90, now: 39)
        XCTAssertEqual(controller.currentBitrate, 2_500_000)
    }
}

final class RTMPReconnectPolicyTests: XCTestCase {
  func testDefaultBackoffSequence() {
    let policy = RTMPReconnectPolicy()

    XCTAssertEqual(policy.delay(forAttempt: 1), 2)
    XCTAssertEqual(policy.delay(forAttempt: 2), 4)
    XCTAssertEqual(policy.delay(forAttempt: 3), 8)
    XCTAssertEqual(policy.delay(forAttempt: 4), 16)
    XCTAssertEqual(policy.delay(forAttempt: 5), 30)
  }

  func testDelayClampsBeyondBackoffTable() {
    let policy = RTMPReconnectPolicy(backoffDelays: [1, 3], maxAttempts: 4)

    XCTAssertEqual(policy.delay(forAttempt: 1), 1)
    XCTAssertEqual(policy.delay(forAttempt: 2), 3)
    // 表外按最后一项封顶，而不是失败
    XCTAssertEqual(policy.delay(forAttempt: 3), 3)
    XCTAssertEqual(policy.delay(forAttempt: 4), 3)
  }

  func testDelayNilBeyondMaxAttempts() {
    let policy = RTMPReconnectPolicy(maxAttempts: 3)

    XCTAssertNotNil(policy.delay(forAttempt: 3))
    XCTAssertNil(policy.delay(forAttempt: 4))
    XCTAssertNil(policy.delay(forAttempt: 100))
  }

  func testDelayNilForInvalidAttemptNumbers() {
    let policy = RTMPReconnectPolicy()

    XCTAssertNil(policy.delay(forAttempt: 0))
    XCTAssertNil(policy.delay(forAttempt: -1))
  }

  func testEmptyBackoffTableNeverDelays() {
    let policy = RTMPReconnectPolicy(backoffDelays: [], maxAttempts: 5)

    XCTAssertNil(policy.delay(forAttempt: 1))
    XCTAssertFalse(policy.canAttempt(afterFailedAttempts: 0))
  }

  func testCanAttemptWithinLimit() {
    let policy = RTMPReconnectPolicy(maxAttempts: 3)

    XCTAssertTrue(policy.canAttempt(afterFailedAttempts: 0))
    XCTAssertTrue(policy.canAttempt(afterFailedAttempts: 2))
    XCTAssertFalse(policy.canAttempt(afterFailedAttempts: 3))
    XCTAssertFalse(policy.canAttempt(afterFailedAttempts: 10))
    XCTAssertFalse(policy.canAttempt(afterFailedAttempts: -1))
  }

  func testMaxAttemptsShorterThanTableStopsEarly() {
    let policy = RTMPReconnectPolicy(backoffDelays: [2, 4, 8, 16, 30], maxAttempts: 2)

    XCTAssertEqual(policy.delay(forAttempt: 2), 4)
    XCTAssertNil(policy.delay(forAttempt: 3))
    XCTAssertFalse(policy.canAttempt(afterFailedAttempts: 2))
  }

  func testCustomPolicyValues() {
    let policy = RTMPReconnectPolicy(backoffDelays: [5, 10], maxAttempts: 2)

    XCTAssertEqual(policy.delay(forAttempt: 1), 5)
    XCTAssertEqual(policy.delay(forAttempt: 2), 10)
    XCTAssertNil(policy.delay(forAttempt: 3))
  }
}

final class RTMPAdaptiveQualityControllerTests: XCTestCase {
  func testInitialPresetClampsByBitrate() {
    let controller = RTMPAdaptiveQualityController(initialBitrate: 2_000_000)
    XCTAssertEqual(controller.currentPreset.bitrate, 2_000_000)
    XCTAssertEqual(controller.currentPreset.width, 420)
    XCTAssertEqual(controller.currentPreset.height, 420)
    XCTAssertEqual(controller.currentPreset.fps, 24)
  }

  func testInitialPresetByExactPreset() {
    let preset = RTMPQualityPreset(bitrate: 4_000_000, width: 504, height: 504, fps: 30)
    let controller = RTMPAdaptiveQualityController(initialPreset: preset)
    XCTAssertEqual(controller.currentPreset, preset)
  }

  func testDownshiftChangesBitrateResolutionAndFps() {
    var controller = RTMPAdaptiveQualityController(
      initialPreset: RTMPQualityPreset(bitrate: 4_000_000, width: 504, height: 504, fps: 30),
      now: 0
    )
    let decision = controller.decide(droppedFrames: 30, totalFrames: 100, now: 9)
    XCTAssertEqual(decision.action, .downshift)
    XCTAssertEqual(decision.preset.bitrate, 3_000_000)
    XCTAssertEqual(decision.preset.width, 504)
    XCTAssertEqual(decision.preset.height, 504)
    XCTAssertEqual(decision.preset.fps, 24)
  }

  func testDownshiftResolutionAfterBitrateTiersExhausted() {
    var controller = RTMPAdaptiveQualityController(
      initialPreset: RTMPQualityPreset(bitrate: 2_000_000, width: 420, height: 420, fps: 24),
      now: 0
    )
    let decision = controller.decide(droppedFrames: 30, totalFrames: 100, now: 9)
    XCTAssertEqual(decision.preset.bitrate, 1_500_000)
    XCTAssertEqual(decision.preset.width, 360)
    XCTAssertEqual(decision.preset.height, 360)
    XCTAssertEqual(decision.preset.fps, 20)
  }

  func testDropThresholdBoundaryIsStrict() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 4_000_000, now: 0)
    let boundary = controller.decide(droppedFrames: 5, totalFrames: 100, now: 9)
    XCTAssertEqual(boundary.action, .hold)
    let below = controller.decide(droppedFrames: 3, totalFrames: 100, now: 30)
    XCTAssertEqual(below.action, .hold)
  }

  func testDownshiftCooldownBlocksRapidDegradation() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 4_000_000, now: 0)
    let early = controller.decide(droppedFrames: 50, totalFrames: 100, now: 5)
    XCTAssertEqual(early.action, .hold)
    let later = controller.decide(droppedFrames: 50, totalFrames: 100, now: 9)
    XCTAssertEqual(later.action, .downshift)
  }

  func testUpshiftRequiresZeroDropsAndCooldown() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 1_000_000, now: 0)
    // 冷却未到
    let early = controller.decide(droppedFrames: 0, totalFrames: 90, now: 15)
    XCTAssertEqual(early.action, .hold)
    // 有丢帧不升
    let withDrops = controller.decide(droppedFrames: 1, totalFrames: 90, now: 25)
    XCTAssertEqual(withDrops.action, .hold)
    // 稳定后回升
    let later = controller.decide(droppedFrames: 0, totalFrames: 90, now: 45)
    XCTAssertEqual(later.action, .upshift)
    XCTAssertEqual(later.preset.bitrate, 1_500_000)
  }

  func testEmptyPeriodNeverChangesQuality() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 4_000_000, now: 0)
    let decision = controller.decide(droppedFrames: 0, totalFrames: 0, now: 100)
    XCTAssertEqual(decision.action, .hold)
    XCTAssertEqual(controller.currentPreset.bitrate, 4_000_000)
  }

  func testLowestTierStaysPut() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 1_000_000, now: 0)
    let decision = controller.decide(droppedFrames: 50, totalFrames: 100, now: 9)
    XCTAssertEqual(decision.action, .hold)
    XCTAssertEqual(controller.currentPreset.bitrate, 1_000_000)
  }

  func testHighestTierStaysPut() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 4_000_000, now: 0)
    let decision = controller.decide(droppedFrames: 0, totalFrames: 90, now: 30)
    XCTAssertEqual(decision.action, .hold)
    XCTAssertEqual(controller.currentPreset.bitrate, 4_000_000)
  }

  func testWalkDownToFloorThenRecover() {
    var controller = RTMPAdaptiveQualityController(initialBitrate: 4_000_000, now: 0)
    var bitrates: [Int] = []
    var now: TimeInterval = 0
    for _ in 0..<5 {
      now += 9
      let decision = controller.decide(droppedFrames: 30, totalFrames: 100, now: now)
      if decision.action != .hold { bitrates.append(decision.preset.bitrate) }
    }
    XCTAssertEqual(bitrates, [3_000_000, 2_500_000, 2_000_000, 1_500_000, 1_000_000])
    XCTAssertEqual(controller.currentPreset.fps, 15)
    XCTAssertEqual(controller.currentPreset.width, 288)

    // 网络恢复后逐级回升
    now += 20
    let up = controller.decide(droppedFrames: 0, totalFrames: 90, now: now)
    XCTAssertEqual(up.action, .upshift)
    XCTAssertEqual(up.preset.bitrate, 1_500_000)
    XCTAssertEqual(up.preset.fps, 20)
  }

  func testEmptyPresetsAreSafe() {
    let controller = RTMPAdaptiveQualityController(presets: [])
    XCTAssertEqual(controller.currentPreset.bitrate, 0)
    XCTAssertEqual(RTMPAdaptiveQualityController.clampIndex(for: 2_000_000, presets: []), 0)
  }

  func testShortLabelFormat() {
    let preset = RTMPQualityPreset(bitrate: 2_500_000, width: 504, height: 504, fps: 24)
    XCTAssertEqual(preset.shortLabel, "504×504@24")
  }
}

final class RTMPAudioBitratePolicyTests: XCTestCase {
  func testDefaultMappingMatchesQualityTiers() {
    let policy = RTMPAudioBitratePolicy()

    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 0), 128_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 1), 128_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 2), 96_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 3), 96_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 4), 64_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 5), 64_000)
  }

  func testClampsOutOfRangeIndex() {
    let policy = RTMPAudioBitratePolicy()

    XCTAssertEqual(policy.audioBitrate(forQualityIndex: -1), 128_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 99), 64_000)
  }

  func testCustomMapping() {
    let policy = RTMPAudioBitratePolicy(bitrates: [160_000, 80_000])

    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 0), 160_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 1), 80_000)
    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 5), 80_000)
  }

  func testEmptyMappingReturnsZero() {
    let policy = RTMPAudioBitratePolicy(bitrates: [])

    XCTAssertEqual(policy.audioBitrate(forQualityIndex: 0), 0)
  }
}

final class RTMPScenarioStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    RTMPScenarioStore.clear()
  }

  override func tearDown() {
    RTMPScenarioStore.clear()
    super.tearDown()
  }

  private func makeScenario(
    name: String = "B站直播",
    platform: String = "bilibili",
    url: String = "rtmp://push.bilivideo.com/live",
    bitrate: Int = 2_000_000,
    updatedAt: Date = Date()
  ) -> RTMPStreamScenario {
    RTMPStreamScenario(
      name: name,
      platform: platform,
      rtmpUrl: url,
      bitrate: bitrate,
      adaptiveQualityEnabled: true,
      autoReconnectEnabled: true,
      adaptiveAudioEnabled: true,
      updatedAt: updatedAt
    )
  }

  func testStoreDefaultsEmpty() {
    XCTAssertTrue(RTMPScenarioStore.scenarios.isEmpty)
  }

  func testSaveAddsAndSortsByUpdatedAtDescending() {
    let older = makeScenario(name: "旧场景", updatedAt: Date(timeIntervalSinceNow: -100))
    let newer = makeScenario(name: "新场景", updatedAt: Date(timeIntervalSinceNow: -10))

    XCTAssertTrue(RTMPScenarioStore.save(older))
    XCTAssertTrue(RTMPScenarioStore.save(newer))
    XCTAssertEqual(RTMPScenarioStore.scenarios.map(\.name), ["新场景", "旧场景"])
  }

  func testSaveRejectsEmptyNameAndTrimsWhitespace() {
    XCTAssertFalse(RTMPScenarioStore.save(makeScenario(name: "   ")))
    XCTAssertTrue(RTMPScenarioStore.save(makeScenario(name: "  抖音  ")))
    XCTAssertEqual(RTMPScenarioStore.scenarios.first?.name, "抖音")
  }

  func testSaveUpdatesByIdWithoutDuplicating() {
    let scenario = makeScenario(name: "B站")
    XCTAssertTrue(RTMPScenarioStore.save(scenario))

    var updated = scenario
    updated.name = "B站主号"
    updated.bitrate = 4_000_000
    XCTAssertTrue(RTMPScenarioStore.save(updated))

    let items = RTMPScenarioStore.scenarios
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].id, scenario.id)
    XCTAssertEqual(items[0].name, "B站主号")
    XCTAssertEqual(items[0].bitrate, 4_000_000)
  }

  func testSaveRespectsMaxCount() {
    for index in 0..<RTMPScenarioStore.maxCount {
      XCTAssertTrue(RTMPScenarioStore.save(makeScenario(name: "场景\(index)")))
    }
    XCTAssertEqual(RTMPScenarioStore.scenarios.count, RTMPScenarioStore.maxCount)
    XCTAssertFalse(RTMPScenarioStore.save(makeScenario(name: "超限")))
  }

  func testDeleteById() {
    let scenario = makeScenario()
    XCTAssertTrue(RTMPScenarioStore.save(scenario))

    RTMPScenarioStore.delete(id: scenario.id)
    XCTAssertTrue(RTMPScenarioStore.scenarios.isEmpty)
  }

  func testRenameRejectsEmptyAndDuplicate() {
    let first = makeScenario(name: "B站")
    let second = makeScenario(name: "抖音")
    _ = RTMPScenarioStore.save(first)
    _ = RTMPScenarioStore.save(second)

    XCTAssertFalse(RTMPScenarioStore.rename(id: first.id, to: "   "))
    XCTAssertFalse(RTMPScenarioStore.rename(id: first.id, to: "抖音"))
    XCTAssertTrue(RTMPScenarioStore.rename(id: first.id, to: "B站主号"))
    XCTAssertEqual(RTMPScenarioStore.scenarios.first(where: { $0.id == first.id })?.name, "B站主号")
  }

  func testRenameUnknownIdFails() {
    XCTAssertFalse(RTMPScenarioStore.rename(id: UUID(), to: "任意"))
  }

  func testPersistenceRoundTrip() {
    XCTAssertTrue(RTMPScenarioStore.save(makeScenario(name: "B站")))
    XCTAssertEqual(RTMPScenarioStore.scenarios.count, 1)
    XCTAssertEqual(RTMPScenarioStore.scenarios[0].name, "B站")
  }
}

final class RTMPRecordingNamingTests: XCTestCase {
  func testFileNameUsesInjectedFormatter() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"

    let name = RTMPRecordingNaming.fileName(
      startedAt: Date(timeIntervalSince1970: 0),
      formatter: formatter
    )
    XCTAssertEqual(name, "HyperMetaAI-19700101-000000.mp4")
  }

  func testDefaultFileNameShape() {
    let name = RTMPRecordingNaming.fileName(startedAt: Date())
    XCTAssertTrue(name.hasPrefix("HyperMetaAI-"))
    XCTAssertTrue(name.hasSuffix(".mp4"))
    XCTAssertEqual(name.count, "HyperMetaAI-".count + 15 + ".mp4".count)
  }

  func testDurationText() {
    XCTAssertEqual(RTMPRecordingNaming.durationText(0), "00:00")
    XCTAssertEqual(RTMPRecordingNaming.durationText(65), "01:05")
    XCTAssertEqual(RTMPRecordingNaming.durationText(3599), "59:59")
    XCTAssertEqual(RTMPRecordingNaming.durationText(3600), "1:00:00")
    XCTAssertEqual(RTMPRecordingNaming.durationText(3661), "1:01:01")
    XCTAssertEqual(RTMPRecordingNaming.durationText(-5), "00:00")
  }

  func testMarkerTimeText() {
    XCTAssertEqual(RTMPRecordingNaming.markerTimeText(125.9), "02:06")
  }
}

final class RTMPMarkerTimelineTests: XCTestCase {
  func testAddTrimsAndRejectsEmptyLabel() {
    var timeline = RTMPMarkerTimeline()
    XCTAssertNil(timeline.add(label: "   ", at: 5))
    XCTAssertNil(timeline.add(label: "精彩", at: -1))
    XCTAssertNotNil(timeline.add(label: "  高光时刻  ", at: 3))
    XCTAssertEqual(timeline.markers.count, 1)
    XCTAssertEqual(timeline.markers[0].label, "高光时刻")
    XCTAssertEqual(timeline.markers[0].timeOffset, 3)
  }

  func testLabelClippedToMaxLength() {
    var timeline = RTMPMarkerTimeline()
    let long = String(repeating: "a", count: 40)
    _ = timeline.add(label: long, at: 1)
    XCTAssertEqual(timeline.markers[0].label.count, RTMPMarkerTimeline.maxLabelLength)
  }

  func testMarkersSortedByOffset() {
    var timeline = RTMPMarkerTimeline()
    _ = timeline.add(label: "三", at: 30)
    _ = timeline.add(label: "一", at: 5)
    _ = timeline.add(label: "二", at: 15)
    XCTAssertEqual(timeline.markers.map(\.label), ["一", "二", "三"])
  }

  func testClearRemovesMarkers() {
    var timeline = RTMPMarkerTimeline()
    _ = timeline.add(label: "一", at: 5)
    timeline.clear()
    XCTAssertTrue(timeline.markers.isEmpty)
  }
}

final class RTMPRecordingStoreTests: XCTestCase {
  override func setUp() {
    super.setUp()
    RTMPRecordingStore.clear()
  }

  override func tearDown() {
    RTMPRecordingStore.clear()
    super.tearDown()
  }

  private func makeRecord(
    startedAt: Date,
    duration: TimeInterval = 30,
    markers: [RTMPRecordingMarker] = []
  ) -> RTMPRecordingRecord {
    RTMPRecordingRecord(
      fileName: "HyperMetaAI-test.mp4",
      startedAt: startedAt,
      duration: duration,
      fileSize: 1_024,
      markers: markers
    )
  }

  func testAddSortsNewestFirst() {
    let older = makeRecord(startedAt: Date(timeIntervalSinceNow: -100))
    let newer = makeRecord(startedAt: Date(timeIntervalSinceNow: -10))
    RTMPRecordingStore.add(older)
    RTMPRecordingStore.add(newer)

    XCTAssertEqual(RTMPRecordingStore.records.count, 2)
    XCTAssertEqual(RTMPRecordingStore.records[0].startedAt, newer.startedAt)
  }

  func testAddKeepsNewestWithinLimit() {
    for index in 0..<(RTMPRecordingStore.maxCount + 5) {
      RTMPRecordingStore.add(makeRecord(startedAt: Date(timeIntervalSinceNow: TimeInterval(-index))))
    }
    XCTAssertEqual(RTMPRecordingStore.records.count, RTMPRecordingStore.maxCount)
  }

  func testDeleteById() {
    let record = makeRecord(startedAt: Date())
    RTMPRecordingStore.add(record)
    RTMPRecordingStore.delete(id: record.id)
    XCTAssertTrue(RTMPRecordingStore.records.isEmpty)
  }

  func testPersistenceRoundTripWithMarkers() {
    let marker = RTMPRecordingMarker(timeOffset: 12.5, label: "高光")
    RTMPRecordingStore.add(makeRecord(startedAt: Date(), markers: [marker]))

    XCTAssertEqual(RTMPRecordingStore.records.first?.markers.count, 1)
    XCTAssertEqual(RTMPRecordingStore.records.first?.markers[0].label, "高光")
  }
}

final class RTMPLiveSceneSchedulerTests: XCTestCase {
  func testFirstSampleAlwaysAllowed() {
    var scheduler = RTMPLiveSceneScheduler(sampleInterval: 10)
    XCTAssertTrue(scheduler.shouldSample(now: 0))
  }

  func testSampleIntervalGating() {
    var scheduler = RTMPLiveSceneScheduler(sampleInterval: 10)
    _ = scheduler.shouldSample(now: 0)

    XCTAssertFalse(scheduler.shouldSample(now: 5))
    XCTAssertFalse(scheduler.shouldSample(now: 9.99))
    XCTAssertTrue(scheduler.shouldSample(now: 10))
    XCTAssertFalse(scheduler.shouldSample(now: 12))
    XCTAssertTrue(scheduler.shouldSample(now: 20))
  }

  func testResetAllowsImmediateSampling() {
    var scheduler = RTMPLiveSceneScheduler(sampleInterval: 10)
    _ = scheduler.shouldSample(now: 0)
    XCTAssertFalse(scheduler.shouldSample(now: 5))

    scheduler.reset()
    XCTAssertTrue(scheduler.shouldSample(now: 6))
  }

  func testConsumeDetectsSceneChange() {
    var scheduler = RTMPLiveSceneScheduler(sampleInterval: 10)
    XCTAssertTrue(scheduler.consume(summary: "Restaurant"))
    XCTAssertFalse(scheduler.consume(summary: "Restaurant"))
    XCTAssertTrue(scheduler.consume(summary: "Street"))
  }

  func testConsumeEmptySummaryIsAChangeFromNilOnlyOnce() {
    var scheduler = RTMPLiveSceneScheduler(sampleInterval: 10)
    XCTAssertTrue(scheduler.consume(summary: ""))
    XCTAssertFalse(scheduler.consume(summary: ""))
  }
}

final class RTMPLiveSceneProcessorTests: XCTestCase {
  private func result(classifications: [(String, Float)]) -> VisionSceneResult {
    VisionSceneResult(
      classifications: classifications.map {
        VisionSceneItem(identifier: $0.0, confidence: $0.1)
      }
    )
  }

  func testSceneLabelPicksHighestConfidenceAboveThreshold() {
    let result = result(classifications: [("Street", 0.6), ("Restaurant", 0.8)])
    XCTAssertEqual(RTMPLiveSceneProcessor.sceneLabel(from: result), "Restaurant")
  }

  func testSceneLabelIgnoresLowConfidence() {
    let result = result(classifications: [("Street", 0.1), ("Restaurant", 0.2)])
    XCTAssertNil(RTMPLiveSceneProcessor.sceneLabel(from: result))
  }

  func testSceneLabelEmptyResult() {
    XCTAssertNil(RTMPLiveSceneProcessor.sceneLabel(from: VisionSceneResult()))
  }
}

final class RTMPDiagnosticsCollectorTests: XCTestCase {
  func testBeginResetsAndCountsInitialConnection() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin(now: Date(timeIntervalSince1970: 100))
    XCTAssertEqual(collector.snapshot.connectionAttempts, 1)
    XCTAssertEqual(collector.snapshot.startedAt?.timeIntervalSince1970, 100)
  }

  func testEndSetsDuration() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin(now: Date(timeIntervalSince1970: 100))
    collector.end(now: Date(timeIntervalSince1970: 130))
    XCTAssertEqual(collector.snapshot.duration, 30)
  }

  func testReconnectIncrementsCounters() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin()
    collector.recordReconnect()
    collector.recordReconnect()
    XCTAssertEqual(collector.snapshot.reconnectAttempts, 2)
    XCTAssertEqual(collector.snapshot.connectionAttempts, 3)
  }

  func testQualityChangesTrackHistory() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin()
    collector.recordQualityChange(upshift: false, presetLabel: "420×420@24")
    collector.recordQualityChange(upshift: false, presetLabel: "360×360@20")
    collector.recordQualityChange(upshift: true, presetLabel: "420×420@24")

    XCTAssertEqual(collector.snapshot.qualityDownshifts, 2)
    XCTAssertEqual(collector.snapshot.qualityUpshifts, 1)
    XCTAssertEqual(collector.snapshot.qualityHistory, ["420×420@24", "360×360@20", "420×420@24"])
  }

  func testDropRateComputedFromFrameStats() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin()
    collector.recordFrameStats(total: 1000, dropped: 30)
    XCTAssertEqual(collector.snapshot.totalFrames, 1000)
    XCTAssertEqual(collector.snapshot.droppedFrames, 30)
    XCTAssertEqual(collector.snapshot.dropRate, 0.03, accuracy: 0.0001)

    collector.recordFrameStats(total: 0, dropped: 0)
    XCTAssertEqual(collector.snapshot.dropRate, 0)
  }

  func testMarkerAndSceneCounters() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin()
    collector.recordRecordingMarker()
    collector.recordRecordingMarker()
    collector.recordSceneChange()
    XCTAssertEqual(collector.snapshot.recordingMarkers, 2)
    XCTAssertEqual(collector.snapshot.sceneChanges, 1)
  }
}

final class RTMPDiagnosticsReportTests: XCTestCase {
  func testReportTextContainsKeyMetrics() {
    var collector = RTMPDiagnosticsCollector()
    collector.begin(now: Date(timeIntervalSince1970: 0))
    collector.end(now: Date(timeIntervalSince1970: 125))
    collector.recordFrameStats(total: 3000, dropped: 150)
    collector.recordReconnect()
    collector.recordQualityChange(upshift: false, presetLabel: "360×360@20")
    collector.recordRecordingMarker()

    let report = RTMPDiagnosticsReport.text(
      from: collector.snapshot,
      durationText: { $0.map(RTMPRecordingNaming.durationText) ?? "00:00" },
      numberText: { "\($0)" }
    )

    XCTAssertTrue(report.contains("Duration: 02:05"))
    XCTAssertTrue(report.contains("reconnects: 1"))
    XCTAssertTrue(report.contains("5.0%"))
    XCTAssertTrue(report.contains("360×360@20"))
    XCTAssertTrue(report.contains("Recording markers: 1"))
  }
}
