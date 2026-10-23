import Foundation
import HIDPP

/// UI-facing state of one receiver.
public struct ReceiverSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ReceiverKind
    /// Slots with a paired device that is currently driven by a session.
    public var connectedSlots: [UInt8]

    public init(id: String, name: String, kind: ReceiverKind, connectedSlots: [UInt8]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.connectedSlots = connectedSlots
    }
}

/// Discovers Logitech HID++ interfaces and runs a `DeviceSession` per device.
///
/// Direct Bluetooth/USB devices answer on device index 0xFF. Receivers (Bolt/Unifying/Lightspeed on usage
/// page 0xFF00) multiplex up to six devices on indexes 1...6: they are announced with HID++ 1.0 "device
/// connection" (0x41) notifications, which attach sessions live, with a one-time probe as fallback.
public final class DeviceManager: @unchecked Sendable {
    public var onSessionsChanged: (@Sendable ([DeviceSession]) -> Void)?
    public var onReceiversChanged: (@Sendable ([ReceiverSnapshot]) -> Void)?
    public var onReceiverEvent: (@Sendable (String, ReceiverEvent) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?
    public var onBatteryAlert: (@Sendable (DeviceSnapshot, BatteryAlertPolicy.Alert) -> Void)?

    private let hid = HIDManager()
    private let store: SettingsStore
    private let lock = NSLock()
    private var sessions: [String: [UInt8: DeviceSession]] = [:]  // interface key → device index → session
    private var receivers: [String: ReceiverContext] = [:]

    /// When false (the default), devices are only inspected; nothing is written to them.
    public let drive: Bool

    public init(store: SettingsStore = .shared, drive: Bool = false) {
        self.store = store
        self.drive = drive
    }

    public var allSessions: [DeviceSession] {
        lock.withLock { sessions.values.flatMap { $0.values } }.sorted { $0.snapshot.name < $1.snapshot.name }
    }

    public var allReceivers: [ReceiverSnapshot] {
        lock.withLock { receivers.map { k, r in r.snapshot(id: k, slots: Array((sessions[k] ?? [:]).keys).sorted()) } }
            .sorted { $0.name < $1.name }
    }

    public func receiver(id: String) -> HIDPPReceiver? { lock.withLock { receivers[id]?.receiver } }

    /// Receiver key and slot a session is reached through, or nil for direct (Bluetooth/USB) devices.
    public func receiverSlot(of session: DeviceSession) -> (receiver: String, slot: UInt8)? {
        let k = key(session.info)
        return lock.withLock { receivers[k] != nil ? (k, session.device.deviceIndex) : nil }
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
        let all = lock.withLock { sessions.values.flatMap { $0.values } }
        for s in all { await s.stop() }
    }

    private func key(_ info: HIDInterfaceInfo) -> String {
        "\(info.vendorID):\(info.productID):\(info.locationID):\(info.serial)"
    }

    private func log(_ s: String) {
        onLog?(s)
        NSLog("Freespin: %@", s)
    }

    private func isReceiver(_ info: HIDInterfaceInfo) -> Bool {
        !info.isBluetooth
            && (ReceiverKind(productID: info.productID) != .unknown || info.product.localizedCaseInsensitiveContains("receiver"))
    }

    private func attach(transport: HIDPPTransport, info: HIDInterfaceInfo) async {
        let router = ReportRouter()
        transport.setInputHandler { raw in router.route(raw) }
        let k = key(info)
        if isReceiver(info), lock.withLock({ receivers[k] != nil }) {
            // Receivers expose several vendor interfaces; one HID++ channel per receiver is enough.
            return
        }
        guard isReceiver(info) else {
            let device = HIDPPDevice(transport: transport, deviceIndex: HIDPPDeviceIndex.direct)
            device.retries = 1
            router.register(device)
            await attachSession(device: device, info: info, key: k)
            return
        }

        let receiverDevice = HIDPPDevice(transport: transport, deviceIndex: HIDPPDeviceIndex.receiver)
        receiverDevice.requestTimeout = 1.5
        router.register(receiverDevice)
        let receiver = HIDPPReceiver(device: receiverDevice, kind: ReceiverKind(productID: info.productID))
        let context = ReceiverContext(receiver: receiver, info: info, transport: transport, router: router)
        lock.withLock { receivers[k] = context; sessions[k] = [:] }
        router.onReceiverReport = { [weak self, weak context] raw in
            if ProcessInfo.processInfo.environment["FREESPIN_DEBUG"] != nil {
                self?.log("rx report " + raw.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            guard let self, let context, let ev = context.decode(raw) else { return }
            self.handle(ev, receiverKey: k, context: context)
        }
        log("receiver \(info.product) [\(receiver.kind.rawValue)]")
        do {
            try await receiver.enableNotifications()
            try await receiver.refreshConnections()
        } catch {
            log("receiver notifications unavailable: \(error); probing slots")
        }
        // Fallback probe for receivers that don't answer the connection-state request.
        try? await Task.sleep(nanoseconds: 800_000_000)
        for slot: UInt8 in 1...6 where lock.withLock({ sessions[k]?[slot] == nil }) {
            await attachSlot(slot, key: k, context: context, quiet: true)
        }
        publish()
    }

    private func handle(_ ev: ReceiverEvent, receiverKey k: String, context: ReceiverContext) {
        onReceiverEvent?(k, ev)
        switch ev {
        case let .connection(slot, linked, _, _, _):
            let known = lock.withLock { sessions[k]?[slot] != nil }
            if linked, !known {
                Task { await attachSlot(slot, key: k, context: context, quiet: false) }
            }
        case let .disconnection(slot):
            let removed = lock.withLock { sessions[k]?.removeValue(forKey: slot) }
            if let removed {
                log("unpaired \(removed.snapshot.name) from slot \(slot)")
                context.router.unregister(slot)
                publish()
            }
        default:
            break
        }
    }

    private func attachSlot(_ slot: UInt8, key k: String, context: ReceiverContext, quiet: Bool) async {
        guard lock.withLock({ sessions[k]?[slot] == nil && !context.attaching.contains(slot) }) else { return }
        lock.withLock { _ = context.attaching.insert(slot) }
        defer { lock.withLock { _ = context.attaching.remove(slot) } }
        let device = HIDPPDevice(transport: context.transport, deviceIndex: slot)
        device.requestTimeout = 1.0
        device.retries = quiet ? 0 : 2
        context.router.register(device)
        if !(await attachSession(device: device, info: context.info, key: k, quiet: quiet)) {
            context.router.unregister(slot)
        }
    }

    @discardableResult
    private func attachSession(device: HIDPPDevice, info: HIDInterfaceInfo, key k: String, quiet: Bool = false) async -> Bool {
        let session = DeviceSession(device: device, info: info, store: store)
        session.onChange = { [weak self] _ in self?.publish() }
        session.onBatteryAlert = { [weak self] snap, alert in self?.onBatteryAlert?(snap, alert) }
        do {
            try await session.start(drive: drive)
            lock.withLock { sessions[k, default: [:]][device.deviceIndex] = session }
            log("attached \(session.snapshot.name) [\(info.transport.isEmpty ? info.product : info.transport), index \(device.deviceIndex)]")
            publish()
            return true
        } catch {
            if !quiet || ProcessInfo.processInfo.environment["FREESPIN_DEBUG"] != nil {
                log("\(info.product) index \(device.deviceIndex): \(error)")
            }
            return false
        }
    }

    private func detach(info: HIDInterfaceInfo) {
        let k = key(info)
        let removed: Bool = lock.withLock {
            let had = sessions.removeValue(forKey: k) != nil
            receivers[k] = nil
            return had
        }
        if removed {
            log("detached \(info.product)")
            publish()
        }
    }

    private func publish() {
        onSessionsChanged?(allSessions)
        onReceiversChanged?(allReceivers)
    }
}

/// Per-receiver state: transport, router, and the Bolt discovery reassembly buffers.
final class ReceiverContext: @unchecked Sendable {
    let receiver: HIDPPReceiver
    let info: HIDInterfaceInfo
    let transport: HIDPPTransport
    let router: ReportRouter
    var attaching: Set<UInt8> = []
    private let lock = NSLock()
    private var names: [UInt16: (Int, [UInt8])] = [:]
    private var discovered: [UInt16: DiscoveredDevice] = [:]

    init(receiver: HIDPPReceiver, info: HIDInterfaceInfo, transport: HIDPPTransport, router: ReportRouter) {
        self.receiver = receiver
        self.info = info
        self.transport = transport
        self.router = router
    }

    func decode(_ raw: [UInt8]) -> ReceiverEvent? {
        lock.withLock { ReceiverEvent.decode(raw, names: &names, pending: &discovered) }
    }

    func snapshot(id: String, slots: [UInt8]) -> ReceiverSnapshot {
        let name = receiver.kind == .bolt ? "Logi Bolt Receiver" : receiver.kind == .unifying ? "Unifying Receiver"
            : (info.product.isEmpty ? "USB Receiver" : info.product)
        return ReceiverSnapshot(id: id, name: name, kind: receiver.kind, connectedSlots: slots)
    }
}

/// Dispatches raw reports from one interface: HID++ 1.0 receiver notifications go to the receiver
/// handler, everything else to the device at the matching index.
final class ReportRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [UInt8: HIDPPDevice] = [:]
    var onReceiverReport: (@Sendable ([UInt8]) -> Void)?

    func register(_ d: HIDPPDevice) { lock.withLock { devices[d.deviceIndex] = d } }
    func unregister(_ index: UInt8) { lock.withLock { devices[index] = nil } }

    func route(_ raw: [UInt8]) {
        guard let msg = HIDPPMessage(raw: raw) else { return }
        if let handler = onReceiverReport, raw.count > 2, ReceiverNotification(rawValue: raw[2]) != nil {
            handler(raw)
            return
        }
        let target = lock.withLock { devices[msg.deviceIndex] }
        target?.handle(msg)
    }
}
