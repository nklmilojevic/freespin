import Foundation

/// Easy-Switch state from ChangeHost (0x1814) fn 0 GetHostInfo.
public struct HostInfo: Sendable, Equatable {
    /// Number of host channels (Easy-Switch buttons), usually 3.
    public var count: Int
    /// Zero-based channel this computer is connected on.
    public var current: Int
    /// Bit 0: enhanced host switch (cookies) supported.
    public var flags: UInt8

    public init(count: Int, current: Int, flags: UInt8 = 0) {
        self.count = count
        self.current = current
        self.flags = flags
    }

    static func decode(_ r: [UInt8]) -> HostInfo {
        HostInfo(count: Int(r.byte(0)), current: Int(r.byte(1)), flags: r.byte(2))
    }
}

/// Stable identity of a device from FirmwareInfo (0x0003) fn 0. Unlike the HID serial (on Bluetooth a
/// per-host address), the unit ID is the same on every computer the device is paired with.
public struct DeviceIdentity: Sendable, Equatable, Hashable {
    public var unitID: [UInt8]
    public var modelID: [UInt8]

    public init(unitID: [UInt8], modelID: [UInt8]) {
        self.unitID = unitID
        self.modelID = modelID
    }

    /// Hex unit ID, e.g. "a1b2c3d4".
    public var key: String { unitID.map { String(format: "%02x", $0) }.joined() }

    /// Layout: [entityCount, unitID(4), transport(2), modelID(6), extendedModelID, capabilities].
    static func decode(_ r: [UInt8]) -> DeviceIdentity? {
        guard r.count >= 13 else { return nil }
        let unit = Array(r[1..<5])
        guard unit.contains(where: { $0 != 0 }) else { return nil }
        return DeviceIdentity(unitID: unit, modelID: Array(r[7..<13]))
    }
}

extension HIDPPDevice {
    /// ChangeHost (0x1814) GetHostInfo.
    public func hostInfo() async throws -> HostInfo {
        HostInfo.decode(try await request(feature: FeatureID.changeHost.rawValue, function: 0))
    }

    /// ChangeHost (0x1814) SetCurrentHost. The device drops this link immediately, so no reply is awaited.
    public func switchHost(to channel: Int) async throws {
        let index = try await featureIndex(for: FeatureID.changeHost.rawValue)
        try post(featureIndex: index, function: 1, parameters: [UInt8(truncatingIfNeeded: channel)])
    }

    /// FirmwareInfo (0x0003) fn 0: unit and model IDs.
    public func identity() async throws -> DeviceIdentity? {
        DeviceIdentity.decode(try await request(feature: FeatureID.firmwareInfo.rawValue, function: 0))
    }
}
