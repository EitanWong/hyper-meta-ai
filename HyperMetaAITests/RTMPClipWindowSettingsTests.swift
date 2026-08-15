import XCTest

@testable import HyperMetaAI

final class RTMPClipWindowSettingsTests: XCTestCase {

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: RTMPClipWindowSettings.leadKey)
    UserDefaults.standard.removeObject(forKey: RTMPClipWindowSettings.tailKey)
    super.tearDown()
  }

  func testDefaults() {
    XCTAssertEqual(RTMPClipWindowSettings.leadSeconds, 10)
    XCTAssertEqual(RTMPClipWindowSettings.tailSeconds, 5)
  }

  func testClampLowerBound() {
    XCTAssertEqual(RTMPClipWindowSettings.clamp(-5), 0)
    XCTAssertEqual(RTMPClipWindowSettings.clamp(0), 0)
  }

  func testClampUpperBound() {
    XCTAssertEqual(RTMPClipWindowSettings.clamp(120), 60)
    XCTAssertEqual(RTMPClipWindowSettings.clamp(60), 60)
  }

  func testClampKeepsValidValue() {
    XCTAssertEqual(RTMPClipWindowSettings.clamp(25), 25)
  }

  func testPersistenceRoundTrip() {
    RTMPClipWindowSettings.leadSeconds = 30
    RTMPClipWindowSettings.tailSeconds = 8

    XCTAssertEqual(RTMPClipWindowSettings.leadSeconds, 30)
    XCTAssertEqual(RTMPClipWindowSettings.tailSeconds, 8)
  }

  func testPersistClampsOutOfRange() {
    RTMPClipWindowSettings.leadSeconds = 999
    RTMPClipWindowSettings.tailSeconds = -3

    XCTAssertEqual(RTMPClipWindowSettings.leadSeconds, 60)
    XCTAssertEqual(RTMPClipWindowSettings.tailSeconds, 0)
  }
}
