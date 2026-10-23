import CoreGraphics
import CryptoKit
import XCTest
@testable import Flow

final class FrameAndMessageTests: XCTestCase {
    func testFramesSurviveArbitrarySplits() throws {
        let payloads = [Data("hello".utf8), Data(), Data(repeating: 7, count: 70_000)]
        let stream = payloads.map(FrameCodec.encode).reduce(Data(), +)
        var decoder = FrameDecoder()
        var out: [Data] = []
        var i = 0
        while i < stream.count {
            let n = min(1 + i % 13, stream.count - i)
            out += try decoder.feed(stream.subdata(in: i..<(i + n)))
            i += n
        }
        XCTAssertEqual(out, payloads)
    }

    func testOversizedFrameIsRejected() {
        var decoder = FrameDecoder(limit: 10)
        XCTAssertThrowsError(try decoder.feed(Data([0, 0, 0, 11]))) { error in
            XCTAssertEqual(error as? FlowError, .frameTooLarge(11))
        }
    }

    func testMessagesRoundTrip() throws {
        let messages: [FlowMessage] = [
            .inventory([FlowDeviceRecord(unitID: "01020304", name: "MX Master 3S", kind: .mouse, channel: 1, channelCount: 3)]),
            .pairRequest(name: "Studio"), .pairConfirm, .pairCancel, .unpair,
            .incoming(id: 42, edge: .left, fraction: 0.25), .ready(id: 42),
            .clipboard([ClipboardItem(type: "public.utf8-plain-text", data: Data("hi".utf8))]), .ping, .pong,
        ]
        for m in messages { XCTAssertEqual(try FlowMessage.decode(try m.encoded()), m) }
    }
}

final class HandshakeTests: XCTestCase {
    /// Runs both sides in memory; `tamper` may rewrite frames in flight (initiator → responder).
    private func run(_ a: FlowIdentity = FlowIdentity(), _ b: FlowIdentity = FlowIdentity(),
                     tamper: (Data) -> Data = { $0 }) throws -> (Handshake, Handshake) {
        var i = Handshake(role: .initiator, identity: a, name: "A")
        var r = Handshake(role: .responder, identity: b, name: "B")
        let helloI = tamper(try i.start())
        let helloR = try r.start()
        let authR = try r.receive(helloI)
        let authI = try i.receive(helloR)
        _ = try i.receive(authR[0])
        _ = try r.receive(tamper(authI[0]))
        return (i, r)
    }

    func testBothSidesAgreeOnPeerAndCode() throws {
        let a = FlowIdentity(), b = FlowIdentity()
        let (i, r) = try run(a, b)
        let pi = try XCTUnwrap(i.result?.peer), pr = try XCTUnwrap(r.result?.peer)
        XCTAssertEqual(pi.hostID, b.hostID)
        XCTAssertEqual(pr.hostID, a.hostID)
        XCTAssertEqual(pi.name, "B")
        XCTAssertEqual(pi.pairingCode, pr.pairingCode)
        XCTAssertEqual(pi.pairingCode.count, 6)
    }

    func testSessionEncryptsBothWaysAndRejectsReplayAndTampering() throws {
        let (i, r) = try run()
        var si = try XCTUnwrap(i.result?.session), sr = try XCTUnwrap(r.result?.session)
        let f1 = try si.seal(Data("one".utf8))
        let f2 = try si.seal(Data("two".utf8))
        XCTAssertEqual(try sr.open(f1), Data("one".utf8))
        XCTAssertThrowsError(try sr.open(f1)) { XCTAssertEqual($0 as? FlowError, .outOfOrder) }
        var bad = f2
        bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try sr.open(bad)) { XCTAssertEqual($0 as? FlowError, .decryptFailed) }
        XCTAssertEqual(try sr.open(f2), Data("two".utf8))
        XCTAssertEqual(try si.open(try sr.seal(Data("back".utf8))), Data("back".utf8))
    }

    func testSwappedEphemeralKeyFailsSignature() {
        // A man in the middle replacing the initiator's ephemeral key changes the transcript.
        XCTAssertThrowsError(try run(tamper: { frame in
            guard var hello = try? PropertyListDecoder().decode(HelloFrame.self, from: frame) else { return frame }
            hello.ephemeralKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            return (try? PropertyListEncoder().encode(hello)) ?? frame
        })) { XCTAssertEqual($0 as? FlowError, .badSignature) }
    }

    func testHostIDIsBoundToKey() {
        let id = FlowIdentity()
        XCTAssertEqual(id.hostID, FlowIdentity.hostID(for: id.publicKey))
        XCTAssertEqual(id.hostID.count, 16)
        XCTAssertNotEqual(id.hostID, FlowIdentity().hostID)
    }
}

final class EdgeGeometryTests: XCTestCase {
    // Main 1920×1080 at origin, a second 1280×1024 display to its right, top-aligned.
    let layout = EdgeGeometry(displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                         CGRect(x: 1920, y: 0, width: 1280, height: 1024)])

    func testOuterEdgesHitAndSharedEdgeDoesNot() {
        XCTAssertEqual(layout.hit(at: CGPoint(x: 0, y: 540), delta: CGVector(dx: -3, dy: 0))?.edge, .left)
        XCTAssertEqual(layout.hit(at: CGPoint(x: 3199, y: 100), delta: CGVector(dx: 4, dy: 0))?.edge, .right)
        XCTAssertNil(layout.hit(at: CGPoint(x: 1919, y: 500), delta: CGVector(dx: 5, dy: 0)), "edge between displays")
        XCTAssertNil(layout.hit(at: CGPoint(x: 0, y: 540), delta: CGVector(dx: 3, dy: 0)), "moving away from the edge")
        // Below the shorter display, the main display's right edge is an outer edge too.
        XCTAssertEqual(layout.hit(at: CGPoint(x: 1919, y: 1050), delta: CGVector(dx: 2, dy: 0))?.edge, .right)
        XCTAssertEqual(layout.hit(at: CGPoint(x: 2500, y: 1023), delta: CGVector(dx: 0, dy: 2))?.edge, .bottom)
    }

    func testFractionAlongBoundingBox() throws {
        let hit = try XCTUnwrap(layout.hit(at: CGPoint(x: 0, y: 270), delta: CGVector(dx: -1, dy: 0)))
        XCTAssertEqual(hit.fraction, 0.25, accuracy: 0.001)
    }

    func testCornersAreIgnoredWithInset() {
        XCTAssertNil(layout.hit(at: CGPoint(x: 0, y: 5), delta: CGVector(dx: -1, dy: 0), cornerInset: 20))
        XCTAssertNotNil(layout.hit(at: CGPoint(x: 0, y: 500), delta: CGVector(dx: -1, dy: 0), cornerInset: 20))
    }

    func testEntryPointsLandInsideOutermostDisplay() throws {
        let right = try XCTUnwrap(layout.entryPoint(edge: .right, fraction: 0.5))
        XCTAssertEqual(right.x, 3197)
        XCTAssertTrue(layout.contains(right))
        // Low on the right edge: the second display is too short, so the main display's edge is the entry.
        let lowRight = try XCTUnwrap(layout.entryPoint(edge: .right, fraction: 0.99))
        XCTAssertTrue(layout.contains(lowRight))
        let left = try XCTUnwrap(layout.entryPoint(edge: .left, fraction: 0))
        XCTAssertEqual(left, CGPoint(x: 2, y: 0))
        let top = try XCTUnwrap(layout.entryPoint(edge: .top, fraction: 1))
        XCTAssertTrue(layout.contains(top))
    }

    func testPushFilterNeedsRepeatedPushesWithinWindow() {
        var f = EdgePushFilter(requiredPushes: 3, window: 0.3)
        XCTAssertNil(f.feed(.left, at: 0))
        XCTAssertNil(f.feed(.left, at: 0.1))
        XCTAssertEqual(f.feed(.left, at: 0.2), .left)
        XCTAssertNil(f.feed(.left, at: 1.0))
        XCTAssertNil(f.feed(nil, at: 1.1), "leaving the edge resets")
        XCTAssertNil(f.feed(.left, at: 1.2))
        XCTAssertNil(f.feed(.left, at: 1.9), "too slow: window restarts")
    }
}

final class FlowSettingsTests: XCTestCase {
    func testDecodesOlderFilesWithDefaults() throws {
        let s = try JSONDecoder().decode(FlowSettings.self, from: Data(#"{"enabled": true}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.syncClipboard)
        XCTAssertTrue(s.peers.isEmpty)
    }

    func testStorePersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        FlowSettingsStore(url: url).update { $0.requireControl = true }
        XCTAssertTrue(FlowSettingsStore(url: url).settings.requireControl)
    }
}
