import Foundation
import XCTest

@testable import HyperMetaAI

final class RTMPChecklistStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    RTMPChecklistStore.items = RTMPChecklistStore.defaultItems()
    RTMPChecklistStore.remembered = false
  }

  override func tearDown() {
    RTMPChecklistStore.items = RTMPChecklistStore.defaultItems()
    RTMPChecklistStore.remembered = false
    super.tearDown()
  }

  func testDefaultItemsContainsThreeEntries() {
    let items = RTMPChecklistStore.defaultItems()
    XCTAssertEqual(items.count, 3)
    XCTAssertTrue(items.allSatisfy { !$0.isChecked })
    XCTAssertEqual(Set(items.map(\.titleKey)).count, 3)
  }

  func testAllConfirmedRequiresEveryItem() {
    var items = RTMPChecklistStore.defaultItems()
    XCTAssertFalse(RTMPChecklistStore.allConfirmed(items))

    items[0].isChecked = true
    XCTAssertFalse(RTMPChecklistStore.allConfirmed(items))

    for index in items.indices {
      items[index].isChecked = true
    }
    XCTAssertTrue(RTMPChecklistStore.allConfirmed(items))
  }

  func testAllConfirmedRejectsEmptyList() {
    XCTAssertFalse(RTMPChecklistStore.allConfirmed([]))
  }

  func testItemsPersistRoundTrip() {
    var items = RTMPChecklistStore.defaultItems()
    items[0].isChecked = true
    items[2].isChecked = true
    RTMPChecklistStore.save(items: items, remembered: true)

    let loaded = RTMPChecklistStore.items
    XCTAssertEqual(loaded.count, 3)
    XCTAssertTrue(loaded[0].isChecked)
    XCTAssertFalse(loaded[1].isChecked)
    XCTAssertTrue(loaded[2].isChecked)
    XCTAssertTrue(RTMPChecklistStore.remembered)
  }

  func testSaveUncheckedItemsNotRemembered() {
    RTMPChecklistStore.save(items: RTMPChecklistStore.defaultItems(), remembered: false)
    XCTAssertFalse(RTMPChecklistStore.remembered)
  }
}

final class RTMPGoLiveGateTests: XCTestCase {

  func testShowsChecklistWhenNotRememberedAndNotConfirmed() {
    XCTAssertTrue(RTMPGoLiveGate.shouldShowChecklist(remembered: false, itemsConfirmed: false))
  }

  func testHidesChecklistWhenRemembered() {
    XCTAssertFalse(RTMPGoLiveGate.shouldShowChecklist(remembered: true, itemsConfirmed: false))
    XCTAssertFalse(RTMPGoLiveGate.shouldShowChecklist(remembered: true, itemsConfirmed: true))
  }

  func testHidesChecklistWhenConfirmedEvenIfNotRemembered() {
    XCTAssertFalse(RTMPGoLiveGate.shouldShowChecklist(remembered: false, itemsConfirmed: true))
  }
}

final class RTMPPrivacyShieldTests: XCTestCase {

  func testStartsVisible() {
    var shield = RTMPPrivacyShield.visible
    XCTAssertFalse(shield.isHidden)
  }

  func testToggleHidesAndShows() {
    var shield = RTMPPrivacyShield.visible
    shield.toggle()
    XCTAssertTrue(shield.isHidden)

    shield.toggle()
    XCTAssertFalse(shield.isHidden)
  }
}
