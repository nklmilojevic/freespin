import EventSynth
import Foundation
import HIDPP
import FreespinCore

let usage = """
usage: freespinctl <command>

  list                 list connected Logitech HID++ devices
  features             list HID++ features of each device
  wheel                show 0x2121 wheel capability and mode
  controls             list divertable buttons (0x1B04)
  receivers            list Bolt/Unifying/LIGHTSPEED receivers and their connected devices
  pair                 pair a new device to the first receiver (Bolt: auto-picks the first device found)
  unpair <slot>        unpair the device in <slot> from the first receiver
  wheel-mode <divert> <hires> <invert>   set wheel mode (0/1 each)
  sniff                print every HID++ notification (Ctrl-C to stop)
  trace <file.jsonl>   passively record 0x2121 wheel reports + scroll CGEvents (golden traces)
  run                  run the native scroll engine headless (Ctrl-C restores the wheel)
  hosts                show Easy-Switch channels (0x1814) and unit IDs (0x0003) used by Flow (read-only)
  flow-sim [options]   headless Flow node with a simulated mouse (freespinctl flow-sim --help)
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(64)
}

func hex(_ v: UInt16) -> String { String(format: "0x%04X", v) }

/// Collects sessions for a short discovery window.
/// Kept alive for the whole process: releasing the IOHIDManager closes its devices.
nonisolated(unsafe) var activeManager: DeviceManager?

func discover(timeout: TimeInterval = 2.5, drive: Bool = false) async throws -> (DeviceManager, [DeviceSession]) {
    let manager = DeviceManager(drive: drive)
    activeManager = manager
    manager.onLog = { FileHandle.standardError.write(("· " + $0 + "\n").data(using: .utf8)!) }
    try manager.start()
    try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
    return (manager, manager.allSessions)
}

func waitForInterrupt() async {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        source.setEventHandler { c.resume() }
        source.resume()
    }
}

let task = Task {
    do {
        switch command {
        case "list":
            let (_, sessions) = try await discover()
            if sessions.isEmpty { print("no HID++ devices found") }
            for s in sessions {
                let snap = s.snapshot
                var line = "\(snap.name)  pid=\(String(format: "%04x", snap.productID))  \(snap.transport)  idx=\(snap.deviceIndex)"
                if let b = snap.battery { line += "  battery=\(b.percent.map { "\($0)%" } ?? b.level) \(b.charging)" }
                if let d = snap.dpi { line += "  dpi=\(d)" }
                print(line)
            }
        case "features":
            let (_, sessions) = try await discover()
            for s in sessions {
                print("\(s.snapshot.name):")
                for f in s.snapshot.features {
                    print("  [\(String(format: "%02d", f.index))] \(hex(f.id)) v\(f.version)\(f.known.map { "  \($0)" } ?? "")")
                }
            }
        case "wheel":
            let (_, sessions) = try await discover()
            for s in sessions where s.snapshot.has(.hiResWheel) {
                let mode = try await s.device.wheelMode()
                print("\(s.snapshot.name): capability=\(String(describing: s.snapshot.wheel)) mode=\(mode)")
                if let t = s.snapshot.thumbwheel { print("  thumbwheel: \(t) multiplier=\(t.multiplier)") }
            }
        case "controls":
            let (_, sessions) = try await discover()
            for s in sessions {
                print("\(s.snapshot.name):")
                for c in s.snapshot.controls {
                    let rep = (try? await s.device.request(feature: FeatureID.specialKeys.rawValue, function: 2,
                                                           parameters: [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF)])) ?? []
                    print(String(format: "  0x%04X  %@  task=0x%04X  rawXY=%@  action=%@  reporting=%@", c.cid, c.name, c.taskID,
                                 c.rawXY ? "yes" : "no", s.settings.action(for: c.cid).title,
                                 rep.prefix(5).map { String(format: "%02x", $0) }.joined(separator: " ")))
                }
            }
        case "receivers":
            let (manager, _) = try await discover(timeout: 3.5)
            if manager.allReceivers.isEmpty { print("no receivers found") }
            for r in manager.allReceivers {
                print("\(r.name) [\(r.kind.rawValue)]")
                for s in manager.allSessions {
                    if let slot = manager.receiverSlot(of: s), slot.receiver == r.id {
                        print("  slot \(slot.slot): \(s.snapshot.name)")
                    }
                }
            }
        case "pair":
            try await runPairing()
        case "unpair":
            guard args.count == 2, let slot = UInt8(args[1]) else { print(usage); exit(64) }
            let (manager, _) = try await discover(timeout: 3.5)
            guard let r = manager.allReceivers.first, let rx = manager.receiver(id: r.id) else { print("no receiver"); exit(1) }
            try await rx.unpair(slot: slot)
            print("unpaired slot \(slot) from \(r.name)")
        case "wheel-mode":
            guard args.count == 4 else { print(usage); exit(64) }
            let mode = WheelMode(diverted: args[1] == "1", highResolution: args[2] == "1", inverted: args[3] == "1")
            let (_, sessions) = try await discover()
            for s in sessions where s.snapshot.has(.hiResWheel) {
                print("\(s.snapshot.name): \(try await s.device.setWheelMode(mode))")
            }
        case "sniff":
            let (_, sessions) = try await discover()
            for s in sessions {
                let name = s.snapshot.name
                s.device.onAnyNotification { msg in print("\(name): \(msg)") }
            }
            print("sniffing \(sessions.count) device(s); Ctrl-C to stop")
            await waitForInterrupt()
        case "trace":
            guard args.count == 2 else { print(usage); exit(64) }
            try await runTrace(path: args[1])
        case "hosts":
            let (_, sessions) = try await discover()
            for s in sessions where s.snapshot.has(.changeHost) {
                let host = try? await s.device.hostInfo()
                let id = try? await s.device.identity()
                print("\(s.snapshot.name)  unit=\(id?.key ?? "?")  channel=\(host.map { "\($0.current + 1)/\($0.count)" } ?? "?")")
            }
        case "flow-sim":
            if args.contains("--help") { print(flowSimUsage); exit(0) }
            try await runFlowSim(Array(args.dropFirst()))
        case "run":
            guard ScrollEventPoster.hasPostPermission(prompt: true) else {
                print("Accessibility permission is required to post scroll events.")
                exit(1)
            }
            let (manager, sessions) = try await discover(drive: true)
            print("driving \(sessions.filter { $0.snapshot.has(.hiResWheel) }.count) wheel(s); Ctrl-C to restore and quit")
            await waitForInterrupt()
            await manager.stopAll()
            print("wheels restored")
        default:
            print(usage)
            exit(64)
        }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

CFRunLoopRun()
