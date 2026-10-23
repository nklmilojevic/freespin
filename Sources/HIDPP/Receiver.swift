import Foundation

/// HID++ 1.0 receiver protocol (Unifying and Bolt). Command layouts are taken from the Options+ agent's
/// `devio::HPP10Command` (open_lock @0x1001e9d50, close_lock @0x1001ea280, unpair @0x1001ea770,
/// ble_pro_perform_discovery @0x1001eac34, ble_pro_pair @0x1001eaec0, ble_pro_cancel_pairing @0x1001eb968,
/// ble_pro_unpair @0x1001ebbe8, set_receiver_connection_state @0x1001e5f08) and the notification dispatch in
/// `devio::UnifyingBus::onRead` @0x10029c268.
public enum ReceiverKind: String, Sendable, Codable {
    case unifying, bolt, lightspeed, unknown

    /// Classifies by product ID (public Logitech receiver PIDs).
    public init(productID: Int) {
        switch productID {
        case 0xC548: self = .bolt
        case 0xC52B, 0xC532, 0xC534: self = .unifying
        case 0xC539, 0xC53A, 0xC53F, 0xC545, 0xC547, 0xC54D: self = .lightspeed
        default: self = .unknown
        }
    }

    public var supportsPairing: Bool { self == .unifying || self == .bolt }
}

public enum ReceiverRegister {
    public static let notifications: UInt8 = 0x00
    public static let connectionState: UInt8 = 0x02
    public static let unifyingPairing: UInt8 = 0xB2
    public static let pairingInfo: UInt8 = 0xB5
    public static let boltDiscovery: UInt8 = 0xC0
    public static let boltPairing: UInt8 = 0xC1
    public static let boltPairingInfo: UInt8 = 0xB5
}

/// HID++ 1.0 notification sub IDs a receiver sends (byte 2 of the report).
public enum ReceiverNotification: UInt8, Sendable {
    case deviceDisconnection = 0x40
    case deviceConnection = 0x41
    case lockStatus = 0x4A
    case passkeyRequest = 0x4D
    case passkeyPressed = 0x4E
    case discoveredDevice = 0x4F
    case discoveryStatus = 0x53
    case pairingStatus = 0x54
}

/// A Bolt device seen during discovery (0x4F part 0 + name parts).
public struct DiscoveredDevice: Sendable, Equatable, Identifiable {
    /// Discovery counter that ties the info part to its name parts.
    public var counter: UInt16
    public var kind: UInt8
    public var productID: UInt16
    /// Six address bytes exactly as reported; passed back verbatim when pairing.
    public var address: [UInt8]
    public var authentication: UInt8
    public var name: String

    public init(counter: UInt16, kind: UInt8, productID: UInt16, address: [UInt8], authentication: UInt8, name: String) {
        self.counter = counter
        self.kind = kind
        self.productID = productID
        self.address = address
        self.authentication = authentication
        self.name = name
    }

    public var id: String { address.map { String(format: "%02x", $0) }.joined(separator: ":") }

    public var kindName: String {
        switch kind {
        case 1: "Keyboard"
        case 2: "Mouse"
        case 3: "Numpad"
        case 4: "Presenter"
        case 8: "Trackball"
        case 9: "Touchpad"
        default: "Device"
        }
    }

    public var isKeyboardLike: Bool { kind == 1 || kind == 3 }

    /// Authentication Options+ requests for this device (`devio_helper::from_authentication_method`):
    /// bit 0 → passkey, bit 1 → two buttons, otherwise none.
    public var pairingMethod: BoltAuthentication {
        if authentication & 0x01 != 0 { return .passkey }
        if authentication & 0x02 != 0 { return .twoButtons }
        return .none
    }
}

/// Bolt pairing authentication and the entropy Options+ pairs with
/// (`device_base::on_pair_device` @0x1007f4bd0: none → 0, passkey → 20, two buttons → 10).
public enum BoltAuthentication: UInt8, Sendable {
    case none = 0, passkey = 1, twoButtons = 2

    public var entropy: UInt8 {
        switch self {
        case .none: 0
        case .passkey: 20
        case .twoButtons: 10
        }
    }
}

public enum ReceiverEvent: Sendable, Equatable {
    /// 0x41: a paired device is reachable (`linked`) or went to sleep.
    case connection(slot: UInt8, linked: Bool, kind: UInt8, wirelessPID: UInt16, protocolID: UInt8)
    /// 0x40: a device was unpaired.
    case disconnection(slot: UInt8)
    /// 0x4A: Unifying pairing lock opened/closed; `error` is non-zero when pairing failed.
    case lock(open: Bool, error: UInt8)
    case discovered(DiscoveredDevice)
    /// 0x53: byte 3 is 0 while discovery runs; byte 4 carries an error code.
    case discoveryStatus(active: Bool, error: UInt8)
    /// 0x4D: Bolt passkey to enter on the new device.
    case passkey(String)
    /// 0x4E: progress while the user types the passkey.
    case passkeyPressed(UInt8)
    /// 0x54: Bolt pairing state; `error` non-zero on failure, `done` when finished.
    case pairingStatus(phase: UInt8, error: UInt8)

    /// Decodes a raw report addressed to the receiver or one of its slots.
    public static func decode(_ r: [UInt8], names: inout [UInt16: (Int, [UInt8])], pending: inout [UInt16: DiscoveredDevice]) -> ReceiverEvent? {
        guard r.count >= 7, let sub = ReceiverNotification(rawValue: r[2]) else { return nil }
        func b(_ i: Int) -> UInt8 { i < r.count ? r[i] : 0 }
        switch sub {
        case .deviceConnection:
            // byte3 protocol, byte4 flags (bit6 = link NOT established, low nibble = kind), bytes 5-6 wireless PID (LE)
            return .connection(slot: r[1], linked: b(4) & 0x40 == 0, kind: b(4) & 0x0F,
                               wirelessPID: UInt16(b(6)) << 8 | UInt16(b(5)), protocolID: b(3))
        case .deviceDisconnection:
            return .disconnection(slot: r[1])
        case .lockStatus:
            return .lock(open: b(3) & 0x01 != 0, error: b(4))
        case .discoveryStatus:
            return .discoveryStatus(active: b(3) == 0x00, error: b(4))
        case .passkeyRequest:
            let digits = r[4..<min(10, r.count)].prefix { $0 >= 0x30 && $0 <= 0x39 }
            return .passkey(String(decoding: digits, as: UTF8.self))
        case .passkeyPressed:
            return .passkeyPressed(b(3))
        case .pairingStatus:
            return .pairingStatus(phase: b(3), error: b(4))
        case .discoveredDevice:
            // @0x10029cb08: bytes 3-4 counter (LE), byte 5 part: 0 = info, 1...3 = name chunks.
            guard r.count >= 0x13 || b(5) != 0 else { return nil }
            let counter = UInt16(b(4)) << 8 | UInt16(b(3))
            if b(5) == 0 {
                var d = DiscoveredDevice(counter: counter, kind: b(7) & 0x0F, productID: UInt16(b(9)) << 8 | UInt16(b(8)),
                                         address: Array(r[10..<16]), authentication: b(18), name: "")
                if let (_, chunk) = names[counter] { d.name = String(decoding: chunk, as: UTF8.self) }
                pending[counter] = d
                return .discovered(d)
            }
            let length = Int(b(6))
            let chunk = Array(r[7..<min(r.count, 7 + max(0, min(length, r.count - 7)))])
            var acc = names[counter] ?? (length, [])
            acc.1 += chunk
            names[counter] = acc
            guard var d = pending[counter] else { return nil }
            d.name = String(decoding: acc.1, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            pending[counter] = d
            return .discovered(d)
        }
    }
}

/// The receiver itself (device index 0xFF on its HID++ interface).
public final class HIDPPReceiver: @unchecked Sendable {
    public let device: HIDPPDevice
    public let kind: ReceiverKind

    public init(device: HIDPPDevice, kind: ReceiverKind) {
        self.device = device
        self.kind = kind
    }

    /// Enables wireless + software-present notifications (register 0x00, flags 0x000900).
    public func enableNotifications() async throws {
        _ = try await device.register(.setShort, ReceiverRegister.notifications, [0x00, 0x09, 0x00])
    }

    /// Asks the receiver to re-announce every paired device with 0x41 notifications.
    public func refreshConnections() async throws {
        _ = try await device.register(.setShort, ReceiverRegister.connectionState, [0x02, 0x00, 0x00])
    }

    // MARK: Unifying

    /// Opens the pairing lock; the user then switches the new device off and on. `timeout` 0 = receiver default (30 s).
    public func openLock(timeout: UInt8 = 0) async throws {
        _ = try await device.register(.setShort, ReceiverRegister.unifyingPairing, [0x01, 0x00, timeout])
    }

    public func closeLock() async throws {
        _ = try await device.register(.setShort, ReceiverRegister.unifyingPairing, [0x02, 0x00, 0x00])
    }

    // MARK: Bolt

    public func startDiscovery(timeout: UInt8 = 30) async throws {
        _ = try await device.register(.setShort, ReceiverRegister.boltDiscovery, [timeout, 0x01, 0x00])
    }

    public func cancelDiscovery() async throws {
        _ = try await device.register(.setShort, ReceiverRegister.boltDiscovery, [0x00, 0x02, 0x00])
    }

    /// Pairs a discovered Bolt device (long register 0xC1: action 1, slot 0, address, authentication, entropy).
    public func pair(_ d: DiscoveredDevice) async throws {
        let method = d.pairingMethod
        var params: [UInt8] = [0x01, 0x00]
        params += d.address
        params += [method.rawValue, method.entropy]
        _ = try await device.register(.setLong, ReceiverRegister.boltPairing, params)
    }

    public func cancelPairing() async throws {
        _ = try await device.register(.setLong, ReceiverRegister.boltPairing, [0x02])
    }

    // MARK: Both

    public func unpair(slot: UInt8) async throws {
        switch kind {
        case .bolt:
            _ = try await device.register(.setLong, ReceiverRegister.boltPairing, [0x03, slot])
        default:
            _ = try await device.register(.setShort, ReceiverRegister.unifyingPairing, [0x03, slot, 0x00])
        }
    }
}

/// How the user authenticates a Bolt pairing: keyboards type the digits; mice click the passkey's binary
/// digits (most significant first, `entropy` bits; 1 = right, 0 = left), then press both buttons.
/// Mirrors `logi::devices::passkey_helper` (to_bits = strtol(passkey) & 0xFFFFF, start() = width-1, MSB first).
public enum PasskeyEntry: Sendable, Equatable {
    case typeDigits(String)
    case clickPattern([Bool])   // true = right button, false = left button; then press both together

    public init(passkey: String, method: BoltAuthentication) {
        self.init(passkey: passkey, keyboardLike: method == .passkey, entropy: Int(method.entropy))
    }

    public init(passkey: String, keyboardLike: Bool, entropy: Int = 20) {
        if keyboardLike {
            self = .typeDigits(passkey)
        } else {
            let value = (Int(passkey) ?? 0) & 0xFFFFF
            let width = min(max(entropy, 1), 20)
            self = .clickPattern((0..<width).reversed().map { (value >> $0) & 1 == 1 })
        }
    }
}

/// Codes of the 0x4E "passkey pressed" notification (devio PassKeyCode; protobuf START...END = code + 1).
public enum PasskeyProgress: UInt8, Sendable {
    case start = 0, digitIn = 1, digitOut = 2, clear = 3, end = 4
}
