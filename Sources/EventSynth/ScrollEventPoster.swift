import CoreGraphics
import Foundation
import ScrollEngine

/// Posts synthesized scroll events the way the Options+ injector does:
/// `CGEventCreateScrollWheelEvent(nil, .pixel, 2, …)`, explicit field writes, uptime timestamp,
/// `CGEventPost(kCGHIDEventTap)`.
public final class ScrollEventPoster: @unchecked Sendable {
    /// Lets callers recognise (and ignore) their own events in an event tap.
    public static let eventSourceUserData: Int64 = 0x4C4F4749 // "LOGI"

    public var silent = false
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    @discardableResult
    public func post(_ f: ScrollEventFields) -> Bool {
        guard !silent, !f.isEmpty || f.momentumPhase != 0 || f.scrollPhase != 0 else { return false }
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: f.wheel1, wheel2: f.wheel2, wheel3: 0) else { return false }
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: f.scrollPhase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: f.momentumPhase)
        if let f55 = f.field55 { ev.setIntegerValueField(CGEventField(rawValue: 55)!, value: f55) }
        ev.setIntegerValueField(CGEventField(rawValue: 137)!, value: f.field137)
        ev.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: f.lineDelta1)
        ev.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: f.lineDelta2)
        ev.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: f.fixedDelta1)
        ev.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: f.fixedDelta2)
        ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: f.pointDelta1)
        ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: f.pointDelta2)
        ev.setIntegerValueField(.eventSourceUserData, value: Self.eventSourceUserData)
        ev.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        ev.post(tap: .cghidEventTap)
        return true
    }

    /// True when the process may post events (Accessibility).
    public static func hasPostPermission(prompt: Bool = false) -> Bool {
        if prompt { return CGRequestPostEventAccess() }
        return CGPreflightPostEventAccess()
    }
}
