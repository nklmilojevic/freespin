import XCTest
@testable import ScrollEngine

/// Branch coverage for `WheelDisturbanceFilter`, mirroring `-filterWheelMotion:periodCount:` (0x1016851a8).
final class DisturbanceFilterTests: XCTestCase {
    func testDefaults() {
        let f = WheelDisturbanceFilter()
        XCTAssertEqual(f.disturbanceTime, 0.15)
        XCTAssertEqual(f.stopTime, 0.1)
    }

    func testNotArmedPassesThrough() {
        var f = WheelDisturbanceFilter()
        XCTAssertEqual(f.filter(5, periodCount: 1, now: 1), 5)
    }

    func testZeroSettingNeverArms() {
        var f = WheelDisturbanceFilter()
        f.disturbanceTime = 0
        f.disturbance(now: 1)
        XCTAssertEqual(f.filter(5, periodCount: 1, now: 1.01), 5)
    }

    func testNegativeSettingStillArms() {
        // `fcmp d0,#0; b.ne` in -wheelDisturbance: any non-zero value arms the filter.
        var f = WheelDisturbanceFilter()
        f.disturbanceTime = -1
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(5, periodCount: 1, now: 0), 5)
        XCTAssertEqual(f.filter(5, periodCount: 1, now: 0.5), 5)
    }

    func testZeroPeriodCountOrZeroMotionIsNoOp() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(5, periodCount: 0, now: 0.05), 5)
        XCTAssertEqual(f.filter(0, periodCount: 1, now: 0.05), 0)
        // Neither call touched the window state, so the next real motion still sees it.
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.05), 0)
    }

    func testInsideWindowSuppressesAndRecordsRate() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(6, periodCount: 2, now: 0.05), 0)
        XCTAssertEqual(f.spinning, 3)
        XCTAssertEqual(f.spinTime, 0.05)
    }

    func testWindowRateTruncatesTowardZero() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(-5, periodCount: 2, now: 0.05), 0)
        XCTAssertEqual(f.spinning, -2)
    }

    func testSubPeriodMotionInWindowLeavesZeroSpin() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(1, periodCount: 2, now: 0.05), 0)
        XCTAssertEqual(f.spinning, 0)
        // Not spinning after the window: the first motion passes and disarms.
        XCTAssertEqual(f.filter(3, periodCount: 1, now: 0.2), 3)
        XCTAssertFalse(f.action)
    }

    func testWindowBoundaryIsOutsideWindow() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        // elapsed == disturbanceTime is not `< disturbanceTime`, so the window has closed.
        XCTAssertEqual(f.filter(4, periodCount: 1, now: 0.15), 4)
        XCTAssertFalse(f.action)
    }

    func testAfterWindowWithoutSpinPassesAndDisarms() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(4, periodCount: 1, now: 0.5), 4)
        XCTAssertFalse(f.action)
        XCTAssertEqual(f.filter(4, periodCount: 1, now: 0.5), 4)
    }

    func testStoppedAfterStopTimeReleasesMotion() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.05), 0)
        // now - spinTime = 0.15 > stopTime (0.1): spin has stopped.
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.2), 4)
        XCTAssertFalse(f.action)
        XCTAssertEqual(f.spinning, 0)
    }

    func testStopBoundaryStillSpinning() {
        var f = WheelDisturbanceFilter()
        f.stopTime = 0.25  // dyadic values so the boundary is exact in binary floating point
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.125), 0)
        // now - spinTime == stopTime is not `> stopTime`: still spinning, so suppressed.
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.375), 0)
        XCTAssertEqual(f.spinning, 2)
        XCTAssertTrue(f.action)
    }

    func testDirectionChangeReleasesMotion() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(-4, periodCount: 2, now: 0.12), 0)
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.2), 4)
        XCTAssertFalse(f.action)
        XCTAssertEqual(f.spinning, 0)
    }

    func testPositiveRespinReleasesMotion() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(2, periodCount: 1, now: 0.12), 0)
        // q = 4 > spinning + 1 = 3: respin from speed increase.
        XCTAssertEqual(f.filter(8, periodCount: 2, now: 0.2), 8)
        XCTAssertFalse(f.action)
        XCTAssertEqual(f.spinning, 0)
    }

    func testPositiveSteadySpinSmoothsAndSuppresses() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.12), 0)
        // q = 2, spinning = (2 + 2) / 2 = 2, spinTime = now.
        XCTAssertEqual(f.filter(4, periodCount: 2, now: 0.2), 0)
        XCTAssertEqual(f.spinning, 2)
        XCTAssertEqual(f.spinTime, 0.2)
        XCTAssertTrue(f.action)
    }

    func testPositiveSmoothingMovesHalfwayToward() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(4, periodCount: 1, now: 0.12), 0)     // spinning = 4
        XCTAssertEqual(f.filter(0, periodCount: 1, now: 0.2), 0)      // v == 0 is a no-op
        // q = 1 / 2 = 0 is below spinning + 1, so no respin: spinning = (4 + 0) / 2 = 2.
        XCTAssertEqual(f.filter(1, periodCount: 2, now: 0.2), 0)
        XCTAssertEqual(f.spinning, 2)
    }

    func testNegativeRespinReleasesMotion() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(-2, periodCount: 1, now: 0.12), 0)
        // q = -6 < spinning - 1 = -3: respin.
        XCTAssertEqual(f.filter(-12, periodCount: 2, now: 0.2), -12)
        XCTAssertFalse(f.action)
    }

    func testNegativeSteadySpinSuppresses() {
        var f = WheelDisturbanceFilter()
        f.disturbance(now: 0)
        XCTAssertEqual(f.filter(-4, periodCount: 2, now: 0.12), 0)
        // q = -2, spinning = (-2 + -2) / 2 = -2.
        XCTAssertEqual(f.filter(-4, periodCount: 2, now: 0.2), 0)
        XCTAssertEqual(f.spinning, -2)
        XCTAssertTrue(f.action)
    }

    func testQuotientMatchesSdiv32() {
        XCTAssertEqual(WheelDisturbanceFilter.quotient(7, 2), 3)
        XCTAssertEqual(WheelDisturbanceFilter.quotient(-7, 2), -3)
        XCTAssertEqual(WheelDisturbanceFilter.quotient(7, -2), -3)
        XCTAssertEqual(WheelDisturbanceFilter.quotient(Int(Int32.min), -1), Int(Int32.min))
    }
}
