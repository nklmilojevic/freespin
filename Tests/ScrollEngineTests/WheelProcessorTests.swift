import XCTest
@testable import ScrollEngine

final class AccelerationCurveTests: XCTestCase {
    let curve = AccelerationCurve()

    func testFlatBelowFirstBreakpoint() {
        XCTAssertEqual(curve.screenIPS(fingerIPS: 2, smoothed: 0.1, scrollingSpeed: 0.63), 2, accuracy: 1e-12)
    }

    func testRampBetweenSecondAndThirdBreakpoint() {
        // a = 0.45 is halfway between 0.3 and 0.6: gain = 1 + 0.5 * 11 * s
        let s = 0.5
        XCTAssertEqual(curve.screenIPS(fingerIPS: 1, smoothed: 0.45, scrollingSpeed: s), 1 + 0.5 * 11 * s, accuracy: 1e-12)
    }

    func testPlateau() {
        XCTAssertEqual(curve.screenIPS(fingerIPS: 1, smoothed: 10, scrollingSpeed: 1), 12, accuracy: 1e-12)
    }

    func testAbove120UsesConstantLastEntry() {
        // X[5] = -1 makes the last segment unreachable: gain = S[5] = 1 + (-1 - 1) * s
        XCTAssertEqual(curve.screenIPS(fingerIPS: 1, smoothed: 500, scrollingSpeed: 0.25), 0.5, accuracy: 1e-12)
    }

    func testSymmetricInSmoothedSign() {
        XCTAssertEqual(curve.screenIPS(fingerIPS: -3, smoothed: -10, scrollingSpeed: 1), -36, accuracy: 1e-12)
    }
}

final class WheelSettingsTests: XCTestCase {
    func testScrollingSpeedMapping() {
        var s = WheelSettings()
        s.speed = -1
        XCTAssertEqual(s.scrollingSpeed, 0.06, accuracy: 1e-6)
        s.speed = 0
        XCTAssertEqual(s.scrollingSpeed, 0.63, accuracy: 1e-6)
        s.speed = 1
        XCTAssertEqual(s.scrollingSpeed, 1.2, accuracy: 1e-6)
        s.speed = 7
        XCTAssertEqual(s.scrollingSpeed, 1.2, accuracy: 1e-6)
    }
}

final class HysteresisTests: XCTestCase {
    func testPassThroughBelowMultiplier4() {
        var h = WheelHysteresis()
        h.setMultiplier(1)
        XCTAssertEqual(h.filter(5, now: 0), 5)
        XCTAssertEqual(h.filter(-5, now: 0), -5)
    }

    func testDirectionChangeIsDamped() {
        var h = WheelHysteresis()
        h.setMultiplier(15)
        // After idling, both buckets refill to the dead-band (1), so the first motion loses one step.
        XCTAssertEqual(h.filter(3, now: 100.0), 2)
        // A reversal is reduced by the bucket.
        XCTAssertEqual(h.filter(-3, now: 100.01), -2)
        XCTAssertEqual(h.filter(-3, now: 100.02), -3)
    }

    func testFreespinUsesLargerBand() {
        var h = WheelHysteresis()
        h.setMultiplier(15)
        h.freewheel = true
        XCTAssertEqual(h.filter(10, now: 50), 6)
        XCTAssertEqual(h.filter(-10, now: 50.01), -6)
    }

    func testPreferencesDefaults() {
        let h = WheelHysteresis()
        XCTAssertEqual(h.freespinSetting, 4)
        XCTAssertEqual(h.ratchetSetting, 1)
        XCTAssertEqual(h.timeSetting, 1.0)
        XCTAssertEqual(h.freespinMax, 4)
        XCTAssertEqual(h.ratchetMax, 1)
    }
}

final class RatchetDetectTests: XCTestCase {
    func testQuantisesToMultiplier() {
        var r = WheelRatchetDetect()
        r.setMultiplier(8)
        XCTAssertEqual(r.ratchetSteps(3), 0)
        XCTAssertEqual(r.ratchetSteps(3), 8)
        XCTAssertEqual(r.position, -2)
    }

    func testIdentityForMultiplierOne() {
        var r = WheelRatchetDetect()
        XCTAssertEqual(r.ratchetSteps(7), 7)
    }
}

final class WheelProcessorTests: XCTestCase {
    func testFirstEventUsesMaxPeriodAndOneNotchPixels() {
        var settings = WheelSettings()
        settings.smooth = false
        var p = WheelProcessor(settings: settings, deviceMultiplier: 15)
        let out = p.process(periods: 1, deltaV: 1, deltaH: 0, timestamp: 1_000_000_000, now: 0)
        XCTAssertEqual(out.count, 1)
        // unit = 7/54 in, dt = 0.1 s, v = 1.296 in/s, smoothed = 0.0648 (< 0.3 → gain 1)
        let expected = 0.1 * 100 * (7.0 / 54.0 / 0.1)
        XCTAssertEqual(out[0].pixels, expected, accuracy: 1e-9)
        XCTAssertEqual(out[0].inches, 7.0 / 54.0, accuracy: 1e-12)
        XCTAssertFalse(out[0].horizontal)
    }

    func testSmoothUsesDeviceMultiplier() {
        var p = WheelProcessor(settings: WheelSettings(), deviceMultiplier: 15)
        XCTAssertEqual(p.wheelMultiplier, 15)
        let out = p.process(periods: 1, deltaV: 15, deltaH: 0, timestamp: 5_000_000_000, now: 0)
        XCTAssertEqual(out[0].inches, 7.0 / 54.0, accuracy: 1e-12)
    }

    func testPeriodsSplitReport() {
        var settings = WheelSettings()
        settings.smooth = false
        var p = WheelProcessor(settings: settings)
        let out = p.process(periods: 3, deltaV: 1, deltaH: 0, timestamp: 1, now: 0)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(p.lastTimestamp, 1)
    }

    func testDtClampAndFastScrollAccelerates() {
        var settings = WheelSettings()
        settings.smooth = false
        var p = WheelProcessor(settings: settings)
        var ts: UInt64 = 1_000_000_000
        var last = 0.0
        for _ in 0..<40 {
            ts += 20_000_000 // 20 ms between notches
            last = p.process(periods: 1, deltaV: 1, deltaH: 0, timestamp: ts, now: 0)[0].pixels
        }
        // v = (7/54)/0.02 = 6.48 in/s; smoothed converges toward it → gain on the 1+11s plateau.
        let s = settings.scrollingSpeed
        XCTAssertEqual(last, 0.02 * 100 * 6.48148148148148 * (1 + 11 * s), accuracy: 0.5)
    }

    func testHorizontalOnlyAndShift() {
        var settings = WheelSettings()
        settings.smooth = false
        var p = WheelProcessor(settings: settings)
        let h = p.process(periods: 1, deltaV: 0, deltaH: 1, timestamp: 1, now: 0)[0]
        XCTAssertTrue(h.horizontal)
        XCTAssertLessThan(h.pixels, 0)
        var q = WheelProcessor(settings: settings)
        let s = q.process(periods: 1, deltaV: 1, deltaH: 0, timestamp: 1, shift: true, now: 0)[0]
        XCTAssertTrue(s.horizontal)
    }

    func testNaturalNegates() {
        var settings = WheelSettings()
        settings.smooth = false
        settings.natural = true
        var p = WheelProcessor(settings: settings)
        XCTAssertLessThan(p.process(periods: 2, deltaV: 1, deltaH: 0, timestamp: 1, now: 0)[1].pixels, 0)
    }

    func testZeroPeriodsEmitsNothing() {
        var p = WheelProcessor()
        XCTAssertTrue(p.process(periods: 0, deltaV: 4, deltaH: 0, timestamp: 1, now: 0).isEmpty)
    }
}
