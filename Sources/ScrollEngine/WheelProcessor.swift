import Foundation

/// Clock abstraction so the engine is deterministic under test.
public protocol ScrollClock: Sendable {
    /// Monotonic nanoseconds (Options+ uses the HID report time / `upTimeInNanoSeconds`).
    func uptimeNanoseconds() -> UInt64
    /// Wall-clock seconds (Options+ uses `[NSDate date].timeIntervalSince1970` in the filters).
    func wallSeconds() -> Double
}

public struct SystemClock: ScrollClock {
    public init() {}
    public func uptimeNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public func wallSeconds() -> Double { Date().timeIntervalSince1970 }
}

/// Acceleration curve of `-[wheel_mouse_handler screenIPSFromFingerIPS:smoothed:]` (0x10168742c).
public struct AccelerationCurve: Sendable, Equatable {
    /// Breakpoints in inches/s (static table at 0x1032655b0).
    public var x: [Double] = [0.0, 0.3, 0.6, 60.0, 120.0, -1.0]
    /// Gain at each breakpoint for scrollingSpeed = 1 (static table at 0x1032655e0).
    public var y: [Double] = [1.0, 1.0, 12.0, 12.0, 6.0, -1.0]

    public init() {}

    /// Returns `gain(smoothed) * fingerIPS`, exactly as the agent does (including the quirk that the
    /// sixth breakpoint is -1 so everything ≥ x[4] uses the constant S[5]).
    public func screenIPS(fingerIPS: Double, smoothed: Double, scrollingSpeed s: Double) -> Double {
        let scaled = y.map { 1.0 + ($0 - 1.0) * s }
        let a = abs(smoothed)
        var gain = scaled[5]
        for i in 1...5 where a < x[i] {
            gain = scaled[i - 1] + (a - x[i - 1]) / (x[i] - x[i - 1]) * (scaled[i] - scaled[i - 1])
            break
        }
        return gain * fingerIPS
    }
}

/// Settings that drive the wheel engine (what Options+ derives from `ScrollWheelSettings`).
public struct WheelSettings: Sendable, Equatable {
    /// UI speed in [-1, 1] (Options+ shows `round((speed+1)*50)` %, default 0 → 50 %).
    public var speed: Double = 0
    /// Hi-res diversion + fractional notches. Off ⇒ native scrolling (wheel not diverted).
    public var smooth = true
    /// Natural ("inverted") direction: applied to raw deltas before the engine (as the devio layer does).
    public var natural = false
    /// Apply the acceleration curve (`!disable_acceleration`; production = true).
    public var accelerate = true
    /// SmartShift freespin state (feeds the hysteresis freespin thresholds).
    public var freewheel = false
    /// Screen DPI constant used by Options+ (`set_scroll_speed` lambda passes 100).
    public var screenDPI = 100
    public var hysteresis = WheelHysteresis.Preferences()

    public init() {}

    /// `set_scroll_speed` lambda $_27 (0x101679c9c): scrollingSpeed = 0.06 + ((speed+1)/2) * 1.14.
    public var scrollingSpeed: Double {
        let v = Float(min(max(speed, -1), 1))
        let frac = (v - -1.0) / (1.0 - -1.0)
        return Double(Float(0.06 + Double(frac) * (1.2 - 0.06)))
    }
}

/// One emitted scroll quantum, the input of the injector stage.
public struct WheelOutput: Sendable, Equatable {
    /// Signed pixels for this sub-period.
    public var pixels: Double
    /// |unit * steps| before filtering, in inches (Options+ passes it as X/YInches).
    public var inches: Double
    public var horizontal: Bool
    public var timestamp: UInt64
}

/// Port of `wheel_mouse_handler` (0x101686a28 / 0x101686d40).
public struct WheelProcessor: Sendable {
    public static let stepsPerInch = 54.0 / 7.0          // 0x401edb6db6db6db7
    public static let minPeriod = 0.008                  // 0x3f80624dd2f1a9fc
    public static let maxPeriod = 0.1                    // 0x3fb999999999999a
    public static let smoothDecay = 0.95                 // 0x3fee666666666666
    public static let smoothGain = 0.05                  // 0x3fa99999999999a0

    public var settings: WheelSettings { didSet { applySettings() } }
    public var curve = AccelerationCurve()
    /// Device hi-res multiplier from 0x2121 GetWheelCapability.
    public var deviceMultiplier = 1 { didSet { applySettings() } }

    public private(set) var hysteresis = WheelHysteresis()
    public private(set) var ratchet = WheelRatchetDetect()
    public var disturbance = WheelDisturbanceFilter()
    public var forceDisturbanceFilter = false

    var lastTimestamp: UInt64 = 0
    var smoothed = 0.0

    public init(settings: WheelSettings = .init(), deviceMultiplier: Int = 1) {
        self.settings = settings
        self.deviceMultiplier = deviceMultiplier
        applySettings()
    }

    /// Effective multiplier: `gestures::set_wheel_multiplier` uses `smooth ? m : 1`.
    public var wheelMultiplier: Int { settings.smooth ? max(deviceMultiplier, 1) : 1 }

    private mutating func applySettings() {
        let w = wheelMultiplier
        hysteresis.setMultiplier(w)
        hysteresis.apply(settings.hysteresis)
        hysteresis.freewheel = settings.freewheel
        ratchet.setMultiplier(w)
    }

    public mutating func reset() {
        lastTimestamp = 0
        smoothed = 0
        ratchet.reset()
    }

    /// Entry point equivalent to a diverted 0x2121 `onWheelMovement` → `gestures::scroll`.
    /// - Parameters:
    ///   - deltaV/deltaH: signed hi-res counts as reported by the device.
    ///   - shift: Shift held (bit 17 of the modifier flags) → horizontal scrolling.
    public mutating func process(periods: Int, deltaV: Int, deltaH: Int, timestamp: UInt64,
                                 shift: Bool = false, now: Double) -> [WheelOutput] {
        let sign = settings.natural ? -1 : 1
        var value = deltaV * sign
        var horizontalOnly = false
        if deltaV == 0, deltaH != 0 {
            horizontalOnly = true
            value = deltaH * sign
        }
        guard periods > 0 else { return [] }
        var out: [WheelOutput] = []
        out.reserveCapacity(periods)
        for k in 0..<periods {
            if let o = postMouseWheel(steps: value, periodCount: periods, periodIndex: k, timestamp: timestamp,
                                      horizontal: horizontalOnly || shift, now: now) {
                out.append(o)
            }
        }
        return out
    }

    /// `-postMouseWheel:horizontal:accelerate:scrollphase:pcount:pnum:timestamp:` (0x101686d40).
    mutating func postMouseWheel(steps input: Int, periodCount: Int, periodIndex k: Int, timestamp ts: UInt64,
                                 horizontal: Bool, now: Double) -> WheelOutput? {
        let n = max(periodCount, 1)
        let w = Double(wheelMultiplier)
        var dt: Double
        if lastTimestamp != 0 {
            let dtTotal = Double(ts &- lastTimestamp) / 1e9
            let perPeriod = dtTotal / Double(n)
            ratchet.timeSinceLastReport(dtTotal)
            if perPeriod < Self.minPeriod {
                dt = Self.minPeriod
            } else if perPeriod < Self.maxPeriod {
                dt = perPeriod
            } else {
                smoothed = 0
                dt = Self.maxPeriod
            }
        } else {
            ratchet.reset()
            dt = Self.maxPeriod
        }
        let unit = 1.0 / (w * Self.stepsPerInch)
        if k == n - 1 { lastTimestamp = ts }
        let raw = unit * Double(input)
        ratchet.ratchetSteps(input)
        var v = hysteresis.filter(input, now: now)
        if settings.freewheel || wheelMultiplier > 1 || forceDisturbanceFilter {
            v = disturbance.filter(v, periodCount: n, now: now)
        }
        let ips = unit * Double(v) / dt
        smoothed = Self.smoothDecay * smoothed + Self.smoothGain * abs(ips)
        let screen = settings.accelerate
            ? curve.screenIPS(fingerIPS: ips, smoothed: smoothed, scrollingSpeed: settings.scrollingSpeed)
            : ips
        let px = dt * Double(settings.screenDPI) * screen
        return WheelOutput(pixels: horizontal ? -px : px, inches: abs(raw), horizontal: horizontal, timestamp: ts)
    }
}
