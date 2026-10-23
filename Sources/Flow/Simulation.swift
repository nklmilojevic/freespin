import CoreGraphics
import Foundation

/// A Flow device without hardware: for tests and `freespinctl flow-sim`.
public final class SimulatedDevice: FlowLocalDevice, @unchecked Sendable {
    public let record: FlowDeviceRecord
    private let lock = NSLock()
    private var connected = true
    private var history: [Int] = []
    /// Called after a switch, with the new channel.
    public var onSwitch: (@Sendable (Int) -> Void)?

    public init(record: FlowDeviceRecord) {
        self.record = record
    }

    public var present: Bool {
        get { lock.withLock { connected } }
        set { lock.withLock { connected = newValue } }
    }

    /// Channels the device was switched to, in order.
    public var switches: [Int] { lock.withLock { history } }

    public func isPresent() async -> Bool { present }

    public func switchHost(to channel: Int) async throws {
        lock.withLock {
            history.append(channel)
            connected = channel == record.channel
        }
        onSwitch?(channel)
    }
}

/// A pointer that records warps and lets the caller inject edge hits.
public final class ScriptedPointer: FlowPointer, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FlowEdge, Double, Bool) -> Void)?
    private var warpLog: [CGPoint] = []
    private var retreatLog: [FlowEdge] = []
    public let geometry: EdgeGeometry

    public init(geometry: EdgeGeometry = EdgeGeometry(displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])) {
        self.geometry = geometry
    }

    public var isRunning: Bool { lock.withLock { handler != nil } }
    public var warps: [CGPoint] { lock.withLock { warpLog } }
    public var retreats: [FlowEdge] { lock.withLock { retreatLog } }

    public func start(onEdge: @escaping @Sendable (FlowEdge, Double, Bool) -> Void) {
        lock.withLock { handler = onEdge }
    }

    public func stop() { lock.withLock { handler = nil } }

    public func warp(to point: CGPoint) { lock.withLock { warpLog.append(point) } }

    public func retreat(from edge: FlowEdge) { lock.withLock { retreatLog.append(edge) } }

    /// Simulates the cursor being pushed through `edge`. Returns false while Flow isn't watching.
    @discardableResult
    public func push(_ edge: FlowEdge, fraction: Double = 0.5, control: Bool = false) -> Bool {
        guard let h = lock.withLock({ handler }) else { return false }
        h(edge, fraction, control)
        return true
    }
}

public final class MemoryClipboard: FlowClipboard, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardItem] = []
    private var dirty = false

    public init() {}

    public var contents: [ClipboardItem] { lock.withLock { items } }

    /// Simulates the user copying something.
    public func copy(_ new: [ClipboardItem]) {
        lock.withLock {
            items = new
            dirty = true
        }
    }

    public func captureIfChanged() -> [ClipboardItem]? {
        lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return items
        }
    }

    public func apply(_ new: [ClipboardItem]) {
        lock.withLock {
            items = new
            dirty = false
        }
    }
}
