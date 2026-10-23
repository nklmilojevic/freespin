import CoreGraphics
import Foundation

/// Synthesizes trackpad-style dock swipes (Spaces / Mission Control follow the finger) with the
/// private CGS gesture events the Dock listens to. Technique as used by Mac Mouse Fix's TouchSimulator:
/// a type-30 "dock control" event carrying the swipe, followed by a type-29 gesture event.
public final class DockSwipePoster: @unchecked Sendable {
    public enum Axis: Double, Sendable { case horizontal = 1, vertical = 2 }
    public enum Phase: Double, Sendable { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    private enum Field {
        static let eventType: UInt32 = 55
        static let magic: UInt32 = 41
        static let hidType: UInt32 = 110
        static let axis: UInt32 = 123
        static let offset: UInt32 = 124
        static let exitSpeed1: UInt32 = 129
        static let exitSpeed2: UInt32 = 130
        static let phase1: UInt32 = 132
        static let phase2: UInt32 = 134
        static let offsetBits: UInt32 = 135
        static let inverted: UInt32 = 136
        static let axis2: UInt32 = 165
    }

    private static let magicValue = 33231.0
    private static let kIOHIDEventTypeDockSwipe = 23.0

    public init() {}

    /// `offset` is the cumulative swipe distance (≈1.0 = one full space), `velocity` its speed per second.
    public func post(axis: Axis, phase: Phase, offset: Double, velocity: Double = 0) {
        guard let dock = CGEvent(source: nil), let gesture = CGEvent(source: nil) else { return }
        func d(_ e: CGEvent, _ f: UInt32, _ v: Double) { e.setDoubleValueField(CGEventField(rawValue: f)!, value: v) }

        d(dock, Field.eventType, 30)
        d(dock, Field.magic, Self.magicValue)
        d(dock, Field.hidType, Self.kIOHIDEventTypeDockSwipe)
        d(dock, Field.phase1, phase.rawValue)
        d(dock, Field.phase2, phase.rawValue)
        d(dock, Field.offset, offset)
        let bits = Float32(offset).bitPattern
        dock.setIntegerValueField(CGEventField(rawValue: Field.offsetBits)!, value: Int64(bits))
        d(dock, Field.axis, axis.rawValue)
        d(dock, Field.axis2, axis.rawValue)
        d(dock, Field.inverted, 0)
        if phase == .ended || phase == .cancelled {
            d(dock, Field.exitSpeed1, velocity)
            d(dock, Field.exitSpeed2, velocity)
        }
        d(gesture, Field.eventType, 29)
        d(gesture, Field.magic, Self.magicValue)

        dock.post(tap: .cgSessionEventTap)
        gesture.post(tap: .cgSessionEventTap)
    }
}

/// Turns gesture-button raw motion into one dock swipe (pure state machine, testable).
public struct DockSwipeTracker: Sendable {
    public enum Output: Sendable, Equatable {
        case swipe(axis: DockSwipePoster.Axis, phase: DockSwipePoster.Phase, offset: Double, velocity: Double)
        case click
    }

    /// Raw counts before the swipe starts and the axis locks.
    public var threshold = 40.0
    /// Raw counts per full space.
    public var countsPerUnit = 700.0

    private(set) var axis: DockSwipePoster.Axis?
    private var x = 0.0, y = 0.0
    private var skipNext = true
    private var lastOffset = 0.0
    private var lastTime = 0.0
    private var velocity = 0.0

    public init() {}

    public mutating func begin() {
        self = DockSwipeTracker(threshold: threshold, countsPerUnit: countsPerUnit)
    }

    private init(threshold: Double, countsPerUnit: Double) {
        self.threshold = threshold
        self.countsPerUnit = countsPerUnit
    }

    public mutating func add(dx: Int, dy: Int, time: Double) -> Output? {
        if skipNext { skipNext = false; lastTime = time; return nil }
        guard abs(dx) <= 400, abs(dy) <= 400 else { return nil }
        x += Double(dx)
        y += Double(dy)
        if axis == nil {
            guard max(abs(x), abs(y)) >= threshold else { return nil }
            axis = abs(x) >= abs(y) ? .horizontal : .vertical
            lastOffset = offset
            lastTime = time
            return .swipe(axis: axis!, phase: .began, offset: offset, velocity: 0)
        }
        let o = offset
        let dt = max(time - lastTime, 1e-3)
        velocity = 0.7 * velocity + 0.3 * (o - lastOffset) / dt
        lastOffset = o
        lastTime = time
        return .swipe(axis: axis!, phase: .changed, offset: o, velocity: velocity)
    }

    public mutating func end() -> Output {
        guard let axis else { return .click }
        return .swipe(axis: axis, phase: .ended, offset: offset, velocity: velocity)
    }

    /// Dock convention: positive horizontal offset reveals the space on the left; vertical negative = up.
    private var offset: Double {
        switch axis {
        case .horizontal: -x / countsPerUnit
        case .vertical: y / countsPerUnit
        case nil: 0
        }
    }
}
