import EventSynth
import XCTest
@testable import FreespinCore

final class DaemonConfigTests: XCTestCase {
    private func device(id: String = "b034-FD094774-ff", name: String = "MX Master 3S", productID: Int = 0xB034) -> DeviceSnapshot {
        DeviceSnapshot(id: id, name: name, productID: productID, transport: "Bluetooth Low Energy", deviceIndex: 0xFF,
                       features: [], dpiList: [])
    }

    private func parse(_ json: String) throws -> FreespinConfig {
        try FreespinConfig.parse(Data(json.utf8))
    }

    func testEmptyConfigKeepsBase() throws {
        let config = try parse("{}")
        var base = DeviceSettings()
        base.dpi = 1600
        base.smartShiftSensitivity = 22
        XCTAssertEqual(config.settings(for: device(), base: base), base)
        XCTAssertTrue(config.notifications)
    }

    func testLayersFromDefaultToDeviceKey() throws {
        let config = try parse("""
        {
          "default": { "scrollSpeed": 60, "smoothScrolling": false, "dpi": 1000 },
          "devices": {
            "mx master 3s": { "scrollSpeed": 70, "naturalScrolling": true },
            "0xB034": { "scrollSpeed": 80 },
            "b034-fd094774-ff": { "dpi": 2000 }
          }
        }
        """)
        let s = config.settings(for: device(), base: DeviceSettings())
        XCTAssertEqual(s.scrollSpeedPercent, 80)
        XCTAssertFalse(s.smoothScrolling)
        XCTAssertTrue(s.naturalDirection)
        XCTAssertEqual(s.dpi, 2000)

        let other = config.settings(for: device(id: "c548-1-01", name: "MX Keys", productID: 0xC548), base: DeviceSettings())
        XCTAssertEqual(other.scrollSpeedPercent, 60)
        XCTAssertEqual(other.dpi, 1000)
        XCTAssertFalse(other.naturalDirection)
    }

    func testButtonsAppsAndGestureStyle() throws {
        let config = try parse("""
        {
          "default": {
            "buttons": { "gesture": "gestures", "0x0053": "missionControl", "forward": "default" },
            "gestureStyle": "trackpad",
            "thumbwheelSpeed": 100,
            "apps": { "com.apple.Safari": { "scrollSpeed": 25, "buttons": { "middle": "appExpose" } } }
          }
        }
        """)
        let s = config.settings(for: device(), base: DeviceSettings())
        XCTAssertEqual(s.action(for: 0x00C3), .gestures)
        XCTAssertEqual(s.action(for: 0x0053), .missionControl)
        XCTAssertEqual(s.buttons["0056"], .native)
        XCTAssertTrue(s.trackpadSwipes)
        XCTAssertEqual(s.thumbwheelSpeed, 1, accuracy: 1e-9)
        let safari = s.effective(for: "com.apple.Safari")
        XCTAssertEqual(safari.scrollSpeed, -0.5, accuracy: 1e-9)
        XCTAssertEqual(safari.action(for: 0x0052), .appExpose)
        XCTAssertEqual(s.effective(for: "com.apple.Terminal").scrollSpeedPercent, 50)
    }

    func testDeviceAppEntryAddsToDefaultAppEntry() throws {
        let config = try parse("""
        {
          "default": { "apps": { "com.apple.Safari": { "scrollSpeed": 25, "buttons": { "back": "missionControl" } } } },
          "devices": { "MX Master 3S": { "apps": { "com.apple.Safari": { "buttons": { "middle": "appExpose" } } } } }
        }
        """)
        let safari = config.settings(for: device(), base: DeviceSettings()).effective(for: "com.apple.Safari")
        XCTAssertEqual(safari.scrollSpeed, -0.5, accuracy: 1e-9)
        XCTAssertEqual(safari.action(for: 0x0053), .missionControl)
        XCTAssertEqual(safari.action(for: 0x0052), .appExpose)
    }

    func testNotificationsOff() throws {
        XCTAssertFalse(try parse(#"{ "notifications": false }"#).notifications)
    }

    func testRejectsMistakes() {
        let cases: [(String, String)] = [
            (#"{ "default": { "scrolSpeed": 60 } }"#, "default.scrolSpeed: unknown key"),
            (#"{ "default": { "scrollSpeed": 120 } }"#, "default.scrollSpeed: 120 is outside 0...100"),
            (#"{ "default": { "buttons": { "thumb": "back" } } }"#, "unknown button \"thumb\""),
            (#"{ "default": { "buttons": { "back": "launchpd" } } }"#, "unknown action \"launchpd\""),
            (#"{ "default": { "smoothScrolling": "yes" } }"#, "default.smoothScrolling: expected Bool"),
            (#"{ "notification": false }"#, "notification: unknown key"),
            (#"{ "default": "#, "invalid JSON"),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try parse(json), json) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(json): \(error)")
            }
        }
    }

    func testStoreSeedsBaseInMemoryAndReloads() throws {
        let store = ConfigSettingsStore(config: try parse(#"{ "default": { "scrollSpeed": 70 } }"#))
        let d = device()
        XCTAssertFalse(store.hasSettings(for: d))
        store.update(d) { $0.dpi = 1200 }
        XCTAssertTrue(store.hasSettings(for: d))
        XCTAssertEqual(store.settings(for: d).dpi, 1200)
        XCTAssertEqual(store.settings(for: d).scrollSpeedPercent, 70)

        store.replace(try parse(#"{ "default": { "scrollSpeed": 30, "dpi": 800 } }"#))
        XCTAssertEqual(store.settings(for: d).scrollSpeedPercent, 30)
        XCTAssertEqual(store.settings(for: d).dpi, 800)
        store.replace(try parse("{}"))
        XCTAssertEqual(store.settings(for: d).dpi, 1200)
    }
}
