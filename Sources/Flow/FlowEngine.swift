import CoreGraphics
import Foundation
import Network

/// A Logitech device on this computer that Flow can switch.
public protocol FlowLocalDevice: AnyObject, Sendable {
    var record: FlowDeviceRecord { get }
    /// Confirms the device is still connected to this computer (a mouse that left doesn't answer).
    func isPresent() async -> Bool
    /// HID++ 0x1814 SetCurrentHost.
    func switchHost(to channel: Int) async throws
}

/// Cursor access: edge hits in, cursor placement out.
public protocol FlowPointer: AnyObject, Sendable {
    /// Called with every edge hit; `controlDown` reports the Control modifier.
    func start(onEdge: @escaping @Sendable (FlowEdge, Double, Bool) -> Void)
    func stop()
    var geometry: EdgeGeometry { get }
    func warp(to point: CGPoint)
    /// Moves the cursor a little away from `edge` when a flow out didn't move the mouse, so it doesn't bounce back.
    func retreat(from edge: FlowEdge)
    /// Applies pointer-related settings (corner avoidance).
    func configure(_ settings: FlowSettings)
    /// Calls `handler` on every key press and pointer move or click while set; nil stops.
    /// Only says what kind of input happened, never which key.
    func watchInput(_ handler: (@Sendable (FlowInput) -> Void)?)
}

public enum FlowInput: Sendable {
    case key, pointer
}

extension FlowPointer {
    public func configure(_ settings: FlowSettings) {}
    public func watchInput(_ handler: (@Sendable (FlowInput) -> Void)?) {}
}

public protocol FlowClipboard: AnyObject, Sendable {
    /// Current contents if they changed since the last capture or apply, nil otherwise.
    func captureIfChanged() -> [ClipboardItem]?
    func apply(_ items: [ClipboardItem])
}

/// UI-facing state.
public struct FlowStatus: Sendable, Equatable {
    public struct Host: Sendable, Equatable, Identifiable {
        public var hostID: String
        public var name: String
        public var discovered: Bool
        public var connected: Bool
        public var paired: Bool
        public var id: String { hostID }
    }

    public struct Pairing: Sendable, Equatable {
        public var hostID: String
        public var name: String
        public var code: String
        public var localConfirmed: Bool
        public var remoteConfirmed: Bool
        /// Started on this computer (false = the other computer asked).
        public var outgoing: Bool
    }

    public var hostID = ""
    public var name = ""
    public var hosts: [Host] = []
    public var pairing: Pairing?
    public var localDevices: [FlowDeviceRecord] = []
    public var presentDevices: Set<String> = []
    public var settings = FlowSettings()
    public var lastEvent: String?

    public init() {}

    public init(hostID: String, name: String, hosts: [Host], pairing: Pairing?, localDevices: [FlowDeviceRecord],
                presentDevices: Set<String>, settings: FlowSettings, lastEvent: String?) {
        self.hostID = hostID
        self.name = name
        self.hosts = hosts
        self.pairing = pairing
        self.localDevices = localDevices
        self.presentDevices = presentDevices
        self.settings = settings
        self.lastEvent = lastEvent
    }
}

public enum FlowEvent: Sendable, Equatable {
    case linkUp(hostID: String, trusted: Bool)
    case linkDown(hostID: String)
    case pairingStarted(hostID: String, code: String)
    case paired(hostID: String)
    case pairingCancelled(hostID: String)
    case inventory(hostID: String, devices: [FlowDeviceRecord])
    case flowedOut(hostID: String, edge: FlowEdge, switched: [String: Int])
    case flowedIn(hostID: String, point: CGPoint)
    /// A keyboard that slept through a flow out woke up and was sent after the mouse.
    case keyboardFollowed(unitID: String, channel: Int)
    case clipboardSent(items: Int)
    case clipboardReceived(items: Int)
    case skipped(String)
    case error(String)
}

/// Freespin Flow: pairs computers, tracks their channels on each shared device, and moves the mouse
/// (and linked keyboards) when the cursor is pushed through the edge facing another computer.
public final class FlowEngine: @unchecked Sendable {
    public let queue = DispatchQueue(label: "freespin.flow", qos: .userInteractive)
    public let node: FlowNode
    public var onStatus: (@Sendable (FlowStatus) -> Void)?
    public var onEvent: (@Sendable (FlowEvent) -> Void)?

    private let store: FlowSettingsStore
    private let pointer: FlowPointer
    private let clipboard: FlowClipboard
    private let bonjour: Bool
    private var links: [UUID: PeerLink] = [:]
    private var devices: [String: FlowLocalDevice] = [:]
    private var present: Set<String> = []
    private var discovered: [DiscoveredHost] = []
    private var pairing: FlowStatus.Pairing?
    private var pendingOut: [UInt32: (hostID: String, edge: FlowEdge)] = [:]
    private var busy = false
    private var quietUntil = Date.distantPast
    private var pointerRunning = false
    private var lastEvent: String?
    private var started = false
    /// Keyboards to send after the mouse once they wake: unit ID → target channel and deadline.
    private var follow: [String: (channel: Int, until: Date)] = [:]
    private var followBusy = false
    private var watchingInput = false
    /// Pointer input is ignored until then: motion still in flight from the mouse that just left.
    private var followGraceUntil = Date.distantPast

    /// How long the receiver gets to place its cursor before the switch is abandoned.
    public var readyTimeout: TimeInterval = 0.8
    /// After a switch, edge hits are ignored for this long (the cursor was just placed at an edge).
    public var cooldown: TimeInterval = 0.8
    /// A sleeping keyboard misses SetCurrentHost; for this long after a flow out it follows the mouse
    /// as soon as it wakes (a key press or reconnect) and is still on this computer's channel.
    public var followWindow: TimeInterval = 60

    public init(identity: FlowIdentity, name: String, store: FlowSettingsStore, pointer: FlowPointer,
                clipboard: FlowClipboard, bonjour: Bool = true) {
        node = FlowNode(identity: identity, name: name, queue: queue)
        self.store = store
        self.pointer = pointer
        self.clipboard = clipboard
        self.bonjour = bonjour
        node.onLink = { [weak self] link in self?.adopt(link) }
        node.onDiscovered = { [weak self] hosts in self?.discoveredChanged(hosts) }
        node.onLog = { [weak self] line in self?.emit(.error(line)) }
    }

    public var settings: FlowSettings { store.settings }

    // MARK: - Lifecycle

    public func start(port: UInt16 = 0) throws {
        try queue.sync {
            guard !started else { return }
            started = true
            try node.start(port: port, bonjour: bonjour)
            updatePointer()
            publish()
        }
    }

    public func stop() {
        queue.sync {
            started = false
            node.stop()
            links.values.forEach { $0.close() }
            links.removeAll()
            stopPointer()
            follow.removeAll()
            updateInputWatch()
        }
    }

    /// Connects by address (tests, or a computer Bonjour can't see).
    public func connect(to endpoint: NWEndpoint) {
        queue.async { _ = self.node.connect(to: endpoint) }
    }

    public func updateSettings(_ body: @escaping @Sendable (inout FlowSettings) -> Void) {
        queue.async {
            self.store.update(body)
            self.updatePointer()
            self.publish()
        }
    }

    // MARK: - Devices

    /// Replaces the set of Flow-capable devices currently connected to this computer.
    public func setDevices(_ list: [FlowLocalDevice]) {
        queue.async {
            self.devices = Dictionary(list.map { ($0.record.unitID, $0) }, uniquingKeysWith: { a, _ in a })
            self.present = Set(self.devices.keys)
            self.store.update { s in for d in list { s.upsert(local: d.record) } }
            self.broadcastInventory()
            self.updatePointer()
            self.followKeyboards()
            self.publish()
        }
    }

    // MARK: - Pairing

    /// Starts pairing with a discovered (or connected) computer.
    public func pair(hostID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let link = self.trustedOrAnyLink(hostID) {
                self.requestPairing(over: link)
            } else if let host = self.discovered.first(where: { $0.hostID == hostID }) {
                let link = self.node.connect(to: host.endpoint)
                link.onReady = { [weak self] l in
                    self?.linkReady(l)
                    self?.requestPairing(over: l)
                }
            }
        }
    }

    public func confirmPairing() {
        queue.async {
            guard var p = self.pairing, let link = self.anyLink(p.hostID) else { return }
            p.localConfirmed = true
            self.pairing = p
            link.send(.pairConfirm)
            self.completePairingIfReady()
            self.publish()
        }
    }

    public func cancelPairing() {
        queue.async {
            guard let p = self.pairing else { return }
            self.anyLink(p.hostID)?.send(.pairCancel)
            self.pairing = nil
            self.emit(.pairingCancelled(hostID: p.hostID))
            self.publish()
        }
    }

    public func unpair(hostID: String) {
        queue.async {
            for link in self.links.values where link.peer?.hostID == hostID {
                link.send(.unpair)
                link.trusted = false
            }
            self.store.update { $0.peers.removeAll { $0.hostID == hostID } }
            self.updatePointer()
            self.publish()
        }
    }

    public func setSide(_ side: FlowEdge, for hostID: String) {
        updateSettings { s in
            guard var peer = s.peer(hostID) else { return }
            peer.side = side
            s.upsert(peer: peer)
        }
    }

    private func requestPairing(over link: PeerLink) {
        guard let peer = link.peer else { return }
        pairing = FlowStatus.Pairing(hostID: peer.hostID, name: peer.name, code: peer.pairingCode,
                                     localConfirmed: false, remoteConfirmed: false, outgoing: true)
        link.send(.pairRequest(name: node.name))
        emit(.pairingStarted(hostID: peer.hostID, code: peer.pairingCode))
        publish()
    }

    private func completePairingIfReady() {
        guard let p = pairing, p.localConfirmed, p.remoteConfirmed, let link = anyLink(p.hostID), let peer = link.peer else { return }
        let existing = store.settings.peer(peer.hostID)
        let side = existing?.side ?? (p.outgoing ? .right : .left)
        store.update { s in
            s.upsert(peer: PairedPeer(hostID: peer.hostID, name: peer.name, signingKey: peer.signingKey, side: side,
                                      devices: existing?.devices ?? []))
            if s.peers.count == 1 { s.enabled = true }
        }
        pairing = nil
        link.trusted = true
        dropDuplicates(of: link)
        emit(.paired(hostID: peer.hostID))
        link.send(.inventory(store.settings.localDevices))
        updatePointer()
        publish()
    }

    // MARK: - Links

    private func adopt(_ link: PeerLink) {
        links[link.id] = link
        if link.onReady == nil { link.onReady = { [weak self] l in self?.linkReady(l) } }
        link.onMessage = { [weak self] l, m in self?.handle(m, from: l) }
        link.onClose = { [weak self] l, _ in self?.linkClosed(l) }
    }

    private func linkReady(_ link: PeerLink) {
        guard let peer = link.peer else { return }
        if let known = store.settings.peer(peer.hostID) {
            guard known.signingKey == peer.signingKey else {
                emit(.error("\(peer.name): key changed; pair again"))
                link.close()
                return
            }
            link.trusted = true
            dropDuplicates(of: link)
            if known.name != peer.name {
                store.update { s in
                    guard var p = s.peer(peer.hostID) else { return }
                    p.name = peer.name
                    s.upsert(peer: p)
                }
            }
            link.send(.inventory(store.settings.localDevices))
        }
        emit(.linkUp(hostID: peer.hostID, trusted: link.trusted))
        updatePointer()
        publish()
    }

    /// Both computers may dial each other; keep the link the lower host ID initiated.
    private func dropDuplicates(of link: PeerLink) {
        guard let hostID = link.peer?.hostID else { return }
        let others = links.values.filter { $0 !== link && $0.trusted && $0.peer?.hostID == hostID }
        guard !others.isEmpty else { return }
        let all = others + [link]
        let mineFirst = node.identity.hostID < hostID
        let keep = all.first { ($0.role == .initiator) == mineFirst } ?? link
        for l in all where l !== keep { l.trusted = false; l.close() }
    }

    private func linkClosed(_ link: PeerLink) {
        links[link.id] = nil
        if let id = link.peer?.hostID {
            if pairing?.hostID == id, anyLink(id) == nil {
                pairing = nil
                emit(.pairingCancelled(hostID: id))
            }
            emit(.linkDown(hostID: id))
        }
        updatePointer()
        publish()
    }

    private func trustedLink(_ hostID: String) -> PeerLink? {
        links.values.first { $0.trusted && $0.peer?.hostID == hostID }
    }

    private func anyLink(_ hostID: String) -> PeerLink? {
        links.values.first { $0.peer?.hostID == hostID }
    }

    private func trustedOrAnyLink(_ hostID: String) -> PeerLink? { trustedLink(hostID) ?? anyLink(hostID) }

    private func discoveredChanged(_ hosts: [DiscoveredHost]) {
        discovered = hosts
        // Dial paired computers we aren't connected to; the lower host ID dials first, the other after a delay.
        for host in hosts where store.settings.peer(host.hostID) != nil && anyLink(host.hostID) == nil {
            let delay: TimeInterval = node.identity.hostID < host.hostID ? 0 : 2
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.started, self.anyLink(host.hostID) == nil else { return }
                _ = self.node.connect(to: host.endpoint)
            }
        }
        publish()
    }

    private func broadcastInventory() {
        let inventory = store.settings.localDevices
        for link in links.values where link.trusted { link.send(.inventory(inventory)) }
    }

    // MARK: - Messages

    private func handle(_ message: FlowMessage, from link: PeerLink) {
        guard let peer = link.peer else { return }
        switch message {
        case let .pairRequest(name):
            pairing = FlowStatus.Pairing(hostID: peer.hostID, name: name, code: peer.pairingCode,
                                         localConfirmed: false, remoteConfirmed: false, outgoing: false)
            emit(.pairingStarted(hostID: peer.hostID, code: peer.pairingCode))
            publish()
            return
        case .pairConfirm:
            guard var p = pairing, p.hostID == peer.hostID else { return }
            p.remoteConfirmed = true
            pairing = p
            completePairingIfReady()
            publish()
            return
        case .pairCancel:
            if pairing?.hostID == peer.hostID {
                pairing = nil
                emit(.pairingCancelled(hostID: peer.hostID))
                publish()
            }
            return
        case .ping:
            link.send(.pong)
            return
        case .pong:
            return
        default:
            break
        }
        // Everything below needs a paired computer.
        guard link.trusted else {
            emit(.skipped("ignored \(message) from unpaired \(peer.name)"))
            return
        }
        switch message {
        case let .inventory(list):
            store.update { s in
                guard var p = s.peer(peer.hostID) else { return }
                p.devices = list
                s.upsert(peer: p)
            }
            emit(.inventory(hostID: peer.hostID, devices: list))
            updatePointer()
            publish()
        case .unpair:
            link.trusted = false
            store.update { $0.peers.removeAll { $0.hostID == peer.hostID } }
            updatePointer()
            publish()
        case let .incoming(id, edge, fraction):
            flowIn(id: id, edge: store.settings.peer(peer.hostID)?.side ?? edge, fraction: fraction, from: link)
        case let .ready(id):
            guard let out = pendingOut.removeValue(forKey: id), out.hostID == peer.hostID else { return }
            finishFlowOut(to: link, edge: out.edge)
        case let .clipboard(items):
            guard store.settings.syncClipboard else { return }
            clipboard.apply(items)
            emit(.clipboardReceived(items: items.count))
        default:
            break
        }
    }

    // MARK: - Flow

    private func updatePointer() {
        let s = store.settings
        pointer.configure(s)
        let shouldRun = started && s.enabled && s.peers.contains { trustedLink($0.hostID) != nil }
            && devices.values.contains { $0.record.kind == .mouse }
        if shouldRun, !pointerRunning {
            pointerRunning = true
            pointer.start { [weak self] edge, fraction, control in
                self?.queue.async { self?.edgeHit(edge, fraction: fraction, controlDown: control) }
            }
        } else if !shouldRun {
            stopPointer()
        }
    }

    private func stopPointer() {
        if pointerRunning { pointer.stop() }
        pointerRunning = false
    }

    /// Entry point for edge hits (from the pointer, or injected by tests and the simulator).
    public func edgeHit(_ edge: FlowEdge, fraction: Double, controlDown: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let s = store.settings
        guard s.enabled, !busy, Date() >= quietUntil else { return }
        if s.requireControl, !controlDown { return }
        guard let peer = s.peers.first(where: { $0.side == edge }), let link = trustedLink(peer.hostID) else { return }
        guard let mouse = devices.values.first(where: { $0.record.kind == .mouse && peer.channel(for: $0.record.unitID) != nil }) else {
            emit(.skipped("\(peer.name) has no channel for a mouse here"))
            return
        }
        busy = true
        Task {
            let here = await mouse.isPresent()
            self.queue.async {
                guard here else {
                    self.busy = false
                    self.present.remove(mouse.record.unitID)
                    self.emit(.skipped("\(mouse.record.name) is not connected to this computer"))
                    self.publish()
                    return
                }
                let id = UInt32.random(in: 1...UInt32.max)
                self.pendingOut[id] = (peer.hostID, edge)
                link.send(.incoming(id: id, edge: edge.opposite, fraction: fraction))
                self.queue.asyncAfter(deadline: .now() + self.readyTimeout) {
                    if self.pendingOut.removeValue(forKey: id) != nil {
                        self.busy = false
                        self.emit(.skipped("\(peer.name) did not answer"))
                    }
                }
            }
        }
    }

    private func finishFlowOut(to link: PeerLink, edge: FlowEdge) {
        guard let peer = link.peer, let paired = store.settings.peer(peer.hostID) else { busy = false; return }
        let s = store.settings
        if s.syncClipboard, let items = clipboard.captureIfChanged(), !items.isEmpty {
            link.send(.clipboard(items))
            emit(.clipboardSent(items: items.count))
        }
        let candidates = devices.values.filter { $0.record.kind == .mouse || ($0.record.kind == .keyboard && s.linkKeyboard) }
        for d in candidates where d.record.kind == .keyboard && paired.channel(for: d.record.unitID) == nil {
            emit(.skipped("\(d.record.name) has no channel on \(peer.name); connect it there once with Freespin running"))
        }
        // Keyboards first: once the mouse leaves, this computer may lose the receiver link too.
        let targets = candidates
            .compactMap { d in paired.channel(for: d.record.unitID).map { (d, $0) } }
            .sorted { ($0.0.record.kind == .keyboard ? 0 : 1) < ($1.0.record.kind == .keyboard ? 0 : 1) }
        Task {
            var switched: [String: Int] = [:]
            for (device, channel) in targets {
                do {
                    try await device.switchHost(to: channel)
                    switched[device.record.unitID] = channel
                } catch {
                    self.emit(.error("switch \(device.record.name) to channel \(channel + 1) failed: \(error)"))
                }
            }
            self.queue.async {
                // The mouse stayed here: move the cursor off the edge so it doesn't push straight through again.
                let mouseLeft = targets.contains { $0.0.record.kind == .mouse && switched[$0.0.record.unitID] != nil }
                if !mouseLeft { self.pointer.retreat(from: edge) }
                self.busy = false
                self.quietUntil = Date().addingTimeInterval(self.cooldown)
                for id in switched.keys { self.present.remove(id) }
                // Asleep or not, any linked keyboard may have missed the switch; one that got it is no longer
                // on this computer's channel, so following it later is a no-op.
                if mouseLeft, s.linkKeyboard {
                    let until = Date().addingTimeInterval(self.followWindow)
                    for k in s.localDevices where k.kind == .keyboard {
                        if let ch = paired.channel(for: k.unitID) { self.follow[k.unitID] = (ch, until) }
                    }
                    self.followGraceUntil = Date().addingTimeInterval(self.cooldown)
                    self.updateInputWatch()
                    self.queue.asyncAfter(deadline: .now() + self.followWindow) { self.followKeyboards() }
                }
                self.emit(.flowedOut(hostID: peer.hostID, edge: edge, switched: switched))
                self.publish()
            }
        }
    }

    /// Sends keyboards that slept through a flow out after the mouse, once they answer on this computer's channel.
    private func followKeyboards() {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = Date()
        follow = follow.filter { $0.value.until > now }
        updateInputWatch()
        guard !followBusy else { return }
        let due = follow.compactMap { id, f in devices[id].map { ($0, f.channel) } }
        guard !due.isEmpty else { return }
        followBusy = true
        Task {
            var done: [String: Int] = [:]
            for (device, channel) in due where await device.isPresent() {
                do {
                    try await device.switchHost(to: channel)
                    done[device.record.unitID] = channel
                } catch {
                    self.emit(.error("switch \(device.record.name) to channel \(channel + 1) failed: \(error)"))
                }
            }
            self.queue.async {
                self.followBusy = false
                for (id, channel) in done {
                    self.follow[id] = nil
                    self.present.remove(id)
                    self.emit(.keyboardFollowed(unitID: id, channel: channel))
                }
                self.updateInputWatch()
                if !done.isEmpty { self.publish() }
            }
        }
    }

    private func updateInputWatch() {
        let want = !follow.isEmpty
        guard want != watchingInput else { return }
        watchingInput = want
        guard want else { pointer.watchInput(nil); return }
        pointer.watchInput { [weak self] input in
            guard let self else { return }
            self.queue.async { self.inputSeen(input) }
        }
    }

    private func inputSeen(_ input: FlowInput) {
        switch input {
        case .key:
            followKeyboards()
        case .pointer:
            // Someone is using a pointer here: the mouse came back without Flow (its Easy-Switch button) or
            // they're on a trackpad. Keep the keyboard on this computer.
            guard Date() >= followGraceUntil, !follow.isEmpty else { return }
            follow.removeAll()
            updateInputWatch()
        }
    }

    private func flowIn(id: UInt32, edge: FlowEdge, fraction: Double, from link: PeerLink) {
        guard let peer = link.peer else { return }
        follow.removeAll()
        updateInputWatch()
        if let point = pointer.geometry.entryPoint(edge: edge, fraction: fraction) {
            pointer.warp(to: point)
            emit(.flowedIn(hostID: peer.hostID, point: point))
        }
        quietUntil = Date().addingTimeInterval(cooldown)
        link.send(.ready(id: id))
    }

    // MARK: - Status

    private func emit(_ event: FlowEvent) {
        lastEvent = "\(event)"
        onEvent?(event)
    }

    private func publish() {
        let s = store.settings
        var hosts: [String: FlowStatus.Host] = [:]
        for d in discovered {
            hosts[d.hostID] = .init(hostID: d.hostID, name: d.name, discovered: true, connected: false, paired: false)
        }
        for l in links.values {
            guard let p = l.peer else { continue }
            var h = hosts[p.hostID] ?? .init(hostID: p.hostID, name: p.name, discovered: false, connected: false, paired: false)
            h.connected = h.connected || l.trusted
            hosts[p.hostID] = h
        }
        for p in s.peers {
            var h = hosts[p.hostID] ?? .init(hostID: p.hostID, name: p.name, discovered: false, connected: false, paired: true)
            h.paired = true
            h.name = p.name
            hosts[p.hostID] = h
        }
        let status = FlowStatus(hostID: node.identity.hostID, name: node.name,
                                hosts: hosts.values.sorted { $0.name < $1.name }, pairing: pairing,
                                localDevices: s.localDevices, presentDevices: present, settings: s, lastEvent: lastEvent)
        onStatus?(status)
    }
}
