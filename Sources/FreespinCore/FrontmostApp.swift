import AppKit
import Foundation

/// Tracks the frontmost application (the Options+ agent does the same via `set_foreground_process_info`).
public final class FrontmostAppMonitor: @unchecked Sendable {
    public static let shared = FrontmostAppMonitor()

    private let lock = NSLock()
    private var current: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private var observers: [UUID: @Sendable (String?) -> Void] = [:]
    private var token: NSObjectProtocol?

    private init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(app?.bundleIdentifier)
        }
    }

    public var bundleID: String? { lock.withLock { current } }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (String?) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func remove(_ id: UUID) { lock.withLock { observers[id] = nil } }

    private func set(_ id: String?) {
        let handlers: [@Sendable (String?) -> Void] = lock.withLock {
            guard current != id else { return [] }
            current = id
            return Array(observers.values)
        }
        for h in handlers { h(id) }
    }
}
