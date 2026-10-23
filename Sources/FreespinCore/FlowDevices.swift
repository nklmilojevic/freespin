import Flow
import Foundation
import HIDPP

/// A HID++ device with ChangeHost (0x1814), as Flow sees it.
public final class HIDPPFlowDevice: FlowLocalDevice, @unchecked Sendable {
    public let record: FlowDeviceRecord
    let device: HIDPPDevice
    /// False in inspect-only mode: switches are logged, never sent.
    let canSwitch: Bool

    init(record: FlowDeviceRecord, device: HIDPPDevice, canSwitch: Bool) {
        self.record = record
        self.device = device
        self.canSwitch = canSwitch
    }

    /// Reads identity, kind and host channel; nil for devices Flow can't switch.
    public static func probe(_ session: DeviceSession, canSwitch: Bool) async -> HIDPPFlowDevice? {
        let snap = session.snapshot
        guard snap.has(.changeHost), snap.has(.firmwareInfo) else { return nil }
        let device = session.device
        guard let identity = try? await device.identity(), let host = try? await device.hostInfo(), host.count > 1 else {
            return nil
        }
        let type = (try? await device.deviceType()) ?? (snap.has(.hiResWheel) ? 3 : 0)
        let kind: FlowDeviceRecord.Kind
        switch type {
        case 0: kind = .keyboard
        case 3, 4, 5: kind = .mouse  // mouse, trackpad, trackball
        default: return nil
        }
        return HIDPPFlowDevice(record: FlowDeviceRecord(unitID: identity.key, name: snap.name, kind: kind,
                                                        channel: host.current, channelCount: host.count),
                               device: device, canSwitch: canSwitch)
    }

    public func isPresent() async -> Bool {
        guard let info = try? await device.hostInfo() else { return false }
        return info.current == record.channel
    }

    public func switchHost(to channel: Int) async throws {
        guard canSwitch else {
            NSLog("Freespin: inspect-only, not switching %@ to channel %d", record.name, channel + 1)
            return
        }
        try await device.switchHost(to: channel)
    }
}

/// Owns the Flow engine for the app and feeds it the HID++ devices `DeviceManager` finds.
public final class FlowCoordinator: @unchecked Sendable {
    public let engine: FlowEngine
    private let lock = NSLock()
    private var probed: [ObjectIdentifier: HIDPPFlowDevice] = [:]
    private var live: Set<ObjectIdentifier> = []
    private var generation = 0
    private let canSwitch: Bool

    public init(engine: FlowEngine, canSwitch: Bool = true) {
        self.engine = engine
        self.canSwitch = canSwitch
    }

    /// Default app setup: keychain identity, `flow.json`, NSEvent pointer and the general pasteboard.
    /// `stateDirectory` (FREESPIN_FLOW_DIR) keeps identity and settings in a folder instead, for test instances.
    public static func standard(canSwitch: Bool, stateDirectory: URL? = nil, name: String? = nil) throws -> FlowCoordinator {
        let identity: FlowIdentity
        let store: FlowSettingsStore
        if let dir = stateDirectory {
            identity = try FileIdentityStore(url: dir.appendingPathComponent("identity.key")).loadOrCreate()
            store = FlowSettingsStore(url: dir.appendingPathComponent("flow.json"))
        } else {
            identity = try KeychainIdentityStore().loadOrCreate()
            store = FlowSettingsStore()
        }
        let name = name ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return FlowCoordinator(engine: FlowEngine(identity: identity, name: name, store: store,
                                                  pointer: SystemPointer(), clipboard: SystemClipboard()),
                               canSwitch: canSwitch)
    }

    /// Call whenever the device list changes.
    public func sessionsChanged(_ sessions: [DeviceSession]) {
        let gen: Int = lock.withLock {
            generation += 1
            live = Set(sessions.map { ObjectIdentifier($0) })
            probed = probed.filter { live.contains($0.key) }
            return generation
        }
        Task {
            for s in sessions where lock.withLock({ probed[ObjectIdentifier(s)] == nil }) {
                guard let d = await HIDPPFlowDevice.probe(s, canSwitch: canSwitch) else { continue }
                // A newer call may have dropped this session (it disconnected) while the probe was out.
                lock.withLock { if live.contains(ObjectIdentifier(s)) { probed[ObjectIdentifier(s)] = d } }
            }
            let list: [FlowLocalDevice]? = lock.withLock { gen == generation ? Array(probed.values) : nil }
            if let list { engine.setDevices(list) }
        }
    }
}
