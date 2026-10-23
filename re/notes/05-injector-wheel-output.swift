import Foundation

// Reference model of -[injector InjectScrollX:Y:XInches:YInches:scrollphase:inertia:timestamp:pageswipe:applyHysteresis:yFixedLineFactor:]
// (Logi Options+ agent v2.6.944893, arm64, 0x10167d920) for the mouse-wheel call made from
// -[wheel_mouse_handler postMouseWheel:...] (0x101687374):
//   scrollphase = caller value (0 for onMouseWheel), inertia = 0, pageswipe = 0, applyHysteresis = 1.
// Only that path is modelled. Phase 1/2/4 and inertia != 0 paths are intentionally not modelled.
// Ivar offsets are from _OBJC_IVAR_$_injector.*; global addresses are the merged globals page 0x1034c39f8.

// MARK: - Hysteresis (hysteresis_switch, singleton at 0x1034c3a00)

struct HysteresisSwitch {
    var ratio: Double = 2.0            // initWithRatio:timeConstant:priorityRatio: from injector init (d0)
    var timeConstant: Double = 0.3     // seconds (d1 = 0x3FD3333333333333)
    var priorityRatio: Double = 4.0    // (d2)
    var first: Double = 0              // ivar 0x08
    var second: Double = 0             // ivar 0x10
    var lastTime: UInt64 = 0           // ivar 0x18, mach_absolute_time ticks
    var active: Int32 = 0              // ivar 0x20: 0 idle, 1 = first wins, 2 = second wins

    /// secondsPerTick = Double(timebase.numer) / (Double(timebase.denom) * 1e9)
    mutating func decay(now: UInt64, secondsPerTick: Double) {
        guard now >= lastTime else { return }
        let dt = Double(now - lastTime) * secondsPerTick
        let f = exp(-dt / timeConstant)
        first *= f
        second *= f
        lastTime = now
    }

    mutating func progressFirst(_ p: Double, now: UInt64, secondsPerTick: Double) {
        decay(now: now, secondsPerTick: secondsPerTick)
        first += p * priorityRatio
        if active != 1 && first >= ratio * second { active = 1 }
    }

    mutating func progressSecond(_ p: Double, now: UInt64, secondsPerTick: Double) {
        decay(now: now, secondsPerTick: secondsPerTick)
        second += p
        if active != 2 && second >= ratio * first { active = 2 }
    }

    mutating func endFirst() {
        first = 0
        if active == 1 { active = 0 }
    }

    mutating func endSecond() {
        second = 0
        if active == 2 { active = 0 }
    }

    var doingFirst: Bool { active == 1 }
    var doingSecond: Bool { active == 2 }
}

// MARK: - Injector state (wheel injector instance) plus merged globals used by InjectScroll

struct WheelInjectorState {
    var naturalFlag: UInt8 = 0            // ivar 0x20 (setNaturalScrolling:). Never set on the wheel injector.
    var zoomLockActive: UInt8 = 0         // ivar 0x70 (setFullScreenZoomLock:withNaturalDirection:)
    var zoomLockNaturalFlag: UInt8 = 0    // ivar 0x71
    var silentPlayback: Bool = false      // ivar 0x21: when non-zero the event is created but not posted
    var floatLineValues: Bool = false     // ivar 0x22 (setInjectFloatLineValues:, Adobe-related)
    var remainderX: Double = 0            // ivar 0x28 scrollRemainderX
    var remainderY: Double = 0            // ivar 0x30 scrollRemainderY
    var lastDirX: Double = 0              // ivar 0x38 scrollXLastDir (+1 / -1 / 0)
    var lastDirY: Double = 0              // ivar 0x40 scrollYLastDir
    var accPxX: Double = 0                // ivar 0x48 scrollXAccumulatedPixelMotion
    var accPxY: Double = 0                // ivar 0x50 scrollYAccumulatedPixelMotion
    var accInX: Double = 0                // ivar 0x58 scrollXAccumulatedWheelInches
    var accInY: Double = 0                // ivar 0x60 scrollYAccumulatedWheelInches
    // Merged globals (0x1034c39f8 page)
    var appSwipeActive: Bool = false      // 0x1034c39f9, set by InjectAppSwipe
    var appSwipeHorizontal: UInt8 = 0     // 0x1034c39fa, set by InjectAppSwipe
    var phaseGate: UInt8 = 0              // 0x1034c39fc, written from the phase-0/4 path

    init() {}
}

// MARK: - Output

struct WheelEvent: Equatable {
    // CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel=0, 2, wheel1, wheel2)
    var wheel1: Int32                 // pixel Y (intY)
    var wheel2: Int32                 // pixel X (intX)
    // CGEventSetIntegerValueField values after creation
    var field11DeltaAxis1: Int32      // line Y
    var field12DeltaAxis2: Int32      // line X
    var field93FixedAxis1: Int32      // Y, 16.16 fixed
    var field94FixedAxis2: Int32      // X, 16.16 fixed
    var field96PointAxis1: Int32      // Y point delta
    var field97PointAxis2: Int32      // X point delta
    var field99ScrollPhase: Int32     // pageswipe ? phase : 0  -> 0 on this path
    var field123MomentumPhase: Int32  // inertia -> 0 on this path
    var field137Natural: Int32        // natural flag byte (0x20 or 0x71)
    var field55: Int32?               // 28 only when fullScreenZoomModifierPressed
}

enum WheelOutcome: Equatable {
    case posted(WheelEvent)            // CGEventPost(kCGHIDEventTap = 0, ...)
    case createdOnly(WheelEvent)       // silentPlayback != 0: created, not posted
    case discardedByHysteresis         // hysteresis.doingFirst == true; progressSecond still applied
    case droppedByPhaseGate            // 0x1034c39fc != 0 at entry; nothing injected, state unchanged
}

struct WheelInjectionResult: Equatable {
    var outcome: WheelOutcome
    /// Non-nil when the InjectAppSwipe(end:1, deliberateEnd:0, horizontal:, all deltas 0) call is issued
    /// before the wheel event (value = horizontal byte at 0x1034c39fa).
    var appSwipeEndHorizontal: UInt8?
}

// MARK: - Helpers (ARM64 instruction semantics)

/// FCVTZS (32-bit): truncate toward zero, saturate, NaN -> 0.
@inline(__always)
func fcvtzs(_ d: Double) -> Int32 {
    if d.isNaN { return 0 }
    if d >= 2147483647.0 { return Int32.max }
    if d <= -2147483648.0 { return Int32.min }
    return Int32(d.rounded(.towardZero))
}

/// -[injector fullScreenZoomModifierPressed] @ 0x10167d868.
/// toggle = CFPreferences closeViewScrollWheelToggle (com.apple.universalaccess), ivar 0x6a.
/// modifierMask = closeViewScrollWheelModifiersInt, ivar 0x6c (default 0x40000 = Control when key absent).
/// flags = raw [NSEvent modifierFlags].
func fullScreenZoomModifierPressed(toggle: Bool, modifierMask: Int32, flags: UInt64) -> Bool {
    guard toggle else { return false }
    let shift = flags & 0x20000 != 0
    let control = flags & 0x40000 != 0
    let option = flags & 0x80000 != 0
    let command = flags & 0x100000 != 0
    let fn = flags & 0x800000 != 0
    switch UInt32(bitPattern: modifierMask) {
    case 0x40000:  return control && !shift && !option && !command && !fn
    case 0x80000:  return option && !shift && !control && !command && !fn
    case 0x100000: return command && !shift && !option && !control && !fn
    default:       return false
    }
}

// MARK: - Wheel path

/// Pure model of InjectScroll for scrollphase=0, inertia=0, pageswipe=0, applyHysteresis=1.
///
/// Inputs as passed by postMouseWheel (0x101687374):
///   vertical:   x = 0,      y = px (signed), xInches = 0,      yInches = |raw inches|
///   horizontal: x = -px,    y = 0,           xInches = |raw|,  yInches = 0
///   yFixedLineFactor = yFixedLineFactor (ivar 0x68, default 1.0) * additionalYFixedLineFactor (0.25 if Adobe, else 1.0)
/// `now` / `secondsPerTick` are mach_absolute_time and the mach timebase ratio (decay uses the same clock).
func injectWheelScroll(
    x: Double,
    y: Double,
    xInches: Double,
    yInches: Double,
    yFixedLineFactor: Double,
    zoomPressed: Bool,
    now: UInt64,
    secondsPerTick: Double,
    injector s: inout WheelInjectorState,
    hysteresis h: inout HysteresisSwitch
) -> WheelInjectionResult {
    // 1. applyHysteresis branch (0x10167da24 .. 0x10167db74)
    h.progressSecond(abs(xInches) + abs(yInches), now: now, secondsPerTick: secondsPerTick)
    if h.doingFirst {
        return WheelInjectionResult(outcome: .discardedByHysteresis, appSwipeEndHorizontal: nil)
    }

    // 2. pending app swipe is ended before the wheel event (0x10167de00 .. 0x10167df14)
    var appSwipeEnd: UInt8? = nil
    if s.appSwipeActive {
        appSwipeEnd = s.appSwipeHorizontal
        s.appSwipeActive = false
    }

    // 3. phase gate (0x10167e10c .. 0x10167e128). Dead G_9FB branch omitted (never set to 1 in binary).
    if s.phaseGate != 0 {
        return WheelInjectionResult(outcome: .droppedByPhaseGate, appSwipeEndHorizontal: appSwipeEnd)
    }
    // inertia == 0 -> (inertia - 1) <u 2 is false, so the gate is cleared (0x10167e5f4 .. 0x10167e604)
    s.phaseGate = 0

    // 4. natural flag byte and sign of the deltas (0x10167d9d8 .. 0x10167da0c)
    let flag: UInt8 = (zoomPressed && s.zoomLockActive != 0) ? s.zoomLockNaturalFlag : s.naturalFlag
    let xEff = flag != 0 ? x : -x
    let yEff = flag != 0 ? -y : y

    // 5. integer pixel parts with remainder carry (modf), phase 0 keeps the remainders (0x10167e38c .. 0x10167e3f0)
    let tX = xEff + s.remainderX
    let intXD = tX.rounded(.towardZero)
    s.remainderX = tX - intXD
    let tY = yEff + s.remainderY
    let intYD = tY.rounded(.towardZero)
    s.remainderY = tY - intYD
    let intX = fcvtzs(intXD)   // wheel2 / point2
    let intY = fcvtzs(intYD)   // wheel1 / point1

    // 6. direction change resets (0x10167e608 .. 0x10167e6a4, 0x10167e988 .. 0x10167e9a8)
    let prevDirX = s.lastDirX
    if prevDirX == 0 || ((prevDirX > 0) != (xEff >= 0)) {
        s.accPxX = 0
        s.accInX = 0
    }
    let dirX: Double = xEff < 0 ? -1 : 1
    s.lastDirX = dirX

    let prevDirY = s.lastDirY
    if prevDirY == 0 || ((prevDirY > 0) != (yEff >= 0)) {
        s.accPxY = 0
        s.accInY = 0
    }
    let dirY: Double = yEff < 0 ? -1 : 1
    s.lastDirY = dirY

    // 7. accumulate (0x10167e6a4 .. 0x10167e6c8)
    s.accPxX += xEff
    s.accPxY += yEff
    s.accInX += xInches
    s.accInY += yInches

    // 8. flush thresholds: 0.02 in (raw), else accumulated inches > 0.06f (0.005f if zoom modifier)
    let thr = Double(zoomPressed ? Float(0.005) : Float(0.06))
    var lineXD = 0.0   // d11, pixel-accumulator / 10 (10 px per line)
    if intX != 0 && (xInches >= 0.02 || s.accInX > thr) {
        lineXD = s.accPxX / 10.0
        s.accPxX = 0
        s.accInX = 0
    }
    var lineYD = 0.0   // d10
    if intY != 0 && (yInches >= 0.02 || s.accInY > thr) {
        lineYD = s.accPxY / 10.0
        s.accPxY = 0
        s.accInY = 0
    }

    // 9. integer line values; a sub-line remainder yields one line in the current direction
    let lx = lineXD.rounded(.towardZero)
    let lineX: Double = lx != 0 ? lx : ((lineXD - lx) != 0 ? dirX : 0)
    let ly = lineYD.rounded(.towardZero)
    let lineY: Double = ly != 0 ? ly : ((lineYD - ly) != 0 ? dirY : 0)

    // 10. fixed / point values
    var fixed1: Double      // d8 before *65536
    var fixed2: Double      // d10 before *65536
    var point1: Int32
    let point2: Int32 = intX
    if !s.floatLineValues {
        // rounded path (0x10167e9b0)
        fixed1 = lineYD.rounded(.toNearestOrAwayFromZero) * yFixedLineFactor
        fixed2 = lineXD.rounded(.toNearestOrAwayFromZero)
        point1 = intY
    } else {
        // float path (0x10167e954)
        fixed1 = yEff / 10.0
        fixed2 = xEff / 10.0
        let sc = Double(intY) * yFixedLineFactor
        if sc > 0 && sc < 1 {
            point1 = 1
        } else if sc > -1 && sc < 0 {
            point1 = -1
        } else {
            point1 = fcvtzs(sc)
        }
    }

    let event = WheelEvent(
        wheel1: intY,
        wheel2: intX,
        field11DeltaAxis1: fcvtzs(lineY),
        field12DeltaAxis2: fcvtzs(lineX),
        field93FixedAxis1: fcvtzs(fixed1 * 65536.0),
        field94FixedAxis2: fcvtzs(fixed2 * 65536.0),
        field96PointAxis1: point1,
        field97PointAxis2: point2,
        field99ScrollPhase: 0,
        field123MomentumPhase: 0,
        field137Natural: Int32(flag),
        field55: zoomPressed ? 28 : nil
    )

    // 11. timestamp = upTimeInNanoseconds() (caller timestamp is not used here); post unless silentPlayback
    let outcome: WheelOutcome = s.silentPlayback ? .createdOnly(event) : .posted(event)
    return WheelInjectionResult(outcome: outcome, appSwipeEndHorizontal: appSwipeEnd)
}
