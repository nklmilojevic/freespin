import Flow
import Foundation
import FreespinCore
import Network

let flowSimUsage = """
usage: freespinctl flow-sim [options]

Runs a headless Flow node with a simulated Easy-Switch mouse, for testing Flow between two machines
(or a Mac and a VM) without hardware. Prints one line per event.

  --name NAME          computer name (default: this host's name + " (sim)")
  --dir DIR            state directory for identity and flow.json (default: $TMPDIR/freespin-flow-sim/<name>)
  --port N             listen port (default: any)
  --connect HOST:PORT  dial this address instead of waiting for Bonjour
  --no-bonjour         don't advertise or browse
  --unit HEX           unit ID of the simulated mouse (default 5f5f5f5f)
  --channel N          this computer's Easy-Switch channel for the mouse, 1-3 (default 1)
  --here               the mouse starts connected to this computer
  --keyboard HEX       also simulate a linked keyboard with this unit ID
  --pair               pair with the first computer found (the other side needs --auto-accept or --pair)
  --peer-name NAME     with --pair: only pair with the computer called NAME
  --auto-accept        confirm pairing requests without asking
  --side EDGE          where the peer sits once paired: left|right|top|bottom
  --push EDGE          push the pointer through EDGE every --every seconds while the mouse is here
  --every S            push interval (default 2)
  --copy TEXT          put "TEXT #n" on the clipboard before each push
  --duration S         exit after S seconds (default: run until Ctrl-C)
  --expect N           with --duration: exit 0 only after N flows out and N flows in
"""

struct FlowSimOptions {
    var name = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName) + " (sim)"
    var dir: String?
    var port: UInt16 = 0
    var connect: String?
    var bonjour = true
    var unit = "5f5f5f5f"
    var channel = 0
    var here = false
    var keyboard: String?
    var pair = false
    var peerName: String?
    var autoAccept = false
    var side: FlowEdge?
    var push: FlowEdge?
    var every: TimeInterval = 2
    var copy: String?
    var duration: TimeInterval?
    var expect = 0

    init(_ args: [String]) throws {
        var it = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw FlowSimError.usage("\(flag) needs a value") }
            return v
        }
        func edge(_ flag: String) throws -> FlowEdge {
            let v = try value(flag)
            guard let e = FlowEdge(rawValue: v) else { throw FlowSimError.usage("bad edge \(v)") }
            return e
        }
        while let a = it.next() {
            switch a {
            case "--name": name = try value(a)
            case "--dir": dir = try value(a)
            case "--port": port = UInt16(try value(a)) ?? 0
            case "--connect": connect = try value(a)
            case "--no-bonjour": bonjour = false
            case "--unit": unit = try value(a).lowercased()
            case "--channel": channel = max(0, (Int(try value(a)) ?? 1) - 1)
            case "--here": here = true
            case "--keyboard": keyboard = try value(a).lowercased()
            case "--pair": pair = true
            case "--peer-name": peerName = try value(a)
            case "--auto-accept": autoAccept = true
            case "--side": side = try edge(a)
            case "--push": push = try edge(a)
            case "--every": every = TimeInterval(try value(a)) ?? 2
            case "--copy": copy = try value(a)
            case "--duration": duration = TimeInterval(try value(a))
            case "--expect": expect = Int(try value(a)) ?? 0
            default: throw FlowSimError.usage("unknown option \(a)")
            }
        }
        guard every.isFinite, every > 0 else { throw FlowSimError.usage("--every must be a positive number of seconds") }
    }
}

enum FlowSimError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case let .usage(m): "\(m)\n\n\(flowSimUsage)" }
    }
}

/// Counters and state shared between engine callbacks.
final class FlowSimState: @unchecked Sendable {
    let lock = NSLock()
    var outs = 0
    var ins = 0
    var pushes = 0
    var pairingAnswered = false
    var pairRequested = false
}

func runFlowSim(_ args: [String]) async throws {
    let o = try FlowSimOptions(args)
    let dir = URL(fileURLWithPath: o.dir ?? NSTemporaryDirectory() + "freespin-flow-sim/" + o.name.replacingOccurrences(of: "/", with: "-"))
    let identity = try FileIdentityStore(url: dir.appendingPathComponent("identity.key")).loadOrCreate()
    let pointer = ScriptedPointer()
    let clipboard = MemoryClipboard()
    let engine = FlowEngine(identity: identity, name: o.name, store: FlowSettingsStore(url: dir.appendingPathComponent("flow.json")),
                            pointer: pointer, clipboard: clipboard, bonjour: o.bonjour)
    let state = FlowSimState()
    let started = Date()

    @Sendable func say(_ s: String) {
        let t = String(format: "%7.3f", Date().timeIntervalSince(started))
        print("[\(t)] \(o.name): \(s)")
        fflush(stdout)
    }

    let mouse = SimulatedDevice(record: FlowDeviceRecord(unitID: o.unit, name: "Simulated MX Master", kind: .mouse,
                                                         channel: o.channel, channelCount: 3))
    mouse.present = o.here
    var simulated: [SimulatedDevice] = [mouse]
    if let kb = o.keyboard {
        let k = SimulatedDevice(record: FlowDeviceRecord(unitID: kb, name: "Simulated MX Keys", kind: .keyboard,
                                                         channel: o.channel, channelCount: 3))
        k.present = o.here
        simulated.append(k)
    }
    let devices = simulated
    for d in devices {
        d.onSwitch = { ch in say("HID++ 0x1814 SetCurrentHost(\(ch)) → \(d.record.name) leaves for channel \(ch + 1)") }
    }

    engine.onEvent = { event in
        switch event {
        case let .flowedIn(host, point):
            // The other computer just switched the physical devices to this computer's channel.
            devices.forEach { $0.present = true }
            state.lock.withLock { state.ins += 1 }
            say("flowed in from \(host) at (\(Int(point.x)), \(Int(point.y))); devices are here now")
        case let .flowedOut(host, edge, switched):
            state.lock.withLock { state.outs += 1 }
            say("flowed out through \(edge) to \(host); switched \(switched)")
        case let .clipboardReceived(n):
            let text = clipboard.contents.first { $0.type == "public.utf8-plain-text" }.map { String(decoding: $0.data, as: UTF8.self) }
            say("clipboard received (\(n) item\(n == 1 ? "" : "s")): \(text ?? "-")")
        case let .pairingStarted(host, code):
            say("pairing with \(host), code \(code)")
            if o.autoAccept || o.pair {
                engine.confirmPairing()
                say("confirmed code \(code)")
            }
        case let .paired(host):
            say("paired with \(host)")
            if let side = o.side { engine.setSide(side, for: host) }
        default:
            say("\(event)")
        }
    }
    engine.onStatus = { status in
        guard o.pair, status.pairing == nil else { return }
        let target = status.hosts.first { !$0.paired && (o.peerName == nil || $0.name == o.peerName) }
        let shouldPair: Bool = state.lock.withLock {
            guard !state.pairRequested, target != nil, status.settings.peers.isEmpty else { return false }
            state.pairRequested = true
            return true
        }
        if shouldPair, let target {
            say("found \(target.name) [\(target.hostID)], pairing")
            engine.pair(hostID: target.hostID)
        }
    }

    try engine.start(port: o.port)
    try await Task.sleep(nanoseconds: 300_000_000)
    say("host ID \(identity.hostID), listening on port \(engine.queue.sync { engine.node.port } ?? 0)\(o.bonjour ? ", Bonjour on" : "")")
    engine.setDevices(devices)
    if let s = o.side { for p in engine.settings.peers { engine.setSide(s, for: p.hostID) } }
    engine.updateSettings { $0.enabled = true }

    if let c = o.connect {
        let parts = c.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else { throw FlowSimError.usage("bad --connect \(c)") }
        // With --pair, the status handler pairs over this link once it is up.
        engine.connect(to: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port))
    }

    let deadline = o.duration.map { started.addingTimeInterval($0) }
    var n = 0
    while deadline.map({ Date() < $0 }) ?? true {
        try await Task.sleep(nanoseconds: UInt64(o.every * 1e9))
        guard let edge = o.push, mouse.present else { continue }
        n += 1
        if let text = o.copy {
            clipboard.copy([ClipboardItem(type: "public.utf8-plain-text", data: Data("\(text) #\(n)".utf8))])
        }
        if pointer.push(edge, fraction: 0.5) {
            say("pushed \(edge) edge")
        } else {
            say("not watching the pointer yet (paired peer connected? mouse here?)")
        }
    }
    let (outs, ins) = state.lock.withLock { (state.outs, state.ins) }
    say("done: \(outs) out, \(ins) in")
    engine.stop()
    if o.expect > 0, outs < o.expect || ins < o.expect { exit(2) }
}
