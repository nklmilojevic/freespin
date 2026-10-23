import XCTest
@testable import HIDPP

/// Fake device: answers Root.GetFeature and records sent reports.
final class MockTransport: HIDPPTransport, @unchecked Sendable {
    var sent: [[UInt8]] = []
    var handler: (@Sendable ([UInt8]) -> Void)?
    var features: [UInt16: UInt8] = [0x2121: 0x0B, 0x0001: 0x01]
    var responder: ((HIDPPMessage) -> [UInt8]?)?

    func setInputHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void) { self.handler = handler }

    func send(_ report: [UInt8]) throws {
        sent.append(report)
        guard let msg = HIDPPMessage(raw: report) else { return }
        var reply: [UInt8]?
        if msg.featureIndex == 0, msg.function == 0 {
            let id = UInt16(msg.parameters[0]) << 8 | UInt16(msg.parameters[1])
            reply = [features[id] ?? 0, 0, 0]
        } else {
            reply = responder?(msg)
        }
        guard let params = reply else { return }
        let response = HIDPPMessage(deviceIndex: msg.deviceIndex, featureIndex: msg.featureIndex,
                                    function: msg.function, softwareID: msg.softwareID, parameters: params)
        let bytes = response.encoded()
        let h = handler
        DispatchQueue.global().async { h?(bytes) }
    }

    func inject(_ msg: HIDPPMessage) { handler?(msg.encoded()) }
}

final class HIDPPMessageTests: XCTestCase {
    func testEncodeLong() {
        let m = HIDPPMessage(deviceIndex: 0xFF, featureIndex: 0x0B, function: 2, softwareID: 3, parameters: [0x03, 0, 0])
        let e = m.encoded()
        XCTAssertEqual(e.count, 20)
        XCTAssertEqual(Array(e.prefix(7)), [0x11, 0xFF, 0x0B, 0x23, 0x03, 0, 0])
        XCTAssertEqual(HIDPPMessage(raw: e), m.withPaddedParameters())
    }

    func testWheelMovementDecode() {
        // hiRes=1, periods=2, dV=-3 (0xFFFD), dH=+1
        let ev = WheelEvent(eventIndex: 0, parameters: [0x12, 0xFF, 0xFD, 0x00, 0x01, 0, 0])
        XCTAssertEqual(ev, .movement(highResolution: true, periods: 2, deltaV: -3, deltaH: 1))
        XCTAssertEqual(WheelEvent(eventIndex: 1, parameters: [0x01]), .ratchetSwitch(ratchet: true))
        XCTAssertNil(WheelEvent(eventIndex: 0, parameters: [0x12]))
    }

    func testThumbwheelDecode() {
        // rotation -2, ts 0x0102, status active, flags touch|proximity
        let ev = ThumbwheelEvent(parameters: [0xFF, 0xFE, 0x01, 0x02, 0x02, 0x06])
        XCTAssertEqual(ev?.rotation, -2)
        XCTAssertEqual(ev?.timestamp, 0x0102)
        XCTAssertEqual(ev?.status, .active)
        XCTAssertEqual(ev?.touch, true)
        XCTAssertEqual(ev?.proximity, true)
        XCTAssertEqual(ev?.singleTap, false)
        XCTAssertNil(ThumbwheelEvent(parameters: [0, 1, 2]))
    }

    func testSpecialKeysDecode() {
        XCTAssertEqual(SpecialKeysEvent(eventIndex: 0, parameters: [0x00, 0xC3, 0x00, 0x53, 0, 0, 0, 0]), .pressed([0xC3, 0x53]))
        XCTAssertEqual(SpecialKeysEvent(eventIndex: 0, parameters: [0, 0, 0, 0, 0, 0, 0, 0]), .pressed([]))
        XCTAssertEqual(SpecialKeysEvent(eventIndex: 1, parameters: [0xFF, 0xF6, 0x00, 0x05]), .rawXY(dx: -10, dy: 5))
    }

    func testDivertFlagsMatchOptionsPlus() async throws {
        let t = MockTransport()
        t.features[0x1B04] = 0x09
        t.responder = { msg in msg.featureIndex == 0x09 ? [] : nil }
        let dev = HIDPPDevice(transport: t)
        dev.attach()
        try await dev.divertControl(0xC3, diverted: true, rawXY: true)
        XCTAssertEqual(Array(t.sent.last!.prefix(9)).suffix(5), [0x00, 0xC3, 0x33, 0x00, 0x00])
        try await dev.divertControl(0x53, diverted: true)
        XCTAssertEqual(t.sent.last![6], 0x03)
        try await dev.divertControl(0xC3, diverted: false)
        XCTAssertEqual(t.sent.last![6], 0x22)
    }

    func testWheelModeByteLayout() {
        let mode = WheelMode(diverted: true, highResolution: true, inverted: false)
        XCTAssertEqual(mode.byte0, 0x03)
        XCTAssertEqual(WheelMode(bytes: [0x07, 1, 2]), WheelMode(diverted: true, highResolution: true, inverted: true, priority: 1, rate: 2))
    }
}

final class HIDPPDeviceTests: XCTestCase {
    func testSetWheelModeRoundTrip() async throws {
        let t = MockTransport()
        t.responder = { msg in msg.featureIndex == 0x0B && msg.function == 2 ? Array(msg.parameters.prefix(3)) : nil }
        let dev = HIDPPDevice(transport: t)
        dev.attach()
        let result = try await dev.setWheelMode(WheelMode(diverted: true, highResolution: true, inverted: false))
        XCTAssertTrue(result.diverted && result.highResolution && !result.inverted)
        let last = try XCTUnwrap(t.sent.last)
        XCTAssertEqual(Array(last.prefix(5)), [0x11, 0xFF, 0x0B, 0x20 | (last[3] & 0x0F), 0x03])
    }

    func testUnsupportedFeature() async {
        let t = MockTransport()
        let dev = HIDPPDevice(transport: t)
        dev.attach()
        do {
            _ = try await dev.featureIndex(for: 0x2150)
            XCTFail("expected error")
        } catch HIDPPError.featureNotSupported(let id) {
            XCTAssertEqual(id, 0x2150)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testErrorResponse() async {
        let t = MockTransport()
        let dev = HIDPPDevice(transport: t)
        dev.attach()
        dev.requestTimeout = 1
        t.responder = { [weak t] msg in
            let err = HIDPPMessage(deviceIndex: 0xFF, featureIndex: 0xFF, function: 0, softwareID: 0,
                                   parameters: [msg.featureIndex, msg.function << 4 | msg.softwareID, 0x02])
            let h = t?.handler
            DispatchQueue.global().async { h?(err.encoded()) }
            return nil
        }
        do {
            _ = try await dev.request(featureIndex: 0x0B, function: 1)
            XCTFail("expected error")
        } catch HIDPPError.device(let code) {
            XCTAssertEqual(code, .invalidArgument)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testWheelNotificationDispatch() async throws {
        let t = MockTransport()
        let dev = HIDPPDevice(transport: t)
        dev.attach()
        let got = expectation(description: "wheel event")
        try await dev.onWheelEvent { ev in
            if case .movement(_, 1, 8, 0) = ev { got.fulfill() }
        }
        t.inject(HIDPPMessage(deviceIndex: 0xFF, featureIndex: 0x0B, function: 0, softwareID: 0,
                              parameters: [0x11, 0x00, 0x08, 0x00, 0x00]))
        await fulfillment(of: [got], timeout: 1)
    }
}

extension HIDPPMessage {
    func withPaddedParameters() -> HIDPPMessage {
        var copy = self
        copy.parameters += Array(repeating: 0, count: reportID.parameterLength - parameters.count)
        return copy
    }
}
