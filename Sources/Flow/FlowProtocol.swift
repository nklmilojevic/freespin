import CoreGraphics
import Foundation

/// Version of the Freespin Flow wire protocol (`_freespin-flow._tcp`).
public enum FlowProtocol {
    public static let version = 1
    public static let serviceType = "_freespin-flow._tcp"
    /// Upper bound for one frame; clipboard payloads are capped well below this.
    public static let maxFrame = 64 << 20
}

public enum FlowEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    public var opposite: FlowEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// Unit step pointing out of the screen through this edge (CG coordinates, y grows downward).
    public var outward: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .top: CGVector(dx: 0, dy: -1)
        case .bottom: CGVector(dx: 0, dy: 1)
        }
    }
}

/// A Logitech device as one computer sees it: which Easy-Switch channel it uses for that computer.
public struct FlowDeviceRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case mouse, keyboard }

    /// HID++ 0x0003 unit ID (hex): identical on every host the device is paired with.
    public var unitID: String
    public var name: String
    public var kind: Kind
    /// Zero-based host channel of the computer that published this record.
    public var channel: Int
    public var channelCount: Int

    public var id: String { unitID }

    public init(unitID: String, name: String, kind: Kind, channel: Int, channelCount: Int) {
        self.unitID = unitID
        self.name = name
        self.kind = kind
        self.channel = channel
        self.channelCount = channelCount
    }
}

public struct ClipboardItem: Codable, Sendable, Equatable {
    /// Pasteboard type (UTI), e.g. `public.utf8-plain-text`.
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Application messages exchanged once the secure channel is up.
public enum FlowMessage: Codable, Sendable, Equatable {
    /// The sender's Flow-capable devices and its channel on each.
    case inventory([FlowDeviceRecord])
    /// The sender's user started pairing; both sides now show the confirmation code.
    case pairRequest(name: String)
    /// The sender's user confirmed that the codes match.
    case pairConfirm
    case pairCancel
    /// The receiver should no longer trust the sender.
    case unpair
    /// The cursor is about to arrive through `edge` of the receiver's screens at `fraction` (0...1) along it.
    case incoming(id: UInt32, edge: FlowEdge, fraction: Double)
    /// The receiver placed its cursor; the sender may switch the devices now.
    case ready(id: UInt32)
    case clipboard([ClipboardItem])
    case ping
    case pong

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(Box(message: self))
    }

    public static func decode(_ data: Data) throws -> FlowMessage {
        try PropertyListDecoder().decode(Box.self, from: data).message
    }

    /// Property lists need a container at the top level.
    private struct Box: Codable {
        var message: FlowMessage
    }
}

// MARK: - Framing

public enum FlowError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case badHandshake(String)
    case badSignature
    case decryptFailed
    case outOfOrder
    case notTrusted
    case closed
}

/// Length-prefixed frames: u32 big-endian length, then the payload.
public enum FrameCodec {
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        let n = UInt32(payload.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(payload)
        return out
    }
}

/// Reassembles frames from a byte stream.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    public let limit: Int

    public init(limit: Int = FlowProtocol.maxFrame) {
        self.limit = limit
    }

    /// Appends bytes and returns every complete frame.
    public mutating func feed(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let b = Array(buffer.prefix(4))
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard n <= limit else { throw FlowError.frameTooLarge(n) }
            guard buffer.count >= 4 + n else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(n)))
            buffer = Data(buffer.dropFirst(4 + n))
        }
        return frames
    }
}
