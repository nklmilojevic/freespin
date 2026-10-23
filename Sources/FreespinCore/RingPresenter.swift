import EventSynth
import Foundation

/// Draws the Actions Ring. The session drives it; the app supplies the UI.
public protocol RingPresenter: AnyObject, Sendable {
    func show(items: [ButtonAction])
    func highlight(_ index: Int?)
    func hide()
}

/// Global hook the app sets at launch (the CLI leaves it nil and the ring is a no-op).
public enum RingPresenterRegistry {
    nonisolated(unsafe) public static var presenter: RingPresenter?
}
