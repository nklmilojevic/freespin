import AppKit
import EventSynth
import FreespinCore
import Observation
import SwiftUI

@MainActor
@Observable
final class RingState {
    var items: [ButtonAction] = []
    var highlighted: Int?
}

/// Floating, click-through Actions Ring shown at the cursor while the assigned button is held.
final class ActionsRingPresenter: RingPresenter, @unchecked Sendable {
    static let size: CGFloat = 300

    @MainActor private lazy var state = RingState()
    @MainActor private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: RingView(state: state))
        return p
    }()

    func show(items: [ButtonAction]) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                state.items = items
                state.highlighted = nil
                let mouse = NSEvent.mouseLocation
                panel.setFrameOrigin(NSPoint(x: mouse.x - Self.size / 2, y: mouse.y - Self.size / 2))
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
            }
        }
    }

    func highlight(_ index: Int?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.1)) { state.highlighted = index }
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

struct RingView: View {
    let state: RingState

    var body: some View {
        let n = max(state.items.count, 1)
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .frame(width: ActionsRingPresenter.size - 20, height: ActionsRingPresenter.size - 20)
            ForEach(Array(state.items.enumerated()), id: \.offset) { i, item in
                let angle = Angle.degrees(Double(i) / Double(n) * 360 - 90)
                let r = (ActionsRingPresenter.size - 20) / 2 - 42
                let active = state.highlighted == i
                VStack(spacing: 4) {
                    Image(systemName: item.symbol).font(.system(size: 20, weight: .medium))
                    Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(active ? Color.black : Color.primary)
                .frame(width: 70, height: 56)
                .background(active ? Color.mauve : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .scaleEffect(active ? 1.08 : 1)
                .offset(x: cos(angle.radians) * r, y: sin(angle.radians) * r)
            }
            Circle()
                .fill(Color.mauve.opacity(state.highlighted == nil ? 0.9 : 0.35))
                .frame(width: 14, height: 14)
        }
        .frame(width: ActionsRingPresenter.size, height: ActionsRingPresenter.size)
        .environment(\.colorScheme, .dark)
    }
}
