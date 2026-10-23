import Foundation
import FreespinCore
import HIDPP
import Observation

/// Drives one pairing attempt on a receiver (Unifying lock or Bolt discovery + passkey).
@MainActor
@Observable
final class PairingModel {
    enum Phase: Equatable {
        case idle
        /// Unifying: the lock is open; the user switches the device off and on.
        case waitingForDevice
        /// Bolt: scanning; the user puts the device into pairing mode.
        case discovering
        case pairing(DiscoveredDevice)
        case passkey(DiscoveredDevice, PasskeyEntry, pressed: Int)
        case succeeded(String)
        case failed(String)
    }

    let receiverID: String
    let kind: ReceiverKind
    var phase: Phase = .idle
    var found: [DiscoveredDevice] = []
    private let manager: DeviceManager
    private var slotsBefore: Set<UInt8> = []
    private var timeoutTask: Task<Void, Never>?

    init(receiverID: String, kind: ReceiverKind, manager: DeviceManager) {
        self.receiverID = receiverID
        self.kind = kind
        self.manager = manager
    }

    var isActive: Bool {
        switch phase {
        case .waitingForDevice, .discovering, .pairing, .passkey: true
        default: false
        }
    }

    func start(connectedSlots: [UInt8]) {
        guard let receiver = manager.receiver(id: receiverID) else { return fail("Receiver disconnected.") }
        slotsBefore = Set(connectedSlots)
        found = []
        Task {
            do {
                if kind == .bolt {
                    phase = .discovering
                    try await receiver.startDiscovery(timeout: 30)
                } else {
                    phase = .waitingForDevice
                    try await receiver.openLock(timeout: 30)
                }
                armTimeout(seconds: 45)
            } catch {
                fail("The receiver refused to start pairing (\(error)).")
            }
        }
    }

    func pair(_ device: DiscoveredDevice) {
        guard let receiver = manager.receiver(id: receiverID) else { return fail("Receiver disconnected.") }
        phase = .pairing(device)
        Task {
            do {
                try? await receiver.cancelDiscovery()
                try await receiver.pair(device)
                armTimeout(seconds: 60)
            } catch {
                if case HIDPPError.device10(0x07) = error {
                    fail("The receiver is busy with another pairing. Wait a moment and try again.")
                } else {
                    fail("Pairing could not start (\(error)).")
                }
            }
        }
    }

    func cancel() {
        let receiver = manager.receiver(id: receiverID)
        let current = phase
        timeoutTask?.cancel()
        phase = .idle
        Task {
            switch current {
            case .waitingForDevice: try? await receiver?.closeLock()
            case .discovering: try? await receiver?.cancelDiscovery()
            case .pairing, .passkey: try? await receiver?.cancelPairing()
            default: break
            }
        }
    }

    /// Feeds receiver notifications for this receiver.
    func handle(_ ev: ReceiverEvent) {
        switch ev {
        case let .discovered(d):
            guard phase == .discovering else { return }
            if let i = found.firstIndex(where: { $0.id == d.id }) { found[i] = d } else { found.append(d) }
        case let .passkey(key):
            if case let .pairing(d) = phase { phase = .passkey(d, PasskeyEntry(passkey: key, method: d.pairingMethod), pressed: 0) }
        case let .passkeyPressed(code):
            if case let .passkey(d, entry, pressed) = phase {
                switch PasskeyProgress(rawValue: code) {
                case .digitIn: phase = .passkey(d, entry, pressed: pressed + 1)
                case .digitOut: phase = .passkey(d, entry, pressed: max(0, pressed - 1))
                case .clear, .start: phase = .passkey(d, entry, pressed: 0)
                default: break
                }
            }
        case let .pairingStatus(_, error) where error != 0:
            if isActive { fail(Self.describeBolt(error)) }
        case let .lock(open, error):
            if phase == .waitingForDevice, !open {
                if error != 0 { fail(Self.describe(error)) }
            }
        case let .connection(slot, linked, _, _, _):
            // Only a pairing we started counts: a device on an already-paired channel just reconnects.
            let pairingStarted: Bool = {
                switch phase {
                case .pairing, .passkey: true
                case .waitingForDevice: kind != .bolt
                default: false
                }
            }()
            guard pairingStarted, linked, !slotsBefore.contains(slot) else { return }
            succeed(slot: slot)
        case let .discoveryStatus(active, error):
            if phase == .discovering, !active, error != 0 { fail(Self.describe(error)) }
        default:
            break
        }
    }

    private func succeed(slot: UInt8) {
        timeoutTask?.cancel()
        let name: String = {
            if case let .pairing(d) = phase { return d.name }
            if case let .passkey(d, _, _) = phase { return d.name }
            return ""
        }()
        phase = .succeeded(name.isEmpty ? "Device paired in slot \(slot)" : "\(name) is paired")
    }

    private func fail(_ message: String) {
        timeoutTask?.cancel()
        phase = .failed(message)
    }

    private func armTimeout(seconds: Double) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.cancel()
            self.phase = .failed("No device was paired in time. Make sure it is in pairing mode and close to the receiver.")
        }
    }

    /// Bolt pairing status errors (0x54 byte 4).
    static func describeBolt(_ code: UInt8) -> String {
        switch code {
        case 0x01: "The device didn't finish the passkey in time."
        case 0x02: "The device rejected the passkey. Check the click sequence and try again."
        default: String(format: "Pairing failed (error 0x%02X).", code)
        }
    }

    static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x01: "Pairing timed out."
        case 0x02: "The device is not supported by this receiver."
        case 0x03: "The receiver has no free slots. Unpair a device first."
        case 0x06: "Pairing was cancelled by the device."
        default: String(format: "Pairing failed (error 0x%02X).", code)
        }
    }
}
