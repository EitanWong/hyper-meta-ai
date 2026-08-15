import XCTest
@testable import HyperMetaAI

final class DevicePreferenceStoreTests: XCTestCase {
    private let key = "device.preferred.id"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultIsNil() {
        XCTAssertNil(DevicePreferenceStore.preferredDeviceID)
    }

    func testRoundtrip() {
        DevicePreferenceStore.preferredDeviceID = "glasses-001"
        XCTAssertEqual(DevicePreferenceStore.preferredDeviceID, "glasses-001")
    }

    func testClearingRemovesPreference() {
        DevicePreferenceStore.preferredDeviceID = "glasses-001"
        DevicePreferenceStore.preferredDeviceID = nil
        XCTAssertNil(DevicePreferenceStore.preferredDeviceID)
    }

    func testEmptyStringClearsPreference() {
        DevicePreferenceStore.preferredDeviceID = "glasses-001"
        DevicePreferenceStore.preferredDeviceID = ""
        XCTAssertNil(DevicePreferenceStore.preferredDeviceID)
    }
}
