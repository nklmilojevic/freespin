import CryptoKit
import Foundation

/// Long-term identity of one computer: an Ed25519 key. The host ID is derived from the public key, so it
/// can't be claimed by another key.
public struct FlowIdentity: Sendable {
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(signingKey: Curve25519.Signing.PrivateKey = .init()) {
        self.signingKey = signingKey
    }

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
    public var hostID: String { Self.hostID(for: publicKey) }

    public static func hostID(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// First frame each side sends, in the clear.
struct HelloFrame: Codable, Equatable {
    var version: Int
    var name: String
    var signingKey: Data
    var ephemeralKey: Data
}

/// Second frame: signature over the handshake transcript, proving possession of the signing key.
struct AuthFrame: Codable, Equatable {
    var signature: Data
}

/// Who the other side is, as established by the handshake.
public struct FlowPeerIdentity: Sendable, Equatable {
    public var hostID: String
    public var name: String
    public var signingKey: Data
    /// Six-digit code both users compare when pairing; equal on both sides only without a man in the middle.
    public var pairingCode: String
}

/// Handshake (both roles send the same frames):
///
///     → Hello{version, name, Ed25519 pub, X25519 ephemeral pub}
///     → Auth{Ed25519 sig(transcript ‖ role)}
///     transcript = SHA256("freespin-flow-v1" ‖ len‖hello_initiator ‖ len‖hello_responder)
///     keys       = HKDF-SHA256(X25519(e_i, e_r), salt: transcript, info: "i2r" | "r2i" | "code")
///
/// Every later frame is ChaCha20-Poly1305 with a 64-bit counter nonce, strictly in order.
public struct Handshake {
    public enum Role: Sendable { case initiator, responder }

    public let role: Role
    private let identity: FlowIdentity
    private let name: String
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var ownHello = Data()
    private var peerHello: HelloFrame?
    private var peerHelloBytes = Data()
    private var transcript = Data()
    public private(set) var result: (peer: FlowPeerIdentity, session: SecureSession)?

    public init(role: Role, identity: FlowIdentity, name: String) {
        self.role = role
        self.identity = identity
        self.name = name
    }

    /// The Hello frame to send first.
    public mutating func start() throws -> Data {
        let hello = HelloFrame(version: FlowProtocol.version, name: name, signingKey: identity.publicKey,
                               ephemeralKey: ephemeral.publicKey.rawRepresentation)
        ownHello = try PropertyListEncoder().encode(hello)
        return ownHello
    }

    /// Feeds one received frame; returns frames to send. `result` is set once the peer is verified.
    public mutating func receive(_ frame: Data) throws -> [Data] {
        guard result == nil else { throw FlowError.badHandshake("handshake already complete") }
        if peerHello == nil {
            guard let hello = try? PropertyListDecoder().decode(HelloFrame.self, from: frame) else {
                throw FlowError.badHandshake("expected hello")
            }
            guard hello.version == FlowProtocol.version else {
                throw FlowError.badHandshake("protocol version \(hello.version)")
            }
            guard hello.signingKey.count == 32, hello.ephemeralKey.count == 32 else {
                throw FlowError.badHandshake("bad key length")
            }
            peerHello = hello
            peerHelloBytes = frame
            let (first, second) = role == .initiator ? (ownHello, frame) : (frame, ownHello)
            transcript = Self.transcript(first, second)
            let signature = try identity.signingKey.signature(for: transcript + Self.roleTag(role))
            return [try PropertyListEncoder().encode(AuthFrame(signature: signature))]
        }
        guard let hello = peerHello,
              let auth = try? PropertyListDecoder().decode(AuthFrame.self, from: frame) else {
            throw FlowError.badHandshake("expected auth")
        }
        let peerRole: Role = role == .initiator ? .responder : .initiator
        let peerKey = try Curve25519.Signing.PublicKey(rawRepresentation: hello.signingKey)
        guard peerKey.isValidSignature(auth.signature, for: transcript + Self.roleTag(peerRole)) else {
            throw FlowError.badSignature
        }
        let peerEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.ephemeralKey)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        func derive(_ info: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data(info.utf8),
                                           outputByteCount: 32)
        }
        let i2r = derive("i2r"), r2i = derive("r2i")
        let session = role == .initiator ? SecureSession(sendKey: i2r, receiveKey: r2i)
            : SecureSession(sendKey: r2i, receiveKey: i2r)
        let codeBytes = derive("code").withUnsafeBytes { Array($0.prefix(4)) }
        let code = (UInt32(codeBytes[0]) << 24 | UInt32(codeBytes[1]) << 16 | UInt32(codeBytes[2]) << 8
            | UInt32(codeBytes[3])) % 1_000_000
        let peer = FlowPeerIdentity(hostID: FlowIdentity.hostID(for: hello.signingKey), name: hello.name,
                                    signingKey: hello.signingKey, pairingCode: String(format: "%06u", code))
        result = (peer, session)
        return []
    }

    static func transcript(_ first: Data, _ second: Data) -> Data {
        var h = SHA256()
        h.update(data: Data("freespin-flow-v1".utf8))
        for part in [first, second] {
            var n = UInt32(part.count).bigEndian
            h.update(data: Data(bytes: &n, count: 4))
            h.update(data: part)
        }
        return Data(h.finalize())
    }

    static func roleTag(_ role: Role) -> Data { Data([role == .initiator ? 0x49 : 0x52]) }
}

/// Encrypts and decrypts application frames after the handshake.
public struct SecureSession: Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    /// Frame payload: counter (8, big-endian) ‖ ciphertext ‖ tag (16).
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        sendCounter += 1
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter))
        return Self.counterBytes(counter) + box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 24 else { throw FlowError.decryptFailed }
        let bytes = [UInt8](frame.prefix(8))
        let counter = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter == receiveCounter else { throw FlowError.outOfOrder }
        let body = frame.dropFirst(8)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter), ciphertext: body.dropLast(16),
                                               tag: body.suffix(16))
            let plain = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plain
        } catch {
            throw FlowError.decryptFailed
        }
    }

    private static func counterBytes(_ c: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: c >> (56 - 8 * $0)) })
    }

    private static func nonce(_ c: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + counterBytes(c))
    }
}
