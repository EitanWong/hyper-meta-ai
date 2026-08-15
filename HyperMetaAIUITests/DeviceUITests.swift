import XCTest

final class DeviceUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launch()
  }

  func testOrbAssistantLaunches() {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(app.buttons["assistant.orb.primary"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["assistant.settings"].exists)
  }

  func testSettingsOpenFromOrb() {
    let settings = app.buttons["assistant.settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
  }
}
