import AppKit
import CoreGraphics
import Foundation

/// What a remapped control does. Mirrors the core of the Options+ action catalog
/// (data/migration/task_id_card_map_osx.json) that makes sense natively.
public enum ButtonAction: Codable, Sendable, Hashable {
    case native
    case back
    case forward
    case middleClick
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case desktopLeft
    case desktopRight
    /// Hold + move: up Mission Control, down App Exposé, left/right switch desktops, click = Mission Control.
    case gestures
    /// Hold to show a radial menu at the cursor, move toward an item, release to run it.
    case actionsRing
    case screenshot
    case keystroke(keyCode: UInt16, modifiers: UInt64)

    public static let catalog: [ButtonAction] = [
        .native, .back, .forward, .middleClick, .missionControl, .appExpose, .showDesktop, .launchpad,
        .desktopLeft, .desktopRight, .screenshot, .gestures, .actionsRing,
    ]

    /// Default Actions Ring slices, clockwise from the top.
    public static let defaultRing: [ButtonAction] = [
        .missionControl, .desktopRight, .screenshot, .showDesktop, .appExpose, .launchpad, .middleClick, .desktopLeft,
    ]

    public var title: String {
        switch self {
        case .native: "Default"
        case .back: "Back"
        case .forward: "Forward"
        case .middleClick: "Middle Click"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .launchpad: "Launchpad"
        case .desktopLeft: "Desktop Left"
        case .desktopRight: "Desktop Right"
        case .gestures: "Gestures"
        case .actionsRing: "Actions Ring"
        case .screenshot: "Screenshot"
        case let .keystroke(code, mods): "Keystroke \(code) (\(String(mods, radix: 16)))"
        }
    }

    /// Gesture mode needs raw pointer motion while the control is held.
    public var needsRawXY: Bool { self == .gestures || self == .actionsRing }

    public var symbol: String {
        switch self {
        case .native: "circle"
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .middleClick: "computermouse"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.stack"
        case .showDesktop: "menubar.dock.rectangle"
        case .launchpad: "square.grid.3x3"
        case .desktopLeft: "arrow.left.square"
        case .desktopRight: "arrow.right.square"
        case .gestures: "hand.draw"
        case .actionsRing: "circle.circle"
        case .screenshot: "camera.viewfinder"
        case .keystroke: "keyboard"
        }
    }
}

public enum GestureDirection: Sendable, Equatable {
    case click, up, down, left, right
}

/// Performs actions by synthesizing input (requires Accessibility).
public final class ActionPerformer: @unchecked Sendable {
    public static let shared = ActionPerformer()

    private let source = CGEventSource(stateID: .hidSystemState)

    private enum Key {
        static let left: CGKeyCode = 123, right: CGKeyCode = 124, down: CGKeyCode = 125, up: CGKeyCode = 126
        static let f11: CGKeyCode = 103
    }

    public init() {}

    /// Discrete actions fire on press; mouse-button actions mirror press/release.
    public func perform(_ action: ButtonAction, pressed: Bool) {
        switch action {
        case .native, .gestures, .actionsRing:
            return
        case .back:
            mouseButton(3, down: pressed)
        case .forward:
            mouseButton(4, down: pressed)
        case .middleClick:
            mouseButton(2, down: pressed)
        default:
            guard pressed else { return }
            fire(action)
        }
    }

    /// Runs a discrete action once (press + release for mouse-button actions).
    public func trigger(_ action: ButtonAction) {
        perform(action, pressed: true)
        perform(action, pressed: false)
    }

    public func perform(gesture: GestureDirection) {
        switch gesture {
        case .click, .up: fire(.missionControl)
        case .down: fire(.appExpose)
        case .left: fire(.desktopRight)   // swipe left reveals the desktop to the right, like the trackpad
        case .right: fire(.desktopLeft)
        }
    }

    private func fire(_ action: ButtonAction) {
        switch action {
        case .missionControl: key(Key.up, flags: .maskControl)
        case .appExpose: key(Key.down, flags: .maskControl)
        case .desktopLeft: key(Key.left, flags: .maskControl)
        case .desktopRight: key(Key.right, flags: .maskControl)
        case .showDesktop: key(Key.f11, flags: [])
        case .screenshot: key(21, flags: [.maskCommand, .maskShift])   // ⌘⇧4
        case .launchpad:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
        case let .keystroke(code, mods):
            key(CGKeyCode(code), flags: CGEventFlags(rawValue: mods))
        default:
            break
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        var flags = flags
        // Real arrow keys carry NumericPad + SecondaryFn; symbolic hotkeys (Mission Control, Spaces) only
        // match Ctrl+arrow when those bits are present.
        if (123...126).contains(code) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: ScrollEventPoster.eventSourceUserData)
            e.post(tap: .cghidEventTap)
        }
    }

    private func mouseButton(_ number: Int64, down: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                              mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .center) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: number)
        e.setIntegerValueField(.eventSourceUserData, value: ScrollEventPoster.eventSourceUserData)
        e.post(tap: .cghidEventTap)
    }
}

/// Selection logic of the Actions Ring (pure, testable): accumulates raw motion and picks a slice.
public struct RingSelector: Sendable {
    public var slices: Int
    /// Raw counts from the center before a slice is selected.
    public var deadZone = 60.0
    public private(set) var x = 0.0
    public private(set) var y = 0.0
    private var skipNext = true

    public init(slices: Int) { self.slices = slices }

    public mutating func add(dx: Int, dy: Int) {
        if skipNext { skipNext = false; return }
        guard abs(dx) <= 400, abs(dy) <= 400 else { return }
        x += Double(dx)
        y += Double(dy)
        // Keep the virtual pointer within a short radius so reversing direction is quick.
        let r = (x * x + y * y).squareRoot(), limit = deadZone * 2.5
        if r > limit { x *= limit / r; y *= limit / r }
    }

    /// Index clockwise from the top, or nil inside the dead zone.
    public var selected: Int? {
        guard slices > 0, (x * x + y * y).squareRoot() >= deadZone else { return nil }
        // Screen-style coordinates: +y is down. Angle 0 = up, increasing clockwise.
        var angle = atan2(x, -y)
        if angle < 0 { angle += 2 * .pi }
        let sector = 2 * .pi / Double(slices)
        return Int(((angle + sector / 2) / sector).rounded(.down)) % slices
    }
}

/// Classifies a held gesture-button movement (pure, testable).
public struct GestureTracker: Sendable {
    /// Raw sensor counts required before a movement counts as a swipe.
    public var threshold = 50
    public private(set) var dx = 0
    public private(set) var dy = 0

    public init() {}

    /// The first raw-XY report after a press carries a stale, very large delta on the MX Master 3S
    /// (observed: dx -1810, dy -370), so it is dropped, as are implausible single-report jumps.
    public var maxReportDelta = 400
    private var skipNext = false

    public mutating func begin() { dx = 0; dy = 0; skipNext = true }

    public mutating func add(dx: Int, dy: Int) {
        if skipNext { skipNext = false; return }
        guard abs(dx) <= maxReportDelta, abs(dy) <= maxReportDelta else { return }
        self.dx += dx
        self.dy += dy
    }

    public func finish() -> GestureDirection {
        guard max(abs(dx), abs(dy)) >= threshold else { return .click }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }
}
