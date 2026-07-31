import AVFoundation
import CoreVideo
import XCTest

@testable import HyperMetaAI

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
