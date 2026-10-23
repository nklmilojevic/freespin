import AppKit
import EventSynth
import HIDPP
import FreespinCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Devices") {
                    ForEach(model.devices) { item in
                        DeviceRow(item: item).tag(item.id)
                    }
                }
                if !model.receivers.isEmpty {
                    Section("Receivers") {
                        ForEach(model.receivers) { r in
                            ReceiverRow(receiver: r).tag("rx:" + r.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .overlay {
                if model.devices.isEmpty && model.receivers.isEmpty {
                    ContentUnavailableView("No devices", systemImage: "computermouse",
                                           description: Text("Turn on a Logitech mouse or keyboard."))
                }
            }
        } detail: {
            VStack(spacing: 0) {
                StatusBanners()
                if let id = model.selection, id.hasPrefix("rx:"),
                   let r = model.receivers.first(where: { "rx:" + $0.id == id }) {
                    ReceiverDetail(receiver: r)
                } else if let id = model.selection, let item = model.devices.first(where: { $0.id == id }) {
                    DeviceDetail(item: item)
                } else {
                    ContentUnavailableView("Select a device", systemImage: "sidebar.left")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshBattery()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh battery and device state")
            }
            ToolbarItem {
                AppMenu()
            }
        }
        .tint(.mauve)
        .sheet(isPresented: .constant(model.previewPairing != nil)) {
            if let (m, r) = model.previewPairing { PairingSheet(pairing: m, receiver: r) }
        }
    }
}

/// Freespin has no Dock icon or menu bar: app-level controls live here.
struct AppMenu: View {
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Menu {
            Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
                do {
                    try LoginItem.set(on)
                    openAtLogin = LoginItem.isEnabled
                } catch {
                    loginError = error.localizedDescription
                }
            }))
            Divider()
            Text("Closing this window keeps Freespin running.")
            Button("Quit Freespin") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Label("Freespin", systemImage: "gearshape")
        }
        .help("Open at login, quit")
        .alert("Couldn't change login item", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
    }
}

struct DeviceRow: View {
    let item: DeviceItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.snapshot.has(.hiResWheel) ? "computermouse.fill" : "keyboard")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.snapshot.name).lineLimit(1)
                Text(item.snapshot.transport.isEmpty ? "Connected" : item.snapshot.transport)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let b = item.snapshot.battery {
                BatteryBadge(battery: b)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BatteryBadge: View {
    let battery: BatteryState

    var body: some View {
        let pct = battery.percent ?? 0
        HStack(spacing: 3) {
            Image(systemName: symbol(pct))
            if battery.percent != nil { Text("\(pct)%").monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(pct <= 15 && battery.percent != nil ? Color.red : Color.secondary)
    }

    private func symbol(_ pct: Int) -> String {
        if battery.charging == .charging || battery.charging == .chargingSlow { return "battery.100.bolt" }
        switch pct {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 11...: return "battery.25"
        default: return "battery.0"
        }
    }
}

struct StatusBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if !model.accessibilityGranted {
                Banner(symbol: "hand.raised.fill", color: .peach,
                       title: "Accessibility access needed",
                       message: "Freespin posts scroll events on behalf of your mouse.") {
                    Button("Grant Access…") { model.requestAccessibility() }
                }
            }
            if model.optionsPlusRunning {
                Banner(symbol: "exclamationmark.triangle.fill", color: .yellow,
                       title: "Logi Options+ is running",
                       message: "Both apps would handle the wheel. Quit Options+ (and its agent) for correct scrolling.") {
                    EmptyView()
                }
            }
            if let err = model.startError {
                Banner(symbol: "xmark.octagon.fill", color: .red, title: "Can't access HID devices", message: err) {
                    EmptyView()
                }
            }
        }
        .padding(model.accessibilityGranted && !model.optionsPlusRunning && model.startError == nil ? 0 : 12)
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DeviceDetail: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    private var snap: DeviceSnapshot { item.snapshot }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: snap.has(.hiResWheel) ? "computermouse.fill" : "keyboard.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.mauve)
                        .frame(width: 64, height: 64)
                        .background(Color.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snap.name).font(.title2.weight(.semibold))
                        Text(String(format: "%@ · PID %04X", snap.transport, snap.productID))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let b = snap.battery { BatteryBadge(battery: b).font(.title3) }
                }
                .padding(.vertical, 4)
            }


            if snap.has(.hiResWheel) {
                ScrollSection(item: item)
            }
            if snap.thumbwheel != nil {
                ThumbwheelSection(item: item)
            }
            if let ss = snap.smartShift {
                SmartShiftSection(item: item, state: ss)
            }
            if snap.has(.adjustableDPI), !snap.dpiList.isEmpty {
                PointerSection(item: item)
            }
            if !snap.controls.isEmpty {
                ButtonsSection(item: item)
            }
            if snap.has(.hiResWheel) {
                AppProfilesSection(item: item)
            }
            if snap.fnInversion != nil || snap.backlight != nil {
                KeyboardSection(item: item)
            }
            Section("Device") {
                BatteryNotificationToggle(snapshot: snap)
                LabeledContent("Features", value: "\(snap.features.count)")
                DisclosureGroup("HID++ feature table") {
                    ForEach(snap.features, id: \.index) { f in
                        HStack {
                            Text(String(format: "0x%04X", f.id)).monospaced()
                            Text(f.known.map { "\($0)" } ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text("v\(f.version)").foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ScrollSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    var body: some View {
        Section {
            Toggle(isOn: binding(\.smoothScrolling)) {
                Text("Smooth scrolling")
                Text("Reads the wheel in high resolution (\(item.snapshot.wheel?.multiplier ?? 1) steps per notch) and scrolls by pixels.")
            }
            LabeledContent("Scroll speed") {
                HStack {
                    Slider(value: percentBinding, in: 0...100) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                    Text("\(item.settings.scrollSpeedPercent)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Direction", selection: binding(\.naturalDirection)) {
                Text("Standard").tag(false)
                Text("Natural").tag(true)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Scrolling")
        } footer: {
            if !item.settings.smoothScrolling {
                Text("With smooth scrolling off, the wheel uses native macOS line scrolling.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentBinding: Binding<Double> {
        Binding(get: { Double(item.settings.scrollSpeedPercent) },
                set: { v in model.update(item.id) { $0.scrollSpeedPercent = Int(v.rounded()) } })
    }

    private func binding<T: Sendable>(_ kp: WritableKeyPath<DeviceSettings, T> & Sendable) -> Binding<T> {
        Binding(get: { item.settings[keyPath: kp] },
                set: { v in model.update(item.id) { $0[keyPath: kp] = v } })
    }
}

struct ThumbwheelSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    var body: some View {
        Section("Thumb wheel") {
            LabeledContent("Speed") {
                HStack {
                    Slider(value: Binding(get: { (item.settings.thumbwheelSpeed + 1) * 50 },
                                          set: { v in model.update(item.id) { $0.thumbwheelSpeed = min(max(v.rounded() / 50 - 1, -1), 1) } }),
                           in: 0...100) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                    Text("\(Int(((item.settings.thumbwheelSpeed + 1) * 50).rounded()))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Direction", selection: Binding(get: { item.settings.thumbwheelNatural },
                                                   set: { v in model.update(item.id) { $0.thumbwheelNatural = v } })) {
                Text("Standard").tag(false)
                Text("Inverted").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }
}

struct SmartShiftSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem
    let state: SmartShiftState

    var body: some View {
        Section("SmartShift") {
            Toggle(isOn: Binding(get: { item.settings.smartShiftEnabled },
                                 set: { v in model.update(item.id) { $0.smartShiftEnabled = v } })) {
                Text("SmartShift")
                Text("Switches from ratchet to free-spin when you flick the wheel.")
            }
            if item.settings.smartShiftEnabled {
                LabeledContent("Sensitivity") {
                    Slider(value: Binding(get: { Double(item.settings.smartShiftSensitivity) },
                                          set: { v in model.update(item.id) { $0.smartShiftSensitivity = Int(v.rounded()) } }),
                           in: 1...50)
                }
            }
            if state.torque != nil {
                LabeledContent("Ratchet force") {
                    Slider(value: Binding(get: { Double(item.settings.smartShiftTorque) },
                                          set: { v in model.update(item.id) { $0.smartShiftTorque = Int(v.rounded()) } }),
                           in: 1...100)
                }
            }
        }
    }
}

struct PointerSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    var body: some View {
        let list = item.snapshot.dpiList
        let current = item.settings.dpi ?? item.snapshot.dpi ?? list.first ?? 1000
        let index = list.firstIndex(where: { $0 >= current }) ?? 0
        Section("Pointer") {
            LabeledContent("Pointer speed") {
                HStack {
                    Slider(value: Binding(get: { Double(index) },
                                          set: { v in
                                              let dpi = list[min(max(Int(v.rounded()), 0), list.count - 1)]
                                              model.update(item.id) { $0.dpi = dpi }
                                          }),
                           in: 0...Double(max(list.count - 1, 1)))
                    Text("\(current) DPI").monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}

struct ButtonsSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    var body: some View {
        Section {
            ForEach(item.snapshot.controls.filter { $0.cid != 0x00D7 }) { control in
                Picker(control.name, selection: Binding(
                    get: { item.settings.action(for: control.cid) },
                    set: { action in
                        let key = DeviceSettings.key(control.cid)
                        model.update(item.id) { $0.buttons[key] = action == .native ? nil : action }
                    })) {
                    ForEach(ButtonAction.catalog.filter { !$0.needsRawXY || control.rawXY }, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
            }
            if item.settings.buttons.values.contains(.gestures) {
                Picker("Gesture style", selection: Binding(get: { item.settings.trackpadSwipes },
                                                           set: { v in model.update(item.id) { $0.trackpadSwipes = v } })) {
                    Text("Shortcuts").tag(false)
                    Text("Trackpad swipes").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Buttons")
        } footer: {
            Text("Gestures: hold the button and move the mouse — up for Mission Control, down for App Exposé, left/right to switch desktops; a click opens Mission Control. Actions Ring: hold, move toward an action, release.")
                .foregroundStyle(.secondary)
        }
    }
}

struct BatteryNotificationToggle: View {
    @AppStorage(BatteryNotifier.enabledKey) private var enabled = true
    let snapshot: DeviceSnapshot

    var body: some View {
        HStack {
            Toggle(isOn: $enabled) {
                Text("Low battery notifications")
                Text("Notifies at 15% and again at 5%.")
            }
            Button("Test") {
                BatteryNotifier.post(device: snapshot, alert: .low(percent: snapshot.battery?.percent ?? 15))
            }
            .disabled(!enabled)
        }
    }
}

struct KeyboardSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    var body: some View {
        Section("Keyboard") {
            if let fn = item.snapshot.fnInversion {
                Toggle(isOn: Binding(get: { item.settings.fnKeysFirst ?? fn.fnKeysFirst },
                                     set: { v in model.update(item.id) { $0.fnKeysFirst = v } })) {
                    Text("Use F1, F2, etc. as standard function keys")
                    Text("Press Fn for media and brightness keys.")
                }
            }
            if let b = item.snapshot.backlight {
                Toggle("Backlight", isOn: Binding(get: { item.settings.backlightEnabled ?? b.enabled },
                                                  set: { v in model.update(item.id) { $0.backlightEnabled = v } }))
            }
        }
    }
}

struct AppProfilesSection: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem

    var body: some View {
        Section {
            ForEach(item.settings.apps.keys.sorted(), id: \.self) { bundle in
                if let o = item.settings.apps[bundle] {
                    AppOverrideRow(item: item, bundle: bundle, override: o)
                }
            }
            Button("Add Application…", systemImage: "plus") { pickApp() }
        } header: {
            Text("Application-specific settings")
        } footer: {
            Text("Overrides apply while the app is frontmost.").foregroundStyle(.secondary)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        model.update(item.id) { if $0.apps[bundle] == nil { $0.apps[bundle] = AppOverride(name: name) } }
    }
}

struct AppOverrideRow: View {
    @Environment(AppModel.self) private var model
    let item: DeviceItem
    let bundle: String
    let override: AppOverride

    var body: some View {
        DisclosureGroup {
            Toggle("Override scroll speed", isOn: Binding(
                get: { override.scrollSpeed != nil },
                set: { on in edit { $0.scrollSpeed = on ? item.settings.scrollSpeed : nil } }))
            if let speed = override.scrollSpeed {
                Slider(value: Binding(get: { (speed + 1) * 50 }, set: { v in edit { $0.scrollSpeed = v / 50 - 1 } }), in: 0...100)
            }
            Picker("Smooth scrolling", selection: Binding(
                get: { override.smoothScrolling }, set: { v in edit { $0.smoothScrolling = v } })) {
                Text("Same as device").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
            Picker("Direction", selection: Binding(
                get: { override.naturalDirection }, set: { v in edit { $0.naturalDirection = v } })) {
                Text("Same as device").tag(Bool?.none)
                Text("Standard").tag(Bool?.some(false))
                Text("Natural").tag(Bool?.some(true))
            }
            Button("Remove", role: .destructive) {
                model.update(item.id) { $0.apps[bundle] = nil }
            }
        } label: {
            HStack {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                }
                Text(override.name)
                Text(bundle).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func edit(_ body: @escaping @Sendable (inout AppOverride) -> Void) {
        let b = bundle
        model.update(item.id) { s in
            guard var o = s.apps[b] else { return }
            body(&o)
            s.apps[b] = o
        }
    }
}

extension Color {
    /// Catppuccin Mocha accents.
    static let mauve = Color(red: 0xCB / 255, green: 0xA6 / 255, blue: 0xF7 / 255)
    static let peach = Color(red: 0xFA / 255, green: 0xB3 / 255, blue: 0x87 / 255)
}
