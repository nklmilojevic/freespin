import XCTest
@testable import HIDPP

final class ReceiverTests: XCTestCase {
    func makeReceiver(_ kind: ReceiverKind) -> (MockTransport, HIDPPReceiver) {
        let t = MockTransport()
        t.responder = { msg in msg.featureIndex >= 0x80 && msg.featureIndex <= 0x83 ? [] : nil }
        let d = HIDPPDevice(transport: t, deviceIndex: 0xFF)
        d.attach()
        return (t, HIDPPReceiver(device: d, kind: kind))
    }

    func testUnifyingCommandsMatchOptionsPlus() async throws {
        let (t, r) = makeReceiver(.unifying)
        try await r.openLock()
        XCTAssertEqual(t.sent.last, [0x10, 0xFF, 0x80, 0xB2, 0x01, 0x00, 0x00])
        try await r.closeLock()
        XCTAssertEqual(t.sent.last, [0x10, 0xFF, 0x80, 0xB2, 0x02, 0x00, 0x00])
        try await r.unpair(slot: 3)
        XCTAssertEqual(t.sent.last, [0x10, 0xFF, 0x80, 0xB2, 0x03, 0x03, 0x00])
        try await r.refreshConnections()
        XCTAssertEqual(t.sent.last, [0x10, 0xFF, 0x80, 0x02, 0x02, 0x00, 0x00])
    }

    func testBoltCommandsMatchOptionsPlus() async throws {
        let (t, r) = makeReceiver(.bolt)
        try await r.startDiscovery(timeout: 30)
        XCTAssertEqual(t.sent.last, [0x10, 0xFF, 0x80, 0xC0, 30, 0x01, 0x00])
        // Mouse advertising two-button auth (observed bitmask 0x02) → auth 2, entropy 10, like Options+.
        let mouse = DiscoveredDevice(counter: 1, kind: 2, productID: 0xB034, address: [1, 2, 3, 4, 5, 6],
                                     authentication: 0x02, name: "MX Master 3S")
        try await r.pair(mouse)
        XCTAssertEqual(Array(t.sent.last!.prefix(14)), [0x11, 0xFF, 0x82, 0xC1, 0x01, 0x00, 1, 2, 3, 4, 5, 6, 0x02, 10])
        let keyboard = DiscoveredDevice(counter: 2, kind: 1, productID: 0xB369, address: [6, 5, 4, 3, 2, 1],
                                        authentication: 0x03, name: "MX Keys")
        try await r.pair(keyboard)
        XCTAssertEqual(Array(t.sent.last!.prefix(14)), [0x11, 0xFF, 0x82, 0xC1, 0x01, 0x00, 6, 5, 4, 3, 2, 1, 0x01, 20])
        try await r.cancelPairing()
        XCTAssertEqual(Array(t.sent.last!.prefix(5)), [0x11, 0xFF, 0x82, 0xC1, 0x02])
        try await r.unpair(slot: 2)
        XCTAssertEqual(Array(t.sent.last!.prefix(6)), [0x11, 0xFF, 0x82, 0xC1, 0x03, 0x02])
    }

    func testRegisterError() async {
        let t = MockTransport()
        let d = HIDPPDevice(transport: t, deviceIndex: 0xFF)
        d.attach()
        d.requestTimeout = 1
        t.responder = { [weak t] msg in
            let err: [UInt8] = [0x10, 0xFF, 0x8F, 0x80, msg.function << 4 | msg.softwareID, 0x03, 0x00]
            let h = t?.handler
            DispatchQueue.global().async { h?(err) }
            return nil
        }
        do {
            _ = try await d.register(.setShort, 0xB2, [1, 0, 0])
            XCTFail("expected error")
        } catch HIDPPError.device10(let code) {
            XCTAssertEqual(code, 0x03)
        } catch { XCTFail("\(error)") }
    }

    func testDecodeConnection() {
        var n: [UInt16: (Int, [UInt8])] = [:], p: [UInt16: DiscoveredDevice] = [:]
        let linked = ReceiverEvent.decode([0x10, 0x02, 0x41, 0x10, 0x02, 0x34, 0xB0], names: &n, pending: &p)
        XCTAssertEqual(linked, .connection(slot: 2, linked: true, kind: 2, wirelessPID: 0xB034, protocolID: 0x10))
        let asleep = ReceiverEvent.decode([0x10, 0x02, 0x41, 0x10, 0x42, 0x34, 0xB0], names: &n, pending: &p)
        XCTAssertEqual(asleep, .connection(slot: 2, linked: false, kind: 2, wirelessPID: 0xB034, protocolID: 0x10))
        XCTAssertEqual(ReceiverEvent.decode([0x10, 0x03, 0x40, 0x02, 0, 0, 0], names: &n, pending: &p), .disconnection(slot: 3))
        XCTAssertEqual(ReceiverEvent.decode([0x10, 0xFF, 0x4A, 0x01, 0x00, 0, 0], names: &n, pending: &p), .lock(open: true, error: 0))
    }

    func testDecodeBoltDiscoveryWithName() {
        var n: [UInt16: (Int, [UInt8])] = [:], p: [UInt16: DiscoveredDevice] = [:]
        var info = [UInt8](repeating: 0, count: 20)
        info[0] = 0x11; info[1] = 0xFF; info[2] = 0x4F; info[3] = 0x07; info[4] = 0x00; info[5] = 0
        info[7] = 0x02; info[8] = 0x34; info[9] = 0xB0
        info.replaceSubrange(10..<16, with: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]); info[18] = 0x04
        guard case let .discovered(d)? = ReceiverEvent.decode(info, names: &n, pending: &p) else { return XCTFail() }
        XCTAssertEqual(d.kind, 2)
        XCTAssertEqual(d.productID, 0xB034)
        XCTAssertEqual(d.address, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(d.authentication, 0x04)
        var name = [UInt8](repeating: 0, count: 20)
        name[0] = 0x11; name[1] = 0xFF; name[2] = 0x4F; name[3] = 0x07; name[5] = 1; name[6] = 12
        name.replaceSubrange(7..<19, with: Array("MX Master 3S".utf8))
        guard case let .discovered(named)? = ReceiverEvent.decode(name, names: &n, pending: &p) else { return XCTFail() }
        XCTAssertEqual(named.name, "MX Master 3S")
        XCTAssertEqual(named.id, "aa:bb:cc:dd:ee:ff")
    }

    func testPasskeyAndEntry() {
        var n: [UInt16: (Int, [UInt8])] = [:], p: [UInt16: DiscoveredDevice] = [:]
        var r = [UInt8](repeating: 0, count: 20)
        r[0] = 0x11; r[1] = 0xFF; r[2] = 0x4D
        r.replaceSubrange(4..<10, with: Array("000613".utf8))
        XCTAssertEqual(ReceiverEvent.decode(r, names: &n, pending: &p), .passkey("000613"))
        XCTAssertEqual(PasskeyEntry(passkey: "123456", keyboardLike: true), .typeDigits("123456"))
        // Observed passkey 943844 = 0b1110_0110_0110_1110_0100 (20 bits, MSB first).
        guard case let .clickPattern(clicks) = PasskeyEntry(passkey: "943844", keyboardLike: false) else { return XCTFail() }
        XCTAssertEqual(clicks.count, 20)
        XCTAssertEqual(clicks.map { $0 ? "R" : "L" }.joined(), "RRRLLRRLLRRLRRRLLRLL")
        guard case let .clickPattern(ten) = PasskeyEntry(passkey: "613", method: .twoButtons) else { return XCTFail() }
        XCTAssertEqual(ten.count, 10)
        XCTAssertEqual(PasskeyEntry(passkey: "000613", keyboardLike: false, entropy: 10),
                       .clickPattern([true, false, false, true, true, false, false, true, false, true]))
    }

    func testDiscoveryStatusDecode() {
        var n: [UInt16: (Int, [UInt8])] = [:], p: [UInt16: DiscoveredDevice] = [:]
        // Observed on a Bolt receiver right after startDiscovery: 10 ff 53 00 00 00 00
        XCTAssertEqual(ReceiverEvent.decode([0x10, 0xFF, 0x53, 0x00, 0x00, 0, 0], names: &n, pending: &p),
                       .discoveryStatus(active: true, error: 0))
        XCTAssertEqual(ReceiverEvent.decode([0x10, 0xFF, 0x53, 0x01, 0x00, 0, 0], names: &n, pending: &p),
                       .discoveryStatus(active: false, error: 0))
    }

    func testKindByProductID() {
        XCTAssertEqual(ReceiverKind(productID: 0xC548), .bolt)
        XCTAssertEqual(ReceiverKind(productID: 0xC52B), .unifying)
        XCTAssertEqual(ReceiverKind(productID: 0xC547), .lightspeed)
    }
}
