import CryptoKit
import Foundation
import Security

/// A computer this one trusts.
public struct PairedPeer: Codable, Sendable, Equatable, Identifiable {
    public var hostID: String
    public var name: String
    public var signingKey: Data
    /// Which side of this computer's screens the peer sits on.
    public var side: FlowEdge
    /// Last inventory the peer sent: its channel on each shared device.
    public var devices: [FlowDeviceRecord]

    public var id: String { hostID }

    public init(hostID: String, name: String, signingKey: Data, side: FlowEdge, devices: [FlowDeviceRecord] = []) {
        self.hostID = hostID
        self.name = name
        self.signingKey = signingKey
        self.side = side
        self.devices = devices
    }

    public func channel(for unitID: String) -> Int? { devices.first { $0.unitID == unitID }?.channel }
}

public struct FlowSettings: Codable, Sendable, Equatable {
    public var enabled = false
    /// Only flow while Control is held.
    public var requireControl = false
    /// Ignore the corners of each display (hot corners keep working).
    public var avoidCorners = true
    public var syncClipboard = true
    /// Switch Logitech keyboards together with the mouse.
    public var linkKeyboard = true
    public var peers: [PairedPeer] = []
    /// Devices seen on this computer and this computer's channel on each, kept while they are away.
    public var localDevices: [FlowDeviceRecord] = []

    public init() {}

    public func peer(_ hostID: String) -> PairedPeer? { peers.first { $0.hostID == hostID } }

    public mutating func upsert(peer: PairedPeer) {
        if let i = peers.firstIndex(where: { $0.hostID == peer.hostID }) { peers[i] = peer } else { peers.append(peer) }
    }

    public mutating func upsert(local record: FlowDeviceRecord) {
        if let i = localDevices.firstIndex(where: { $0.unitID == record.unitID }) {
            localDevices[i] = record
        } else {
            localDevices.append(record)
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, requireControl, avoidCorners, syncClipboard, linkKeyboard, peers, localDevices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FlowSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        requireControl = try c.decodeIfPresent(Bool.self, forKey: .requireControl) ?? d.requireControl
        avoidCorners = try c.decodeIfPresent(Bool.self, forKey: .avoidCorners) ?? d.avoidCorners
        syncClipboard = try c.decodeIfPresent(Bool.self, forKey: .syncClipboard) ?? d.syncClipboard
        linkKeyboard = try c.decodeIfPresent(Bool.self, forKey: .linkKeyboard) ?? d.linkKeyboard
        peers = try c.decodeIfPresent([PairedPeer].self, forKey: .peers) ?? []
        localDevices = try c.decodeIfPresent([FlowDeviceRecord].self, forKey: .localDevices) ?? []
    }
}

/// `flow.json` next to Freespin's `settings.json`.
public final class FlowSettingsStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var value: FlowSettings

    public init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freespin", isDirectory: true)
        self.url = url ?? base.appendingPathComponent("flow.json")
        value = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode(FlowSettings.self, from: $0) }
            ?? FlowSettings()
    }

    public var settings: FlowSettings { lock.withLock { value } }

    @discardableResult
    public func update(_ body: (inout FlowSettings) -> Void) -> FlowSettings {
        let snapshot: FlowSettings = lock.withLock {
            body(&value)
            return value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return snapshot
    }
}

public protocol FlowIdentityStore: Sendable {
    func loadOrCreate() throws -> FlowIdentity
}

/// Keeps the private key in the login keychain (generic password, this device only).
public struct KeychainIdentityStore: FlowIdentityStore {
    public var service = "dev.nkl.freespin.flow"
    public var account = "identity"

    public init() {}

    public func loadOrCreate() throws -> FlowIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return FlowIdentity(signingKey: try .init(rawRepresentation: data))
        }
        let identity = FlowIdentity()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecValueData as String: identity.signingKey.rawRepresentation]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return identity
    }
}

/// Private key in a 0600 file; for the headless simulator and tests, where no unlocked keychain exists.
public struct FileIdentityStore: FlowIdentityStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadOrCreate() throws -> FlowIdentity {
        if let data = try? Data(contentsOf: url) { return FlowIdentity(signingKey: try .init(rawRepresentation: data)) }
        let identity = FlowIdentity()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An identity that isn't saved would come back as a different computer on the next launch.
        guard FileManager.default.createFile(atPath: url.path, contents: identity.signingKey.rawRepresentation,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return identity
    }
}
