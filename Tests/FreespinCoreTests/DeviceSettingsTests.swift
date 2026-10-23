import XCTest
@testable import FreespinCore

final class DeviceSettingsTests: XCTestCase {
    func testPercentRoundTrip() {
        var s = DeviceSettings()
        XCTAssertEqual(s.scrollSpeedPercent, 50)
        s.scrollSpeedPercent = 100
        XCTAssertEqual(s.scrollSpeed, 1, accuracy: 1e-9)
        s.scrollSpeedPercent = 0
        XCTAssertEqual(s.scrollSpeed, -1, accuracy: 1e-9)
    }

    func testStorePersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json")
        let store = SettingsStore(url: url)
        store.update("dev") { $0.smoothScrolling = false; $0.scrollSpeed = 0.5 }
        let reloaded = SettingsStore(url: url)
        XCTAssertFalse(reloaded.settings(for: "dev").smoothScrolling)
        XCTAssertEqual(reloaded.settings(for: "dev").scrollSpeed, 0.5)
    }
}
