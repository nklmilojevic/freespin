import CoreGraphics
import Foundation

/// Screen layout in CG global coordinates (origin top-left of the main display, y grows downward).
public struct EdgeGeometry: Sendable, Equatable {
    public var displays: [CGRect]

    public init(displays: [CGRect]) {
        self.displays = displays.filter { !$0.isEmpty }
    }

    public var bounds: CGRect { displays.reduce(CGRect.null) { $0.union($1) } }

    public func contains(_ p: CGPoint) -> Bool { displays.contains { $0.contains(p) } }

    /// The outer edge the cursor at `p` is pushing through, with its position along the layout's
    /// bounding box (0 = top/left, 1 = bottom/right). Edges shared with another display don't count, and
    /// with `cornerInset` > 0 neither do the corners of a display.
    public func hit(at p: CGPoint, delta: CGVector, cornerInset: CGFloat = 0, slack: CGFloat = 1) -> (edge: FlowEdge, fraction: Double)? {
        guard let display = displays.first(where: { $0.insetBy(dx: -slack, dy: -slack).contains(p) }) else { return nil }
        let b = bounds
        for edge in FlowEdge.allCases {
            let pushing: Bool
            let atEdge: Bool
            switch edge {
            case .left: pushing = delta.dx < 0; atEdge = p.x <= display.minX + slack
            case .right: pushing = delta.dx > 0; atEdge = p.x >= display.maxX - 1 - slack
            case .top: pushing = delta.dy < 0; atEdge = p.y <= display.minY + slack
            case .bottom: pushing = delta.dy > 0; atEdge = p.y >= display.maxY - 1 - slack
            }
            guard pushing, atEdge else { continue }
            // Another display continues past this edge: the cursor just moves on, no Flow.
            let probe = CGPoint(x: p.x + edge.outward.dx * (slack + 2), y: p.y + edge.outward.dy * (slack + 2))
            if contains(probe) { continue }
            if cornerInset > 0 {
                let along = edge == .left || edge == .right ? p.y : p.x
                let (lo, hi) = edge == .left || edge == .right ? (display.minY, display.maxY) : (display.minX, display.maxX)
                if along < lo + cornerInset || along > hi - cornerInset { return nil }
            }
            let fraction = edge == .left || edge == .right
                ? (p.y - b.minY) / max(b.height, 1)
                : (p.x - b.minX) / max(b.width, 1)
            return (edge, Double(min(max(fraction, 0), 1)))
        }
        return nil
    }

    /// Where the cursor should appear when it arrives through `edge` at `fraction`: on the outermost
    /// display along that edge, `inset` points inside.
    public func entryPoint(edge: FlowEdge, fraction: Double, inset: CGFloat = 2) -> CGPoint? {
        let b = bounds
        guard !b.isNull else { return nil }
        let f = CGFloat(min(max(fraction, 0), 1))
        let vertical = edge == .left || edge == .right
        let coord = vertical ? b.minY + f * b.height : b.minX + f * b.width
        func span(_ r: CGRect) -> ClosedRange<CGFloat> { vertical ? r.minY...(r.maxY - 1) : r.minX...(r.maxX - 1) }
        func distance(_ r: CGRect) -> CGFloat {
            let s = span(r)
            return coord < s.lowerBound ? s.lowerBound - coord : coord > s.upperBound ? coord - s.upperBound : 0
        }
        let nearest = displays.map(distance).min() ?? 0
        let candidates = displays.filter { distance($0) == nearest }
        let display: CGRect?
        switch edge {
        case .left: display = candidates.min { $0.minX < $1.minX }
        case .right: display = candidates.max { $0.maxX < $1.maxX }
        case .top: display = candidates.min { $0.minY < $1.minY }
        case .bottom: display = candidates.max { $0.maxY < $1.maxY }
        }
        guard let d = display else { return nil }
        let s = span(d)
        let along = min(max(coord, s.lowerBound), s.upperBound)
        switch edge {
        case .left: return CGPoint(x: d.minX + inset, y: along)
        case .right: return CGPoint(x: d.maxX - 1 - inset, y: along)
        case .top: return CGPoint(x: along, y: d.minY + inset)
        case .bottom: return CGPoint(x: along, y: d.maxY - 1 - inset)
        }
    }
}

/// Requires the cursor to keep pushing against an edge before it flows, so brushing the edge doesn't
/// switch computers.
public struct EdgePushFilter: Sendable {
    public var requiredPushes: Int
    public var window: TimeInterval
    private var edge: FlowEdge?
    private var count = 0
    private var first: TimeInterval = 0

    public init(requiredPushes: Int = 3, window: TimeInterval = 0.35) {
        self.requiredPushes = requiredPushes
        self.window = window
    }

    /// Feeds one hit (or nil for a move that isn't at an edge); returns the edge once it has been pushed enough.
    public mutating func feed(_ hit: FlowEdge?, at time: TimeInterval) -> FlowEdge? {
        guard let hit else { reset(); return nil }
        if hit != edge || time - first > window {
            edge = hit
            count = 0
            first = time
        }
        count += 1
        if count >= requiredPushes {
            reset()
            return hit
        }
        return nil
    }

    public mutating func reset() {
        edge = nil
        count = 0
    }
}
