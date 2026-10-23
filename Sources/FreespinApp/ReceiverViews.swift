import FreespinCore
import HIDPP
import SwiftUI

struct ReceiverRow: View {
    let receiver: ReceiverSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(receiver.name).lineLimit(1)
                Text(receiver.connectedSlots.isEmpty ? "No devices" : "\(receiver.connectedSlots.count) connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ReceiverDetail: View {
    @Environment(AppModel.self) private var model
    let receiver: ReceiverSnapshot
    @State private var showPairing = false

    var body: some View {
        let paired = model.devices(on: receiver)
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.mauve)
                        .frame(width: 64, height: 64)
                        .background(Color.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receiver.name).font(.title2.weight(.semibold))
                        Text(receiver.kind == .lightspeed ? "LIGHTSPEED · pairing is not supported" : "Up to 6 devices")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if receiver.kind.supportsPairing {
                        Button("Pair Device…") { showPairing = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Paired devices") {
                if paired.isEmpty {
                    Text("No connected devices. Sleeping devices appear when they wake up.")
                        .foregroundStyle(.secondary)
                }
                ForEach(paired, id: \.0.id) { item, slot in
                    HStack {
                        Text("\(slot)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 18)
                        Text(item.snapshot.name)
                        Spacer()
                        if let b = item.snapshot.battery { BatteryBadge(battery: b) }
                        Button("Unpair", role: .destructive) { model.unpair(item, from: receiver) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing) {
            PairingSheet(pairing: model.pairingModel(for: receiver), receiver: receiver)
        }
    }
}

struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var pairing: PairingModel
    let receiver: ReceiverSnapshot

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair with \(receiver.name)").font(.title3.weight(.semibold))
            content
                .frame(maxWidth: .infinity, minHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if pairing.isActive {
                    Button("Cancel") { pairing.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close") { pairing.phase = .idle; dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if pairing.phase == .idle { pairing.start(connectedSlots: receiver.connectedSlots) } }
    }

    @ViewBuilder private var content: some View {
        switch pairing.phase {
        case .idle:
            ProgressView()
        case .waitingForDevice:
            Instruction(symbol: "power", title: "Turn your device off and on",
                        detail: "Use its power switch. If it has Easy-Switch, pick a free channel first.")
        case .discovering:
            VStack(alignment: .leading, spacing: 10) {
                Instruction(symbol: "antenna.radiowaves.left.and.right", title: "Put your device in pairing mode",
                            detail: "Hold its Easy-Switch (channel) button until the light blinks quickly.")
                if !pairing.found.isEmpty {
                    ForEach(pairing.found) { d in
                        Button {
                            pairing.pair(d)
                        } label: {
                            HStack {
                                Image(systemName: d.isKeyboardLike ? "keyboard" : "computermouse")
                                Text(d.name.isEmpty ? d.kindName : d.name)
                                Spacer()
                                Text("Pair").foregroundStyle(Color.mauve)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case let .pairing(d):
            VStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(d.name.isEmpty ? d.kindName : d.name)…").foregroundStyle(.secondary)
            }
        case let .passkey(d, entry, pressed):
            PasskeyView(device: d, entry: entry, pressed: pressed)
        case let .succeeded(message):
            Instruction(symbol: "checkmark.circle.fill", title: message, detail: "It now shows up in the sidebar.", tint: .green)
        case let .failed(message):
            Instruction(symbol: "xmark.octagon.fill", title: "Pairing failed", detail: message, tint: .red)
        }
    }
}

struct PasskeyView: View {
    let device: DiscoveredDevice
    let entry: PasskeyEntry
    let pressed: Int

    var body: some View {
        VStack(spacing: 14) {
            switch entry {
            case let .typeDigits(code):
                Text("Type this code on \(device.name.isEmpty ? "the keyboard" : device.name), then press Return")
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    ForEach(Array(code.enumerated()), id: \.offset) { i, ch in
                        Text(String(ch))
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .frame(width: 36, height: 46)
                            .background(i < pressed ? Color.mauve.opacity(0.35) : Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            case let .clickPattern(clicks):
                // Like Options+: one prompt at a time (passkey_helper → next_click LEFT/RIGHT, BOTH at the end).
                let done = pressed >= clicks.count
                let next: MouseButtons.Highlight = done ? .both : (clicks[min(pressed, clicks.count - 1)] ? .right : .left)
                Text(done ? "Now press both buttons together" : "Click the highlighted button on \(device.name.isEmpty ? "the mouse" : device.name)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                MouseButtons(highlight: next)
                    .frame(width: 104, height: 148)
                    .padding(.vertical, 4)
                HStack(spacing: 5) {
                    ForEach(0..<clicks.count, id: \.self) { i in
                        Circle()
                            .fill(i < pressed ? Color.mauve : Color.secondary.opacity(0.25))
                            .frame(width: 8, height: 8)
                    }
                }
                Text(done ? "\(clicks.count) of \(clicks.count)" : "Click \(pressed + 1) of \(clicks.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// Top-down mouse with its left/right buttons; the one to press next is lit.
struct MouseButtons: View {
    enum Highlight { case left, right, both }
    let highlight: Highlight

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5))
                HStack(spacing: 3) {
                    button(lit: highlight != .right, leading: true)
                    button(lit: highlight != .left, leading: false)
                }
                .frame(width: w - 12, height: h * 0.42)
                .padding(.top, 6)
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 10, height: h * 0.16)
                    .padding(.top, h * 0.12)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: highlight)
    }

    private func button(lit: Bool, leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 60 : 6, bottomLeadingRadius: 4,
                               bottomTrailingRadius: 4, topTrailingRadius: leading ? 6 : 60, style: .continuous)
            .fill(lit ? Color.mauve : Color.secondary.opacity(0.12))
            .shadow(color: lit ? Color.mauve.opacity(0.6) : .clear, radius: 10)
    }
}

struct Instruction: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = .mauve

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(tint)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
