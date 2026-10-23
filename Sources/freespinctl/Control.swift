import Flow
import Foundation
import FreespinCore

/// What `freespinctl flow` asks the daemon over its control socket: one JSON request line in, one JSON reply out.
struct ControlRequest: Codable {
    var command: String
    /// Computer name (may contain spaces), host ID or unique host ID prefix.
    var host: String?
    var edge: String?
}

struct ControlReply: Codable {
    struct Host: Codable {
        var hostID: String
        var name: String
        var discovered: Bool
        var connected: Bool
        var paired: Bool
        var side: String?
    }

    struct Pairing: Codable {
        var hostID: String
        var name: String
        var code: String
        var localConfirmed: Bool
        var remoteConfirmed: Bool
        var outgoing: Bool
    }

    struct Status: Codable {
        var hostID: String
        var name: String
        var enabled: Bool
        var hosts: [Host]
        var pairing: Pairing?
    }

    var error: String?
    var status: Status?
}

/// Unix socket in the daemon's state directory (0600 in a 0700 folder, peer UID checked) that lets the CLI
/// pair and arrange Flow computers without the app.
final class ControlServer: @unchecked Sendable {
    private let engine: FlowEngine
    private let path: String
    private let queue = DispatchQueue(label: "freespin.control")
    private let lock = NSLock()
    private var latest = FlowStatus()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// The socket file this server created, so `stop` never removes another daemon's.
    private var bound: (dev: dev_t, ino: ino_t)?

    /// Call before `engine.start()` so the first status isn't missed.
    init(engine: FlowEngine, socket: URL) {
        self.engine = engine
        path = socket.path
        engine.onStatus = { [weak self] s in self?.lock.withLock { self?.latest = s } }
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            guard !acceptsConnections(path) else {
                throw ConfigError(message: "another freespinctl daemon is already using \(dir)")
            }
            unlink(path)  // left behind by a daemon that didn't stop cleanly
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var addr = try unixAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw posixError("bind \(path)") }
        chmod(path, 0o600)
        var st = stat()
        if stat(path, &st) == 0 { self.bound = (st.st_dev, st.st_ino) }
        guard listen(fd, 16) == 0 else { throw posixError("listen") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd) }
        fd = -1
        var st = stat()
        if let bound, stat(path, &st) == 0, st.st_dev == bound.dev, st.st_ino == bound.ino { unlink(path) }
        bound = nil
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(client) else { return }
        let reply = (try? JSONDecoder().decode(ControlRequest.self, from: Data(line.utf8))).map(handle)
            ?? ControlReply(error: "malformed request")
        var data = (try? JSONEncoder().encode(reply)) ?? Data()
        data.append(0x0A)
        // A client that hung up must not take the daemon down with SIGPIPE.
        writeAll(client, data)
    }

    func handle(_ request: ControlRequest) -> ControlReply {
        let arg = request.host
        let status = lock.withLock { latest }
        switch request.command {
        case "status":
            return ControlReply(status: reply(status))
        case "pair":
            guard let host = resolve(arg, in: status.hosts.map { ($0.hostID, $0.name) }) else {
                return ControlReply(error: "no computer named \(arg ?? "?") (see `freespinctl flow status`)")
            }
            engine.pair(hostID: host)
        case "confirm":
            guard status.pairing != nil else { return ControlReply(error: "no pairing in progress") }
            engine.confirmPairing()
        case "cancel":
            engine.cancelPairing()
        case "unpair":
            guard let host = resolve(arg, in: engine.settings.peers.map { ($0.hostID, $0.name) }) else {
                return ControlReply(error: "not paired with \(arg ?? "?")")
            }
            engine.unpair(hostID: host)
        case "side":
            guard let host = resolve(arg, in: engine.settings.peers.map { ($0.hostID, $0.name) }) else {
                return ControlReply(error: "not paired with \(arg ?? "?")")
            }
            guard let edge = request.edge.flatMap(FlowEdge.init(rawValue:)) else {
                return ControlReply(error: "side must be one of: \(FlowEdge.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            engine.setSide(edge, for: host)
        default:
            return ControlReply(error: "unknown request \(request.command)")
        }
        return ControlReply()
    }

    /// Host ID, a unique host ID prefix, or a name (case-insensitive).
    private func resolve(_ query: String?, in hosts: [(id: String, name: String)]) -> String? {
        guard let query, !query.isEmpty else { return nil }
        if let exact = hosts.first(where: { $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact.id
        }
        let prefixed = hosts.filter { $0.id.hasPrefix(query) }
        return prefixed.count == 1 ? prefixed[0].id : nil
    }

    private func reply(_ s: FlowStatus) -> ControlReply.Status {
        let peers = engine.settings.peers
        return ControlReply.Status(
            hostID: s.hostID, name: s.name, enabled: s.settings.enabled,
            hosts: s.hosts.map { h in
                ControlReply.Host(hostID: h.hostID, name: h.name, discovered: h.discovered, connected: h.connected,
                                  paired: h.paired, side: peers.first { $0.hostID == h.hostID }?.side.rawValue)
            },
            pairing: s.pairing.map {
                ControlReply.Pairing(hostID: $0.hostID, name: $0.name, code: $0.code, localConfirmed: $0.localConfirmed,
                                     remoteConfirmed: $0.remoteConfirmed, outgoing: $0.outgoing)
            })
    }
}

private func readLine(_ fd: Int32) -> String? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < 4096 {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { break }
        data.append(buffer, count: n)
        if data.contains(0x0A) { break }
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    return text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Writes everything, on a socket that reports a closed peer as an error instead of raising SIGPIPE.
@discardableResult
private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return data.withUnsafeBytes { buf in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}

/// A connected socket to `path`; throws when nothing listens there.
private func connectUnix(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError("socket") }
    var addr = try unixAddress(path)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        let error = posixError("connect")
        close(fd)
        throw error
    }
    return fd
}

private func acceptsConnections(_ path: String) -> Bool {
    guard let fd = try? connectUnix(path) else { return false }
    close(fd)
    return true
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        throw ConfigError(message: "control socket path too long: \(path)")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    return addr
}

private func posixError(_ what: String) -> Error {
    ConfigError(message: "\(what): \(String(cString: strerror(errno)))")
}

// MARK: - Client

let flowUsage = """
usage: freespinctl flow <command> [--state <dir>]

Talks to a running `freespinctl daemon` with Flow enabled.

  status               this computer, the computers it can see, and pairing in progress
  pair <computer>      pair with a computer (name or host ID); asks you to compare the six-digit code
  confirm              accept a pairing the other computer started (after checking the code)
  cancel               cancel the pairing in progress
  unpair <computer>    forget a paired computer
  side <computer> <left|right|top|bottom>
                       which side of this computer's screens the other computer is on
"""

func runFlowControl(_ args: [String]) async throws {
    var words: [String] = []
    var state = DaemonOptions.defaultState
    var it = args.makeIterator()
    while let a = it.next() {
        if a == "--state", let v = it.next() {
            state = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            words.append(a)
        }
    }
    guard let command = words.first, command != "--help" else {
        print(flowUsage)
        return
    }
    let client = ControlClient(socketURL: state.appendingPathComponent("control.sock"))
    switch command {
    case "status":
        guard let s = try client.send("status").status else { return }
        printStatus(s)
    case "pair":
        // Unquoted multi-word names work too: `flow pair MacBook Pro`.
        guard words.count >= 2 else { throw ConfigError(message: "usage: freespinctl flow pair <computer>") }
        try await pairInteractively(words.dropFirst().joined(separator: " "), client: client)
    case "confirm":
        guard let p = try client.send("status").status?.pairing else { throw ConfigError(message: "no pairing in progress") }
        try client.send("confirm")
        print("confirmed code \(p.code) with \(p.name); waiting for it to confirm too")
        try await waitForPairing(p.hostID, client: client)
    case "cancel":
        try client.send("cancel")
        print("ok")
    case "unpair":
        guard words.count >= 2 else { throw ConfigError(message: "usage: freespinctl flow unpair <computer>") }
        try client.send("unpair", host: words.dropFirst().joined(separator: " "))
        print("ok")
    case "side":
        guard words.count >= 3 else { throw ConfigError(message: "usage: freespinctl flow side <computer> <left|right|top|bottom>") }
        try client.send("side", host: words.dropFirst().dropLast().joined(separator: " "), edge: words.last)
        print("ok")
    default:
        print(flowUsage)
        exit(64)
    }
}

private func printStatus(_ s: ControlReply.Status) {
    print("\(s.name) (\(s.hostID)), flow \(s.enabled ? "on" : "off")")
    if s.hosts.isEmpty { print("no other computers found") }
    for h in s.hosts {
        var flags: [String] = []
        if h.paired { flags.append("paired" + (h.side.map { ", \($0) side" } ?? "")) }
        flags.append(h.connected ? "connected" : h.discovered ? "on the network" : "offline")
        print("  \(h.name)  \(h.hostID)  \(flags.joined(separator: ", "))")
    }
    if let p = s.pairing {
        print("pairing with \(p.name): code \(p.code)" + (p.localConfirmed ? " (confirmed here)" : " (run `freespinctl flow confirm`)"))
    }
}

private func pairInteractively(_ host: String, client: ControlClient) async throws {
    try client.send("pair", host: host)
    var pairing: ControlReply.Pairing?
    for _ in 0..<120 {
        pairing = try client.send("status").status?.pairing
        if pairing != nil { break }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    guard let p = pairing else { throw ConfigError(message: "\(host) did not answer") }
    print("code \(p.code). Does \(p.name) show the same code? [y/N] ", terminator: "")
    guard Swift.readLine()?.lowercased().hasPrefix("y") == true else {
        try client.send("cancel")
        print("cancelled")
        return
    }
    try client.send("confirm")
    print("waiting for \(p.name) to confirm")
    try await waitForPairing(p.hostID, client: client)
}

private func waitForPairing(_ hostID: String, client: ControlClient) async throws {
    for _ in 0..<480 {
        let s = try client.send("status").status
        if s?.hosts.first(where: { $0.hostID == hostID })?.paired == true {
            print("paired. Set its side with `freespinctl flow side \(hostID) <left|right|top|bottom>`")
            return
        }
        if s?.pairing == nil {
            throw ConfigError(message: "pairing was cancelled")
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw ConfigError(message: "timed out waiting for the other computer")
}

struct ControlClient {
    let socketURL: URL

    @discardableResult
    func send(_ command: String, host: String? = nil, edge: String? = nil) throws -> ControlReply {
        let fd: Int32
        do {
            fd = try connectUnix(socketURL.path)
        } catch {
            throw ConfigError(message: "no daemon with Flow enabled at \(socketURL.path) (\(error))")
        }
        defer { close(fd) }
        var data = try JSONEncoder().encode(ControlRequest(command: command, host: host, edge: edge))
        data.append(0x0A)
        guard writeAll(fd, data) else { throw ConfigError(message: "the daemon closed the connection") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(fd), let reply = try? JSONDecoder().decode(ControlReply.self, from: Data(line.utf8)) else {
            throw ConfigError(message: "no reply from the daemon")
        }
        if let error = reply.error { throw ConfigError(message: error) }
        return reply
    }
}
