import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

@MainActor
final class WearablesBootstrapTests: XCTestCase {
  func testDetectsTheXCTestRuntime() {
    XCTAssertTrue(UnitTestRuntime.isActive)
  }

  func testUnitTestBootstrapDefersSDKConfiguration() {
    let bootstrap = WearablesBootstrap(isRunningUnitTests: true)

    guard case .testing = bootstrap.state else {
      return XCTFail("The unit-test host must not access Wearables.shared before mock setup")
    }
  }

  func testAppBundleContainsUsableDATConfiguration() {
    guard let configuration = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] else {
      return XCTFail("The app bundle must contain MWDAT configuration")
    }

    XCTAssertEqual(configuration["AppLinkURLScheme"] as? String, "hypermetaai://")
    XCTAssertFalse((configuration["MetaAppID"] as? String)?.isEmpty ?? true)
    XCTAssertFalse((configuration["TeamID"] as? String)?.isEmpty ?? true)

    let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
    let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
    XCTAssertTrue(schemes.contains("hypermetaai"))
  }
}

final class FrameUpdateThrottleTests: XCTestCase {
  func testPublishesFirstFrameAndThrottlesFramesWithinInterval() {
    var throttle = FrameUpdateThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldPublish(at: 0))
    XCTAssertFalse(throttle.shouldPublish(at: 0.05))
    XCTAssertTrue(throttle.shouldPublish(at: 1.0 / 15.0))
  }

  func testResetAllowsAnImmediateFrame() {
    var throttle = FrameUpdateThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldPublish(at: 10))
    XCTAssertFalse(throttle.shouldPublish(at: 10.01))

    throttle.reset()

    XCTAssertTrue(throttle.shouldPublish(at: 10.01))
  }
}

final class FrameIngressThrottleTests: XCTestCase {
  func testAcceptsOnlyFramesAtTheConfiguredCadence() {
    let throttle = FrameIngressThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldAccept(at: 10))
    XCTAssertFalse(throttle.shouldAccept(at: 10.05))
    XCTAssertTrue(throttle.shouldAccept(at: 10 + (1.0 / 15.0)))
  }

  func testResetAllowsTheFirstFrameOfANewStreamGeneration() {
    let throttle = FrameIngressThrottle(maximumFramesPerSecond: 15)

    XCTAssertTrue(throttle.shouldAccept(at: 10))
    XCTAssertFalse(throttle.shouldAccept(at: 10.01))

    throttle.reset()

    XCTAssertTrue(throttle.shouldAccept(at: 10.01))
  }

  func testProviderSnapshotCadenceAcceptsOnlyTheLatestTwoFramesPerSecond() {
    let throttle = FrameIngressThrottle(maximumFramesPerSecond: 2)

    XCTAssertTrue(throttle.shouldAccept(at: 500))
    XCTAssertFalse(throttle.shouldAccept(at: 500.499))
    XCTAssertTrue(throttle.shouldAccept(at: 500.5))
    XCTAssertFalse(throttle.shouldAccept(at: 500.999))
    XCTAssertTrue(throttle.shouldAccept(at: 501))
  }
}

final class PhonePreviewSharpeningConfigurationTests: XCTestCase {
  func testIsDisabledWithoutTheLaunchArgument() {
    XCTAssertEqual(
      PhonePreviewSharpeningConfiguration.from(arguments: ["HyperMetaAI"]),
      .disabled
    )
  }

  func testEnablesOnlyForAnExplicitTruthyLaunchArgument() {
    XCTAssertEqual(
      PhonePreviewSharpeningConfiguration.from(
        arguments: ["HyperMetaAI", "-PhonePreviewSharpeningEnabled", "YES"]
      ),
      .enabled
    )
    XCTAssertEqual(
      PhonePreviewSharpeningConfiguration.from(
        arguments: ["HyperMetaAI", "-PhonePreviewSharpeningEnabled", "NO"]
      ),
      .disabled
    )
  }

  func testLowPowerModeReducesTheDisplayOnlyBudget() {
    let budget = PhonePreviewSharpeningBudget.apply(
      requested: .enabled,
      isLowPowerModeEnabled: true,
      thermalState: .nominal
    )

    XCTAssertTrue(budget.isEnabled)
    XCTAssertEqual(budget.maximumFramesPerSecond, 10)
    XCTAssertEqual(budget.maximumPixelDimension, 960)
    XCTAssertEqual(budget.sharpness, 0.18)
  }

  func testSeriousThermalStateReducesTheDisplayOnlyBudget() {
    let budget = PhonePreviewSharpeningBudget.apply(
      requested: .enabled,
      isLowPowerModeEnabled: false,
      thermalState: .serious
    )

    XCTAssertTrue(budget.isEnabled)
    XCTAssertEqual(budget.maximumFramesPerSecond, 10)
    XCTAssertEqual(budget.maximumPixelDimension, 960)
    XCTAssertEqual(budget.sharpness, 0.18)
  }

  func testCriticalThermalStateDisablesThePreviewFilter() {
    XCTAssertEqual(
      PhonePreviewSharpeningBudget.apply(
        requested: .enabled,
        isLowPowerModeEnabled: false,
        thermalState: .critical
      ),
      .disabled
    )
  }

  func testRuntimeBudgetCanDisableTheFilterWithoutTouchingTheSourceBuffer() {
    let source = makePixelBuffer(width: 8, height: 8)
    let renderer = PhonePreviewSharpeningRenderer(
      configuration: .enabled,
      runtimeBudget: { _ in .disabled }
    )

    guard case .ready(let preview) = renderer.prepare(source) else {
      return XCTFail("A disabled runtime budget should pass the source through")
    }

    XCTAssertTrue(CFEqual(source, preview))
    XCTAssertEqual(renderer.drainPerformanceSnapshot().inputFrames, 0)
  }

  func testCreatesAnIndependentDisplayBufferWithoutMutatingTheSource() {
    let source = makePixelBuffer(width: 8, height: 8)
    fillPixelBuffer(source, with: 0x7F)
    let renderer = PhonePreviewSharpeningRenderer(configuration: .enabled)

    let preview: CVPixelBuffer
    switch renderer.prepare(source) {
    case .ready(let pixelBuffer):
      preview = pixelBuffer
    case .throttled:
      return XCTFail("The first preview frame should not be throttled")
    }

    XCTAssertEqual(CVPixelBufferGetPixelFormatType(preview), kCVPixelFormatType_32BGRA)
    XCTAssertFalse(CFEqual(source, preview))
    XCTAssertTrue(readPixelBufferBytes(source).allSatisfy { $0 == 0x7F })

    let metrics = renderer.drainPerformanceSnapshot()
    XCTAssertEqual(metrics.inputFrames, 1)
    XCTAssertEqual(metrics.renderedFrames, 1)
    XCTAssertEqual(metrics.renderFailures, 0)
  }

  func testBoundsSharpenedDisplayOutputToConfiguredPixelDimension() {
    let source = makePixelBuffer(width: 1_600, height: 900)
    let renderer = PhonePreviewSharpeningRenderer(configuration: .enabled)

    let preview: CVPixelBuffer
    switch renderer.prepare(source) {
    case .ready(let pixelBuffer):
      preview = pixelBuffer
    case .throttled:
      return XCTFail("The first preview frame should not be throttled")
    }

    XCTAssertEqual(CVPixelBufferGetWidth(preview), 1_280)
    XCTAssertEqual(CVPixelBufferGetHeight(preview), 720)
    XCTAssertFalse(CFEqual(source, preview))
  }

  func testDropsFramesThatExceedThePreviewBudgetCadence() {
    let configuration = PhonePreviewSharpeningConfiguration(
      isEnabled: true,
      maximumFramesPerSecond: 1,
      maximumPixelDimension: 64,
      sharpness: 0.25
    )
    let renderer = PhonePreviewSharpeningRenderer(configuration: configuration)
    let source = makePixelBuffer(width: 8, height: 8)

    guard case .ready = renderer.prepare(source) else {
      return XCTFail("The first preview frame should not be throttled")
    }
    guard case .throttled = renderer.prepare(source) else {
      return XCTFail("The second immediate frame should be throttled")
    }

    let metrics = renderer.drainPerformanceSnapshot()
    XCTAssertEqual(metrics.inputFrames, 2)
    XCTAssertEqual(metrics.renderedFrames, 1)
    XCTAssertEqual(metrics.throttleDrops, 1)
  }

  func testSharpeningPerformanceForDATLowResolutionFrame() {
    let source = makePixelBuffer(width: 504, height: 504)
    fillPixelBuffer(source, with: 0x7F)
    let renderer = PhonePreviewSharpeningRenderer(configuration: .enabled)

    // Warm Core Image and the pixel-buffer pool before recording the steady
    // state. The result bundle retains the measurement for trend comparison.
    _ = renderer.prepare(source)
    renderer.reset()

    let options = XCTMeasureOptions()
    options.iterationCount = 5
    measure(metrics: [XCTClockMetric()], options: options) {
      renderer.reset()
      guard case .ready = renderer.prepare(source) else {
        return XCTFail("A reset renderer should accept its first frame")
      }
    }
  }

  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    return try! XCTUnwrap(pixelBuffer)
  }

  private func fillPixelBuffer(_ pixelBuffer: CVPixelBuffer, with value: UInt8) {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return XCTFail("Expected writable pixel buffer memory")
    }
    _ = memset(baseAddress, Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
  }

  private func readPixelBufferBytes(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      XCTFail("Expected readable pixel buffer memory")
      return []
    }
    return Array(
      UnsafeBufferPointer(
        start: baseAddress.assumingMemoryBound(to: UInt8.self),
        count: CVPixelBufferGetDataSize(pixelBuffer)
      )
    )
  }
}

final class RealtimeTextDeltaCoalescerTests: XCTestCase {
  func testFlushBatchesMultipleDeltasIntoOneBackgroundSnapshot() {
    let snapshotExpectation = expectation(description: "coalesced snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.flush",
      publishingInterval: 60
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var snapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 4) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      snapshotExpectation.fulfill()
    }

    XCTAssertEqual(coalescer.append("Hello"), .accepted)
    XCTAssertEqual(coalescer.append(" world"), .accepted)
    coalescer.flush()

    wait(for: [snapshotExpectation], timeout: 1)

    lock.lock()
    let snapshot = snapshots.first
    lock.unlock()
    XCTAssertEqual(snapshot?.sessionGeneration, 4)
    XCTAssertEqual(snapshot?.responseID, 1)
    XCTAssertEqual(snapshot?.sequence, 1)
    XCTAssertEqual(snapshot?.text, "Hello world")
    XCTAssertFalse(snapshot?.isFinal ?? true)
    XCTAssertEqual(snapshot?.coalescedDeltaCount, 2)

    let metrics = coalescer.performanceSnapshot()
    XCTAssertEqual(metrics.inputDeltas, 2)
    XCTAssertEqual(metrics.publishedSnapshots, 1)
    XCTAssertEqual(metrics.currentPendingDeltas, 0)
    XCTAssertEqual(metrics.maximumPendingDeltas, 2)
  }

  func testFinalProviderTextReplacesBufferedDeltaAndIsDeliveredOnce() {
    let finalExpectation = expectation(description: "final snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.final",
      publishingInterval: 60
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var finalSnapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 9) { snapshot in
      guard snapshot.isFinal else { return }
      lock.lock()
      finalSnapshots.append(snapshot)
      lock.unlock()
      finalExpectation.fulfill()
    }

    XCTAssertEqual(coalescer.append("partial"), .accepted)
    coalescer.finish(finalText: "authoritative final text")
    coalescer.finish(finalText: "duplicate completion")

    wait(for: [finalExpectation], timeout: 1)

    lock.lock()
    let snapshots = finalSnapshots
    lock.unlock()
    XCTAssertEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots.first?.text, "authoritative final text")
    XCTAssertTrue(snapshots.first?.isFinal ?? false)

    let metrics = coalescer.performanceSnapshot()
    XCTAssertEqual(metrics.completedResponses, 1)
    XCTAssertEqual(metrics.publishedSnapshots, 1)
  }

  func testNewResponseAfterCompletionUsesANewResponseID() {
    let firstFinalExpectation = expectation(description: "first response final")
    let secondSnapshotExpectation = expectation(description: "second response snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.responses",
      publishingInterval: 60
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var snapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 2) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      if snapshot.isFinal {
        firstFinalExpectation.fulfill()
      } else if snapshot.responseID == 2 {
        secondSnapshotExpectation.fulfill()
      }
    }

    XCTAssertEqual(coalescer.append("first"), .accepted)
    coalescer.finish()
    wait(for: [firstFinalExpectation], timeout: 1)

    XCTAssertEqual(coalescer.append("second"), .accepted)
    coalescer.flush()
    wait(for: [secondSnapshotExpectation], timeout: 1)

    lock.lock()
    let delivered = snapshots
    lock.unlock()
    XCTAssertEqual(delivered.map(\.responseID), [1, 2])
    XCTAssertEqual(delivered.map(\.text), ["first", "second"])
  }

  func testRestartDropsPendingTextAndIncomingDeltasStayBounded() {
    let snapshotExpectation = expectation(description: "new session snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.bounds",
      publishingInterval: 60,
      maximumPendingDeltaCount: 4,
      maximumPendingCharacterCount: 4
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var snapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 1) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      if snapshot.sessionGeneration == 2 {
        snapshotExpectation.fulfill()
      }
    }
    XCTAssertEqual(coalescer.append("old"), .accepted)

    coalescer.start(generation: 2) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      if snapshot.sessionGeneration == 2 {
        snapshotExpectation.fulfill()
      }
    }
    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
      _ = coalescer.append("x")
    }
    coalescer.flush()

    wait(for: [snapshotExpectation], timeout: 1)

    lock.lock()
    let delivered = snapshots
    lock.unlock()
    XCTAssertEqual(delivered.last?.sessionGeneration, 2)
    XCTAssertEqual(delivered.last?.text, "xxxx")
    XCTAssertEqual(delivered.last?.coalescedDeltaCount, 4)

    let metrics = coalescer.performanceSnapshot()
    XCTAssertLessThanOrEqual(metrics.maximumPendingDeltas, 4)
    XCTAssertLessThanOrEqual(metrics.maximumPendingCharacters, 4)
    XCTAssertEqual(metrics.pendingBufferDrops, 996)

    coalescer.stop()
    XCTAssertEqual(coalescer.append("after stop"), .inactive)
  }
}

final class VideoFramePerformanceMonitorTests: XCTestCase {
  func testCapturesQueueDepthLatencyDropsAndConversionTiming() {
    let monitor = VideoFramePerformanceMonitor(windowStartedAt: 10)

    monitor.recordFrameReceived()
    monitor.recordMailboxOffer(replacedExistingFrame: false)
    monitor.recordFrameReceived()
    monitor.recordMailboxOffer(replacedExistingFrame: true)
    monitor.recordMainActorEntry(at: 10.010, receivedAt: 10)
    monitor.recordDrop(.throttle)
    monitor.recordMainActorEntry(at: 10.030, receivedAt: 10)
    monitor.recordImageConversion(duration: 0.004, published: true)
    monitor.recordDrop(.staleGeneration)
    monitor.recordDrop(.decoderBackpressure)
    monitor.recordQueueDepth(4)

    let snapshot = monitor.snapshot(at: 11)

    XCTAssertEqual(snapshot.inputFrames, 2)
    XCTAssertEqual(snapshot.mainActorDeliveries, 2)
    XCTAssertEqual(snapshot.publishedFrames, 1)
    XCTAssertEqual(snapshot.mailboxReplacements, 1)
    XCTAssertEqual(snapshot.throttleDrops, 1)
    XCTAssertEqual(snapshot.staleGenerationDrops, 1)
    XCTAssertEqual(snapshot.decoderBackpressureDrops, 1)
    XCTAssertEqual(snapshot.droppedFrames, 4)
    XCTAssertEqual(snapshot.currentQueueDepth, 0)
    XCTAssertEqual(snapshot.maximumQueueDepth, 4)
    XCTAssertEqual(snapshot.inputFramesPerSecond, 2)
    XCTAssertEqual(snapshot.publishedFramesPerSecond, 1)
    XCTAssertEqual(snapshot.averageMainActorDispatchLatencyMilliseconds, 20, accuracy: 0.001)
    XCTAssertEqual(snapshot.maximumMainActorDispatchLatencyMilliseconds, 30, accuracy: 0.001)
    XCTAssertEqual(snapshot.averageImageConversionMilliseconds, 4, accuracy: 0.001)
    XCTAssertEqual(snapshot.maximumImageConversionMilliseconds, 4, accuracy: 0.001)
  }

  func testSnapshotStartsANewMetricsWindow() {
    let monitor = VideoFramePerformanceMonitor(windowStartedAt: 0)

    monitor.recordFrameReceived()
    monitor.recordMailboxOffer(replacedExistingFrame: false)
    _ = monitor.snapshot(at: 1)

    let secondWindow = monitor.snapshot(at: 2)

    XCTAssertTrue(secondWindow.isEmpty)
    XCTAssertEqual(secondWindow.intervalSeconds, 1)
    XCTAssertEqual(secondWindow.currentQueueDepth, 0)
  }

  func testCountsRenderedFramesOnlyWhenTheMainActorPublishesThem() {
    let monitor = VideoFramePerformanceMonitor(windowStartedAt: 0)

    monitor.recordImageConversion(duration: 0.004, published: false)
    monitor.recordPublishedFrame()

    let snapshot = monitor.snapshot(at: 1)
    XCTAssertEqual(snapshot.publishedFrames, 1)
    XCTAssertEqual(snapshot.averageImageConversionMilliseconds, 4, accuracy: 0.001)
  }
}

final class RealtimeProviderAudioProfileTests: XCTestCase {
  func testQwenProfileUsesCanonicalPCMAndExplicitSampleRates() {
    let profile = RealtimeProviderAudioProfiles.qwen

    XCTAssertEqual(profile.sessionInputFormat, "pcm")
    XCTAssertEqual(profile.sessionOutputFormat, "pcm")
    XCTAssertEqual(profile.inputSampleRate, 16_000)
    XCTAssertEqual(profile.outputFormat, .realtimePCM16Mono24kHz)
  }

  func testQwenProfileBoundsUploadTailLatency() {
    let profile = RealtimeProviderAudioProfiles.qwen

    XCTAssertEqual(profile.uploadSendTimeout, 0.25)
    XCTAssertEqual(profile.maximumQueuedInputAge, 0.12)
    XCTAssertEqual(profile.criticalControlSendTimeout, 0.15)
  }

  func testOmniSessionConfigurationUsesTheQwenPCMContract() throws {
    let event = OmniRealtimeService.makeSessionConfiguration(
      eventID: "test-event",
      voice: "Tina",
      instructions: "test instructions"
    )
    let session = try XCTUnwrap(event["session"] as? [String: Any])

    XCTAssertEqual(event["event_id"] as? String, "test-event")
    XCTAssertEqual(event["type"] as? String, OmniClientEvent.sessionUpdate.rawValue)
    XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
    XCTAssertEqual(session["output_audio_format"] as? String, "pcm")
    XCTAssertEqual(session["modalities"] as? [String], ["text", "audio"])
  }
}

final class TTSOutputLevelTests: XCTestCase {
  func testMixerRMSIsNormalizedForOrbFeedback() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)
    )
    buffer.frameLength = 128
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<128 {
      samples[index] = 0.0625
    }

    XCTAssertEqual(TTSService.normalizedAudioLevel(buffer), 0.5, accuracy: 0.01)
  }
}

final class AudioSessionProfileTests: XCTestCase {
  func testRealtimeProfilesReserveTheExclusiveInputPath() {
    XCTAssertTrue(AudioSessionProfile.voiceChat.requiresExclusiveInput)
    XCTAssertTrue(AudioSessionProfile.translation(usePhoneMic: true).requiresExclusiveInput)
    XCTAssertFalse(AudioSessionProfile.playback.requiresExclusiveInput)
  }

  func testDuplicateLiveAIClaimDoesNotReconfigureTheAudioRoute() throws {
    var registry = AudioSessionClaimRegistry()

    XCTAssertEqual(
      try registry.activate(.liveAI, profile: .voiceChat),
      .apply(.voiceChat)
    )
    XCTAssertEqual(
      try registry.activate(.liveAI, profile: .voiceChat),
      .none
    )
  }

  func testDuplicateReleaseDoesNotDeactivateTheAudioRouteTwice() throws {
    var registry = AudioSessionClaimRegistry()
    _ = try registry.activate(.liveAI, profile: .voiceChat)

    XCTAssertEqual(registry.deactivate(.liveAI), .deactivate)
    XCTAssertEqual(registry.deactivate(.liveAI), .none)
  }

  func testLowerPriorityPlaybackClaimDoesNotReconfigureVoiceChat() throws {
    var registry = AudioSessionClaimRegistry()
    _ = try registry.activate(.liveAI, profile: .voiceChat)

    XCTAssertEqual(
      try registry.activate(.textToSpeech, profile: .playback),
      .none
    )
    XCTAssertEqual(registry.deactivate(.textToSpeech), .none)
    XCTAssertEqual(registry.deactivate(.liveAI), .deactivate)
  }
}

final class RealtimeSessionConfigurationGateTests: XCTestCase {
  func testConfigurationConfirmationIsGenerationScopedAndIdempotent() {
    let gate = RealtimeSessionConfigurationGate()

    gate.activate(generation: 4)
    XCTAssertFalse(gate.confirm(generation: 3))
    XCTAssertTrue(gate.confirm(generation: 4))
    XCTAssertFalse(gate.confirm(generation: 4))

    gate.activate(generation: 5)
    XCTAssertTrue(gate.confirm(generation: 5))
    gate.invalidate()
    XCTAssertFalse(gate.confirm(generation: 5))
  }
}

final class LatestFrameMailboxTests: XCTestCase {
  func testRetainsOnlyTheLatestFrame() {
    let mailbox = LatestFrameMailbox<Int>()
    XCTAssertFalse(mailbox.activate(generation: 3))

    guard case .accepted(let firstOfferReplaced) = mailbox.offer(
      LatestFrameMailboxItem(value: 1, generation: 3, receivedAt: 10)
    ) else {
      return XCTFail("The active generation should accept its first frame")
    }
    XCTAssertFalse(firstOfferReplaced)

    guard case .accepted(let secondOfferReplaced) = mailbox.offer(
      LatestFrameMailboxItem(value: 2, generation: 3, receivedAt: 11)
    ) else {
      return XCTFail("The active generation should accept its replacement frame")
    }
    XCTAssertTrue(secondOfferReplaced)
    XCTAssertEqual(mailbox.depth, 1)

    let item = mailbox.takeLatest()

    XCTAssertEqual(item?.value, 2)
    XCTAssertEqual(item?.generation, 3)
    XCTAssertEqual(item?.receivedAt, 11)
    XCTAssertEqual(mailbox.depth, 0)
  }

  func testConcurrentOffersRemainBounded() {
    let mailbox = LatestFrameMailbox<Int>()
    _ = mailbox.activate(generation: 1)

    DispatchQueue.concurrentPerform(iterations: 1_000) { index in
      _ = mailbox.offer(
        LatestFrameMailboxItem(value: index, generation: 1, receivedAt: Double(index))
      )
    }

    XCTAssertEqual(mailbox.depth, 1)
    XCTAssertNotNil(mailbox.takeLatest())
    XCTAssertEqual(mailbox.depth, 0)
  }

  func testRejectsFramesFromInactiveAndPreviousGenerations() {
    let mailbox = LatestFrameMailbox<Int>()

    XCTAssertEqual(
      mailbox.offer(LatestFrameMailboxItem(value: 1, generation: 1, receivedAt: 1)),
      .staleGeneration
    )
    XCTAssertFalse(mailbox.activate(generation: 1))
    _ = mailbox.offer(LatestFrameMailboxItem(value: 2, generation: 1, receivedAt: 2))

    XCTAssertTrue(mailbox.activate(generation: 2))
    XCTAssertEqual(mailbox.depth, 0)
    XCTAssertEqual(
      mailbox.offer(LatestFrameMailboxItem(value: 3, generation: 1, receivedAt: 3)),
      .staleGeneration
    )
    XCTAssertEqual(
      mailbox.offer(LatestFrameMailboxItem(value: 4, generation: 2, receivedAt: 4)),
      .accepted(replacedExistingFrame: false)
    )
  }
}

final class RealtimeAudioCaptureMailboxTests: XCTestCase {
  private static let interactiveUploadBudgetMilliseconds = 20.0
  private static let resamplingBudgetMillisecondsPerFrame = 0.35

  func testPCM16EncoderMapsFloatSamplesWithoutResampling() throws {
    let encoder = PCM16AudioEncoder(targetSampleRate: nil)
    let frame = RealtimeAudioCapturedFrame(
      samples: [-1, 0, 0.5, 1],
      sampleRate: 16_000,
      sourceChannelCount: 1,
      generation: 1,
      capturedAt: 0
    )

    let data = try XCTUnwrap(encoder.encode(frame))
    let samples = data.withUnsafeBytes { bytes in
      Array(bytes.bindMemory(to: Int16.self))
    }

    XCTAssertEqual(samples, [-32_767, 0, 16_383, 32_767])
    XCTAssertEqual(encoder.allocatedAudioBufferCount, 0)
  }

  func testEncoderCalculatesRMSWhileWritingPCM16() throws {
    let encoder = PCM16AudioEncoder(targetSampleRate: nil)
    let frame = RealtimeAudioCapturedFrame(
      samples: [-1, -0.5, 0, 0.25, 0.75, 1],
      sampleRate: 16_000,
      sourceChannelCount: 1,
      generation: 1,
      capturedAt: 0
    )

    let encoded = try XCTUnwrap(encoder.encode(frame, includeStats: true))
    XCTAssertEqual(
      encoded.stats,
      RealtimePCM16AudioMeter.stats(for: encoded.data)
    )
  }

  func testUploadPipelineUsesInjectedBackgroundSenderAndReportsAudioStats() throws {
    let pipeline = RealtimeAudioUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.injected-audio-sender",
      targetSampleRate: 16_000,
      slotCount: 2,
      maximumFramesPerBuffer: 16
    )
    let format = try makeFormat(sampleRate: 48_000)
    let sent = expectation(description: "audio message sent")
    let analyzed = expectation(description: "audio frame analyzed")
    let firstAudio = expectation(description: "first audio callback")

    pipeline.start(
      generation: 5,
      inputFormat: format,
      messageBuilder: { .string($0.base64EncodedString()) },
      messageSender: { message, completion in
        XCTAssertFalse(Thread.isMainThread)
        guard case .string(let text) = message else {
          return XCTFail("expected a text WebSocket message")
        }
        XCTAssertFalse(text.isEmpty)
        sent.fulfill()
        completion(nil)
      },
      onEncodedAudio: { stats in
        XCTAssertEqual(stats.sampleCount, 4)
        XCTAssertGreaterThan(stats.rms, 0)
        analyzed.fulfill()
      },
      onFirstAudioSent: {
        firstAudio.fulfill()
      },
      onFailure: { message in
        XCTFail("unexpected upload failure: \(message)")
      }
    )

    pipeline.capture(
      try makeBuffer(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 16_000),
      generation: 5
    )

    wait(for: [sent, analyzed, firstAudio], timeout: 2)
    let metrics = pipeline.snapshot()
    XCTAssertEqual(metrics.sentBuffers, 1)
    pipeline.stop()
  }

  func testCapturedAudioFeedbackBypassesBlockedSend() throws {
    let pipeline = RealtimeAudioUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.capture-side-audio-feedback",
      targetSampleRate: 16_000,
      slotCount: 3,
      maximumFramesPerBuffer: 1_024,
      sendTimeout: 1
    )
    defer { pipeline.stop() }
    let format = try makeFormat(sampleRate: 48_000)
    let firstSendStarted = expectation(description: "first send is blocked")
    let firstCaptured = expectation(description: "first frame reaches capture feedback")
    let secondCaptured = expectation(description: "second frame bypasses blocked send")
    let secondSendStarted = expectation(description: "second frame sends after release")
    let firstAudio = expectation(description: "first send completion reaches main actor")
    var blockedCompletion: ((Error?) -> Void)?
    var sendCount = 0
    let feedbackProbe = RealtimeCaptureFeedbackProbe()

    pipeline.start(
      generation: 1,
      inputFormat: format,
      messageBuilder: { .data($0) },
      messageSender: { _, completion in
        sendCount += 1
        if sendCount == 1 {
          blockedCompletion = completion
          firstSendStarted.fulfill()
        } else {
          secondSendStarted.fulfill()
          completion(nil)
        }
      },
      onCapturedAudio: { stats in
        XCTAssertEqual(stats.sampleCount, 960)
        XCTAssertEqual(stats.sampleRate, 48_000)
        XCTAssertEqual(stats.duration, 0.02, accuracy: 0.000_001)
        XCTAssertGreaterThan(stats.rms, 0)
        let feedback = feedbackProbe.record(at: ProcessInfo.processInfo.systemUptime)
        if feedback.index == 1 {
          firstCaptured.fulfill()
        } else if feedback.index == 2 {
          secondCaptured.fulfill()
        }
      },
      onFirstAudioSent: {
        firstAudio.fulfill()
      },
      onFailure: { message in
        XCTFail("unexpected upload failure: \(message)")
      }
    )

    let samples = (0..<960).map { index in
      index.isMultiple(of: 2) ? Float(0.25) : Float(-0.25)
    }
    let buffer = try makeBuffer(samples: samples, sampleRate: 48_000)
    pipeline.capture(buffer, generation: 1)
    wait(for: [firstSendStarted, firstCaptured], timeout: 1)

    feedbackProbe.markSecondCapture(at: ProcessInfo.processInfo.systemUptime)
    pipeline.capture(buffer, generation: 1)
    wait(for: [secondCaptured], timeout: 1)
    let blockedMetrics = pipeline.snapshot()
    XCTAssertEqual(blockedMetrics.encodedBuffers, 1)
    XCTAssertEqual(blockedMetrics.sentBuffers, 0)

    blockedCompletion?(nil)
    wait(for: [firstAudio, secondSendStarted], timeout: 1)

    let secondCaptureFeedbackMilliseconds = feedbackProbe.secondFeedbackMilliseconds
    let attachment = XCTAttachment(
      string: "captureSideDetectionDelayMs=\(secondCaptureFeedbackMilliseconds)"
    )
    attachment.name = "Realtime capture-side detection under blocked send"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertLessThan(secondCaptureFeedbackMilliseconds, 10)
  }

  func testImmediateFirstCaptureIsNeverLostToAnEmptyStartupDrain() throws {
    let pipeline = RealtimeAudioUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.immediate-first-capture",
      targetSampleRate: 16_000,
      slotCount: 2,
      maximumFramesPerBuffer: 16
    )
    let format = try makeFormat(sampleRate: 16_000)
    let buffer = try makeBuffer(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 16_000)

    for generation in 1...50 {
      let sent = expectation(description: "generation \(generation) first frame sent")
      pipeline.start(
        generation: generation,
        inputFormat: format,
        messageBuilder: { .data($0) },
        messageSender: { _, completion in
          sent.fulfill()
          completion(nil)
        },
        onFirstAudioSent: {},
        onFailure: { message in
          XCTFail("unexpected upload failure: \(message)")
        }
      )
      pipeline.capture(buffer, generation: generation)
      wait(for: [sent], timeout: 0.5)
    }
    pipeline.stop()
  }

  func testFirstCapturedFrameReachesSenderWithinInteractiveLatencyBudget() throws {
    let pipeline = RealtimeAudioUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.first-audio-latency",
      targetSampleRate: 16_000,
      slotCount: 2,
      maximumFramesPerBuffer: 1_024
    )
    let format = try makeFormat(sampleRate: 48_000)
    let sent = expectation(description: "first audio reached sender")
    let firstAudio = expectation(description: "first audio completion reached main actor")
    var senderLatencyMilliseconds = 0.0
    let captureStartedAt = ProcessInfo.processInfo.systemUptime

    pipeline.start(
      generation: 1,
      inputFormat: format,
      messageBuilder: { .data($0) },
      messageSender: { _, completion in
        senderLatencyMilliseconds = (
          ProcessInfo.processInfo.systemUptime - captureStartedAt
        ) * 1_000
        sent.fulfill()
        completion(nil)
      },
      onFirstAudioSent: {
        firstAudio.fulfill()
      },
      onFailure: { message in
        XCTFail("unexpected upload failure: \(message)")
      }
    )
    pipeline.capture(
      try makeBuffer(
        samples: (0..<960).map { sin(Float($0) * 0.05) * 0.25 },
        sampleRate: 48_000
      ),
      generation: 1
    )

    wait(for: [sent, firstAudio], timeout: 2)
    let metrics = pipeline.snapshot()
    print(
      "[RealtimeAudioLatency] firstSenderMs=\(senderLatencyMilliseconds) "
        + "captureToSendMs=\(metrics.maximumCaptureToSendMilliseconds)"
    )
    let latencyAttachment = XCTAttachment(
      string: "firstSenderMs=\(senderLatencyMilliseconds)\n"
        + "captureToSendMs=\(metrics.maximumCaptureToSendMilliseconds)"
    )
    latencyAttachment.name = "Realtime first-frame upload latency"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)
    XCTAssertLessThan(
      senderLatencyMilliseconds,
      Self.interactiveUploadBudgetMilliseconds
    )
    XCTAssertLessThan(
      metrics.maximumCaptureToSendMilliseconds,
      Self.interactiveUploadBudgetMilliseconds
    )
    pipeline.stop()
  }

  func testUploadPipelineDropsQueuedFramesThatExpireBehindABlockedSend() throws {
    let pipeline = RealtimeAudioUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.stale-audio-drop",
      targetSampleRate: 16_000,
      slotCount: 2,
      maximumFramesPerBuffer: 16,
      maximumQueuedFrameAge: 0.12
    )
    let format = try makeFormat(sampleRate: 16_000)
    let firstSendStarted = expectation(description: "first send is in flight")
    let firstAudio = expectation(description: "first send completes")
    let staleFrameSent = expectation(description: "stale queued audio must not be sent")
    staleFrameSent.isInverted = true
    var blockedCompletion: ((Error?) -> Void)?
    var sendCount = 0

    pipeline.start(
      generation: 1,
      inputFormat: format,
      messageBuilder: { .data($0) },
      messageSender: { _, completion in
        sendCount += 1
        if sendCount == 1 {
          blockedCompletion = completion
          firstSendStarted.fulfill()
        } else {
          staleFrameSent.fulfill()
          completion(nil)
        }
      },
      onFirstAudioSent: {
        firstAudio.fulfill()
      },
      onFailure: { message in
        XCTFail("stale audio should be dropped without failing the session: \(message)")
      }
    )
    pipeline.capture(
      try makeBuffer(samples: [0.1, -0.1, 0.2, -0.2], sampleRate: 16_000),
      generation: 1
    )
    wait(for: [firstSendStarted], timeout: 1)
    pipeline.capture(
      try makeBuffer(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 16_000),
      generation: 1,
      capturedAt: ProcessInfo.processInfo.systemUptime - 1
    )
    blockedCompletion?(nil)

    wait(for: [firstAudio, staleFrameSent], timeout: 0.2)
    let metrics = pipeline.snapshot()
    XCTAssertEqual(metrics.staleFrameAgeDrops, 1)
    XCTAssertEqual(metrics.encodedBuffers, 1)
    XCTAssertEqual(metrics.sentBuffers, 1)
    XCTAssertEqual(metrics.currentQueueDepth, 0)
    pipeline.stop()
  }

  func testUploadTimeoutIsBoundedAndLateCompletionCannotPoisonTheNextGeneration() throws {
    let pipeline = RealtimeAudioUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.audio-send-timeout",
      targetSampleRate: 16_000,
      slotCount: 2,
      maximumFramesPerBuffer: 16,
      sendTimeout: 0.04,
      maximumQueuedFrameAge: 0.12
    )
    let format = try makeFormat(sampleRate: 16_000)
    let buffer = try makeBuffer(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 16_000)
    let timedOut = expectation(description: "blocked send times out")
    var blockedCompletion: ((Error?) -> Void)?
    var timeoutMilliseconds = 0.0
    let startedAt = ProcessInfo.processInfo.systemUptime

    pipeline.start(
      generation: 1,
      inputFormat: format,
      messageBuilder: { .data($0) },
      messageSender: { _, completion in
        blockedCompletion = completion
      },
      onFirstAudioSent: {
        XCTFail("a timed-out send must not report first audio")
      },
      onFailure: { message in
        timeoutMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        XCTAssertEqual(message, "Audio send timed out")
        timedOut.fulfill()
      }
    )
    pipeline.capture(buffer, generation: 1)

    wait(for: [timedOut], timeout: 1)
    let timeoutMetrics = pipeline.snapshot()
    print("[RealtimeAudioLatency] blockedSendTimeoutMs=\(timeoutMilliseconds)")
    let timeoutAttachment = XCTAttachment(
      string: "configuredSendTimeoutMs=40\nblockedSendTimeoutMs=\(timeoutMilliseconds)"
    )
    timeoutAttachment.name = "Realtime blocked-send timeout latency"
    timeoutAttachment.lifetime = .keepAlways
    add(timeoutAttachment)
    XCTAssertEqual(timeoutMetrics.sendTimeouts, 1)
    XCTAssertEqual(timeoutMetrics.sentBuffers, 0)
    XCTAssertGreaterThanOrEqual(timeoutMilliseconds, 30)
    XCTAssertLessThan(timeoutMilliseconds, 250)

    let sentAfterRestart = expectation(description: "next generation sends audio")
    let firstAudioAfterRestart = expectation(description: "next generation reports first audio")
    pipeline.start(
      generation: 2,
      inputFormat: format,
      messageBuilder: { .data($0) },
      messageSender: { _, completion in
        sentAfterRestart.fulfill()
        completion(nil)
      },
      onFirstAudioSent: {
        firstAudioAfterRestart.fulfill()
      },
      onFailure: { message in
        XCTFail("unexpected second-generation failure: \(message)")
      }
    )
    blockedCompletion?(nil)
    pipeline.capture(buffer, generation: 2)

    wait(for: [sentAfterRestart, firstAudioAfterRestart], timeout: 1)
    let restartedMetrics = pipeline.snapshot()
    XCTAssertEqual(restartedMetrics.sentBuffers, 1)
    XCTAssertEqual(restartedMetrics.sendFailures, 0)
    pipeline.stop()
  }

  func testFortyEightKilohertzResamplingMeetsPerFrameBudget() throws {
    let encoder = PCM16AudioEncoder(targetSampleRate: 16_000)
    let frame = RealtimeAudioCapturedFrame(
      samples: (0..<960).map { sin(Float($0) * 0.05) * 0.25 },
      sampleRate: 48_000,
      sourceChannelCount: 1,
      generation: 1,
      capturedAt: 0
    )
    for _ in 0..<20 {
      XCTAssertNotNil(encoder.encode(frame))
    }
    let warmBufferAllocationCount = encoder.allocatedAudioBufferCount

    let iterations = 500
    let startedAt = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations {
      XCTAssertNotNil(encoder.encode(frame))
    }
    let averageMilliseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000 / Double(iterations)
    print("[RealtimeAudioLatency] resample48To16AverageMs=\(averageMilliseconds)")
    let latencyAttachment = XCTAttachment(
      string: "resample48To16AverageMs=\(averageMilliseconds)"
    )
    latencyAttachment.name = "Realtime PCM16 resampling latency"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)

    XCTAssertEqual(warmBufferAllocationCount, 2)
    XCTAssertEqual(
      encoder.allocatedAudioBufferCount,
      warmBufferAllocationCount,
      "steady-state realtime encoding must reuse both AVAudioPCMBuffer instances"
    )

    XCTAssertLessThan(
      averageMilliseconds,
      Self.resamplingBudgetMillisecondsPerFrame
    )
  }

  func testDeliversCapturedSamplesAndRecordsMetrics() throws {
    let mailbox = RealtimeAudioCaptureMailbox(
      slotCount: 2,
      maximumFramesPerBuffer: 4,
      windowStartedAt: 10
    )
    let format = try makeFormat(sampleRate: 16_000)
    XCTAssertEqual(mailbox.activate(generation: 7, inputFormat: format), 0)

    let buffer = try makeBuffer(samples: [-1, -0.5, 0.25, 1], sampleRate: 16_000)
    XCTAssertEqual(mailbox.capture(buffer, generation: 7, capturedAt: 10.002), .accepted)

    let frame = try XCTUnwrap(mailbox.takeNext(expectedGeneration: 7))
    XCTAssertEqual(frame.generation, 7)
    XCTAssertEqual(frame.sampleRate, 16_000)
    XCTAssertEqual(frame.sourceChannelCount, 1)
    XCTAssertEqual(frame.samples, [-1, -0.5, 0.25, 1])

    mailbox.recordEncoded(duration: 0.003)
    mailbox.recordSendSuccess(capturedAt: frame.capturedAt, sentAt: 10.012)
    let snapshot = mailbox.snapshot(at: 11)

    XCTAssertEqual(snapshot.inputBuffers, 1)
    XCTAssertEqual(snapshot.inputFrames, 4)
    XCTAssertEqual(snapshot.encodedBuffers, 1)
    XCTAssertEqual(snapshot.sentBuffers, 1)
    XCTAssertEqual(snapshot.currentQueueDepth, 0)
    XCTAssertEqual(snapshot.maximumQueueDepth, 1)
    XCTAssertEqual(snapshot.lastInputSampleRate, 16_000)
    XCTAssertEqual(snapshot.lastInputChannelCount, 1)
    XCTAssertEqual(snapshot.averageEncodingMilliseconds, 3, accuracy: 0.001)
    XCTAssertEqual(snapshot.averageCaptureToSendMilliseconds, 10, accuracy: 0.001)
  }

  func testFullMailboxReplacesTheOldestQueuedBuffer() throws {
    let mailbox = RealtimeAudioCaptureMailbox(slotCount: 2, maximumFramesPerBuffer: 2)
    let format = try makeFormat(sampleRate: 24_000)
    _ = mailbox.activate(generation: 3, inputFormat: format)

    XCTAssertEqual(mailbox.capture(try makeBuffer(samples: [1], sampleRate: 24_000), generation: 3), .accepted)
    XCTAssertEqual(mailbox.capture(try makeBuffer(samples: [2], sampleRate: 24_000), generation: 3), .accepted)
    XCTAssertEqual(
      mailbox.capture(try makeBuffer(samples: [3], sampleRate: 24_000), generation: 3),
      .replacedOldestQueuedBuffer
    )

    XCTAssertEqual(try XCTUnwrap(mailbox.takeNext(expectedGeneration: 3)).samples, [2])
    XCTAssertEqual(try XCTUnwrap(mailbox.takeNext(expectedGeneration: 3)).samples, [3])

    let snapshot = mailbox.snapshot()
    XCTAssertEqual(snapshot.replacedQueuedBuffers, 1)
    XCTAssertEqual(snapshot.maximumQueueDepth, 2)
  }

  func testRejectsStaleAndInactiveGenerations() throws {
    let mailbox = RealtimeAudioCaptureMailbox(slotCount: 1, maximumFramesPerBuffer: 2)
    let format = try makeFormat(sampleRate: 16_000)
    let buffer = try makeBuffer(samples: [0.5], sampleRate: 16_000)
    _ = mailbox.activate(generation: 11, inputFormat: format)

    XCTAssertEqual(mailbox.capture(buffer, generation: 10), .staleGeneration)
    _ = mailbox.activate(generation: 12, inputFormat: format)
    XCTAssertEqual(mailbox.capture(buffer, generation: 11), .staleGeneration)
    XCTAssertEqual(mailbox.capture(buffer, generation: 12), .accepted)
    _ = mailbox.deactivateAndClear()
    XCTAssertEqual(mailbox.capture(buffer, generation: 12), .inactive)

    let snapshot = mailbox.snapshot()
    XCTAssertEqual(snapshot.staleGenerationDrops, 2)
    XCTAssertEqual(snapshot.inactiveDrops, 1)
  }

  func testConcurrentCaptureNeverExceedsFixedCapacity() throws {
    let mailbox = RealtimeAudioCaptureMailbox(slotCount: 3, maximumFramesPerBuffer: 4)
    let format = try makeFormat(sampleRate: 16_000)
    let buffer = try makeBuffer(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000)
    _ = mailbox.activate(generation: 1, inputFormat: format)

    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
      _ = mailbox.capture(buffer, generation: 1)
    }

    let snapshot = mailbox.snapshot()
    XCTAssertLessThanOrEqual(snapshot.currentQueueDepth, 3)
    XCTAssertLessThanOrEqual(snapshot.maximumQueueDepth, 3)
  }

  private func makeFormat(sampleRate: Double) throws -> AVAudioFormat {
    try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
  }

  private func makeBuffer(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
    let format = try makeFormat(sampleRate: sampleRate)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    )
    let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let baseAddress = source.baseAddress else { return }
      channel.update(from: baseAddress, count: samples.count)
    }
    return buffer
  }
}

final class RealtimeImageUploadPipelineTests: XCTestCase {
  func testEncodesImageOffTheMainThread() throws {
    let pipeline = RealtimeImageUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.image-upload"
    )
    let image = try makeTestImage()
    let encoded = expectation(description: "image is encoded")

    pipeline.start(generation: 7)
    let result = pipeline.submit(image, generation: 7) { imageData in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertFalse(imageData.isEmpty)
      encoded.fulfill()
    }

    XCTAssertEqual(result, .accepted)
    wait(for: [encoded], timeout: 2)
    pipeline.stop()
  }

  func testRejectsStaleGenerationAndSubmissionsAfterStop() throws {
    let pipeline = RealtimeImageUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.image-upload-generation"
    )
    let image = try makeTestImage()
    pipeline.start(generation: 11)

    XCTAssertEqual(
      pipeline.submit(image, generation: 10) { _ in },
      .staleGeneration
    )

    pipeline.stop()

    XCTAssertEqual(
      pipeline.submit(image, generation: 11) { _ in },
      .inactive
    )
  }

  private func makeTestImage() throws -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    return renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
  }
}

final class RealtimeAudioJitterBufferTests: XCTestCase {
  func testOnlyAcceptedOffersCanReachAudioConsumers() {
    XCTAssertTrue(RealtimeAudioJitterOfferResult.accepted.isAccepted)
    XCTAssertTrue(
      RealtimeAudioJitterOfferResult.replacedOldestQueuedChunks(
        chunkCount: 1,
        frameCount: 320
      ).isAccepted
    )
    XCTAssertFalse(RealtimeAudioJitterOfferResult.inactive.isAccepted)
    XCTAssertFalse(RealtimeAudioJitterOfferResult.staleGeneration.isAccepted)
    XCTAssertFalse(RealtimeAudioJitterOfferResult.invalidFrameAlignment.isAccepted)
    XCTAssertFalse(RealtimeAudioJitterOfferResult.oversizedChunk.isAccepted)
    XCTAssertFalse(RealtimeAudioJitterOfferResult.queueFull.isAccepted)
  }

  func testParsesProviderMimeParametersIntoAnExplicitFormat() {
    let format = RealtimePCMOutputFormat.pcm16LittleEndian(
      mimeType: "audio/pcm; rate=24000; channels=1",
      defaultSampleRate: 24_000,
      defaultChannelCount: 1
    )

    XCTAssertEqual(format, .realtimePCM16Mono24kHz)
    XCTAssertNil(
      RealtimePCMOutputFormat.pcm16LittleEndian(
        mimeType: "audio/ogg; rate=24000",
        defaultSampleRate: 24_000,
        defaultChannelCount: 1
      )
    )
    XCTAssertNil(
      RealtimePCMOutputFormat.pcm16LittleEndian(
        mimeType: "audio/pcm; rate=not-a-number",
        defaultSampleRate: 24_000,
        defaultChannelCount: 1
      )
    )
  }

  func testQwenObservedResponsePacketFitsItsBoundedJitterWindow() throws {
    let profile = RealtimeProviderAudioProfiles.qwen
    let maximumFrames = Int(
      profile.outputFormat.sampleRate * profile.maximumJitterMilliseconds / 1_000
    )
    let buffer = RealtimeAudioJitterBuffer(maximumQueuedFrames: maximumFrames)
    _ = buffer.activate(generation: 31)
    let response = try XCTUnwrap(buffer.beginResponse(generation: 31))

    // A real Qwen response packet captured on device: 15,360 bytes of PCM16
    // at 24 kHz equals 7,680 frames, or 320 ms.
    let packet = Data(repeating: 0, count: 15_360)
    XCTAssertEqual(
      buffer.offer(
        packet,
        format: profile.outputFormat,
        generation: 31,
        responseID: response.responseID
      ),
      .accepted
    )
    XCTAssertEqual(buffer.snapshot().queuedFrames, 7_680)
    XCTAssertLessThanOrEqual(buffer.snapshot().queuedFrames, maximumFrames)
  }

  func testQwenObservedFastResponseFitsTheBoundedResponseSpool() throws {
    let profile = RealtimeProviderAudioProfiles.qwen
    let maximumFrames = Int(
      profile.outputFormat.sampleRate * profile.maximumBufferedResponseMilliseconds / 1_000
    )
    let buffer = RealtimeAudioJitterBuffer(
      maximumQueuedFrames: maximumFrames,
      maximumQueuedChunks: profile.maximumBufferedResponseChunkCount,
      overflowPolicy: .rejectIncoming
    )
    _ = buffer.activate(generation: 32)
    let response = try XCTUnwrap(buffer.beginResponse(generation: 32))

    // A device capture contained 157 Qwen PCM packets of 7,680 frames each:
    // 50.24 seconds of audio delivered faster than the hardware can play it.
    let packet = Data(repeating: 0, count: 15_360)
    for _ in 0..<157 {
      XCTAssertEqual(
        buffer.offer(
          packet,
          format: profile.outputFormat,
          generation: 32,
          responseID: response.responseID
        ),
        .accepted
      )
    }

    let snapshot = buffer.snapshot()
    XCTAssertEqual(snapshot.queuedChunks, 157)
    XCTAssertEqual(snapshot.queuedFrames, 1_205_760)
    XCTAssertLessThanOrEqual(snapshot.queuedFrames, maximumFrames)
    XCTAssertLessThanOrEqual(snapshot.queuedChunks, profile.maximumBufferedResponseChunkCount)
  }

  func testReplacesOldestQueuedAudioToKeepTheJitterBufferBounded() throws {
    let buffer = RealtimeAudioJitterBuffer(maximumQueuedFrames: 4, maximumQueuedChunks: 3)
    _ = buffer.activate(generation: 8)
    let response = try XCTUnwrap(buffer.beginResponse(generation: 8))

    XCTAssertEqual(offer(sample: 1, to: buffer, response: response.responseID), .accepted)
    XCTAssertEqual(offer(sample: 2, to: buffer, response: response.responseID), .accepted)
    XCTAssertEqual(offer(sample: 3, to: buffer, response: response.responseID), .accepted)
    XCTAssertEqual(
      offer(samples: [4, 5], to: buffer, response: response.responseID),
      .replacedOldestQueuedChunks(chunkCount: 1, frameCount: 1)
    )

    XCTAssertEqual(try XCTUnwrap(buffer.takeNext(generation: 8, responseID: response.responseID)).data, pcm16([2]))
    XCTAssertEqual(try XCTUnwrap(buffer.takeNext(generation: 8, responseID: response.responseID)).data, pcm16([3]))
    XCTAssertEqual(try XCTUnwrap(buffer.takeNext(generation: 8, responseID: response.responseID)).data, pcm16([4, 5]))

    let snapshot = buffer.snapshot()
    XCTAssertEqual(snapshot.queuedChunks, 0)
    XCTAssertEqual(snapshot.queuedFrames, 0)
  }

  func testRejectIncomingOverflowPreservesQueuedSpeechPrefix() throws {
    let buffer = RealtimeAudioJitterBuffer(
      maximumQueuedFrames: 4,
      maximumQueuedChunks: 3,
      overflowPolicy: .rejectIncoming
    )
    _ = buffer.activate(generation: 8)
    let response = try XCTUnwrap(buffer.beginResponse(generation: 8))

    XCTAssertEqual(offer(sample: 1, to: buffer, response: response.responseID), .accepted)
    XCTAssertEqual(offer(sample: 2, to: buffer, response: response.responseID), .accepted)
    XCTAssertEqual(offer(sample: 3, to: buffer, response: response.responseID), .accepted)
    XCTAssertEqual(
      offer(samples: [4, 5], to: buffer, response: response.responseID),
      .queueFull
    )

    XCTAssertEqual(try XCTUnwrap(buffer.takeNext(generation: 8, responseID: response.responseID)).data, pcm16([1]))
    XCTAssertEqual(try XCTUnwrap(buffer.takeNext(generation: 8, responseID: response.responseID)).data, pcm16([2]))
    XCTAssertEqual(try XCTUnwrap(buffer.takeNext(generation: 8, responseID: response.responseID)).data, pcm16([3]))
    XCTAssertNil(buffer.takeNext(generation: 8, responseID: response.responseID))
  }

  func testResponseAndSessionChangesRejectOldAudio() throws {
    let buffer = RealtimeAudioJitterBuffer(maximumQueuedFrames: 4, maximumQueuedChunks: 2)
    _ = buffer.activate(generation: 12)
    let firstResponse = try XCTUnwrap(buffer.beginResponse(generation: 12))
    let secondResponse = try XCTUnwrap(buffer.beginResponse(generation: 12))

    XCTAssertEqual(
      buffer.offer(
        pcm16([1]),
        format: .realtimePCM16Mono24kHz,
        generation: 12,
        responseID: firstResponse.responseID
      ),
      .staleGeneration
    )
    XCTAssertEqual(
      buffer.offer(
        Data([0x01]),
        format: .realtimePCM16Mono24kHz,
        generation: 12,
        responseID: secondResponse.responseID
      ),
      .invalidFrameAlignment
    )
    _ = buffer.deactivateAndClear()
    XCTAssertEqual(
      buffer.offer(
        pcm16([1]),
        format: .realtimePCM16Mono24kHz,
        generation: 12,
        responseID: secondResponse.responseID
      ),
      .inactive
    )
  }

  func testConcurrentOffersNeverExceedConfiguredFrameCapacity() throws {
    let buffer = RealtimeAudioJitterBuffer(maximumQueuedFrames: 6, maximumQueuedChunks: 3)
    _ = buffer.activate(generation: 21)
    let response = try XCTUnwrap(buffer.beginResponse(generation: 21))
    let chunk = pcm16([1, 2])

    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
      _ = buffer.offer(
        chunk,
        format: .realtimePCM16Mono24kHz,
        generation: 21,
        responseID: response.responseID
      )
    }

    let snapshot = buffer.snapshot()
    XCTAssertLessThanOrEqual(snapshot.queuedFrames, 6)
    XCTAssertLessThanOrEqual(snapshot.queuedChunks, 3)
  }

  private func offer(
    sample: UInt8,
    to buffer: RealtimeAudioJitterBuffer,
    response: UInt64
  ) -> RealtimeAudioJitterOfferResult {
    offer(samples: [sample], to: buffer, response: response)
  }

  private func offer(
    samples: [UInt8],
    to buffer: RealtimeAudioJitterBuffer,
    response: UInt64
  ) -> RealtimeAudioJitterOfferResult {
    buffer.offer(
      pcm16(samples),
      format: .realtimePCM16Mono24kHz,
      generation: 8,
      responseID: response
    )
  }

  private func pcm16(_ samples: [UInt8]) -> Data {
    var data = Data()
    for sample in samples {
      data.append(sample)
      data.append(0)
    }
    return data
  }
}

private final class RealtimeCaptureFeedbackProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var feedbackCount = 0
  private var secondCaptureAt: TimeInterval?
  private var measuredSecondFeedbackMilliseconds = 0.0

  func markSecondCapture(at time: TimeInterval) {
    lock.lock()
    secondCaptureAt = time
    lock.unlock()
  }

  func record(at time: TimeInterval) -> (index: Int, delayMilliseconds: Double?) {
    lock.lock()
    defer { lock.unlock() }
    feedbackCount += 1
    guard feedbackCount == 2, let secondCaptureAt else {
      return (feedbackCount, nil)
    }
    measuredSecondFeedbackMilliseconds = (time - secondCaptureAt) * 1_000
    return (feedbackCount, measuredSecondFeedbackMilliseconds)
  }

  var secondFeedbackMilliseconds: Double {
    lock.lock()
    defer { lock.unlock() }
    return measuredSecondFeedbackMilliseconds
  }
}

private final class RealtimePlaybackStartCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

final class RealtimeAudioPlaybackLatencyTests: XCTestCase {
  func testStartupThresholdCrossingSchedulesWithoutPollingDelay() {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-threshold-event-wake",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 1,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      schedulingSafetyIntervalMilliseconds: 200,
      engineStartOverride: { true }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer { pipeline.stop() }

    let prepared = expectation(description: "playback graph prepared")
    pipeline.prepare(generation: 1) { isReady in
      XCTAssertTrue(isReady)
      prepared.fulfill()
    }
    wait(for: [prepared], timeout: 1)

    // At 24 kHz a 1 ms startup threshold is 24 frames. Let the timer observe
    // 23 frames first, then measure how long the threshold-crossing frame waits.
    XCTAssertEqual(
      pipeline.enqueue(Data(repeating: 0, count: 23 * 2), generation: 1),
      .accepted
    )
    Thread.sleep(forTimeInterval: 0.030)

    let crossedAt = ProcessInfo.processInfo.systemUptime
    XCTAssertEqual(pipeline.enqueue(Data([0, 0]), generation: 1), .accepted)
    var metrics = RealtimeAudioPlaybackPerformanceSnapshot.empty
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      metrics = pipeline.snapshot()
      if metrics.scheduledChunks == 2 { break }
      Thread.sleep(forTimeInterval: 0.001)
    }
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - crossedAt) * 1_000
    let attachment = XCTAttachment(
      string: "eventDrivenThresholdCrossingMs=\(elapsedMilliseconds)"
    )
    attachment.name = "Realtime event-driven threshold-crossing latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(metrics.scheduledChunks, 2)
    XCTAssertLessThan(elapsedMilliseconds, 10)
  }

  func testPCM16VectorDecodePreservesSignedLittleEndianExtremes() throws {
    let samples: [Int16] = [.min, -16_384, -1, 0, 1, 16_384, .max]
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-pcm16-vector-mono",
      outputFormat: .realtimePCM16Mono24kHz,
      engineStartOverride: { true }
    )
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    )

    let buffer = try XCTUnwrap(pipeline.makePCMBuffer(
      from: pcm16LittleEndian(samples),
      format: format
    ))
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])

    XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(samples.count))
    for (index, sample) in samples.enumerated() {
      XCTAssertEqual(channel[index], Float(sample) / 32_768.0, accuracy: 0.000_001)
    }
  }

  func testPCM16VectorDecodeDeinterleavesStereoChannels() throws {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-pcm16-vector-stereo",
      outputFormat: RealtimePCMOutputFormat(
        sampleRate: 24_000,
        channelCount: 2,
        encoding: .signedInteger16LittleEndian
      ),
      engineStartOverride: { true }
    )
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)
    )
    let interleaved: [Int16] = [.min, .max, -16_384, 16_384, 0, -1]

    let buffer = try XCTUnwrap(pipeline.makePCMBuffer(
      from: pcm16LittleEndian(interleaved),
      format: format
    ))
    let channels = try XCTUnwrap(buffer.floatChannelData)

    XCTAssertEqual(buffer.frameLength, 3)
    XCTAssertEqual(channels[0][0], -1, accuracy: 0.000_001)
    XCTAssertEqual(channels[0][1], -0.5, accuracy: 0.000_001)
    XCTAssertEqual(channels[0][2], 0, accuracy: 0.000_001)
    XCTAssertEqual(channels[1][0], Float(Int16.max) / 32_768.0, accuracy: 0.000_001)
    XCTAssertEqual(channels[1][1], 0.5, accuracy: 0.000_001)
    XCTAssertEqual(channels[1][2], -1.0 / 32_768.0, accuracy: 0.000_001)
  }

  func testConcurrentInterruptsLeaveNextResponseIngressReusable() {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-interrupt-ingress-race",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 1_000,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: { true }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer { pipeline.stop() }

    let packet = Data([0, 0])
    DispatchQueue.concurrentPerform(iterations: 200) { index in
      if index.isMultiple(of: 2) {
        _ = pipeline.enqueue(packet, generation: 1)
      } else {
        pipeline.interrupt(generation: 1)
      }
    }

    pipeline.invalidateAudioSystem(generation: 1)
    XCTAssertEqual(pipeline.enqueue(packet, generation: 1), .accepted)
    XCTAssertEqual(
      pipeline.snapshot().currentQueuedFrames,
      1,
      "interrupt/enqueue races must not strand responseIsActive away from the jitter lifecycle"
    )
  }

  func testPlayedMillisecondsDoNotLeakAcrossResponses() {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-played-ms-per-response",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 0,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: { true }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer { pipeline.stop() }

    _ = pipeline.enqueue(Data(repeating: 0, count: 960), generation: 1)
    pipeline.interrupt(generation: 1)

    // 新一轮回复必须从 0 开始计数，否则会拿上一轮的进度去截断这一轮，
    // 把服务端上下文截在一个错误的位置。
    _ = pipeline.enqueue(Data(repeating: 0, count: 960), generation: 1)
    XCTAssertEqual(pipeline.playedMillisecondsForActiveResponse, 0)
  }

  func testInterruptReportsZeroPlayedMillisecondsWhenNothingReachedTheSpeaker() {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-played-ms-floor",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 1_000,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: { true }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer { pipeline.stop() }

    // 1s 的启动缓冲意味着这几帧还没被排到播放器，`.dataPlayedBack` 一次都没回调。
    // 此时必须报 0：宁可不截断，也不能谎报一个用户根本没听到的时长，
    // 否则服务端上下文会保留用户没听到的内容。
    _ = pipeline.enqueue(Data(repeating: 0, count: 960), generation: 1)

    XCTAssertEqual(pipeline.playedMillisecondsForActiveResponse, 0)
    XCTAssertEqual(pipeline.interrupt(generation: 1), 0)
  }

  func testStaleGenerationInterruptStillReportsPlayedMillisecondsWithoutTouchingState() {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-played-ms-stale",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 0,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: { true }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer { pipeline.stop() }

    XCTAssertEqual(
      pipeline.interrupt(generation: 99),
      0,
      "过期 generation 的打断不应该报出别人的播放进度"
    )
  }

  func testAudioSystemInvalidationRebuildsPlayerGraphWithoutClosingIngress() {
    let engineStartCount = RealtimePlaybackStartCounter()
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-audio-system-recovery",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 0,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: {
        engineStartCount.increment()
        return true
      }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer { pipeline.stop() }

    let firstPrepare = expectation(description: "initial playback graph prepared")
    pipeline.prepare(generation: 1) { isReady in
      XCTAssertTrue(isReady)
      firstPrepare.fulfill()
    }
    wait(for: [firstPrepare], timeout: 1)

    let invalidationStartedAt = ProcessInfo.processInfo.systemUptime
    pipeline.invalidateAudioSystem(generation: 1)
    let invalidationMilliseconds = (
      ProcessInfo.processInfo.systemUptime - invalidationStartedAt
    ) * 1_000
    let attachment = XCTAttachment(
      string: "audioSystemInvalidateBarrierMs=\(invalidationMilliseconds)"
    )
    attachment.name = "Realtime audio-system invalidation barrier latency"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThan(invalidationMilliseconds, 20)

    let recoveredPrepare = expectation(description: "playback graph rebuilt")
    pipeline.prepare(generation: 1) { isReady in
      XCTAssertTrue(isReady)
      recoveredPrepare.fulfill()
    }
    wait(for: [recoveredPrepare], timeout: 1)

    XCTAssertEqual(engineStartCount.value, 2)
    XCTAssertEqual(
      pipeline.enqueue(Data([0, 0]), generation: 1),
      .accepted,
      "audio ingress must stay active across audio-system recovery"
    )
  }

  func testFirstQwenPacketSchedulesWithinInteractiveBudget() {
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-prewarmed",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 0,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: {
        Thread.sleep(forTimeInterval: 0.030)
        return true
      }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    let prepared = expectation(description: "playback engine prepared")
    pipeline.prepare(generation: 1) { isReady in
      XCTAssertTrue(isReady)
      prepared.fulfill()
    }
    wait(for: [prepared], timeout: 1)

    let packet = Data(repeating: 0, count: 15_360)
    let startedAt = ProcessInfo.processInfo.systemUptime
    XCTAssertEqual(pipeline.enqueue(packet, generation: 1), .accepted)

    var metrics = RealtimeAudioPlaybackPerformanceSnapshot.empty
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      metrics = pipeline.snapshot()
      if metrics.scheduledChunks > 0 { break }
      Thread.sleep(forTimeInterval: 0.001)
    }
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    let attachment = XCTAttachment(
      string: "firstPacketToScheduleMs=\(elapsedMilliseconds)\n"
        + "receiveToScheduleMs=\(metrics.maximumReceiveToScheduleMilliseconds)\n"
        + "decodeMs=\(metrics.maximumDecodeMilliseconds)"
    )
    attachment.name = "Realtime prewarmed playback scheduling latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(metrics.scheduledChunks, 1)
    XCTAssertLessThan(elapsedMilliseconds, 20)
    XCTAssertLessThan(metrics.maximumReceiveToScheduleMilliseconds, 20)
    XCTAssertLessThan(metrics.maximumDecodeMilliseconds, 1)
    pipeline.stop()
  }

  func testInterruptWaitsForPlayerResetBarrierWithinBudget() {
    let engineStartEntered = DispatchSemaphore(value: 0)
    let releaseEngineStart = DispatchSemaphore(value: 0)
    let interruptReturned = DispatchSemaphore(value: 0)
    let pipeline = RealtimeAudioPlaybackPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.playback-interrupt-barrier",
      outputFormat: RealtimeProviderAudioProfiles.qwen.outputFormat,
      startupBufferMilliseconds: 0,
      maximumJitterMilliseconds: RealtimeProviderAudioProfiles.qwen.maximumJitterMilliseconds,
      engineStartOverride: {
        engineStartEntered.signal()
        return releaseEngineStart.wait(timeout: .now() + 1) == .success
      }
    )
    pipeline.start(
      generation: 1,
      onFailure: { message in XCTFail("unexpected playback failure: \(message)") }
    )
    defer {
      releaseEngineStart.signal()
      pipeline.stop()
    }

    pipeline.prepare(generation: 1)
    XCTAssertEqual(engineStartEntered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global(qos: .userInitiated).async {
      pipeline.interrupt(generation: 1)
      interruptReturned.signal()
    }

    XCTAssertEqual(
      interruptReturned.wait(timeout: .now() + 0.03),
      .timedOut,
      "interrupt returned before queued player reset could run"
    )
    let releasedAt = ProcessInfo.processInfo.systemUptime
    releaseEngineStart.signal()
    XCTAssertEqual(interruptReturned.wait(timeout: .now() + 1), .success)
    let barrierMilliseconds = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1_000
    let attachment = XCTAttachment(
      string: "postReleaseInterruptBarrierMs=\(barrierMilliseconds)"
    )
    attachment.name = "Realtime interrupt player-reset barrier latency"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThan(barrierMilliseconds, 20)
  }

  private func pcm16LittleEndian(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
    for sample in samples {
      let bits = UInt16(bitPattern: sample)
      data.append(UInt8(truncatingIfNeeded: bits))
      data.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    return data
  }
}

final class StreamSessionLeaseRegistryTests: XCTestCase {
  func testAgentTriggerLeaseKeepsControlsWithoutRequestingCamera() {
    var registry = StreamSessionLeaseRegistry()

    _ = registry.acquire(.agentTrigger)
    XCTAssertTrue(registry.keepsAgentTriggerSession)
    XCTAssertFalse(registry.requiresCameraStream)

    _ = registry.acquire(.agentChat)
    XCTAssertTrue(registry.requiresCameraStream)
    _ = registry.release(.agentChat)
    XCTAssertFalse(registry.requiresCameraStream)
    XCTAssertTrue(registry.keepsAgentTriggerSession)
  }

  func testOnlyTheFinalOwnerReleasesTheSharedSession() {
    var registry = StreamSessionLeaseRegistry()

    XCTAssertTrue(registry.acquire(.liveAI))
    XCTAssertTrue(registry.acquire(.quickVision))
    XCTAssertFalse(registry.isEmpty)

    XCTAssertTrue(registry.release(.quickVision))
    XCTAssertFalse(registry.isEmpty)
    XCTAssertTrue(registry.owners.contains(.liveAI))

    XCTAssertTrue(registry.release(.liveAI))
    XCTAssertTrue(registry.isEmpty)
  }

  func testDuplicateOwnerDoesNotCreateAnAdditionalLease() {
    var registry = StreamSessionLeaseRegistry()

    XCTAssertTrue(registry.acquire(.rtmp))
    XCTAssertFalse(registry.acquire(.rtmp))
    XCTAssertTrue(registry.release(.rtmp))
    XCTAssertTrue(registry.isEmpty)
  }

  func testQuickVisionRequestsOwnIndependentLeases() {
    var registry = StreamSessionLeaseRegistry()
    let firstRequest = StreamSessionOwner.quickVisionRequest(UUID())
    let secondRequest = StreamSessionOwner.quickVisionRequest(UUID())

    XCTAssertTrue(registry.acquire(firstRequest))
    XCTAssertTrue(registry.acquire(secondRequest))
    XCTAssertTrue(registry.release(firstRequest))
    XCTAssertFalse(registry.isEmpty)
    XCTAssertTrue(registry.owners.contains(secondRequest))

    XCTAssertTrue(registry.release(secondRequest))
    XCTAssertTrue(registry.isEmpty)
  }

  func testOnlyLiveAIRequestsTheDirectRawPreview() {
    var registry = StreamSessionLeaseRegistry()

    XCTAssertFalse(registry.usesDirectRawPreview)
    _ = registry.acquire(.simpleLiveStream)
    XCTAssertFalse(registry.usesDirectRawPreview)

    _ = registry.acquire(.liveAI)
    XCTAssertTrue(registry.usesDirectRawPreview)

    XCTAssertTrue(registry.release(.liveAI))
    XCTAssertFalse(registry.usesDirectRawPreview)
  }

  func testOnlyLiveAIRequestsTheFullDuplexTransportProfile() {
    var registry = StreamSessionLeaseRegistry()

    _ = registry.acquire(.quickVision)
    XCTAssertFalse(registry.requiresFullDuplexTransportProfile)

    _ = registry.acquire(.liveAI)
    XCTAssertTrue(registry.requiresFullDuplexTransportProfile)

    _ = registry.release(.liveAI)
    XCTAssertFalse(registry.requiresFullDuplexTransportProfile)
  }
}

final class CameraStreamTransportProfileTests: XCTestCase {
  func testFullDuplexProfileUsesProviderIndependentCompressedVideo() {
    let profile = CameraStreamTransportProfile.make(
      savedQuality: "high",
      requiresFullDuplexTransport: true
    )

    XCTAssertEqual(profile.videoCodec, .hvc1)
    XCTAssertEqual(profile.resolution, .low)
    XCTAssertEqual(profile.frameRate, 24)
  }

  func testNonFullDuplexProfilePreservesTheSavedCameraQuality() {
    let profile = CameraStreamTransportProfile.make(
      savedQuality: "high",
      requiresFullDuplexTransport: false
    )

    XCTAssertEqual(profile.videoCodec, .raw)
    XCTAssertEqual(profile.resolution, .high)
    XCTAssertEqual(profile.frameRate, 24)
  }
}

final class HVCBitstreamInspectorTests: XCTestCase {
  func testFindsIDRInLengthPrefixedSample() {
    let sample = makeLengthPrefixedSample(nalUnitTypes: [32, 33, 34, 19])

    XCTAssertEqual(
      HVCBitstreamInspector.containsRandomAccessNALUnit(
        sample,
        nalUnitLengthFieldSize: 4
      ),
      true
    )
  }

  func testRejectsInterPredictedSampleAsRecoveryPoint() {
    let sample = makeLengthPrefixedSample(nalUnitTypes: [1])

    XCTAssertEqual(
      HVCBitstreamInspector.containsRandomAccessNALUnit(
        sample,
        nalUnitLengthFieldSize: 4
      ),
      false
    )
  }

  func testRejectsTruncatedNALUnitLength() {
    let sample: [UInt8] = [0, 0, 0, 8, 0x26, 0x01]

    XCTAssertNil(
      HVCBitstreamInspector.containsRandomAccessNALUnit(
        sample,
        nalUnitLengthFieldSize: 4
      )
    )
  }

  private func makeLengthPrefixedSample(nalUnitTypes: [UInt8]) -> [UInt8] {
    nalUnitTypes.flatMap { nalUnitType in
      let payload: [UInt8] = [nalUnitType << 1, 0x01, 0x00]
      return [0, 0, 0, UInt8(payload.count)] + payload
    }
  }
}

final class HVCDecoderFailurePolicyTests: XCTestCase {
  func testKeepsDecoderSessionForRecoverableBitstreamDamage() {
    XCTAssertFalse(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderBadDataErr)
    )
    XCTAssertFalse(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderReferenceMissingErr)
    )
  }

  func testResetsDecoderSessionForDecoderLifecycleFailures() {
    XCTAssertTrue(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTInvalidSessionErr)
    )
    XCTAssertTrue(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderMalfunctionErr)
    )
    XCTAssertTrue(
      HVCDecoderFailurePolicy.shouldResetSession(after: kVTVideoDecoderRemovedErr)
    )
  }
}

final class StreamSessionRecoveryPolicyTests: XCTestCase {
  func testRetriesTransientStreamFailures() {
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.internalError))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.deviceNotFound("test-device")))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.deviceNotConnected("test-device")))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.timeout))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(StreamError.videoStreamingError))
  }

  func testDoesNotRetryTerminalStreamFailures() {
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.permissionDenied))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.hingesClosed))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.thermalCritical))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.thermalEmergency))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.peakPowerShutdown))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(StreamError.batteryCritical))
  }

  func testRetriesOnlyRecoverableDeviceSessionFailures() {
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.noEligibleDevice))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.sessionAlreadyStopped))
    XCTAssertTrue(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.unexpectedError(description: "transport reset")))

    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.sessionAlreadyExists))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.sessionIdle))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.capabilityAlreadyActive))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.capabilityNotFound))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.thermalCritical))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.thermalEmergency))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.peakPowerShutdown))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(DeviceSessionError.batteryCritical))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(.datAppOnTheGlassesUpdateRequired))
    XCTAssertFalse(StreamSessionRecoveryPolicy.shouldRetry(.dwaUnavailable))
  }
}

final class CameraCaptureStateTests: XCTestCase {
  func testStateSemanticsAreStableForFeatureGuards() {
    XCTAssertFalse(CameraCaptureState.unavailable.isStreaming)
    XCTAssertTrue(CameraCaptureState.unavailable.isUnavailable)
    XCTAssertTrue(CameraCaptureState.starting.isBusy)
    XCTAssertTrue(CameraCaptureState.stopping.isBusy)
    XCTAssertTrue(CameraCaptureState.streaming.isStreaming)
    XCTAssertFalse(CameraCaptureState.streaming.isUnavailable)
    XCTAssertTrue(CameraCaptureState.failed("test").isFailed)
  }
}

final class DATGlassesAppUpdateRetryGateTests: XCTestCase {
  func testDetectsOnlyTheDATGlassesAppUpdateRequirement() {
    XCTAssertTrue(
      DATGlassesAppUpdateGuidance.isRequired(for: .datAppOnTheGlassesUpdateRequired)
    )
    XCTAssertTrue(
      DATGlassesAppUpdateGuidance.isRequired(
        for: .unexpectedError(description: "请将直播软件更新至最新版本后重试")
      )
    )
    XCTAssertTrue(
      DATGlassesAppUpdateGuidance.isRequired(message: "请将直播软件更新至最新版本后重试")
    )
    XCTAssertFalse(DATGlassesAppUpdateGuidance.isRequired(for: .dwaUnavailable))
    XCTAssertFalse(
      DATGlassesAppUpdateGuidance.isRequired(
        for: .unexpectedError(description: "Temporary connection failure")
      )
    )
    XCTAssertFalse(DATGlassesAppUpdateGuidance.isRequired(for: .sessionAlreadyStopped))
  }

  func testRequiresTheUpdateRouteBeforePermittingOneManualRetry() {
    var gate = DATGlassesAppUpdateRetryGate()

    gate.requireUpdate()
    XCTAssertTrue(gate.isUpdateRequired)
    XCTAssertFalse(gate.consumeRetry())

    gate.markUpdateDestinationOpened()
    XCTAssertTrue(gate.isRetryArmed)
    XCTAssertTrue(gate.consumeRetry())
    XCTAssertFalse(gate.isUpdateRequired)
    XCTAssertFalse(gate.isRetryArmed)
  }

  func testRequiringAnotherUpdateInvalidatesAStaleRetry() {
    var gate = DATGlassesAppUpdateRetryGate()

    gate.requireUpdate()
    gate.markUpdateDestinationOpened()
    gate.requireUpdate()

    XCTAssertFalse(gate.consumeRetry())
  }
}

final class ConversationMessageCodingTests: XCTestCase {
  func testRoundTripPreservesMessageIdentityAndTimestamp() throws {
    let id = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 123_456)
    let message = ConversationMessage(
      id: id,
      role: .assistant,
      content: "Stable record",
      timestamp: timestamp
    )

    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)

    XCTAssertEqual(decoded.id, id)
    XCTAssertEqual(decoded.timestamp, timestamp)
    XCTAssertEqual(decoded.role, .assistant)
    XCTAssertEqual(decoded.content, "Stable record")
  }
}

final class OpenClawGatewayEndpointTests: XCTestCase {
  func testNormalizesWebSocketPrefixAndTrailingSlash() {
    let endpoint = OpenClawGatewayEndpoint(
      host: "  WSS://gateway.local/// ",
      port: 18789,
      usesTLS: false
    )

    XCTAssertEqual(endpoint.url?.absoluteString, "ws://gateway.local:18789")
  }

  func testRejectsInvalidPortAndEmptyHost() {
    XCTAssertNil(OpenClawGatewayEndpoint(host: "gateway.local", port: 0, usesTLS: false).url)
    XCTAssertNil(OpenClawGatewayEndpoint(host: "", port: 18789, usesTLS: true).url)
  }

  func testUsesSecureWebSocketScheme() {
    let endpoint = OpenClawGatewayEndpoint(host: "gateway.local", port: 443, usesTLS: true)

    XCTAssertEqual(endpoint.url?.scheme, "wss")
    XCTAssertEqual(endpoint.url?.port, 443)
  }
}
