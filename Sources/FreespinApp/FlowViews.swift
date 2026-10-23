import Flow
import FreespinCore
import SwiftUI

struct FlowRow: View {
    let status: FlowStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Flow")
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let connected = status.hosts.filter { $0.paired && $0.connected }.count
        if !status.settings.enabled { return "Off" }
        return connected == 0 ? "No computers connected" : connected == 1 ? "1 computer connected" : "\(connected) computers connected"
    }
}

/// Freespin Flow: move the mouse (and keyboard) between computers at a screen edge, carrying the clipboard.
struct FlowDetail: View {
    @Environment(AppModel.self) private var model

    private var status: FlowStatus { model.flow }
    private var settings: FlowSettings { status.settings }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color.mauve)
                        .frame(width: 64, height: 64)
                        .background(Color.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Flow").font(.title2.weight(.semibold))
                        Text("Push the pointer past a screen edge to move your mouse to the computer on that side.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Flow", isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch)
                }
                .padding(.vertical, 4)
                if let err = model.flowError {
                    Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }

            Section {
                if status.hosts.isEmpty {
                    Text("Looking for computers running Freespin on this network…").foregroundStyle(.secondary)
                }
                ForEach(status.hosts) { host in
                    FlowHostRow(host: host, peer: settings.peer(host.hostID))
                }
            } header: {
                Text("Computers")
            } footer: {
                Text("This computer: \(status.name). Both computers need Freespin and the same network; nothing goes through the internet.")
            }

            Section("Devices") {
                if status.localDevices.isEmpty {
                    Text("Connect a Logitech mouse with Easy-Switch, paired to each computer on its own channel.")
                        .foregroundStyle(.secondary)
                }
                ForEach(status.localDevices) { d in
                    FlowDeviceRow(device: d, present: status.presentDevices.contains(d.unitID), peers: settings.peers)
                }
            }

            Section("Options") {
                Toggle("Only switch while holding Control", isOn: binding(\.requireControl))
                Toggle("Ignore screen corners", isOn: binding(\.avoidCorners))
                Toggle("Copy and paste between computers", isOn: binding(\.syncClipboard))
                Toggle("Switch Logitech keyboards with the mouse", isOn: binding(\.linkKeyboard))
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ key: WritableKeyPath<FlowSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            model.flowEngine?.updateSettings { $0[keyPath: key] = value }
        })
    }
}

struct FlowHostRow: View {
    @Environment(AppModel.self) private var model
    let host: FlowStatus.Host
    let peer: PairedPeer?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                Text(state).font(.caption).foregroundStyle(host.connected ? Color.green : .secondary)
            }
            Spacer()
            if let peer {
                Picker("Side", selection: Binding(get: { peer.side }, set: { model.flowEngine?.setSide($0, for: host.hostID) })) {
                    Text("Left").tag(FlowEdge.left)
                    Text("Right").tag(FlowEdge.right)
                    Text("Above").tag(FlowEdge.top)
                    Text("Below").tag(FlowEdge.bottom)
                }
                .labelsHidden()
                .fixedSize()
                .help("Where \(host.name) sits relative to this computer's screens")
                Button("Unpair") { model.flowEngine?.unpair(hostID: host.hostID) }
            } else if host.discovered {
                Button("Pair…") { model.flowEngine?.pair(hostID: host.hostID) }
            }
        }
    }

    private var state: String {
        if peer != nil { return host.connected ? "Connected" : "Paired · not reachable" }
        return "Available"
    }
}

struct FlowDeviceRow: View {
    let device: FlowDeviceRecord
    let present: Bool
    let peers: [PairedPeer]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: device.kind == .mouse ? "computermouse" : "keyboard").foregroundStyle(.secondary)
                Text(device.name)
                Spacer()
                Text(present ? "Here · channel \(device.channel + 1)" : "Away · channel \(device.channel + 1) here")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(peers) { p in
                if let ch = p.channel(for: device.unitID) {
                    Text("\(p.name): channel \(ch + 1)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not paired with \(p.name) yet. Pair it there on another Easy-Switch channel.")
                        .font(.caption).foregroundStyle(Color.peach)
                }
            }
        }
    }
}

struct FlowPairingSheet: View {
    @Environment(AppModel.self) private var model
    let pairing: FlowStatus.Pairing

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(Color.mauve)
            Text("Pair with \(pairing.name)").font(.title2.weight(.semibold))
            Text("Check that \(pairing.name) shows the same code.")
                .foregroundStyle(.secondary)
            Text(spaced(pairing.code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .padding(.vertical, 4)
            if pairing.localConfirmed {
                ProgressView("Waiting for \(pairing.name)…").controlSize(.small)
            } else if pairing.remoteConfirmed {
                Text("\(pairing.name) confirmed.").font(.callout).foregroundStyle(.green)
            }
            HStack {
                Button("Cancel", role: .cancel) { model.flowEngine?.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match") { model.flowEngine?.confirmPairing() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pairing.localConfirmed)
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    private func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}
