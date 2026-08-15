import AVFoundation
import XCTest

@testable import HyperMetaAI

final class RTMPClipSegmentTests: XCTestCase {

  func testRangeCenteredOnMarker() {
    let range = RTMPClipSegment.timeRange(markerOffset: 60, duration: 120)

    XCTAssertEqual(range?.start.seconds, 50)
    XCTAssertEqual(range?.duration.seconds, 15)
  }

  func testRangeClampedAtStart() {
    let range = RTMPClipSegment.timeRange(markerOffset: 3, duration: 120)

    XCTAssertEqual(range?.start.seconds, 0)
    XCTAssertEqual(range?.duration.seconds, 8)
  }

  func testRangeClampedAtEnd() {
    let range = RTMPClipSegment.timeRange(markerOffset: 118, duration: 120)

    XCTAssertEqual(range?.start.seconds, 108)
    XCTAssertEqual(range?.duration.seconds, 12)
  }

  func testMarkerAtEndStillValid() {
    let range = RTMPClipSegment.timeRange(markerOffset: 120, duration: 120)

    XCTAssertNotNil(range)
    XCTAssertEqual(range?.start.seconds, 110)
    XCTAssertEqual(range?.duration.seconds, 10)
  }

  func testInvalidInputsReturnNil() {
    XCTAssertNil(RTMPClipSegment.timeRange(markerOffset: -1, duration: 120))
    XCTAssertNil(RTMPClipSegment.timeRange(markerOffset: 0, duration: 0))
    XCTAssertNil(RTMPClipSegment.timeRange(markerOffset: 121, duration: 120))
    XCTAssertNil(RTMPClipSegment.timeRange(markerOffset: 0, duration: -5))
  }

  func testClipFileNameUsesSanitizedLabel() {
    let name = RTMPClipSegment.clipFileName(
      fileName: "HyperMetaAI-20260812-180000.mp4",
      label: "精彩 瞬间/片段",
      startOffset: 65
    )

    XCTAssertEqual(name, "HyperMetaAI-20260812-180000-精彩瞬间片段-0105.mp4")
  }

  func testClipFileNameFallsBackForEmptyLabel() {
    let name = RTMPClipSegment.clipFileName(
      fileName: "HyperMetaAI-20260812-180000.mp4",
      label: "",
      startOffset: 5
    )

    XCTAssertEqual(name, "HyperMetaAI-20260812-180000-clip-0005.mp4")
  }
}

final class RTMPClipSegmentCustomWindowTests: XCTestCase {

  func testCustomWindowRespected() {
    let range = RTMPClipSegment.timeRange(
      markerOffset: 60,
      duration: 120,
      leadSeconds: 5,
      tailSeconds: 3
    )

    XCTAssertEqual(range?.start.seconds, 55)
    XCTAssertEqual(range?.duration.seconds, 8)
  }

  func testZeroWindowAtMarkerReturnsNil() {
    XCTAssertNil(RTMPClipSegment.timeRange(
      markerOffset: 60,
      duration: 120,
      leadSeconds: 0,
      tailSeconds: 0
    ))
  }
}
