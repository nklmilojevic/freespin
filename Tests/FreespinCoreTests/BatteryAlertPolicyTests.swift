import HIDPP
import XCTest
@testable import FreespinCore

final class BatteryAlertPolicyTests: XCTestCase {
    func b(_ pct: Int, _ c: BatteryState.Charging = .discharging) -> BatteryState {
        BatteryState(percent: pct, level: "", charging: c)
    }

    func testFiresOncePerThreshold() {
        var p = BatteryAlertPolicy()
        XCTAssertNil(p.evaluate(b(40)))
        XCTAssertEqual(p.evaluate(b(15)), .low(percent: 15))
        XCTAssertNil(p.evaluate(b(14)))
        XCTAssertNil(p.evaluate(b(10)))
        XCTAssertEqual(p.evaluate(b(5)), .critical(percent: 5))
        XCTAssertNil(p.evaluate(b(3)))
    }

    func testAlertsImmediatelyWhenAlreadyLowAtStartup() {
        var p = BatteryAlertPolicy()
        XCTAssertEqual(p.evaluate(b(9)), .low(percent: 9))
    }

    func testCriticalFirstSuppressesLow() {
        var p = BatteryAlertPolicy()
        XCTAssertEqual(p.evaluate(b(4)), .critical(percent: 4))
        XCTAssertNil(p.evaluate(b(12)))
    }

    func testChargingRearms() {
        var p = BatteryAlertPolicy()
        XCTAssertEqual(p.evaluate(b(15)), .low(percent: 15))
        XCTAssertNil(p.evaluate(b(30, .charging)))
        XCTAssertEqual(p.evaluate(b(14)), .low(percent: 14))
    }

    func testHysteresisAvoidsFlapping() {
        var p = BatteryAlertPolicy()
        XCTAssertEqual(p.evaluate(b(15)), .low(percent: 15))
        XCTAssertNil(p.evaluate(b(18)))   // within rearm margin
        XCTAssertNil(p.evaluate(b(15)))
        XCTAssertNil(p.evaluate(b(21)))   // rearmed
        XCTAssertEqual(p.evaluate(b(15)), .low(percent: 15))
    }

    func testCoarseLevels() {
        var p = BatteryAlertPolicy()
        XCTAssertEqual(p.evaluate(BatteryState(percent: nil, level: "low", charging: .discharging)), .low(percent: 15))
        XCTAssertNil(p.evaluate(BatteryState(percent: nil, level: "good", charging: .discharging)))
    }
}
