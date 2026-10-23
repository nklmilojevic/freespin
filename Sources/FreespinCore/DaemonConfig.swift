import EventSynth
import Foundation

/// Declarative configuration for `freespinctl daemon`, read from a JSON file that is never written back.
///
/// Every field is optional: whatever a file leaves out keeps the value the device had when the daemon
/// first saw it. `default` applies to every device, then `devices` entries matching by name
/// ("MX Master 3S"), product ID ("b034") or full device key ("b034-FD094774-ff"), most specific last.
/// Unknown keys are errors, so a typo fails loudly instead of being ignored.
public struct FreespinConfig: Decodable, Sendable, Equatable {
    public var defaults = DeviceConfig()
    public var devices: [String: DeviceConfig] = [:]
    /// Low-battery notifications.
    public var notifications = true

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case defaults = "default", devices, notifications
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try c.decodeIfPresent(DeviceConfig.self, forKey: .defaults) ?? DeviceConfig()
        devices = try c.decodeIfPresent([String: DeviceConfig].self, forKey: .devices) ?? [:]
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
    }

    public static func load(from url: URL) throws -> FreespinConfig {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> FreespinConfig {
        do {
            return try JSONDecoder().decode(FreespinConfig.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError(message: error.configDescription)
        }
    }

    /// `base` with the default block and every matching device entry layered on top.
    public func settings(for device: DeviceSnapshot, base: DeviceSettings) -> DeviceSettings {
        var s = base
        defaults.apply(to: &s)
        for entry in matches(device) { entry.apply(to: &s) }
        return s
    }

    /// Device entries that apply to `device`, least specific first: name, product ID, device key.
    func matches(_ device: DeviceSnapshot) -> [DeviceConfig] {
        let byName = devices.filter { $0.key.caseInsensitiveCompare(device.name) == .orderedSame }
        let byProduct = devices.filter { Self.productID($0.key) == device.productID }
        let byKey = devices.filter { $0.key.caseInsensitiveCompare(device.id) == .orderedSame }
        return [byName, byProduct, byKey].flatMap { $0.values }
    }

    /// "b034" or "0xB034" → 0xB034.
    static func productID(_ key: String) -> Int? {
        let hex = key.lowercased().hasPrefix("0x") ? String(key.dropFirst(2)) : key
        guard hex.count == 4 else { return nil }
        return Int(hex, radix: 16)
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }

    public init(message: String) {
        self.message = message
    }
}

/// One device's settings. Speeds are percentages as the app shows them (50 = default).
public struct DeviceConfig: Decodable, Sendable, Equatable {
    public var scrollSpeed: Int?
    public var smoothScrolling: Bool?
    public var naturalScrolling: Bool?
    public var smartShift: Bool?
    public var smartShiftSensitivity: Int?
    public var smartShiftTorque: Int?
    public var thumbwheelSpeed: Int?
    public var thumbwheelNaturalScrolling: Bool?
    public var dpi: Int?
    /// Button ("middle", "back", "forward", "gesture", "modeShift" or a control ID like "0x00c3") → action.
    public var buttons: [String: ButtonAction]?
    public var gestureStyle: GestureStyle?
    public var fnKeysFirst: Bool?
    public var backlight: Bool?
    /// Bundle identifier → overrides while that app is frontmost.
    public var apps: [String: AppConfig]?

    public enum GestureStyle: String, Decodable, Sendable { case shortcuts, trackpad }

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case scrollSpeed, smoothScrolling, naturalScrolling, smartShift, smartShiftSensitivity, smartShiftTorque
        case thumbwheelSpeed, thumbwheelNaturalScrolling, dpi, buttons, gestureStyle, fnKeysFirst, backlight, apps
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scrollSpeed = try c.decodePercent(.scrollSpeed)
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling)
        naturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .naturalScrolling)
        smartShift = try c.decodeIfPresent(Bool.self, forKey: .smartShift)
        smartShiftSensitivity = try c.decodeInt(.smartShiftSensitivity, in: 1...50)
        smartShiftTorque = try c.decodeInt(.smartShiftTorque, in: 1...100)
        thumbwheelSpeed = try c.decodePercent(.thumbwheelSpeed)
        thumbwheelNaturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .thumbwheelNaturalScrolling)
        dpi = try c.decodeInt(.dpi, in: 1...100_000)
        buttons = try c.decodeButtons(.buttons)
        gestureStyle = try c.decodeIfPresent(GestureStyle.self, forKey: .gestureStyle)
        fnKeysFirst = try c.decodeIfPresent(Bool.self, forKey: .fnKeysFirst)
        backlight = try c.decodeIfPresent(Bool.self, forKey: .backlight)
        apps = try c.decodeIfPresent([String: AppConfig].self, forKey: .apps)
    }

    public func apply(to s: inout DeviceSettings) {
        if let v = scrollSpeed { s.scrollSpeedPercent = v }
        if let v = smoothScrolling { s.smoothScrolling = v }
        if let v = naturalScrolling { s.naturalDirection = v }
        if let v = smartShift { s.smartShiftEnabled = v }
        if let v = smartShiftSensitivity { s.smartShiftSensitivity = v }
        if let v = smartShiftTorque { s.smartShiftTorque = v }
        if let v = thumbwheelSpeed { s.thumbwheelSpeed = Double(v) / 50 - 1 }
        if let v = thumbwheelNaturalScrolling { s.thumbwheelNatural = v }
        if let v = dpi { s.dpi = v }
        for (k, v) in buttons ?? [:] { s.buttons[k] = v }
        if let v = gestureStyle { s.trackpadSwipes = v == .trackpad }
        if let v = fnKeysFirst { s.fnKeysFirst = v }
        if let v = backlight { s.backlightEnabled = v }
        for (bundle, app) in apps ?? [:] { app.apply(to: &s.apps[bundle, default: AppOverride(name: bundle)]) }
    }
}

/// Per-app overrides; same units as `DeviceConfig`.
public struct AppConfig: Decodable, Sendable, Equatable {
    public var scrollSpeed: Int?
    public var smoothScrolling: Bool?
    public var naturalScrolling: Bool?
    public var thumbwheelSpeed: Int?
    public var buttons: [String: ButtonAction]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case scrollSpeed, smoothScrolling, naturalScrolling, thumbwheelSpeed, buttons
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scrollSpeed = try c.decodePercent(.scrollSpeed)
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling)
        naturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .naturalScrolling)
        thumbwheelSpeed = try c.decodePercent(.thumbwheelSpeed)
        buttons = try c.decodeButtons(.buttons)
    }

    /// Layers the fields this entry sets over `o`, so a device entry adds to what `default` set for the app.
    func apply(to o: inout AppOverride) {
        if let v = scrollSpeed { o.scrollSpeed = Double(v) / 50 - 1 }
        if let v = smoothScrolling { o.smoothScrolling = v }
        if let v = naturalScrolling { o.naturalDirection = v }
        if let v = thumbwheelSpeed { o.thumbwheelSpeed = Double(v) / 50 - 1 }
        for (k, v) in buttons ?? [:] { o.buttons[k] = v }
    }
}

/// Config names for buttons and actions.
enum ConfigNames {
    static let buttons: [String: UInt16] = [
        "middle": 0x0052, "back": 0x0053, "forward": 0x0056, "gesture": 0x00C3, "modeShift": 0x00C4,
    ]

    static let actions: [String: ButtonAction] = [
        "default": .native, "back": .back, "forward": .forward, "middleClick": .middleClick,
        "missionControl": .missionControl, "appExpose": .appExpose, "showDesktop": .showDesktop,
        "launchpad": .launchpad, "desktopLeft": .desktopLeft, "desktopRight": .desktopRight,
        "gestures": .gestures, "actionsRing": .actionsRing, "screenshot": .screenshot,
    ]

    /// "gesture" or "0x00c3"/"00c3" → the `DeviceSettings.buttons` key.
    static func buttonKey(_ name: String) -> String? {
        if let cid = buttons[name] { return DeviceSettings.key(cid) }
        guard let cid = FreespinConfig.productID(name) else { return nil }
        return DeviceSettings.key(UInt16(cid))
    }
}

/// Settings for the daemon: the config file layered over what each device was set to when first seen.
/// `update` only changes that in-memory base; nothing is written to disk.
public final class ConfigSettingsStore: DeviceSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var config: FreespinConfig
    private var base: [String: DeviceSettings] = [:]

    public init(config: FreespinConfig) {
        self.config = config
    }

    public var current: FreespinConfig { lock.withLock { config } }

    public func replace(_ config: FreespinConfig) {
        lock.withLock { self.config = config }
    }

    public func hasSettings(for device: DeviceSnapshot) -> Bool {
        lock.withLock { base[device.id] != nil }
    }

    public func settings(for device: DeviceSnapshot) -> DeviceSettings {
        lock.withLock { config.settings(for: device, base: base[device.id] ?? DeviceSettings()) }
    }

    public func update(_ device: DeviceSnapshot, _ body: (inout DeviceSettings) -> Void) {
        lock.withLock {
            var s = base[device.id] ?? DeviceSettings()
            body(&s)
            base[device.id] = s
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension Decoder {
    func rejectUnknownKeys<K: CodingKey & CaseIterable>(_: K.Type) throws {
        let known = Set(K.allCases.map(\.stringValue))
        let c = try container(keyedBy: AnyKey.self)
        guard let bad = c.allKeys.first(where: { !known.contains($0.stringValue) }) else { return }
        let expected = K.allCases.map(\.stringValue).joined(separator: ", ")
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [bad],
                                                debugDescription: "unknown key (expected one of: \(expected))"))
    }
}

private extension KeyedDecodingContainer {
    func decodeInt(_ key: Key, in range: ClosedRange<Int>) throws -> Int? {
        guard let v = try decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard range.contains(v) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "\(v) is outside \(range.lowerBound)...\(range.upperBound)")
        }
        return v
    }

    func decodePercent(_ key: Key) throws -> Int? { try decodeInt(key, in: 0...100) }

    func decodeButtons(_ key: Key) throws -> [String: ButtonAction]? {
        guard let raw = try decodeIfPresent([String: String].self, forKey: key) else { return nil }
        var out: [String: ButtonAction] = [:]
        for (button, action) in raw {
            guard let k = ConfigNames.buttonKey(button) else {
                let names = ConfigNames.buttons.keys.sorted().joined(separator: ", ")
                throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                       debugDescription: "unknown button \"\(button)\" (expected \(names) or a control ID like 0x00c3)")
            }
            guard let a = ConfigNames.actions[action] else {
                let names = ConfigNames.actions.keys.sorted().joined(separator: ", ")
                throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                       debugDescription: "unknown action \"\(action)\" for \(button) (expected one of: \(names))")
            }
            out[k] = a
        }
        return out
    }
}

private extension DecodingError {
    /// "devices.MX Master 3S.scrollSpeed: 120 is outside 0...100".
    var configDescription: String {
        func path(_ c: [CodingKey]) -> String { c.isEmpty ? "config" : c.map(\.stringValue).joined(separator: ".") }
        switch self {
        case let .dataCorrupted(ctx):
            if let underlying = ctx.underlyingError as NSError?, ctx.codingPath.isEmpty {
                return "invalid JSON: \(underlying.userInfo[NSDebugDescriptionErrorKey] ?? underlying.localizedDescription)"
            }
            return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
        case let .typeMismatch(type, ctx):
            return "\(path(ctx.codingPath)): expected \(type)"
        case let .valueNotFound(type, ctx):
            return "\(path(ctx.codingPath)): expected \(type), found null"
        case let .keyNotFound(key, ctx):
            return "\(path(ctx.codingPath + [key])): missing"
        @unknown default:
            return "\(self)"
        }
    }
}
