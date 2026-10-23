import Foundation

// Ports of the Options+ wheel filters (logi/gestures/osx). See re/notes/01-wheel-pipeline.md §2.2–2.4.

/// `wheel_hysteresis`: direction-change dead-band applied to hi-res step counts.
public struct WheelHysteresis: Sendable {
    public struct Preferences: Sendable, Equatable {
        /// `com.logitech.akebono.hysteresisFreespin` etc. Zero means "use the built-in default".
        public var freespin = 0
        public var ratchet = 0
        public var time = 0.0
        public var freespinDamper = 0
        public var ratchetDamper = 0
        public init() {}
    }

    public var freewheel = false
    public private(set) var multiplier = 1
    var timestamp = 0.0
    var positive = 0
    var negative = 0
    var freespinSetting = 4
    var ratchetSetting = 1
    var timeSetting = 1.0
    var freespinMax = 4
    var ratchetMax = 1

    public init(preferences: Preferences = .init()) {
        apply(preferences)
    }

    /// `-readPreferences` (0x101685c68).
    public mutating func apply(_ p: Preferences) {
        let fs = p.freespin >= 1 ? p.freespin : (p.freespin == 0 ? 4 : 0)
        let rs = p.ratchet >= 1 ? p.ratchet : (p.ratchet == 0 ? 1 : 0)
        freespinSetting = fs
        ratchetSetting = rs
        timeSetting = p.time > 0 ? p.time : (p.time == 0 ? 1.0 : 0.0)
        freespinMax = p.freespinDamper >= 1 ? min(2 * fs, p.freespinDamper) : (p.freespinDamper == 0 ? fs : 2 * fs)
        ratchetMax = p.ratchetDamper >= 1 ? min(2 * rs, p.ratchetDamper) : (p.ratchetDamper == 0 ? rs : 2 * rs)
    }

    public mutating func setMultiplier(_ m: Int) { multiplier = m }

    /// `-filterWheelMotion:` (0x101685dd4). `now` is wall-clock seconds.
    public mutating func filter(_ input: Int, now: Double) -> Int {
        var s = input
        if s == 0 || multiplier < 4 { return s }
        let useFreespin = freewheel && multiplier > 7
        let maxV = useFreespin ? freespinMax : ratchetMax
        let x = useFreespin ? freespinSetting : ratchetSetting
        let elapsed = now - timestamp
        if timeSetting > 0, elapsed >= timeSetting {
            let n = Int(elapsed / timeSetting)
            positive = positive >= x ? max(positive - n, x) : min(positive + n, x)
            negative = negative >= x ? max(negative - n, x) : min(negative + n, x)
        }
        timestamp = now
        if s >= 1 {
            negative = min(negative + s, maxV)
            let take = min(positive, s)
            positive -= take
            s -= take
        } else {
            positive = min(positive - s, maxV)
            let take = min(negative, -s)
            negative -= take
            s += take
        }
        return s
    }
}

/// `wheel_ratchet_detect`: quantises hi-res steps to whole notches (state only; the result is unused
/// by Options+ in the scroll path, but the state is kept for parity).
public struct WheelRatchetDetect: Sendable {
    public private(set) var multiplier = 1
    var position = 0

    public init() {}

    public mutating func setMultiplier(_ m: Int) {
        guard m != multiplier else { return }
        position = 0
        multiplier = m
    }

    public mutating func reset() { position = 0 }

    public mutating func timeSinceLastReport(_ dt: Double) {
        if dt >= 2.0 { position = 0 }
    }

    /// `-ratchetSteps:` (0x101687e04). Returns the quantised step count (a multiple of the multiplier).
    @discardableResult
    public mutating func ratchetSteps(_ s: Int) -> Int {
        if multiplier == 1 { return s }
        let m = multiplier
        let h = m / 2
        let total = position + s
        let a = ((total - h) % m) + h
        let b = ((total + (h - 1)) % m) - (h - 1)
        let newPos = total < 0 ? a : b
        position = newPos
        return total - newPos
    }
}

/// `wheel_disturbance_filter`: suppresses wheel motion around a middle-button press so that
/// clicking the wheel doesn't scroll. Ivars: action +8, actionTime +16, spinning +24, spinTime +32,
/// disturbanceTimeSetting +48 (default 0.15), stopTimeSetting +56 (default 0.1). See notes/01 §9.
public struct WheelDisturbanceFilter: Sendable {
    public var disturbanceTime = 0.15
    public var stopTime = 0.1
    /// ivar `action` (+8): a middle-button event armed the filter.
    var action = false
    /// ivar `actionTime` (+16): wall-clock time of the last `disturbance(now:)`.
    var actionTime = 0.0
    /// ivar `spinning` (+24): signed per-period motion estimate; 0 means not spinning.
    var spinning = 0.0
    /// ivar `spinTime` (+32): wall-clock time of the last motion that updated `spinning`.
    var spinTime = 0.0

    public init() {}

    /// `-wheelDisturbance` (0x101684f60). Any non-zero setting arms the filter, including negative
    /// values (`fcmp d0,#0; b.ne`). A zero setting is a no-op.
    public mutating func disturbance(now: Double) {
        guard disturbanceTime != 0 else { return }
        action = true
        actionTime = now
    }

    /// `-filterWheelMotion:periodCount:` (0x1016851a8). Returns the motion to forward (0 = suppressed).
    public mutating func filter(_ v: Int, periodCount: Int, now: Double) -> Int {
        guard periodCount != 0, v != 0, action else { return v }

        // Inside the disturbance window: swallow the motion and remember its per-period rate.
        if now - actionTime < disturbanceTime {
            spinning = Double(Self.quotient(v, periodCount))
            spinTime = now
            return 0
        }

        if spinning != 0 {
            // Stopped: no motion for longer than stopTime since the last spinning update.
            if now - spinTime > stopTime {
                return clear(v)
            }
            // Direction change: motion sign opposite to the spin sign.
            if (v > 0) == (spinning <= 0) {
                return clear(v)
            }
        }

        if spinning == 0 {
            // Never spun during the window: stop tracking and pass the motion through.
            action = false
            return v
        }

        let q = Double(Self.quotient(v, periodCount))
        if spinning > 0 {
            // Respin: rate jumped up by more than one notch per period.
            if spinning + 1 < q { return clear(v) }
        } else if spinning - 1 > q {
            return clear(v)
        }

        // Still spinning: move the estimate halfway toward the new rate and keep suppressing.
        spinning = (spinning + q) * 0.5
        spinTime = now
        return 0
    }

    /// Stop spinning, disarm, and pass the motion through (`0x101685934` / `0x101685938`).
    private mutating func clear(_ v: Int) -> Int {
        spinning = 0
        action = false
        return v
    }

    /// 32-bit signed division as emitted by `sdiv w8, w20, w21` (C `int`, truncating toward zero).
    static func quotient(_ a: Int, _ b: Int) -> Int {
        Int(Int32(truncatingIfNeeded: a).dividedReportingOverflow(by: Int32(truncatingIfNeeded: b)).partialValue)
    }
}
