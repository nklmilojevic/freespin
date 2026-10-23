import CoreGraphics
import Network
import XCTest
@testable import Flow

/// One simulated computer: an engine on loopback TCP with fake devices, pointer and clipboard.
final class TestHost: @unchecked Sendable {
    let name: String
    let engine: FlowEngine
    let pointer = ScriptedPointer()
    let clipboard = MemoryClipboard()
    let dir: URL
    private let lock = NSLock()
    private var log: [FlowEvent] = []
    private var lastStatus = FlowStatus()

    init(_ name: String, identity: FlowIdentity = FlowIdentity(), dir: URL? = nil) throws {
        self.name = name
        self.dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        engine = FlowEngine(identity: identity, name: name, store: FlowSettingsStore(url: self.dir.appendingPathComponent("flow.json")),
                            pointer: pointer, clipboard: clipboard, bonjour: false)
        engine.readyTimeout = 2
        engine.cooldown = 0.2
        engine.onEvent = { [weak self] e in self?.lock.withLock { self?.log.append(e) } }
        engine.onStatus = { [weak self] s in self?.lock.withLock { self?.lastStatus = s } }
        try engine.start()
    }

    var events: [FlowEvent] { lock.withLock { log } }
    var status: FlowStatus { lock.withLock { lastStatus } }
    var hostID: String { engine.node.identity.hostID }
    var port: UInt16? { engine.queue.sync { engine.node.port } }

    func endpoint() -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port!)!) }
}

func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

final class FlowEngineTests: XCTestCase {
    let unit = "a1b2c3d4"
    let keyboardUnit = "0badf00d"
    var hosts: [TestHost] = []

    override func tearDown() {
        hosts.forEach { $0.engine.stop() }
        hosts.removeAll()
    }

    private func makeHost(_ name: String) throws -> TestHost {
        let h = try TestHost(name)
        hosts.append(h)
        waitUntil("\(name) listening") { h.port != nil }
        return h
    }

    private func mouse(channel: Int, present: Bool) -> SimulatedDevice {
        let d = SimulatedDevice(record: FlowDeviceRecord(unitID: unit, name: "MX Master 3S", kind: .mouse,
                                                        channel: channel, channelCount: 3))
        d.present = present
        return d
    }

    /// Connects `a` → `b` and pairs them, confirming on both sides.
    private func pair(_ a: TestHost, _ b: TestHost) {
        a.engine.connect(to: b.endpoint())
        waitUntil("link") { a.events.contains(.linkUp(hostID: b.hostID, trusted: false)) }
        a.engine.pair(hostID: b.hostID)
        waitUntil("pairing request on \(b.name)") { b.status.pairing != nil }
        XCTAssertEqual(a.status.pairing?.code, b.status.pairing?.code, "both computers show the same code")
        XCTAssertEqual(b.status.pairing?.outgoing, false)
        a.engine.confirmPairing()
        b.engine.confirmPairing()
        waitUntil("paired") { a.events.contains(.paired(hostID: b.hostID)) && b.events.contains(.paired(hostID: a.hostID)) }
    }

    func testPairingStoresPeersOnBothSidesFacingEachOther() throws {
        let a = try makeHost("Studio"), b = try makeHost("Laptop")
        pair(a, b)
        let pa = try XCTUnwrap(a.engine.settings.peer(b.hostID)), pb = try XCTUnwrap(b.engine.settings.peer(a.hostID))
        XCTAssertEqual(pa.name, "Laptop")
        XCTAssertEqual(pa.side, .right)
        XCTAssertEqual(pb.side, .left)
        XCTAssertTrue(a.engine.settings.enabled, "first pairing turns Flow on")
    }

    func testCancelledPairingStoresNothing() throws {
        let a = try makeHost("A"), b = try makeHost("B")
        a.engine.connect(to: b.endpoint())
        waitUntil("link") { a.events.contains(.linkUp(hostID: b.hostID, trusted: false)) }
        a.engine.pair(hostID: b.hostID)
        waitUntil("request") { b.status.pairing != nil }
        b.engine.cancelPairing()
        waitUntil("cancel reaches A") { a.events.contains(.pairingCancelled(hostID: b.hostID)) }
        a.engine.confirmPairing()
        XCTAssertNil(a.engine.settings.peer(b.hostID))
        XCTAssertNil(b.engine.settings.peer(a.hostID))
    }

    func testUnpairedComputerCannotDriveFlow() throws {
        let a = try makeHost("A"), b = try makeHost("B")
        a.engine.connect(to: b.endpoint())
        waitUntil("link") { b.events.contains(.linkUp(hostID: a.hostID, trusted: false)) }
        a.engine.setDevices([mouse(channel: 0, present: true)])
        a.engine.queue.sync {}
        XCTAssertFalse(a.pointer.isRunning, "no paired peer, so Flow doesn't watch the pointer")
        XCTAssertTrue(b.pointer.warps.isEmpty)
    }

    func testFlowMovesMouseClipboardAndKeyboardThenComesBack() throws {
        let a = try makeHost("Studio"), b = try makeHost("Laptop")
        pair(a, b)

        // The same physical mouse: channel 0 on A (connected), channel 1 on B (away).
        let mouseA = mouse(channel: 0, present: true), mouseB = mouse(channel: 1, present: false)
        let keyboardA = SimulatedDevice(record: FlowDeviceRecord(unitID: keyboardUnit, name: "MX Keys", kind: .keyboard,
                                                                 channel: 0, channelCount: 3))
        let keyboardB = SimulatedDevice(record: FlowDeviceRecord(unitID: keyboardUnit, name: "MX Keys", kind: .keyboard,
                                                                 channel: 1, channelCount: 3))
        keyboardB.present = false
        // A switch moves the device to whichever computer owns the new channel.
        mouseA.onSwitch = { ch in mouseB.present = ch == 1 }
        mouseB.onSwitch = { ch in mouseA.present = ch == 0 }
        keyboardA.onSwitch = { ch in keyboardB.present = ch == 1 }
        keyboardB.onSwitch = { ch in keyboardA.present = ch == 0 }
        a.engine.setDevices([mouseA, keyboardA])
        b.engine.setDevices([mouseB, keyboardB])
        waitUntil("inventories") {
            a.engine.settings.peer(b.hostID)?.channel(for: unit) == 1 && b.engine.settings.peer(a.hostID)?.channel(for: unit) == 0
        }
        waitUntil("A watches the pointer") { a.pointer.isRunning }

        a.clipboard.copy([ClipboardItem(type: "public.utf8-plain-text", data: Data("from studio".utf8))])
        XCTAssertTrue(a.pointer.push(.right, fraction: 0.25))
        waitUntil("A flowed out") { a.events.contains { if case .flowedOut = $0 { return true }; return false } }

        XCTAssertEqual(mouseA.switches, [1], "A told the mouse to go to B's channel")
        XCTAssertEqual(keyboardA.switches, [1], "linked keyboard follows")
        XCTAssertEqual(a.pointer.retreats, [.right])
        let warp = try XCTUnwrap(b.pointer.warps.first, "B placed its cursor")
        XCTAssertEqual(warp.x, 2, "entered through B's left edge, where A sits")
        XCTAssertEqual(warp.y, 270, accuracy: 1)
        waitUntil("clipboard on B") { b.clipboard.contents.first?.data == Data("from studio".utf8) }
        XCTAssertTrue(mouseB.present)

        // Back from B through its left edge after the cooldown.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(b.pointer.push(.left, fraction: 0.5))
        waitUntil("B flowed out") { b.events.contains { if case .flowedOut = $0 { return true }; return false } }
        XCTAssertEqual(mouseB.switches, [0])
        XCTAssertEqual(a.pointer.warps.last?.x, 1917, "entered through A's right edge")
        XCTAssertTrue(mouseA.present)
    }

    func testFlowSkipsWhenMouseIsNotHereOrEdgeHasNoPeer() throws {
        let a = try makeHost("A"), b = try makeHost("B")
        pair(a, b)
        let m = mouse(channel: 0, present: false)
        a.engine.setDevices([m])
        b.engine.setDevices([mouse(channel: 2, present: false)])
        waitUntil("inventory") { a.engine.settings.peer(b.hostID)?.channel(for: unit) == 2 }
        waitUntil("pointer") { a.pointer.isRunning }
        a.pointer.push(.left)  // nobody on the left
        a.pointer.push(.right)
        waitUntil("skip") { a.events.contains { if case .skipped = $0 { return true }; return false } }
        XCTAssertTrue(m.switches.isEmpty)
        XCTAssertTrue(b.pointer.warps.isEmpty)
    }

    func testRequireControlKey() throws {
        let a = try makeHost("A"), b = try makeHost("B")
        pair(a, b)
        a.engine.updateSettings { $0.requireControl = true }
        let m = mouse(channel: 0, present: true)
        a.engine.setDevices([m])
        b.engine.setDevices([mouse(channel: 1, present: false)])
        waitUntil("inventory") { a.engine.settings.peer(b.hostID)?.channel(for: unit) == 1 }
        waitUntil("pointer") { a.pointer.isRunning }
        a.pointer.push(.right, control: false)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(m.switches.isEmpty)
        a.pointer.push(.right, control: true)
        waitUntil("switched") { m.switches == [1] }
    }

    func testPairedComputersReconnectTrustedAfterRestart() throws {
        let idA = FlowIdentity(), idB = FlowIdentity()
        var a = try TestHost("A", identity: idA), b = try TestHost("B", identity: idB)
        hosts += [a, b]
        waitUntil("ports") { a.port != nil && b.port != nil }
        pair(a, b)
        a.engine.stop()
        b.engine.stop()
        // Same identities and settings files: no pairing needed.
        a = try TestHost("A", identity: idA, dir: a.dir)
        b = try TestHost("B", identity: idB, dir: b.dir)
        hosts += [a, b]
        waitUntil("ports") { a.port != nil && b.port != nil }
        b.engine.connect(to: a.endpoint())
        waitUntil("trusted link") { a.events.contains(.linkUp(hostID: b.hostID, trusted: true)) }
    }

    func testKeyMismatchIsRejected() throws {
        let a = try makeHost("A"), b = try makeHost("B")
        pair(a, b)
        // An impostor reusing B's host ID entry with a different key.
        a.engine.updateSettings { s in
            guard var p = s.peer(b.hostID) else { return }
            p.signingKey = FlowIdentity().publicKey
            s.upsert(peer: p)
        }
        b.engine.connect(to: a.endpoint())
        waitUntil("rejection") { a.events.contains { if case let .error(m) = $0 { return m.contains("key changed") }; return false } }
    }
}
