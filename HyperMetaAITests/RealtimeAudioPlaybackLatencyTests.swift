import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

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
