import Foundation
import XCTest

@testable import HyperMetaAI

final class RTMPRecordingPlaybackTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rtmp-playback-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func makeRecord(
    fileName: String = "HyperMetaAI-20260812-120000.mp4",
    duration: TimeInterval = 120,
    markers: [RTMPRecordingMarker] = []
  ) -> RTMPRecordingRecord {
    RTMPRecordingRecord(
      fileName: fileName,
      startedAt: Date(timeIntervalSince1970: 1_000),
      duration: duration,
      fileSize: 1_024,
      markers: markers
    )
  }

  func testFileURLAppendsFileNameToDirectory() {
    let url = RTMPRecordingPlayback.fileURL(fileName: "clip.mp4", directory: directory)

    XCTAssertEqual(url.deletingLastPathComponent(), directory)
    XCTAssertEqual(url.lastPathComponent, "clip.mp4")
  }

  func testFileExistsReflectsRealFile() throws {
    let fileName = "exists.mp4"
    let url = RTMPRecordingPlayback.fileURL(fileName: fileName, directory: directory)

    XCTAssertFalse(RTMPRecordingPlayback.fileExists(fileName: fileName, directory: directory))
    FileManager.default.createFile(atPath: url.path, contents: Data())
    XCTAssertTrue(RTMPRecordingPlayback.fileExists(fileName: fileName, directory: directory))
  }

  func testMarkerEntriesAreSortedByTimeAscending() {
    let record = makeRecord(
      duration: 100,
      markers: [
        RTMPRecordingMarker(timeOffset: 80, label: "later"),
        RTMPRecordingMarker(timeOffset: 20, label: "earlier"),
        RTMPRecordingMarker(timeOffset: 20.5, label: "middle")
      ]
    )

    let entries = RTMPRecordingPlayback.markerEntries(for: record)

    XCTAssertEqual(entries.map(\.timeOffset), [20, 20.5, 80])
    XCTAssertEqual(entries.map(\.label), ["earlier", "middle", "later"])
    XCTAssertEqual(entries.map(\.timeText), ["00:20", "00:21", "01:20"])
  }

  func testMarkerProgressClampedBetweenZeroAndOne() {
    let record = makeRecord(
      duration: 100,
      markers: [
        RTMPRecordingMarker(timeOffset: 250, label: "beyond-end"),
        RTMPRecordingMarker(timeOffset: 50, label: "middle"),
        RTMPRecordingMarker(timeOffset: -5, label: "negative")
      ]
    )

    let entries = RTMPRecordingPlayback.markerEntries(for: record)

    XCTAssertEqual(entries.first(where: { $0.label == "beyond-end" })?.progress, 1.0)
    XCTAssertEqual(entries.first(where: { $0.label == "middle" })?.progress, 0.5)
    XCTAssertEqual(entries.first(where: { $0.label == "negative" })?.progress, 0.0)
  }

  func testMarkerProgressIsZeroWhenDurationIsInvalid() {
    let record = makeRecord(
      duration: 0,
      markers: [RTMPRecordingMarker(timeOffset: 30, label: "mark")]
    )

    let entries = RTMPRecordingPlayback.markerEntries(for: record)

    XCTAssertEqual(entries.first?.progress, 0.0)
    XCTAssertEqual(entries.first?.timeText, "00:30")
  }

  func testMarkerEntriesOfRecordWithoutMarkersIsEmpty() {
    let entries = RTMPRecordingPlayback.markerEntries(for: makeRecord())

    XCTAssertTrue(entries.isEmpty)
  }
}
