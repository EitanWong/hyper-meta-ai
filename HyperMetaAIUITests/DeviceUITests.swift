import XCTest

final class DeviceUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launch()
  }

  func testHomeScreenLaunchesOnDevice() {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(app.staticTexts["Hyper Meta AI"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Live AI"].exists)
    XCTAssertTrue(app.staticTexts["Quick Vision"].exists)
    XCTAssertTrue(app.staticTexts["Live Translate"].exists)
  }

  func testHomeTabsNavigate() {
    XCTAssertTrue(app.staticTexts["Hyper Meta AI"].waitForExistence(timeout: 10))

    app.buttons["Records"].tap()
    XCTAssertTrue(app.navigationBars["Records"].waitForExistence(timeout: 5))

    app.buttons["Gallery"].tap()
    XCTAssertTrue(app.navigationBars["Gallery"].waitForExistence(timeout: 5))

    app.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
  }
}
