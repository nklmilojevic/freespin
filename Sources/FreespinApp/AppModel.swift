import AppKit
import EventSynth
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
    var selection: String?
    var log: [String] = []
    var accessibilityGranted = ScrollEventPoster.hasPostPermission()
    var optionsPlusRunning = false
    var startError: String?

    /// FREESPIN_INSPECT_ONLY=1 shows devices without diverting the wheel or writing settings.
    private let manager = DeviceManager(drive: ProcessInfo.processInfo.environment["FREESPIN_INSPECT_ONLY"] != "1")
    private var sessions: [String: DeviceSession] = [:]
    private let ringPresenter = ActionsRingPresenter()
    private var permissionTimer: Timer?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        manager.onSessionsChanged = { [weak self] sessions in
            Task { @MainActor in self?.refresh(sessions) }
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
        checkEnvironment()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEnvironment() }
        }
    }

    func shutdown() async {
        await manager.stopAll()
    }

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

    func refreshBattery() {
        for s in sessions.values { Task { await s.refreshBattery() } }
    }

    private func refresh(_ list: [DeviceSession]) {
        sessions = Dictionary(list.map { ($0.snapshot.id, $0) }, uniquingKeysWith: { a, _ in a })
        devices = list.map { DeviceItem(snapshot: $0.snapshot, settings: $0.settings) }
        if selection == nil || !devices.contains(where: { $0.id == selection }) { selection = devices.first?.id }
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
