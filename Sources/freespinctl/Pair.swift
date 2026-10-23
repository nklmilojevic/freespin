import Foundation
import FreespinCore
import HIDPP

/// Interactive pairing from the terminal; prints every receiver event.
func runPairing() async throws {
    let (manager, _) = try await discover(timeout: 3.5)
    guard let r = manager.allReceivers.first, let rx = manager.receiver(id: r.id) else {
        print("no receiver found")
        exit(1)
    }
    guard r.kind.supportsPairing else {
        print("\(r.name) (\(r.kind.rawValue)) does not support pairing")
        exit(1)
    }
    let before = Set(r.connectedSlots)
    let state = PairState()
    manager.onReceiverEvent = { id, ev in
        guard id == r.id else { return }
        print("· \(ev)")
        switch ev {
        case let .discovered(d) where state.claim():
            print("pairing with \(d.name.isEmpty ? d.kindName : d.name) [\(d.id)] method=\(d.pairingMethod) entropy=\(d.pairingMethod.entropy)")
            state.device = d
            Task {
                try? await rx.cancelDiscovery()
                do { try await rx.pair(d) } catch { print("pair failed: \(error)"); exit(1) }
            }
        case let .passkey(key):
            switch PasskeyEntry(passkey: key, method: state.device?.pairingMethod ?? .twoButtons) {
            case let .typeDigits(code): print(">>> type \(code) on the keyboard, then Return")
            case let .clickPattern(clicks):
                let groups = stride(from: 0, to: clicks.count, by: 5).map { i in
                    clicks[i..<min(i + 5, clicks.count)].map { $0 ? "R" : "L" }.joined()
                }
                print(">>> click (\(clicks.count)): " + groups.joined(separator: " ") + "   then both buttons together")
            }
        case let .passkeyPressed(code):
            if let p = PasskeyProgress(rawValue: code) { print("    passkey \(p)") }
        case let .pairingStatus(_, error) where error != 0:
            print("pairing failed: " + (error == 0x02 ? "passkey rejected" : error == 0x01 ? "timed out" : String(format: "error 0x%02X", error)))
            exit(1)
        case let .lock(open, error) where !open && error != 0:
            print("pairing failed: \(PairingErrors.describe(error))")
            exit(1)
        case let .connection(slot, true, _, _, _) where !before.contains(slot) && (r.kind != .bolt || state.device != nil):
            print("paired in slot \(slot)")
            exit(0)
        case let .connection(slot, true, _, _, _):
            print("(slot \(slot) reconnected; it was already paired — put the device in pairing mode to pair it again)")
        default:
            break
        }
    }
    if r.kind == .bolt {
        print("Bolt: put the device in pairing mode (hold its channel button until the light blinks fast)…")
        try await rx.startDiscovery(timeout: 30)
    } else {
        print("Unifying: turn the device off and on…")
        try await rx.openLock(timeout: 30)
    }
    try await Task.sleep(nanoseconds: 90_000_000_000)
    print("timed out")
    exit(1)
}

final class PairState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    var device: DiscoveredDevice?

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

enum PairingErrors {
    static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x01: "timed out"
        case 0x02: "device not supported"
        case 0x03: "receiver has no free slots"
        case 0x06: "cancelled by the device"
        default: String(format: "error 0x%02X", code)
        }
    }
}
