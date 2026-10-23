import AppKit
import EventSynth
import Flow
import Foundation
import HIDPP
import FreespinCore
import Observation

/// UI-facing view of one device.
struct DeviceItem: Identifiable, Equatable {
    var snapshot: DeviceSnapshot
    var settings: DeviceSettings
    var id: String { snapshot.id }
}

@MainActor
@Observable
final class AppModel {
    var devices: [DeviceItem] = []
    var receivers: [ReceiverSnapshot] = []
    var pairing: [String: PairingModel] = [:]
    var selection: String?
    var log: [String] = []
    var accessibilityGranted = ScrollEventPoster.hasPostPermission()
    var optionsPlusRunning = false
    var startError: String?
    var flow = FlowStatus()
    var flowError: String?

    /// FREESPIN_INSPECT_ONLY=1 shows devices without diverting the wheel or writing settings.
    private let manager = DeviceManager(drive: ProcessInfo.processInfo.environment["FREESPIN_INSPECT_ONLY"] != "1")
    private var sessions: [String: DeviceSession] = [:]
    private let ringPresenter = ActionsRingPresenter()
    private var permissionTimer: Timer?
    @ObservationIgnored private(set) var flowCoordinator: FlowCoordinator?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        makePreviewPairing()
        manager.onSessionsChanged = { [weak self] sessions in
            Task { @MainActor in self?.refresh(sessions) }
        }
        manager.onReceiversChanged = { [weak self] list in
            Task { @MainActor in self?.refreshReceivers(list) }
        }
        manager.onReceiverEvent = { [weak self] id, event in
            Task { @MainActor in self?.pairing[id]?.handle(event) }
        }
        RingPresenterRegistry.presenter = ringPresenter
        BatteryNotifier.requestAuthorization()
        manager.onBatteryAlert = { snapshot, alert in BatteryNotifier.post(device: snapshot, alert: alert) }
        manager.onLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        do {
            try manager.start()
        } catch {
            startError = "\(error)"
        }
        startFlow()
        checkEnvironment()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEnvironment() }
        }
    }

    func shutdown() async {
        flowCoordinator?.engine.stop()
        await manager.stopAll()
    }

    /// FREESPIN_FLOW=0 leaves Flow off entirely (no listener, no Bonjour). FREESPIN_FLOW_DIR=<dir> keeps the
    /// Flow identity and settings there instead of the keychain (a second test instance on one Mac).
    private func startFlow() {
        let env = ProcessInfo.processInfo.environment
        guard env["FREESPIN_FLOW"] != "0" else { return }
        do {
            let coordinator = try FlowCoordinator.standard(canSwitch: manager.drive,
                                                           stateDirectory: env["FREESPIN_FLOW_DIR"].map { URL(fileURLWithPath: $0) },
                                                           name: env["FREESPIN_FLOW_NAME"])
            coordinator.engine.onStatus = { [weak self] status in
                Task { @MainActor in self?.flow = status }
            }
            coordinator.engine.onEvent = { [weak self] event in
                guard case let .error(message) = event else { return }
                NSLog("Freespin: flow: %@", message)
                Task { @MainActor in self?.append("flow: \(message)") }
            }
            try coordinator.engine.start()
            flowCoordinator = coordinator
            coordinator.sessionsChanged(Array(sessions.values))
        } catch {
            flowError = "\(error)"
        }
    }

    var flowEngine: FlowEngine? { flowCoordinator?.engine }

    func requestAccessibility() {
        _ = ScrollEventPoster.hasPostPermission(prompt: true)
        checkEnvironment()
    }

    func update(_ id: String, _ body: @escaping @Sendable (inout DeviceSettings) -> Void) {
        guard let session = sessions[id] else { return }
        if let i = devices.firstIndex(where: { $0.id == id }) { body(&devices[i].settings) }
        Task {
            do { try await session.update(body) } catch { append("apply failed: \(error)") }
        }
    }

    /// FREESPIN_PREVIEW_PAIRING=1: a pairing sheet frozen on the click step, for layout checks.
    @ObservationIgnored private(set) var previewPairing: (PairingModel, ReceiverSnapshot)?

    func makePreviewPairing() {
        guard ProcessInfo.processInfo.environment["FREESPIN_PREVIEW_PAIRING"] == "1" else { return }
        let r = ReceiverSnapshot(id: "preview", name: "Logi Bolt Receiver", kind: .bolt, connectedSlots: [])
        let m = PairingModel(receiverID: r.id, kind: .bolt, manager: manager)
        let d = DiscoveredDevice(counter: 0, kind: 2, productID: 0xB034, address: [0, 0, 0, 0, 0, 0], authentication: 2, name: "MX Master 3S")
        m.phase = .passkey(d, PasskeyEntry(passkey: "666", method: .twoButtons), pressed: 2)
        previewPairing = (m, r)
    }

    func pairingModel(for receiver: ReceiverSnapshot) -> PairingModel {
        if let m = pairing[receiver.id] { return m }
        let m = PairingModel(receiverID: receiver.id, kind: receiver.kind, manager: manager)
        pairing[receiver.id] = m
        return m
    }

    /// Devices reached through `receiver`, with their slot.
    func devices(on receiver: ReceiverSnapshot) -> [(DeviceItem, UInt8)] {
        devices.compactMap { item in
            guard let s = sessions[item.id], let r = manager.receiverSlot(of: s), r.receiver == receiver.id else { return nil }
            return (item, r.slot)
        }
    }

    func unpair(_ item: DeviceItem, from receiver: ReceiverSnapshot) {
        guard let s = sessions[item.id], let r = manager.receiverSlot(of: s), let rx = manager.receiver(id: r.receiver) else { return }
        Task {
            do { try await rx.unpair(slot: r.slot) } catch { append("unpair failed: \(error)") }
        }
    }

    private func refreshReceivers(_ list: [ReceiverSnapshot]) {
        receivers = list
        if let sel = selection, sel.hasPrefix("rx:"), !list.contains(where: { "rx:" + $0.id == sel }) { selection = devices.first?.id }
    }

    func refreshBattery() {
        for s in sessions.values { Task { await s.refreshBattery() } }
    }

    private func refresh(_ list: [DeviceSession]) {
        sessions = Dictionary(list.map { ($0.snapshot.id, $0) }, uniquingKeysWith: { a, _ in a })
        devices = list.map { DeviceItem(snapshot: $0.snapshot, settings: $0.settings) }
        flowCoordinator?.sessionsChanged(list)
        if selection == nil || (!(selection ?? "").hasPrefix("rx:") && selection != "flow" && !devices.contains(where: { $0.id == selection })) {
            selection = devices.first?.id
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func checkEnvironment() {
        accessibilityGranted = ScrollEventPoster.hasPostPermission()
        optionsPlusRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.logi.cp-dev-mgr").isEmpty
    }
}
