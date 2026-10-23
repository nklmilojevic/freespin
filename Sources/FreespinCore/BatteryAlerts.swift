import Foundation
import HIDPP

/// Decides when to warn about a low battery: once per threshold per discharge cycle.
/// Re-arms after charging starts or the level rises `rearmMargin` above a threshold.
public struct BatteryAlertPolicy: Sendable, Equatable {
    public enum Alert: Sendable, Equatable {
        case low(percent: Int)
        case critical(percent: Int)
    }

    public var lowThreshold = 15
    public var criticalThreshold = 5
    public var rearmMargin = 5
    var lowFired = false
    var criticalFired = false

    public init(lowThreshold: Int = 15, criticalThreshold: Int = 5) {
        self.lowThreshold = lowThreshold
        self.criticalThreshold = criticalThreshold
    }

    public mutating func evaluate(_ b: BatteryState) -> Alert? {
        if b.charging != .discharging {
            lowFired = false
            criticalFired = false
            return nil
        }
        guard let pct = b.percent ?? Self.percent(forLevel: b.level) else { return nil }
        if pct > lowThreshold + rearmMargin { lowFired = false }
        if pct > criticalThreshold + rearmMargin { criticalFired = false }
        if pct <= criticalThreshold, !criticalFired {
            criticalFired = true
            lowFired = true
            return .critical(percent: pct)
        }
        if pct <= lowThreshold, !lowFired {
            lowFired = true
            return .low(percent: pct)
        }
        return nil
    }

    /// Devices without a percentage only report coarse levels.
    static func percent(forLevel level: String) -> Int? {
        switch level {
        case "critical": 5
        case "low": 15
        default: nil
        }
    }
}
