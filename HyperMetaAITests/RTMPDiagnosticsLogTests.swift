import Foundation
import XCTest

@testable import HyperMetaAI

final class RTMPDiagnosticsLogTests: XCTestCase {

  private var directory: URL!
  /// UTC formatter：文件名与时间行与时区无关
  private let utcFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rtmp-diagnostics-log-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let directory {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func makeSnapshot(
    startedAt: Date = Date(timeIntervalSince1970: 1_000),
    endedAt: Date = Date(timeIntervalSince1970: 1_100)
  ) -> RTMPDiagnosticsSnapshot {
    var collector = RTMPDiagnosticsCollector()
    collector.begin(now: startedAt)
    collector.recordFrameStats(total: 3_000, dropped: 60)
    collector.recordReconnect()
    collector.recordQualityChange(upshift: false, presetLabel: "360×360@20")
    collector.recordRecordingMarker()
    collector.recordSceneChange()
    collector.end(now: endedAt)
    return collector.snapshot
  }

  private let timestampText: (Date) -> String = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: $0)
  }

  private let durationText: (TimeInterval?) -> String = {
    $0.map(RTMPRecordingNaming.durationText) ?? "00:00"
  }

  private let numberText: (Int64) -> String = { "\($0)" }

  @discardableResult
  private func writeLog(
    startedAt: Date = Date(timeIntervalSince1970: 1_000),
    endedAt: Date = Date(timeIntervalSince1970: 1_100)
  ) -> URL? {
    RTMPDiagnosticsLog.write(
      snapshot: makeSnapshot(startedAt: startedAt, endedAt: endedAt),
      directory: directory,
      formatter: utcFormatter,
      timestampText: timestampText,
      durationText: durationText,
      numberText: numberText
    )
  }

  func testFileNameUsesTimestamp() {
    let name = RTMPDiagnosticsLog.fileName(
      startedAt: Date(timeIntervalSince1970: 1_000),
      formatter: utcFormatter
    )

    XCTAssertEqual(name, "RTMPDiagnostics-19700101-001640.log")
  }

  func testWriteCreatesLogFileWithReportContent() throws {
    let url = try XCTUnwrap(writeLog())

    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(url.lastPathComponent, "RTMPDiagnostics-19700101-001640.log")

    let content = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(content.contains("RTMP Streaming Session Log"))
    XCTAssertTrue(content.contains("Started: 1970-01-01 00:16:40"))
    XCTAssertTrue(content.contains("Ended: 1970-01-01 00:18:20"))
    XCTAssertTrue(content.contains("Duration: 01:40"))
    XCTAssertTrue(content.contains("reconnects: 1"))
    XCTAssertTrue(content.contains("360×360@20"))
    XCTAssertTrue(content.contains("Recording markers: 1"))
    XCTAssertTrue(content.contains("Scene changes: 1"))
  }

  func testWriteReturnsNilWhenDirectoryIsInvalid() throws {
    try FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: directory.path, contents: Data())

    XCTAssertNil(writeLog())
  }

  func testLogFilesSortedNewestFirst() throws {
    for seconds in [1_000.0, 1_100.0, 1_200.0] {
      _ = writeLog(startedAt: Date(timeIntervalSince1970: seconds))
    }

    let files = RTMPDiagnosticsLog.logFiles(in: directory)

    XCTAssertEqual(files.count, 3)
    XCTAssertEqual(
      files.map(\.fileName),
      [
        "RTMPDiagnostics-19700101-002000.log",
        "RTMPDiagnostics-19700101-001820.log",
        "RTMPDiagnostics-19700101-001640.log",
      ]
    )
  }

  func testTrimKeepsNewestOnly() throws {
    for seconds in [1_000.0, 1_100.0, 1_200.0, 1_300.0, 1_400.0] {
      _ = writeLog(startedAt: Date(timeIntervalSince1970: seconds))
    }

    let removed = RTMPDiagnosticsLog.trim(directory: directory, maxCount: 3)

    XCTAssertEqual(removed.count, 2)
    let remaining = RTMPDiagnosticsLog.logFiles(in: directory)
    XCTAssertEqual(remaining.count, 3)
    XCTAssertEqual(remaining.first?.fileName, "RTMPDiagnostics-19700101-002320.log")
  }

  func testDeleteRemovesFile() throws {
    let url = try XCTUnwrap(writeLog())

    XCTAssertTrue(RTMPDiagnosticsLog.delete(url: url))
    XCTAssertTrue(RTMPDiagnosticsLog.logFiles(in: directory).isEmpty)
  }

  func testLogFilesEmptyForMissingDirectory() {
    XCTAssertTrue(RTMPDiagnosticsLog.logFiles(in: directory).isEmpty)
  }

  func testDefaultDirectoryContainsRTMPDiagnostics() {
    XCTAssertEqual(RTMPDiagnosticsLog.defaultDirectory().lastPathComponent, "RTMPDiagnostics")
  }
}
