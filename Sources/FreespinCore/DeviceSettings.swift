import EventSynth
import Foundation
import ScrollEngine

/// Persisted per-device configuration (the native equivalent of Options+'s mouse cards).
public struct DeviceSettings: Codable, Sendable, Equatable {
    public var scrollSpeed: Double = 0          // [-1, 1]; UI shows (speed+1)*50 %
    public var smoothScrolling = true
    public var naturalDirection = false
    public var smartShiftEnabled = true
    public var smartShiftSensitivity: Int = 10  // auto-disengage threshold 1...50 in the UI
    public var smartShiftTorque: Int = 50       // 0x2111 only, 1...100 %
    public var thumbwheelSpeed: Double = 0
    public var thumbwheelNatural = false
    public var dpi: Int?
    /// Control ID (hex string, e.g. "00c3") → action. Missing entries keep the native function.
    public var buttons: [String: ButtonAction] = [:]
    /// Gesture button style: false = keyboard shortcuts (default), true = trackpad-style dock swipes.
    public var trackpadSwipes = false
    /// Keyboard: top row sends F-keys first (nil = leave the device as is).
    public var fnKeysFirst: Bool?
    public var backlightEnabled: Bool?
    /// Bundle identifier → overrides applied while that app is frontmost (Options+ "app-specific settings").
    public var apps: [String: AppOverride] = [:]

    /// Settings in effect while `bundleID` is frontmost.
    public func effective(for bundleID: String?) -> DeviceSettings {
        guard let bundleID, let o = apps[bundleID] else { return self }
        var s = self
        if let v = o.scrollSpeed { s.scrollSpeed = v }
        if let v = o.smoothScrolling { s.smoothScrolling = v }
        if let v = o.naturalDirection { s.naturalDirection = v }
        if let v = o.thumbwheelSpeed { s.thumbwheelSpeed = v }
        for (k, v) in o.buttons { s.buttons[k] = v }
        return s
    }

    public init() {}

    public static func key(_ cid: UInt16) -> String { String(format: "%04x", cid) }

    public func action(for cid: UInt16) -> ButtonAction { buttons[Self.key(cid)] ?? .native }

    enum CodingKeys: String, CodingKey {
        case scrollSpeed, smoothScrolling, naturalDirection, smartShiftEnabled, smartShiftSensitivity, smartShiftTorque
        case thumbwheelSpeed, thumbwheelNatural, dpi, buttons, apps, fnKeysFirst, backlightEnabled, trackpadSwipes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeviceSettings()
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? d.scrollSpeed
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? d.smoothScrolling
        naturalDirection = try c.decodeIfPresent(Bool.self, forKey: .naturalDirection) ?? d.naturalDirection
        smartShiftEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartShiftEnabled) ?? d.smartShiftEnabled
        smartShiftSensitivity = try c.decodeIfPresent(Int.self, forKey: .smartShiftSensitivity) ?? d.smartShiftSensitivity
        smartShiftTorque = try c.decodeIfPresent(Int.self, forKey: .smartShiftTorque) ?? d.smartShiftTorque
        thumbwheelSpeed = try c.decodeIfPresent(Double.self, forKey: .thumbwheelSpeed) ?? d.thumbwheelSpeed
        thumbwheelNatural = try c.decodeIfPresent(Bool.self, forKey: .thumbwheelNatural) ?? d.thumbwheelNatural
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        buttons = try c.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
        apps = try c.decodeIfPresent([String: AppOverride].self, forKey: .apps) ?? [:]
        fnKeysFirst = try c.decodeIfPresent(Bool.self, forKey: .fnKeysFirst)
        backlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .backlightEnabled)
        trackpadSwipes = try c.decodeIfPresent(Bool.self, forKey: .trackpadSwipes) ?? false
    }

    public var wheelSettings: WheelSettings {
        var s = WheelSettings()
        s.speed = scrollSpeed
        s.smooth = smoothScrolling
        s.natural = naturalDirection
        return s
    }

    /// Options+ UI percentage.
    public var scrollSpeedPercent: Int {
        get { Int(((scrollSpeed + 1) * 50).rounded()) }
        set { scrollSpeed = min(max(Double(newValue) / 50 - 1, -1), 1) }
    }
}

/// Per-application overrides; nil fields inherit the device setting.
public struct AppOverride: Codable, Sendable, Equatable {
    public var name: String
    public var scrollSpeed: Double?
    public var smoothScrolling: Bool?
    public var naturalDirection: Bool?
    public var thumbwheelSpeed: Double?
    public var buttons: [String: ButtonAction] = [:]

    public init(name: String) { self.name = name }
}

/// JSON store in ~/Library/Application Support/Freespin/settings.json keyed by a stable device key.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    private struct File: Codable {
        var version = 1
        var devices: [String: DeviceSettings] = [:]
    }

    private let url: URL
    private let lock = NSLock()
    private var file = File()

    public init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freespin", isDirectory: true)
        self.url = url ?? base.appendingPathComponent("settings.json")
        if url == nil { Self.migrateLegacyStore(to: self.url) }
        if let data = try? Data(contentsOf: self.url), let decoded = try? JSONDecoder().decode(File.self, from: data) {
            file = decoded
        }
    }

    /// Copies settings written by pre-rename builds (~/Library/Application Support/Logi).
    private static func migrateLegacyStore(to target: URL) {
        let fm = FileManager.default
        let legacy = target.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Logi/settings.json")
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: legacy, to: target)
    }

    public func hasSettings(for key: String) -> Bool {
        lock.withLock { file.devices[key] != nil }
    }

    public func settings(for key: String) -> DeviceSettings {
        lock.withLock { file.devices[key] ?? DeviceSettings() }
    }

    public func update(_ key: String, _ body: (inout DeviceSettings) -> Void) {
        let snapshot: File = lock.withLock {
            var s = file.devices[key] ?? DeviceSettings()
            body(&s)
            file.devices[key] = s
            return file
        }
        save(snapshot)
    }

    private func save(_ snapshot: File) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            NSLog("Freespin: failed to save settings: \(error)")
        }
    }
}
