import AppKit
import CoreGraphics
import Foundation

/// Watches pointer motion with NSEvent monitors and detects pushes through outer screen edges.
public final class SystemPointer: FlowPointer, @unchecked Sendable {
    public var cornerInset: CGFloat = 0
    private var monitors: [Any] = []
    private var keyMonitors: [Any] = []
    private var filter = EdgePushFilter()
    private var callback: (@Sendable (FlowEdge, Double, Bool) -> Void)?
    private var lastFraction = 0.0

    public init() {}

    public var geometry: EdgeGeometry {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return EdgeGeometry(displays: ids.prefix(Int(count)).map { CGDisplayBounds($0) })
    }

    public func start(onEdge: @escaping @Sendable (FlowEdge, Double, Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopMonitors()
            self.callback = onEdge
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
                self.monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
                self?.handle(e)
                return e
            }) {
                self.monitors.append(local)
            }
        }
    }

    public func stop() {
        DispatchQueue.main.async { self.stopMonitors() }
    }

    public func configure(_ settings: FlowSettings) {
        cornerInset = settings.avoidCorners ? 24 : 0
    }

    public func watchKeys(_ handler: (@Sendable () -> Void)?) {
        DispatchQueue.main.async {
            self.keyMonitors.forEach(NSEvent.removeMonitor)
            self.keyMonitors.removeAll()
            guard let handler else { return }
            let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in handler() }) {
                self.keyMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
                handler()
                return e
            }) {
                self.keyMonitors.append(local)
            }
        }
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        callback = nil
        filter.reset()
    }

    private func handle(_ event: NSEvent) {
        guard let cg = event.cgEvent, let callback else { return }
        let delta = CGVector(dx: event.deltaX, dy: event.deltaY)
        let hit = geometry.hit(at: cg.location, delta: delta, cornerInset: cornerInset)
        if let hit { lastFraction = hit.fraction }
        if let edge = filter.feed(hit?.edge, at: event.timestamp) {
            callback(edge, lastFraction, event.modifierFlags.contains(.control))
        }
    }

    public func warp(to point: CGPoint) {
        DispatchQueue.main.async {
            CGWarpMouseCursorPosition(point)
            // Without this the next physical move is swallowed by the post-warp suppression interval.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    public func retreat(from edge: FlowEdge) {
        DispatchQueue.main.async {
            guard let p = CGEvent(source: nil)?.location else { return }
            let step: CGFloat = 40
            CGWarpMouseCursorPosition(CGPoint(x: p.x - edge.outward.dx * step, y: p.y - edge.outward.dy * step))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}

/// NSPasteboard capture/apply for text, rich text, HTML and images, capped at `limit` bytes.
public final class SystemClipboard: FlowClipboard, @unchecked Sendable {
    public static let types: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .tiff]
    public var limit = 16 << 20
    private var lastChangeCount = -1
    private let lock = NSLock()

    public init() {}

    public func captureIfChanged() -> [ClipboardItem]? {
        let pb = NSPasteboard.general
        let changed: Bool = lock.withLock {
            guard pb.changeCount != lastChangeCount else { return false }
            lastChangeCount = pb.changeCount
            return true
        }
        guard changed else { return nil }
        var total = 0
        var items: [ClipboardItem] = []
        for type in Self.types {
            guard let data = pb.data(forType: type), total + data.count <= limit else { continue }
            total += data.count
            items.append(ClipboardItem(type: type.rawValue, data: data))
        }
        return items
    }

    public func apply(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            for item in items { pb.setData(item.data, forType: NSPasteboard.PasteboardType(item.type)) }
            self.lock.withLock { self.lastChangeCount = pb.changeCount }
        }
    }
}
