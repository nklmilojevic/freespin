import AppKit
import EventSynth
import Foundation
import HIDPP
import ScrollEngine

/// Static facts read from a device when it connects.
public struct DeviceSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var productID: Int
    public var transport: String
    public var deviceIndex: UInt8
    public var features: [FeatureInfo]
    public var wheel: WheelCapability?
    public var thumbwheel: ThumbwheelInfo?
    public var controls: [ControlInfo] = []
    public var fnInversion: FnInversionState?
    public var backlight: BacklightState?
    public var battery: BatteryState?
    public var smartShift: SmartShiftState?
    public var dpi: Int?
    public var dpiList: [Int]

    public func has(_ f: FeatureID) -> Bool { features.contains { $0.id == f.rawValue } }
}

/// One connected HID++ device: owns its scroll pipeline and applies settings.
public final class DeviceSession: @unchecked Sendable {
    public let device: HIDPPDevice
    public let info: HIDInterfaceInfo
    public private(set) var snapshot: DeviceSnapshot
    public var onChange: (@Sendable (DeviceSnapshot) -> Void)?
    /// Called (on a background queue) when the battery crosses a warning threshold.
    public var onBatteryAlert: (@Sendable (DeviceSnapshot, BatteryAlertPolicy.Alert) -> Void)?
    private var batteryPolicy = BatteryAlertPolicy()
    private var batteryHandler: UUID?
    private var batteryTimer: DispatchSourceTimer?

    let queue = DispatchQueue(label: "freespin.session", qos: .userInteractive)
    let clock: ScrollClock
    let poster: ScrollEventPoster
    private let store: any DeviceSettingsStore
    var processor = WheelProcessor()
    /// Separate engine instance for the thumbwheel (horizontal), sharing the injector like Options+.
    var thumbProcessor = WheelProcessor()
    var keysHandler: UUID?
    var appObserver: UUID?
    var middleButtonMonitor: Any?
    var divertedControls: Set<UInt16> = []
    var buttonActions: [UInt16: ButtonAction] = [:]
    var held: Set<UInt16> = []
    var gesture = GestureTracker()
    var ring: RingSelector?
    var swipe: DockSwipeTracker?
    var trackpadSwipes = false
    let dockSwipe = DockSwipePoster()
    var ringItems: [ButtonAction] = ButtonAction.defaultRing
    let actions = ActionPerformer.shared
    private var thumbHandler: UUID?
    var injector = ScrollInjectorModel()
    private var originalWheelMode: WheelMode?
    private var wheelHandler: UUID?

    public init(device: HIDPPDevice, info: HIDInterfaceInfo, store: any DeviceSettingsStore = SettingsStore.shared,
                poster: ScrollEventPoster = ScrollEventPoster(), clock: ScrollClock = SystemClock()) {
        self.device = device
        self.info = info
        self.store = store
        self.poster = poster
        self.clock = clock
        // Behind a receiver the HID product name is the receiver's; use a neutral name until 0x0005 answers.
        let initialName = device.deviceIndex == HIDPPDeviceIndex.direct ? info.product : "Device \(device.deviceIndex)"
        snapshot = DeviceSnapshot(id: "", name: initialName, productID: info.productID,
                                  transport: device.deviceIndex == HIDPPDeviceIndex.direct ? info.transport : "Logi receiver",
                                  deviceIndex: device.deviceIndex, features: [], dpiList: [])
    }

    public var settings: DeviceSettings { store.settings(for: snapshot) }

    /// Reads identity and capabilities. Only when `drive` is true does it divert the wheel and apply
    /// stored settings; discovery alone never writes to the device.
    public private(set) var driving = false

    public func start(drive: Bool) async throws {
        _ = try await device.protocolVersion()
        var snap = snapshot
        snap.features = (try? await device.allFeatures()) ?? []
        if let name = try? await device.deviceName(), !name.isEmpty { snap.name = name }
        let serial = info.serial.isEmpty ? String(info.locationID, radix: 16) : info.serial
        snap.id = String(format: "%04x-%@-%02x", info.productID, serial, device.deviceIndex)
        if snap.has(.hiResWheel) { snap.wheel = try? await device.wheelCapability() }
        if snap.has(.thumbwheel) { snap.thumbwheel = try? await device.thumbwheelInfo() }
        if snap.features.contains(where: { [0x40A0, 0x40A2, 0x40A3].contains($0.id) }) {
            snap.fnInversion = try? await device.fnInversion()
        }
        if snap.features.contains(where: { $0.id == 0x1982 }) { snap.backlight = try? await device.backlight() }
        if snap.has(.specialKeys) { snap.controls = (try? await device.controls())?.filter(\.divertable) ?? [] }
        snap.battery = try? await device.battery()
        if snap.has(.smartShift) || snap.has(.smartShiftTunableTorque) { snap.smartShift = try? await device.smartShift() }
        if snap.has(.adjustableDPI) {
            snap.dpi = try? await device.dpi()
            snap.dpiList = (try? await device.dpiList()) ?? []
        }
        snapshot = snap
        if snap.has(.hiResWheel) {
            originalWheelMode = try? await device.wheelMode()
        }
        seedSettingsIfNew()
        await startBatteryMonitoring()
        if drive { try await beginDriving() }
        onChange?(snapshot)
    }

    /// First time we see a device, adopt what it is currently configured to instead of imposing defaults.
    private func seedSettingsIfNew() {
        guard !store.hasSettings(for: snapshot) else { return }
        let snap = snapshot
        store.update(snap) { s in
            if let ss = snap.smartShift {
                s.smartShiftEnabled = ss.autoDisengage != 0xFF && ss.mode != .freespin
                if ss.autoDisengage != 0xFF, ss.autoDisengage > 0 { s.smartShiftSensitivity = Int(ss.autoDisengage) }
                if let t = ss.torque, t > 0 { s.smartShiftTorque = Int(t) }
            }
            s.dpi = snap.dpi
            if snap.controls.contains(where: { $0.cid == 0x00C3 }) { s.buttons[DeviceSettings.key(0x00C3)] = .gestures }
        }
    }

    /// Takes over the wheel: subscribes to diverted wheel reports and applies stored settings.
    public func beginDriving() async throws {
        guard !driving else { return }
        driving = true
        if snapshot.has(.hiResWheel), wheelHandler == nil {
            wheelHandler = try await device.onWheelEvent { [weak self] ev in self?.handleWheel(ev) }
        }
        if middleButtonMonitor == nil {
            // `-[wheel_disturbance_filter watchMiddleButtonStart]`: global monitor, mask 0x6000000
            // (OtherMouseDown|Up); button 2 arms the filter so a wheel click doesn't scroll.
            let clock = self.clock
            middleButtonMonitor = await MainActor.run {
                NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] e in
                    guard let self, e.buttonNumber == 2 else { return }
                    let now = clock.wallSeconds()
                    self.queue.async { self.processor.disturbance.disturbance(now: now) }
                }
            }
        }
        if snapshot.has(.specialKeys), keysHandler == nil {
            keysHandler = try await device.onSpecialKeysEvent { [weak self] ev in self?.handleKeys(ev) }
        }
        if snapshot.has(.thumbwheel), thumbHandler == nil {
            thumbHandler = try await device.onThumbwheelEvent { [weak self] ev in self?.handleThumbwheel(ev) }
            try? await device.setThumbwheelReporting(diverted: true, inverted: false)
        }
        try await apply(settings.effective(for: FrontmostAppMonitor.shared.bundleID))
        if appObserver == nil {
            appObserver = FrontmostAppMonitor.shared.observe { [weak self] bundle in
                guard let self, self.driving else { return }
                Task { try? await self.apply(self.settings.effective(for: bundle)) }
            }
        }
    }

    /// Restores the wheel to the mode it had before we touched it (native scrolling).
    public func stop() async {
        guard driving else { return }
        driving = false
        lastApplied = nil
        if let id = wheelHandler { device.removeHandler(id) }
        wheelHandler = nil
        if let id = thumbHandler {
            device.removeHandler(id)
            try? await device.setThumbwheelReporting(diverted: false, inverted: false)
        }
        thumbHandler = nil
        if let m = middleButtonMonitor { await MainActor.run { NSEvent.removeMonitor(m) } }
        middleButtonMonitor = nil
        if let id = appObserver { FrontmostAppMonitor.shared.remove(id) }
        appObserver = nil
        if let id = keysHandler { device.removeHandler(id) }
        keysHandler = nil
        for cid in divertedControls { try? await device.divertControl(cid, diverted: false) }
        divertedControls.removeAll()
        if snapshot.has(.hiResWheel) {
            // Never leave the wheel diverted: with nobody listening it would stop scrolling.
            let inverted = originalWheelMode?.inverted ?? false
            _ = try? await device.setWheelMode(WheelMode(diverted: false, highResolution: false, inverted: inverted))
        }
    }

    public func update(_ body: @escaping (inout DeviceSettings) -> Void) async throws {
        store.update(snapshot, body)
        try await reapply()
    }

    /// Re-applies the store's current settings, e.g. after the daemon reloads its config.
    public func reapply() async throws {
        if driving { try await apply(settings.effective(for: FrontmostAppMonitor.shared.bundleID)) }
        onChange?(snapshot)
    }

    /// Mirrors `devio_feature_2121_gesture::_set_parameters`: diverted = smooth, highRes = smooth.
    private var lastApplied: DeviceSettings?

    /// Pushes settings to the engine immediately and to the device only for fields that changed.
    public func apply(_ s: DeviceSettings) async throws {
        let multiplier = Int(snapshot.wheel?.multiplier ?? 1)
        queue.sync {
            processor.settings = s.wheelSettings
            processor.deviceMultiplier = multiplier
            var thumb = WheelSettings()
            thumb.speed = s.thumbwheelSpeed
            thumb.smooth = true
            thumb.natural = s.thumbwheelNatural
            thumbProcessor.settings = thumb
            thumbProcessor.deviceMultiplier = snapshot.thumbwheel?.multiplier ?? 1
        }
        let previous = lastApplied
        lastApplied = s
        if snapshot.has(.hiResWheel), previous?.smoothScrolling != s.smoothScrolling {
            let mode = WheelMode(diverted: s.smoothScrolling, highResolution: s.smoothScrolling, inverted: false)
            _ = try await device.setWheelMode(mode)
        }
        if let current = snapshot.smartShift,
           previous == nil || previous?.smartShiftEnabled != s.smartShiftEnabled
            || previous?.smartShiftSensitivity != s.smartShiftSensitivity || previous?.smartShiftTorque != s.smartShiftTorque {
            let threshold = s.smartShiftEnabled ? UInt8(clamping: max(1, s.smartShiftSensitivity)) : 0xFF
            let desired = SmartShiftState(mode: .ratchet, autoDisengage: threshold,
                                          torque: current.torque == nil ? nil : UInt8(clamping: s.smartShiftTorque))
            if desired != current {
                try? await device.setSmartShift(desired)
                snapshot.smartShift = try? await device.smartShift()
            }
        }
        await applyButtons(s)
        if let fn = s.fnKeysFirst, let current = snapshot.fnInversion, current.fnKeysFirst != fn {
            try? await device.setFnInversion(fnKeysFirst: fn)
            snapshot.fnInversion = try? await device.fnInversion()
        }
        if let on = s.backlightEnabled, let current = snapshot.backlight, current.enabled != on {
            try? await device.setBacklight(enabled: on)
            snapshot.backlight = try? await device.backlight()
        }
        if let dpi = s.dpi, snapshot.has(.adjustableDPI), dpi != snapshot.dpi {
            try? await device.setDPI(dpi)
            snapshot.dpi = try? await device.dpi()
        }
    }

    public func refreshBattery() async {
        guard let b = try? await device.battery() else { return }
        updateBattery(b)
    }

    private func updateBattery(_ b: BatteryState) {
        let alert: BatteryAlertPolicy.Alert? = queue.sync {
            snapshot.battery = b
            return batteryPolicy.evaluate(b)
        }
        onChange?(snapshot)
        if let alert { onBatteryAlert?(snapshot, alert) }
    }

    /// Battery broadcasts from the device plus a 10-minute poll as a fallback.
    private func startBatteryMonitoring() async {
        guard snapshot.battery != nil, batteryHandler == nil else { return }
        if let b = snapshot.battery { updateBattery(b) }
        batteryHandler = try? await device.onBatteryEvent { [weak self] b in self?.updateBattery(b) }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 600, repeating: 600)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.refreshBattery() }
        }
        timer.resume()
        batteryTimer = timer
    }


    private func handleWheel(_ ev: WheelEvent) {
        let now = clock.wallSeconds()
        let ts = clock.uptimeNanoseconds()
        let shift = CGEventSourceFlagsShift.isDown
        queue.async { [self] in
            switch ev {
            case let .movement(_, periods, deltaV, deltaH):
                for out in processor.process(periods: periods, deltaV: deltaV, deltaH: deltaH,
                                             timestamp: ts, shift: shift, now: now) {
                    if let f = injector.fields(for: out, nowNs: ts) { poster.post(f) }
                }
            case let .ratchetSwitch(ratchet):
                var s = processor.settings
                s.freewheel = !ratchet
                processor.settings = s
            }
        }
    }
}

import CoreGraphics

extension DeviceSession {
    /// Diverts exactly the controls that have a non-native action (rawXY for gestures), restores the rest.
    func applyButtons(_ s: DeviceSettings) async {
        guard snapshot.has(.specialKeys) else { return }
        var wanted: [UInt16: ButtonAction] = [:]
        for c in snapshot.controls {
            let a = s.action(for: c.cid)
            if a != .native { wanted[c.cid] = a }
        }
        for cid in divertedControls where wanted[cid] == nil {
            try? await device.divertControl(cid, diverted: false)
            divertedControls.remove(cid)
        }
        for (cid, action) in wanted where queue.sync(execute: { buttonActions[cid] }) != action || !divertedControls.contains(cid) {
            let raw = action.needsRawXY && (snapshot.controls.first { $0.cid == cid }?.rawXY ?? false)
            do {
                try await device.divertControl(cid, diverted: true, rawXY: raw)
                divertedControls.insert(cid)
            } catch {
                NSLog("Freespin: divert 0x%04x failed: \(error)", cid)
            }
        }
        queue.sync {
            buttonActions = wanted
            trackpadSwipes = s.trackpadSwipes
        }
    }

    func handleKeys(_ ev: SpecialKeysEvent) {
        queue.async { [self] in
            switch ev {
            case let .pressed(cids):
                let now = Set(cids)
                for cid in now.subtracting(held) {
                    guard let a = buttonActions[cid] else { continue }
                    switch a {
                    case .gestures:
                        if trackpadSwipes {
                            var t = DockSwipeTracker()
                            t.begin()
                            swipe = t
                        } else {
                            gesture.begin()
                        }
                    case .actionsRing:
                        ring = RingSelector(slices: ringItems.count)
                        RingPresenterRegistry.presenter?.show(items: ringItems)
                    default: actions.perform(a, pressed: true)
                    }
                }
                for cid in held.subtracting(now) {
                    guard let a = buttonActions[cid] else { continue }
                    switch a {
                    case .gestures:
                        if var t = swipe {
                            swipe = nil
                            emit(t.end())
                        } else {
                            actions.perform(gesture: gesture.finish())
                        }
                    case .actionsRing:
                        let pick = ring?.selected
                        ring = nil
                        RingPresenterRegistry.presenter?.hide()
                        if let pick, ringItems.indices.contains(pick) {
                            let action = ringItems[pick]
                            // Let the ring window disappear before synthesizing input.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ActionPerformer.shared.trigger(action) }
                        }
                    default: actions.perform(a, pressed: false)
                    }
                }
                held = now
            case let .rawXY(dx, dy):
                if var t = swipe {
                    let out = t.add(dx: dx, dy: dy, time: clock.wallSeconds())
                    swipe = t
                    if let out { emit(out) }
                } else if var r = ring {
                    let before = r.selected
                    r.add(dx: dx, dy: dy)
                    ring = r
                    if r.selected != before { RingPresenterRegistry.presenter?.highlight(r.selected) }
                } else {
                    gesture.add(dx: dx, dy: dy)
                }
            }
        }
    }

    private func emit(_ out: DockSwipeTracker.Output) {
        switch out {
        case .click:
            actions.perform(gesture: .click)
        case let .swipe(axis, phase, offset, velocity):
            dockSwipe.post(axis: axis, phase: phase, offset: offset, velocity: velocity)
        }
    }

    func handleThumbwheel(_ ev: ThumbwheelEvent) {
        guard ev.rotation != 0 else { return }
        let now = clock.wallSeconds()
        let ts = clock.uptimeNanoseconds()
        queue.async { [self] in
            // Device rotation sign maps directly onto the horizontal axis (verified on MX Master 3S).
            for out in thumbProcessor.process(periods: 1, deltaV: 0, deltaH: ev.rotation, timestamp: ts, now: now) {
                if let f = injector.fields(for: out, nowNs: ts) { poster.post(f) }
            }
        }
    }
}

enum CGEventSourceFlagsShift {
    static var isDown: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) }
}
