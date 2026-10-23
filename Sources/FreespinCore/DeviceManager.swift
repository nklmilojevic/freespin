import Foundation
import HIDPP

/// Discovers Logitech HID++ interfaces and runs a `DeviceSession` per device.
///
/// Direct Bluetooth/USB devices answer on device index 0xFF. Receivers (Bolt/Unifying on usage page
/// 0xFF00) multiplex up to six devices on indexes 1...6, which are probed on attach.
public final class DeviceManager: @unchecked Sendable {
    public var onSessionsChanged: (@Sendable ([DeviceSession]) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?
    public var onBatteryAlert: (@Sendable (DeviceSnapshot, BatteryAlertPolicy.Alert) -> Void)?

    private let hid = HIDManager()
    private let store: SettingsStore
    private let lock = NSLock()
    private var sessions: [String: [DeviceSession]] = [:]  // keyed by interface identity

    /// When false (the default), devices are only inspected; nothing is written to them.
    public let drive: Bool

    public init(store: SettingsStore = .shared, drive: Bool = false) {
        self.store = store
        self.drive = drive
    }

    public var allSessions: [DeviceSession] {
        lock.withLock { sessions.values.flatMap { $0 } }.sorted { $0.snapshot.name < $1.snapshot.name }
    }

    public func start() throws {
        try hid.start { [weak self] event in
            guard let self else { return }
            switch event.kind {
            case .added:
                guard let transport = event.transport else {
                    self.log("cannot open \(event.info) (Input Monitoring permission?)")
                    return
                }
                Task { await self.attach(transport: transport, info: event.info) }
            case .removed:
                self.detach(info: event.info)
            }
        }
    }

    /// Restores every device (undiverts wheels). Call before quitting.
    public func stopAll() async {
        let all = lock.withLock { sessions.values.flatMap { $0 } }
        for s in all { await s.stop() }
    }

    private func key(_ info: HIDInterfaceInfo) -> String {
        "\(info.vendorID):\(info.productID):\(info.locationID):\(info.serial)"
    }

    private func log(_ s: String) {
        onLog?(s)
        NSLog("Freespin: %@", s)
    }

    private func attach(transport: HIDPPTransport, info: HIDInterfaceInfo) async {
        let direct = info.isBluetooth || info.usagePage == 0xFF43 || isDirectProduct(info)
        let indexes: [UInt8] = direct ? [HIDPPDeviceIndex.direct] : [1, 2, 3, 4, 5, 6]
        let router = ReportRouter()
        transport.setInputHandler { raw in router.route(raw) }
        var found: [DeviceSession] = []
        for index in indexes {
            let device = HIDPPDevice(transport: transport, deviceIndex: index)
            device.requestTimeout = direct ? 2.0 : 0.6
            device.retries = direct ? 1 : 0
            router.register(device)
            let session = DeviceSession(device: device, info: info, store: store)
            session.onChange = { [weak self] _ in self?.publish() }
            session.onBatteryAlert = { [weak self] snap, alert in self?.onBatteryAlert?(snap, alert) }
            do {
                try await session.start(drive: drive)
                found.append(session)
                log("attached \(session.snapshot.name) [\(info.transport), index \(index)]")
            } catch {
                router.unregister(index)
                if direct { log("\(info.product): \(error)") }
            }
        }
        lock.withLock { sessions[key(info)] = found }
        publish()
    }

    private func detach(info: HIDInterfaceInfo) {
        let removed = lock.withLock { sessions.removeValue(forKey: key(info)) }
        if removed != nil {
            log("detached \(info.product)")
            publish()
        }
    }

    private func publish() { onSessionsChanged?(allSessions) }

    /// USB-wired devices expose HID++ directly on 0xFF00 too; receivers are named as such.
    private func isDirectProduct(_ info: HIDInterfaceInfo) -> Bool {
        !info.product.localizedCaseInsensitiveContains("receiver")
    }
}

/// Dispatches raw reports from one interface to the device at the matching index.
final class ReportRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [UInt8: HIDPPDevice] = [:]

    func register(_ d: HIDPPDevice) { lock.withLock { devices[d.deviceIndex] = d } }
    func unregister(_ index: UInt8) { lock.withLock { devices[index] = nil } }

    func route(_ raw: [UInt8]) {
        guard let msg = HIDPPMessage(raw: raw) else { return }
        let target = lock.withLock { devices[msg.deviceIndex] }
        target?.handle(msg)
    }
}
