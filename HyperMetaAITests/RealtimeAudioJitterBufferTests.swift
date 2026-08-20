import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

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
