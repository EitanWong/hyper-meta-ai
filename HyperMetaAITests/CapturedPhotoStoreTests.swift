import XCTest

@testable import HyperMetaAI

final class CapturedPhotoNamingTests: XCTestCase {
  private func makeDate() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 12, hour: 17, minute: 0, second: 1)
    )!
  }

  func testFileNameFormat() {
    let formatter = CapturedPhotoNaming.makeFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    XCTAssertEqual(
      CapturedPhotoNaming.fileName(for: makeDate(), formatter: formatter),
      "IMG-20260812-170001.jpg"
    )
  }

  func testUniqueFileNameKeepsBaseWhenFree() {
    XCTAssertEqual(
      CapturedPhotoNaming.uniqueFileName(base: "IMG-20260812-170001.jpg", existing: []),
      "IMG-20260812-170001.jpg"
    )
  }

  func testUniqueFileNameAppendsSuffixAndKeepsExtension() {
    let base = "IMG-20260812-170001.jpg"
    XCTAssertEqual(
      CapturedPhotoNaming.uniqueFileName(base: base, existing: [base]),
      "IMG-20260812-170001-2.jpg"
    )
    XCTAssertEqual(
      CapturedPhotoNaming.uniqueFileName(base: base, existing: [base, "IMG-20260812-170001-2.jpg"]),
      "IMG-20260812-170001-3.jpg"
    )
  }

  func testUniqueFileNameHandlesExtensionlessBase() {
    XCTAssertEqual(
      CapturedPhotoNaming.uniqueFileName(base: "photo", existing: ["photo", "photo-2"]),
      "photo-3"
    )
  }
}

final class CapturedPhotoStoreTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    CapturedPhotoStore.clear()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CapturedPhotoTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    CapturedPhotoStore.clear()
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  private func fileURL(_ fileName: String) -> URL {
    CapturedPhotoFileStore.fileURL(fileName: fileName, directory: tempDirectory)
  }

  private func makeDate() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 12, hour: 17, minute: 0, second: 1)
    )!
  }

  func testAddPhotoPersistsRecordAndFile() {
    let record = CapturedPhotoStore.addPhoto(
      data: Data([0xFF, 0xD8]),
      createdAt: makeDate(),
      aiDescription: "桌面",
      directory: tempDirectory
    )

    XCTAssertNotNil(record)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(record!.fileName).path))
    XCTAssertEqual(CapturedPhotoStore.records.count, 1)
    XCTAssertEqual(CapturedPhotoStore.records.first?.id, record?.id)
    XCTAssertEqual(CapturedPhotoStore.records.first?.aiDescription, "桌面")
  }

  func testRecordsSortedNewestFirst() {
    let older = makeDate().addingTimeInterval(-120)
    let newer = makeDate()
    CapturedPhotoStore.addPhoto(data: Data([0x01]), createdAt: older, directory: tempDirectory)
    CapturedPhotoStore.addPhoto(data: Data([0x02]), createdAt: newer, directory: tempDirectory)

    XCTAssertEqual(CapturedPhotoStore.records.count, 2)
    XCTAssertEqual(CapturedPhotoStore.records[0].createdAt, newer)
    XCTAssertEqual(CapturedPhotoStore.records[1].createdAt, older)
  }

  func testSameSecondCaptureGetsUniqueFileNames() {
    let date = makeDate()
    let first = CapturedPhotoStore.addPhoto(data: Data([0x01]), createdAt: date, directory: tempDirectory)
    let second = CapturedPhotoStore.addPhoto(data: Data([0x02]), createdAt: date, directory: tempDirectory)

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first?.fileName, second?.fileName)
    XCTAssertTrue(second?.fileName.hasSuffix("-2.jpg") ?? false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(first!.fileName).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(second!.fileName).path))
  }

  func testCapTrimsRecordsAndPrunesOrphanFiles() {
    for index in 0..<(CapturedPhotoStore.maxCount + 5) {
      let created = makeDate().addingTimeInterval(-TimeInterval(index))
      XCTAssertNotNil(
        CapturedPhotoStore.addPhoto(data: Data([0xFF]), createdAt: created, directory: tempDirectory)
      )
    }

    XCTAssertEqual(CapturedPhotoStore.records.count, CapturedPhotoStore.maxCount)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
    XCTAssertEqual(files.count, CapturedPhotoStore.maxCount)
  }

  func testDeletePhotoRemovesRecordAndFile() {
    let record = CapturedPhotoStore.addPhoto(
      data: Data([0xFF, 0xD8]),
      directory: tempDirectory
    )!

    CapturedPhotoStore.deletePhoto(id: record.id, directory: tempDirectory)

    XCTAssertTrue(CapturedPhotoStore.records.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(record.fileName).path))
  }

  func testDeleteUnknownIDIsNoOp() {
    CapturedPhotoStore.addPhoto(data: Data([0xFF]), directory: tempDirectory)
    CapturedPhotoStore.deletePhoto(id: UUID(), directory: tempDirectory)
    XCTAssertEqual(CapturedPhotoStore.records.count, 1)
  }

  func testUpdateDescriptionBackfillsByID() {
    let record = CapturedPhotoStore.addPhoto(
      data: Data([0xFF, 0xD8]),
      directory: tempDirectory
    )!

    CapturedPhotoStore.updateDescription(id: record.id, description: "像是餐厅")

    XCTAssertEqual(CapturedPhotoStore.records.first?.aiDescription, "像是餐厅")
    XCTAssertEqual(CapturedPhotoStore.records.first?.fileName, record.fileName)
  }

  func testUpdateDescriptionEmptyClearsAndUnknownIDIsNoOp() {
    let record = CapturedPhotoStore.addPhoto(
      data: Data([0xFF, 0xD8]),
      directory: tempDirectory
    )!
    CapturedPhotoStore.updateDescription(id: record.id, description: "像是餐厅")

    CapturedPhotoStore.updateDescription(id: record.id, description: "   ")
    XCTAssertNil(CapturedPhotoStore.records.first?.aiDescription)

    CapturedPhotoStore.updateDescription(id: UUID(), description: "不会写入")
    XCTAssertNil(CapturedPhotoStore.records.first?.aiDescription)
  }

  func testAddPhotoFailsWhenDirectoryUnwritable() {
    // 目录路径被一个普通文件占据 → 无法创建目录 → 落盘失败返回 nil
    let blocker = tempDirectory.appendingPathComponent("blocker")
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    try? Data([0x00]).write(to: blocker)

    let record = CapturedPhotoStore.addPhoto(data: Data([0xFF]), directory: blocker)

    XCTAssertNil(record)
    XCTAssertTrue(CapturedPhotoStore.records.isEmpty)
  }

  func testLoadImageMissingReturnsNil() {
    XCTAssertNil(CapturedPhotoStore.loadImage(fileName: "IMG-20260812-170001.jpg", directory: tempDirectory))
  }
}
