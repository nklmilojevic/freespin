import Foundation

/// One reprogrammable control from 0x1B04 GetCidInfo.
public struct ControlInfo: Sendable, Equatable, Identifiable {
    public var cid: UInt16
    public var taskID: UInt16
    public var flags: UInt8
    public var position: UInt8
    public var group: UInt8
    public var groupMask: UInt8
    public var flags2: UInt8

    public var id: UInt16 { cid }
    public var isMouseButton: Bool { flags & 0x01 != 0 }
    public var reprogrammable: Bool { flags & 0x10 != 0 }
    public var divertable: Bool { flags & 0x20 != 0 }
    public var persistentlyDivertable: Bool { flags & 0x40 != 0 }
    public var virtual: Bool { flags & 0x80 != 0 }
    public var rawXY: Bool { flags2 & 0x01 != 0 }

    /// Friendly names for common MX control IDs (public HID++ CID table).
    public var name: String { Self.names[cid] ?? String(format: "Control 0x%04X", cid) }

    public static let names: [UInt16: String] = [
        0x0050: "Left Click", 0x0051: "Right Click", 0x0052: "Middle Click",
        0x0053: "Back", 0x0056: "Forward", 0x00C3: "Gesture Button", 0x00C4: "Mode Shift (SmartShift)",
        0x00D7: "Virtual Gesture Button", 0x00FD: "DPI Switch", 0x01A0: "Thumb Button",
    ]
}

/// 0x1B04 reporting flags (byte layout matches Options+ `_divert` constants 0x03 / 0x33).
public struct ControlReporting: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let divert = ControlReporting(rawValue: 0x01)
    public static let divertValid = ControlReporting(rawValue: 0x02)
    public static let persist = ControlReporting(rawValue: 0x04)
    public static let persistValid = ControlReporting(rawValue: 0x08)
    public static let rawXY = ControlReporting(rawValue: 0x10)
    public static let rawXYValid = ControlReporting(rawValue: 0x20)
}

public enum SpecialKeysEvent: Sendable, Equatable {
    /// Currently held diverted controls (up to four).
    case pressed([UInt16])
    /// Raw mouse motion while a rawXY-diverted control is held.
    case rawXY(dx: Int, dy: Int)

    public init?(eventIndex: UInt8, parameters p: [UInt8]) {
        switch eventIndex {
        case 0:
            var cids: [UInt16] = []
            var i = 0
            while i + 1 < min(p.count, 8) {
                let c = p.u16BE(at: i)
                if c != 0 { cids.append(c) }
                i += 2
            }
            self = .pressed(cids)
        case 1:
            guard p.count >= 4 else { return nil }
            self = .rawXY(dx: Int(p.i16BE(at: 0)), dy: Int(p.i16BE(at: 2)))
        default:
            return nil
        }
    }
}

extension HIDPPDevice {
    public func controls() async throws -> [ControlInfo] {
        let idx = try await featureIndex(for: FeatureID.specialKeys.rawValue)
        let count = Int(try await request(featureIndex: idx, function: 0).byte(0))
        var result: [ControlInfo] = []
        for i in 0..<count {
            let r = try await request(featureIndex: idx, function: 1, parameters: [UInt8(i)])
            result.append(ControlInfo(cid: r.u16BE(at: 0), taskID: r.u16BE(at: 2), flags: r.byte(4),
                                      position: r.byte(5), group: r.byte(6), groupMask: r.byte(7), flags2: r.byte(8)))
        }
        return result
    }

    /// 0x1B04 fn 3 SetCidReporting. `remap` 0 keeps the native function.
    public func setControlReporting(cid: UInt16, flags: ControlReporting, remap: UInt16 = 0) async throws {
        _ = try await request(feature: FeatureID.specialKeys.rawValue, function: 3,
                              parameters: [UInt8(cid >> 8), UInt8(cid & 0xFF), flags.rawValue,
                                           UInt8(remap >> 8), UInt8(remap & 0xFF)])
    }

    /// Diverts (or restores) one control; `rawXY` also streams pointer motion while it is held.
    public func divertControl(_ cid: UInt16, diverted: Bool, rawXY: Bool = false) async throws {
        var flags: ControlReporting = [.divertValid]
        if diverted { flags.insert(.divert) }
        if rawXY || !diverted {
            flags.insert(.rawXYValid)
            if rawXY && diverted { flags.insert(.rawXY) }
        }
        try await setControlReporting(cid: cid, flags: flags)
    }

    @discardableResult
    public func onSpecialKeysEvent(_ handler: @escaping @Sendable (SpecialKeysEvent) -> Void) async throws -> UUID {
        let idx = try await featureIndex(for: FeatureID.specialKeys.rawValue)
        return onNotification(featureIndex: idx) { msg in
            if let ev = SpecialKeysEvent(eventIndex: msg.function, parameters: msg.parameters) { handler(ev) }
        }
    }
}
