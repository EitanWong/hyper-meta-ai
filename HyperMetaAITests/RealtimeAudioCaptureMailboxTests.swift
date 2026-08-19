import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

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
