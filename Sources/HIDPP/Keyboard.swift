import Foundation

// Keyboard features (public HID++ 2.0 layouts; the Options+ agent implements the same feature IDs:
// devio::Feature40A0FnInversion / 40A2 / 40A3, 1982Backlight, 1983KeyboardBacklight).

extension FeatureID {
    public static let fnInversionWithDefault = 0x40A2 as UInt16
    public static let fnInversionMultiHost = 0x40A3 as UInt16
    public static let backlight2 = 0x1982 as UInt16
}

public struct FnInversionState: Sendable, Equatable {
    /// true: the top row sends F1–F12 by default (Fn needed for media keys).
    public var fnKeysFirst: Bool
    public var defaultFnKeysFirst: Bool?
}

extension HIDPPDevice {
    /// Reads Fn inversion from whichever variant the keyboard supports (0x40A3, 0x40A2, 0x40A0).
    public func fnInversion() async throws -> FnInversionState {
        if let idx = try? await featureIndex(for: FeatureID.fnInversionMultiHost) {
            // fn0 GetGlobalFnInversion(hostIndex 0xFF = current) → [host, state bits, default bits]
            let r = try await request(featureIndex: idx, function: 0, parameters: [0xFF])
            return FnInversionState(fnKeysFirst: r.byte(1) & 1 == 1, defaultFnKeysFirst: r.byte(2) & 1 == 1)
        }
        if let idx = try? await featureIndex(for: FeatureID.fnInversionWithDefault) {
            let r = try await request(featureIndex: idx, function: 0)
            return FnInversionState(fnKeysFirst: r.byte(0) & 1 == 1, defaultFnKeysFirst: r.byte(1) & 1 == 1)
        }
        let r = try await request(feature: FeatureID.fnInversion.rawValue, function: 0)
        return FnInversionState(fnKeysFirst: r.byte(0) & 1 == 1, defaultFnKeysFirst: nil)
    }

    public func setFnInversion(fnKeysFirst: Bool) async throws {
        let v: UInt8 = fnKeysFirst ? 1 : 0
        if let idx = try? await featureIndex(for: FeatureID.fnInversionMultiHost) {
            _ = try await request(featureIndex: idx, function: 1, parameters: [0xFF, v])
            return
        }
        if let idx = try? await featureIndex(for: FeatureID.fnInversionWithDefault) {
            _ = try await request(featureIndex: idx, function: 1, parameters: [v])
            return
        }
        _ = try await request(feature: FeatureID.fnInversion.rawValue, function: 1, parameters: [v])
    }

    public var supportsFnInversion: Bool {
        get async {
            for id in [FeatureID.fnInversionMultiHost, FeatureID.fnInversionWithDefault, FeatureID.fnInversion.rawValue]
            where await hasFeature(id) { return true }
            return false
        }
    }
}

public struct BacklightState: Sendable, Equatable {
    public var enabled: Bool
    /// Current level (0...levels-1) when the device reports discrete levels.
    public var level: Int
    public var levels: Int
}

extension HIDPPDevice {
    /// 0x1982 Backlight: fn0 GetBacklightConfig → [enabled, options, supported options, ...],
    /// fn2 GetBacklightInfo → [levels count, current level, ...].
    public func backlight() async throws -> BacklightState {
        let idx = try await featureIndex(for: FeatureID.backlight2)
        let cfg = try await request(featureIndex: idx, function: 0)
        let info = try? await request(featureIndex: idx, function: 2)
        return BacklightState(enabled: cfg.byte(0) & 1 == 1, level: Int(info?.byte(1) ?? 0),
                              levels: Int(info?.byte(0) ?? 0))
    }

    /// fn1 SetBacklightConfig(enabled, options) keeping the device's other option bits.
    public func setBacklight(enabled: Bool) async throws {
        let idx = try await featureIndex(for: FeatureID.backlight2)
        let cfg = try await request(featureIndex: idx, function: 0)
        _ = try await request(featureIndex: idx, function: 1, parameters: [enabled ? 1 : 0, cfg.byte(1), cfg.byte(2)])
    }
}
