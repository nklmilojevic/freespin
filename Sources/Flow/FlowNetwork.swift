import Foundation
import Network

/// A Freespin computer found through Bonjour.
public struct DiscoveredHost: Sendable, Equatable, Identifiable {
    public var hostID: String
    public var name: String
    public var endpoint: NWEndpoint

    public var id: String { hostID }
}

/// One TCP connection to another computer: handshake, then encrypted `FlowMessage` frames.
/// All callbacks run on the queue passed to `start`.
public final class PeerLink: @unchecked Sendable {
    public let id = UUID()
    public let role: Handshake.Role
    public private(set) var peer: FlowPeerIdentity?
    /// Set by the engine once it has checked the peer's key against the paired list.
    public var trusted = false
    public let openedAt = Date()

    var onReady: ((PeerLink) -> Void)?
    var onMessage: ((PeerLink, FlowMessage) -> Void)?
    var onClose: ((PeerLink, Error?) -> Void)?
    var onLog: ((String) -> Void)?

    private let connection: NWConnection
    private var handshake: Handshake
    private var session: SecureSession?
    private var decoder = FrameDecoder()
    private var queue: DispatchQueue?
    private var closed = false

    init(connection: NWConnection, role: Handshake.Role, identity: FlowIdentity, name: String) {
        self.connection = connection
        self.role = role
        handshake = Handshake(role: role, identity: identity, name: name)
    }

    public var remoteDescription: String { "\(connection.endpoint)" }

    func start(queue: DispatchQueue) {
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["FREESPIN_FLOW_DEBUG"] != nil {
                self.onLog?("\(self.role) \(self.connection.endpoint): \(state)")
            }
            switch state {
            case .ready:
                do { self.write(try self.handshake.start()) } catch { self.close(error) }
                self.receive()
            case let .waiting(error):
                self.onLog?("waiting to connect to \(self.connection.endpoint): \(error)")
                // A dial waits for a network change that may never come (e.g. connection refused); fail it so the
                // engine's backoff retries instead.
                if self.role == .initiator { self.close(error) }
            case let .failed(error):
                self.onLog?("connection to \(self.connection.endpoint) failed: \(error)")
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, self.session == nil { self.close(FlowError.badHandshake("timeout")) }
        }
    }

    public func send(_ message: FlowMessage) {
        guard !closed, var s = session else { return }
        do {
            let frame = try s.seal(try message.encoded())
            session = s
            write(frame)
        } catch {
            close(error)
        }
    }

    public func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(self, error)
    }

    private func write(_ payload: Data) {
        connection.send(content: FrameCodec.encode(payload), completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error) }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.feed(data) { try self.handle(frame) }
                } catch {
                    self.close(error)
                    return
                }
            }
            if let error { self.close(error); return }
            if isComplete { self.close(FlowError.closed); return }
            self.receive()
        }
    }

    private func handle(_ frame: Data) throws {
        if var s = session {
            let plain = try s.open(frame)
            session = s
            onMessage?(self, try FlowMessage.decode(plain))
            return
        }
        for reply in try handshake.receive(frame) { write(reply) }
        if let result = handshake.result {
            peer = result.peer
            session = result.session
            onReady?(self)
        }
    }
}

/// Advertises this computer, browses for others and accepts connections.
public final class FlowNode: @unchecked Sendable {
    public let identity: FlowIdentity
    public let name: String
    public let queue: DispatchQueue

    public var onDiscovered: (([DiscoveredHost]) -> Void)?
    public var onLink: ((PeerLink) -> Void)?
    public var onListening: ((UInt16) -> Void)?
    public var onLog: ((String) -> Void)?

    public private(set) var port: UInt16?
    public private(set) var discovered: [DiscoveredHost] = []
    private var listener: NWListener?
    private var browser: NWBrowser?

    public init(identity: FlowIdentity, name: String, queue: DispatchQueue) {
        self.identity = identity
        self.name = name
        self.queue = queue
    }

    /// `bonjour: false` listens without advertising or browsing (loopback tests connect by port).
    public func start(port requested: UInt16 = 0, bonjour: Bool = true) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        if bonjour { listener.service = service(port: nil) }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if ProcessInfo.processInfo.environment["FREESPIN_FLOW_DEBUG"] != nil { self?.onLog?("bonjour: \(change)") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.adopt(PeerLink(connection: connection, role: .responder, identity: self.identity, name: self.name))
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener?.port?.rawValue
                // Re-register with the port: peers dial host:port from the TXT record (see startBrowsing).
                if bonjour, let p = self.port { listener?.service = self.service(port: p) }
                if let p = self.port { self.onListening?(p) }
            case let .waiting(error):
                self.onLog?("listener waiting: \(error)")
            case let .failed(error):
                self.onLog?("listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        if bonjour { startBrowsing() }
    }

    private func service(port: UInt16?) -> NWListener.Service {
        var txt = ["id": identity.hostID, "v": "\(FlowProtocol.version)"]
        if let port {
            txt["p"] = "\(port)"
            txt["h"] = ProcessInfo.processInfo.hostName
        }
        return NWListener.Service(name: name, type: FlowProtocol.serviceType, domain: nil, txtRecord: NWTXTRecord(txt))
    }

    public func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        discovered = []
    }

    /// Opens an initiator link; the engine receives it through `onLink`.
    @discardableResult
    public func connect(to endpoint: NWEndpoint) -> PeerLink {
        let link = PeerLink(connection: NWConnection(to: endpoint, using: .tcp), role: .initiator,
                            identity: identity, name: name)
        adopt(link)
        return link
    }

    private func adopt(_ link: PeerLink) {
        link.onLog = { [weak self] line in self?.onLog?(line) }
        onLink?(link)
        link.start(queue: queue)
    }

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: FlowProtocol.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var hosts: [DiscoveredHost] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata, let id = txt["id"], id != self.identity.hostID else { continue }
                // Connecting to the `.service` endpoint can sit in `preparing` forever (resolution never
                // completes for a CLI process on macOS 26+), while host:port resolves at once.
                var endpoint = result.endpoint
                if let h = txt["h"], let p = txt["p"].flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:)) {
                    endpoint = .hostPort(host: NWEndpoint.Host(h), port: p)
                }
                hosts.append(DiscoveredHost(hostID: id, name: name, endpoint: endpoint))
            }
            self.discovered = hosts.sorted { $0.name < $1.name }
            self.onDiscovered?(self.discovered)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onLog?("browser failed: \(error)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }
}
