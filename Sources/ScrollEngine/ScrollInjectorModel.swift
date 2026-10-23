import Foundation

/// Values for one synthesized scroll-wheel CGEvent. Field numbers are the CGEventField raw values
/// that `-[injector InjectScrollX:…]` writes (notes/05).
public struct ScrollEventFields: Sendable, Equatable {
    /// Constructor wheel values (`CGEventCreateScrollWheelEvent(nil, .pixel, 2, wheel1, wheel2)`).
    public var wheel1: Int32 = 0
    public var wheel2: Int32 = 0
    /// 11 / 12: line deltas.
    public var lineDelta1: Int64 = 0
    public var lineDelta2: Int64 = 0
    /// 93 / 94: 16.16 fixed-point deltas.
    public var fixedDelta1: Int64 = 0
    public var fixedDelta2: Int64 = 0
    /// 96 / 97: point (pixel) deltas.
    public var pointDelta1: Int64 = 0
    public var pointDelta2: Int64 = 0
    /// 99: scroll phase (0 for the Options+ wheel path).
    public var scrollPhase: Int64 = 0
    /// 123: momentum phase (0 for the Options+ wheel path).
    public var momentumPhase: Int64 = 0
    /// 137: natural-direction flag byte (0 for the Options+ wheel injector).
    public var field137: Int64 = 0
    /// 55: set to 28 only while the accessibility zoom modifier is held.
    public var field55: Int64?

    public init() {}

    public var isEmpty: Bool {
        wheel1 == 0 && wheel2 == 0 && pointDelta1 == 0 && pointDelta2 == 0 && fixedDelta1 == 0 && fixedDelta2 == 0
            && lineDelta1 == 0 && lineDelta2 == 0
    }
}

/// `hysteresis_switch` singleton (0x1034c3a00): arbitrates between gesture swipes ("first") and the
/// wheel ("second"). Created by the first injector with ratio 2.0, time constant 0.3 s, priority 4.0.
public struct HysteresisSwitch: Sendable {
    public var ratio = 2.0
    public var timeConstant = 0.3
    public var priorityRatio = 4.0
    var first = 0.0
    var second = 0.0
    var lastTime: UInt64 = 0
    var active: Int32 = 0  // 0 idle, 1 first wins, 2 second wins

    public init() {}

    mutating func decay(nowNs: UInt64) {
        guard nowNs >= lastTime else { return }
        let f = exp(-(Double(nowNs - lastTime) / 1e9) / timeConstant)
        first *= f
        second *= f
        lastTime = nowNs
    }

    public mutating func progressFirst(_ p: Double, nowNs: UInt64) {
        decay(nowNs: nowNs)
        first += p * priorityRatio
        if active != 1, first >= ratio * second { active = 1 }
    }

    public mutating func progressSecond(_ p: Double, nowNs: UInt64) {
        decay(nowNs: nowNs)
        second += p
        if active != 2, second >= ratio * first { active = 2 }
    }

    public mutating func endFirst() { first = 0; if active == 1 { active = 0 } }
    public mutating func endSecond() { second = 0; if active == 2 { active = 0 } }
    public var doingFirst: Bool { active == 1 }
    public var doingSecond: Bool { active == 2 }
}

/// Port of the wheel path of `-[injector InjectScrollX:Y:XInches:YInches:scrollphase:inertia:timestamp:
/// pageswipe:applyHysteresis:yFixedLineFactor:]` (0x10167d920) with scrollphase 0, inertia 0,
/// pageswipe 0, applyHysteresis 1 — exactly how `postMouseWheel` calls it. See re/notes/05.
public struct ScrollInjectorModel: Sendable {
    public static let pixelsPerLine = 10.0
    public static let fixedPointScale = 65536.0
    public static let rawInchFlush = 0.02
    public static let accumulatedInchFlush = Double(Float(0.06))
    public static let accumulatedInchFlushZoom = Double(Float(0.005))

    /// ivar 0x20. Never set on the Options+ wheel injector (field 137 = 0, X negated).
    public var naturalFlag: UInt8 = 0
    /// ivar 0x22: Adobe Acrobat mode (float line values).
    public var floatLineValues = false
    public var hysteresis = HysteresisSwitch()

    var remainderX = 0.0, remainderY = 0.0
    var lastDirX = 0.0, lastDirY = 0.0
    var accPxX = 0.0, accPxY = 0.0
    var accInX = 0.0, accInY = 0.0

    public init() {}

    public mutating func reset() {
        remainderX = 0; remainderY = 0; lastDirX = 0; lastDirY = 0
        accPxX = 0; accPxY = 0; accInX = 0; accInY = 0
    }

    /// Convenience for a `WheelOutput` from `WheelProcessor` (applies the postMouseWheel axis mapping).
    public mutating func fields(for out: WheelOutput, yFixedLineFactor: Double = 1.0,
                                zoomPressed: Bool = false, nowNs: UInt64) -> ScrollEventFields? {
        if out.horizontal {
            return fields(x: out.pixels, y: 0, xInches: out.inches, yInches: 0,
                          yFixedLineFactor: yFixedLineFactor, zoomPressed: zoomPressed, nowNs: nowNs)
        }
        return fields(x: 0, y: out.pixels, xInches: 0, yInches: out.inches,
                      yFixedLineFactor: yFixedLineFactor, zoomPressed: zoomPressed, nowNs: nowNs)
    }

    /// Returns nil when the hysteresis switch discards the event (a gesture swipe is winning).
    public mutating func fields(x: Double, y: Double, xInches: Double, yInches: Double,
                                yFixedLineFactor: Double = 1.0, zoomPressed: Bool = false,
                                nowNs: UInt64) -> ScrollEventFields? {
        hysteresis.progressSecond(abs(xInches) + abs(yInches), nowNs: nowNs)
        if hysteresis.doingFirst { return nil }

        let flag = naturalFlag
        let xEff = flag != 0 ? x : -x
        let yEff = flag != 0 ? -y : y

        let tX = xEff + remainderX
        let intXD = tX.rounded(.towardZero)
        remainderX = tX - intXD
        let tY = yEff + remainderY
        let intYD = tY.rounded(.towardZero)
        remainderY = tY - intYD
        let intX = fcvtzs(intXD)
        let intY = fcvtzs(intYD)

        if lastDirX == 0 || (lastDirX > 0) != (xEff >= 0) { accPxX = 0; accInX = 0 }
        let dirX: Double = xEff < 0 ? -1 : 1
        lastDirX = dirX
        if lastDirY == 0 || (lastDirY > 0) != (yEff >= 0) { accPxY = 0; accInY = 0 }
        let dirY: Double = yEff < 0 ? -1 : 1
        lastDirY = dirY

        accPxX += xEff
        accPxY += yEff
        accInX += xInches
        accInY += yInches

        let threshold = zoomPressed ? Self.accumulatedInchFlushZoom : Self.accumulatedInchFlush
        var lineXD = 0.0
        if intX != 0, xInches >= Self.rawInchFlush || accInX > threshold {
            lineXD = accPxX / Self.pixelsPerLine
            accPxX = 0
            accInX = 0
        }
        var lineYD = 0.0
        if intY != 0, yInches >= Self.rawInchFlush || accInY > threshold {
            lineYD = accPxY / Self.pixelsPerLine
            accPxY = 0
            accInY = 0
        }

        let lx = lineXD.rounded(.towardZero)
        let lineX: Double = lx != 0 ? lx : (lineXD - lx != 0 ? dirX : 0)
        let ly = lineYD.rounded(.towardZero)
        let lineY: Double = ly != 0 ? ly : (lineYD - ly != 0 ? dirY : 0)

        let fixed1, fixed2: Double
        var point1: Int32
        if !floatLineValues {
            fixed1 = lineYD.rounded(.toNearestOrAwayFromZero) * yFixedLineFactor
            fixed2 = lineXD.rounded(.toNearestOrAwayFromZero)
            point1 = intY
        } else {
            fixed1 = yEff / Self.pixelsPerLine
            fixed2 = xEff / Self.pixelsPerLine
            let sc = Double(intY) * yFixedLineFactor
            point1 = sc > 0 && sc < 1 ? 1 : (sc > -1 && sc < 0 ? -1 : fcvtzs(sc))
        }

        var f = ScrollEventFields()
        f.wheel1 = intY
        f.wheel2 = intX
        f.lineDelta1 = Int64(fcvtzs(lineY))
        f.lineDelta2 = Int64(fcvtzs(lineX))
        f.fixedDelta1 = Int64(fcvtzs(fixed1 * Self.fixedPointScale))
        f.fixedDelta2 = Int64(fcvtzs(fixed2 * Self.fixedPointScale))
        f.pointDelta1 = Int64(point1)
        f.pointDelta2 = Int64(intX)
        f.field137 = Int64(flag)
        f.field55 = zoomPressed ? 28 : nil
        return f
    }
}

/// ARM64 FCVTZS (32-bit): truncate toward zero, saturating, NaN → 0.
@inline(__always)
func fcvtzs(_ d: Double) -> Int32 {
    if d.isNaN { return 0 }
    if d >= 2_147_483_647.0 { return .max }
    if d <= -2_147_483_648.0 { return .min }
    return Int32(d.rounded(.towardZero))
}
