import Foundation

/// HID++ report IDs.
public enum HIDPPReportID: UInt8, Sendable {
    case short = 0x10     // 7 bytes total, 3 parameter bytes
    case long = 0x11      // 20 bytes total, 16 parameter bytes
    case veryLong = 0x12  // 64 bytes total, 60 parameter bytes

    public var totalLength: Int {
        switch self {
        case .short: 7
        case .long: 20
        case .veryLong: 64
        }
    }

    public var parameterLength: Int { totalLength - 4 }
}

/// Device index values. Direct BLE/USB devices answer on 0xFF; receiver slots are 1...6.
public enum HIDPPDeviceIndex {
    public static let direct: UInt8 = 0xFF
    public static let receiver: UInt8 = 0xFF
}

/// One HID++ 2.0 message: `reportID | deviceIndex | featureIndex | function<<4 | softwareID | params…`.
public struct HIDPPMessage: Equatable, Sendable, CustomStringConvertible {
    public var reportID: HIDPPReportID
    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    /// High nibble of byte 3: function index for requests/responses, event index for notifications.
    public var function: UInt8
    /// Low nibble of byte 3. 0 marks a device-initiated notification.
    public var softwareID: UInt8
    public var parameters: [UInt8]

    public init(reportID: HIDPPReportID = .long, deviceIndex: UInt8, featureIndex: UInt8,
                function: UInt8, softwareID: UInt8, parameters: [UInt8] = []) {
        self.reportID = reportID
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function & 0x0F
        self.softwareID = softwareID & 0x0F
        self.parameters = parameters
    }

    /// Error responses use feature index 0xFF (HID++ 2.0) or 0x8F (HID++ 1.0).
    public static let errorFeatureIndex20: UInt8 = 0xFF
    public static let errorSubID10: UInt8 = 0x8F

    public var isNotification: Bool { softwareID == 0 }

    public func encoded() -> [UInt8] {
        var bytes = [reportID.rawValue, deviceIndex, featureIndex, (function << 4) | softwareID]
        let count = reportID.parameterLength
        bytes.append(contentsOf: parameters.prefix(count))
        if bytes.count < reportID.totalLength {
            bytes.append(contentsOf: repeatElement(0, count: reportID.totalLength - bytes.count))
        }
        return bytes
    }

    /// Parses a raw input report (report ID included as the first byte).
    public init?(raw: [UInt8]) {
        guard raw.count >= 4, let id = HIDPPReportID(rawValue: raw[0]) else { return nil }
        reportID = id
        deviceIndex = raw[1]
        featureIndex = raw[2]
        function = raw[3] >> 4
        softwareID = raw[3] & 0x0F
        parameters = Array(raw.dropFirst(4))
    }

    public var description: String {
        let hex = encoded().map { String(format: "%02x", $0) }.joined(separator: " ")
        return "HIDPP[\(hex)]"
    }
}

/// HID++ 2.0 error codes (feature index 0xFF responses).
public enum HIDPP20Error: UInt8, Error, Sendable {
    case noError = 0
    case unknown = 1
    case invalidArgument = 2
    case outOfRange = 3
    case hardwareError = 4
    case logitechInternal = 5
    case invalidFeatureIndex = 6
    case invalidFunctionID = 7
    case busy = 8
    case unsupported = 9
}

public enum HIDPPError: Error, Sendable, CustomStringConvertible {
    case timeout
    case device(HIDPP20Error)
    case device10(UInt8)
    case featureNotSupported(UInt16)
    case shortResponse
    case transport(String)
    case disconnected

    public var description: String {
        switch self {
        case .timeout: "HID++ request timed out"
        case .device(let e): "HID++ 2.0 error \(e)"
        case .device10(let c): String(format: "HID++ 1.0 error 0x%02x", c)
        case .featureNotSupported(let f): String(format: "feature 0x%04x not supported", f)
        case .shortResponse: "HID++ response too short"
        case .transport(let s): "transport: \(s)"
        case .disconnected: "device disconnected"
        }
    }
}

extension Array where Element == UInt8 {
    func u16BE(at i: Int) -> UInt16 {
        guard i + 1 < count else { return 0 }
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func i16BE(at i: Int) -> Int16 { Int16(bitPattern: u16BE(at: i)) }

    func byte(_ i: Int) -> UInt8 { i < count ? self[i] : 0 }
}
