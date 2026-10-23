import Foundation

/// HID++ 2.0 feature IDs used by the app (subset of the ~140 the Options+ agent implements).
public enum FeatureID: UInt16, CaseIterable, Sendable {
    case root = 0x0000
    case featureSet = 0x0001
    case firmwareInfo = 0x0003
    case deviceNameType = 0x0005
    case batteryStatus = 0x1000
    case unifiedBattery = 0x1004
    case changeHost = 0x1814
    case hostsInfo = 0x1815
    case specialKeys = 0x1B04
    case smartShift = 0x2110
    case smartShiftTunableTorque = 0x2111
    case hiResWheel = 0x2121
    case thumbwheel = 0x2150
    case adjustableDPI = 0x2201
    case extendedAdjustableDPI = 0x2202
    case fnInversion = 0x40A0
    case multiPlatform = 0x4531
    case reportRate = 0x8060
}

public struct FeatureInfo: Sendable, Hashable {
    public var index: UInt8
    public var id: UInt16
    public var type: UInt8
    public var version: UInt8

    public var known: FeatureID? { FeatureID(rawValue: id) }
}

// MARK: - Root / FeatureSet / Name

extension HIDPPDevice {
    /// Root.GetProtocolVersion (fn 1). Returns (major, minor). Also serves as a ping.
    public func protocolVersion() async throws -> (major: UInt8, minor: UInt8) {
        let ping: UInt8 = 0x5A
        let r = try await request(featureIndex: 0, function: 1, parameters: [0, 0, ping])
        return (r.byte(0), r.byte(1))
    }

    /// Enumerates every feature through FeatureSet (0x0001).
    public func allFeatures() async throws -> [FeatureInfo] {
        let fs = try await featureIndex(for: FeatureID.featureSet.rawValue)
        let count = Int(try await request(featureIndex: fs, function: 0).byte(0))
        var result = [FeatureInfo(index: 0, id: 0x0000, type: 0, version: 0)]
        for i in 1...max(count, 1) {
            let r = try await request(featureIndex: fs, function: 1, parameters: [UInt8(i)])
            result.append(FeatureInfo(index: UInt8(i), id: r.u16BE(at: 0), type: r.byte(2), version: r.byte(3)))
        }
        return result
    }

    /// DeviceNameType (0x0005): marketing name.
    public func deviceName() async throws -> String {
        let idx = try await featureIndex(for: FeatureID.deviceNameType.rawValue)
        let length = Int(try await request(featureIndex: idx, function: 0).byte(0))
        var bytes: [UInt8] = []
        while bytes.count < length {
            let chunk = try await request(featureIndex: idx, function: 1, parameters: [UInt8(bytes.count)])
            let take = min(length - bytes.count, chunk.count)
            if take <= 0 { break }
            bytes.append(contentsOf: chunk.prefix(take))
        }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// DeviceNameType (0x0005) fn 2: device type (0 keyboard, 1 remote, 2 numpad, 3 mouse, 4 trackpad, ...).
    public func deviceType() async throws -> UInt8 {
        try await request(feature: FeatureID.deviceNameType.rawValue, function: 2).byte(0)
    }
}

// MARK: - Battery

public struct BatteryState: Sendable, Equatable {
    public enum Charging: UInt8, Sendable { case discharging = 0, charging = 1, chargingSlow = 2, full = 3, error = 4 }
    public var percent: Int?
    public var level: String
    public var charging: Charging

    public init(percent: Int?, level: String, charging: Charging) {
        self.percent = percent
        self.level = level
        self.charging = charging
    }
}

extension HIDPPDevice {
    /// UnifiedBattery (0x1004) GetStatus, falling back to BatteryStatus (0x1000).
    public func battery() async throws -> BatteryState {
        if let idx = try? await featureIndex(for: FeatureID.unifiedBattery.rawValue) {
            return Self.decodeBattery1004(try await request(featureIndex: idx, function: 1))
        }
        let r = try await request(feature: FeatureID.batteryStatus.rawValue, function: 0)
        return Self.decodeBattery1000(r)
    }

    static func decodeBattery1004(_ r: [UInt8]) -> BatteryState {
        let levelBits = r.byte(1)
        let level = levelBits & 8 != 0 ? "full" : levelBits & 4 != 0 ? "good" : levelBits & 2 != 0 ? "low" : levelBits & 1 != 0 ? "critical" : "unknown"
        let soc = Int(r.byte(0))
        return BatteryState(percent: soc == 0 ? nil : soc, level: level,
                            charging: BatteryState.Charging(rawValue: r.byte(2)) ?? .error)
    }

    static func decodeBattery1000(_ r: [UInt8]) -> BatteryState {
        let status = r.byte(2)
        let charging: BatteryState.Charging = status == 0 ? .discharging : (status == 3 ? .full : .charging)
        return BatteryState(percent: Int(r.byte(0)), level: "", charging: charging)
    }
}

extension HIDPPDevice {
    /// Battery broadcasts: 0x1004 event 0 (same layout as GetStatus) or 0x1000 event 0.
    @discardableResult
    public func onBatteryEvent(_ handler: @escaping @Sendable (BatteryState) -> Void) async throws -> UUID {
        if let idx = try? await featureIndex(for: FeatureID.unifiedBattery.rawValue) {
            return onNotification(featureIndex: idx) { msg in
                if msg.function == 0 { handler(Self.decodeBattery1004(msg.parameters)) }
            }
        }
        let idx = try await featureIndex(for: FeatureID.batteryStatus.rawValue)
        return onNotification(featureIndex: idx) { msg in
            if msg.function == 0 { handler(Self.decodeBattery1000(msg.parameters)) }
        }
    }
}

// MARK: - HiResWheel 0x2121 (byte layouts verified in the Options+ agent, notes/03 §11.1, §13)

public struct WheelCapability: Sendable, Equatable {
    /// Hi-res counts per ratchet notch when high-resolution reporting is on.
    public var multiplier: UInt8
    public var hasInvert: Bool
    public var hasRatchetSwitch: Bool
    public var ratchetsPerRotation: UInt8
    public var wheelDiameter: UInt8
    public var rawFlags: UInt8
}

public struct WheelMode: Sendable, Equatable {
    /// Wheel reports go to HID++ notifications instead of native HID scroll.
    public var diverted: Bool
    public var highResolution: Bool
    public var inverted: Bool
    public var analytics: Bool = false
    public var priority: UInt8 = 0
    public var rate: UInt8 = 0

    public init(diverted: Bool, highResolution: Bool, inverted: Bool, analytics: Bool = false,
                priority: UInt8 = 0, rate: UInt8 = 0) {
        self.diverted = diverted
        self.highResolution = highResolution
        self.inverted = inverted
        self.analytics = analytics
        self.priority = priority
        self.rate = rate
    }

    var byte0: UInt8 {
        (diverted ? 0x01 : 0) | (highResolution ? 0x02 : 0) | (inverted ? 0x04 : 0) | (analytics ? 0x08 : 0)
    }

    init(bytes: [UInt8]) {
        let b = bytes.byte(0)
        diverted = b & 0x01 != 0
        highResolution = b & 0x02 != 0
        inverted = b & 0x04 != 0
        analytics = b & 0x08 != 0
        priority = bytes.byte(1)
        rate = bytes.byte(2)
    }
}

/// Decoded 0x2121 notifications (`devio::Feature2121HiResWheel::onFeatureReport` @0x1003d4cf8).
public enum WheelEvent: Sendable, Equatable {
    case movement(highResolution: Bool, periods: Int, deltaV: Int, deltaH: Int)
    case ratchetSwitch(ratchet: Bool)

    public init?(eventIndex: UInt8, parameters p: [UInt8]) {
        switch eventIndex {
        case 0:
            guard p.count >= 5 else { return nil }
            self = .movement(highResolution: (p[0] >> 4) & 1 == 1, periods: Int(p[0] & 0x0F),
                             deltaV: Int(p.i16BE(at: 1)), deltaH: Int(p.i16BE(at: 3)))
        case 1:
            guard !p.isEmpty else { return nil }
            self = .ratchetSwitch(ratchet: p[0] & 1 == 1)
        default:
            return nil
        }
    }
}

extension HIDPPDevice {
    public func wheelCapability() async throws -> WheelCapability {
        let r = try await request(feature: FeatureID.hiResWheel.rawValue, function: 0)
        let flags = r.byte(1)
        return WheelCapability(multiplier: max(r.byte(0), 1), hasInvert: flags & 0x08 != 0,
                               hasRatchetSwitch: flags & 0x04 != 0, ratchetsPerRotation: r.byte(2),
                               wheelDiameter: r.byte(3), rawFlags: flags)
    }

    public func wheelMode() async throws -> WheelMode {
        WheelMode(bytes: try await request(feature: FeatureID.hiResWheel.rawValue, function: 1))
    }

    @discardableResult
    public func setWheelMode(_ mode: WheelMode) async throws -> WheelMode {
        let r = try await request(feature: FeatureID.hiResWheel.rawValue, function: 2,
                                  parameters: [mode.byte0, mode.priority, mode.rate])
        return WheelMode(bytes: r)
    }

    /// 0x2121 fn 3: GetRatchetSwitchState → true when ratchet (clicky) mode is engaged.
    public func ratchetSwitchState() async throws -> Bool {
        try await request(feature: FeatureID.hiResWheel.rawValue, function: 3).byte(0) & 1 == 1
    }

    /// Subscribes to decoded wheel events. Requires the feature index to be resolved first.
    @discardableResult
    public func onWheelEvent(_ handler: @escaping @Sendable (WheelEvent) -> Void) async throws -> UUID {
        let idx = try await featureIndex(for: FeatureID.hiResWheel.rawValue)
        return onNotification(featureIndex: idx) { msg in
            if let ev = WheelEvent(eventIndex: msg.function, parameters: msg.parameters) { handler(ev) }
        }
    }
}

// MARK: - SmartShift 0x2110 / 0x2111

public struct SmartShiftState: Sendable, Equatable {
    public enum Mode: UInt8, Sendable { case unchanged = 0, freespin = 1, ratchet = 2 }
    public var mode: Mode
    /// Auto-disengage threshold (1...254, 255 = always ratchet). Options+ calls this "sensitivity".
    public var autoDisengage: UInt8
    /// Tunable torque (0x2111 only), 1...100 percent.
    public var torque: UInt8?

    public init(mode: Mode, autoDisengage: UInt8, torque: UInt8? = nil) {
        self.mode = mode
        self.autoDisengage = autoDisengage
        self.torque = torque
    }
}

extension HIDPPDevice {
    public func smartShift() async throws -> SmartShiftState {
        if let idx = try? await featureIndex(for: FeatureID.smartShiftTunableTorque.rawValue) {
            let r = try await request(featureIndex: idx, function: 1)
            return SmartShiftState(mode: .init(rawValue: r.byte(0)) ?? .unchanged, autoDisengage: r.byte(1), torque: r.byte(2))
        }
        let r = try await request(feature: FeatureID.smartShift.rawValue, function: 0)
        return SmartShiftState(mode: .init(rawValue: r.byte(0)) ?? .unchanged, autoDisengage: r.byte(1))
    }

    public func setSmartShift(_ s: SmartShiftState) async throws {
        if let idx = try? await featureIndex(for: FeatureID.smartShiftTunableTorque.rawValue) {
            _ = try await request(featureIndex: idx, function: 2, parameters: [s.mode.rawValue, s.autoDisengage, s.torque ?? 0])
            return
        }
        _ = try await request(feature: FeatureID.smartShift.rawValue, function: 1, parameters: [s.mode.rawValue, s.autoDisengage, 0])
    }
}

// MARK: - Thumbwheel 0x2150

public struct ThumbwheelEvent: Sendable, Equatable {
    public enum Status: UInt8, Sendable { case inactive = 0, start = 1, active = 2, stop = 3 }
    public var rotation: Int
    public var timestamp: UInt16
    public var status: Status
    public var touch: Bool
    public var proximity: Bool
    public var singleTap: Bool

    /// Layout from `devio::Feature2150Thumbwheel::onFeatureReport` (0x1003e10e0): rotation i16 BE, timestamp u16 BE,
    /// rotation status byte, flags byte (bit1 touch, bit2 proximity, bit3 single tap).
    public init?(parameters p: [UInt8]) {
        guard p.count >= 6 else { return nil }
        rotation = Int(p.i16BE(at: 0))
        timestamp = p.u16BE(at: 2)
        status = Status(rawValue: p[4] & 0x03) ?? .inactive
        touch = p[5] & 0x02 != 0
        proximity = p[5] & 0x04 != 0
        singleTap = p[5] & 0x08 != 0
    }
}

public struct ThumbwheelInfo: Sendable, Equatable {
    public var nativeResolution: Int
    public var divertedResolution: Int
    /// Default direction bit: 1 = positive rotation is "up/left" (inverted relative to the scroll axis).
    public var defaultDirection: UInt8
    public var capabilities: UInt8
    public var timeUnit: Int

    /// Diverted counts per native step — used as the wheel multiplier for the horizontal engine.
    public var multiplier: Int { max(1, nativeResolution > 0 ? divertedResolution / nativeResolution : 1) }
}

extension HIDPPDevice {
    /// 0x2150 fn 0 GetThumbwheelInfo.
    public func thumbwheelInfo() async throws -> ThumbwheelInfo {
        let r = try await request(feature: FeatureID.thumbwheel.rawValue, function: 0)
        return ThumbwheelInfo(nativeResolution: Int(r.u16BE(at: 0)), divertedResolution: Int(r.u16BE(at: 2)),
                              defaultDirection: r.byte(4), capabilities: r.byte(5), timeUnit: Int(r.u16BE(at: 6)))
    }

    /// 0x2150 fn 2 SetThumbwheelReporting(divert, invert).
    public func setThumbwheelReporting(diverted: Bool, inverted: Bool) async throws {
        _ = try await request(feature: FeatureID.thumbwheel.rawValue, function: 2,
                              parameters: [diverted ? 1 : 0, inverted ? 1 : 0])
    }

    @discardableResult
    public func onThumbwheelEvent(_ handler: @escaping @Sendable (ThumbwheelEvent) -> Void) async throws -> UUID {
        let idx = try await featureIndex(for: FeatureID.thumbwheel.rawValue)
        return onNotification(featureIndex: idx) { msg in
            guard msg.function == 0, let ev = ThumbwheelEvent(parameters: msg.parameters) else { return }
            handler(ev)
        }
    }
}

// MARK: - DPI 0x2201

extension HIDPPDevice {
    public func dpi(sensor: UInt8 = 0) async throws -> Int {
        Int(try await request(feature: FeatureID.adjustableDPI.rawValue, function: 2, parameters: [sensor]).u16BE(at: 1))
    }

    public func setDPI(_ dpi: Int, sensor: UInt8 = 0) async throws {
        _ = try await request(feature: FeatureID.adjustableDPI.rawValue, function: 3,
                              parameters: [sensor, UInt8((dpi >> 8) & 0xFF), UInt8(dpi & 0xFF)])
    }

    /// 0x2201 fn 1 GetSensorDpiList: either explicit values or `[min, step-marker(0xE000|step), max]` triples.
    public func dpiList(sensor: UInt8 = 0) async throws -> [Int] {
        let r = try await request(feature: FeatureID.adjustableDPI.rawValue, function: 1, parameters: [sensor])
        var values: [Int] = []
        var i = 1
        while i + 1 < r.count {
            let v = Int(r.u16BE(at: i))
            if v == 0 { break }
            if v >> 13 == 0b111, let last = values.last, i + 3 < r.count {
                let step = v & 0x1FFF
                let end = Int(r.u16BE(at: i + 2))
                if step > 0 { values.append(contentsOf: stride(from: last + step, through: end, by: step)) }
                i += 4
                continue
            }
            values.append(v)
            i += 2
        }
        return values
    }
}
