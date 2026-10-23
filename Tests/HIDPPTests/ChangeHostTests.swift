import XCTest
@testable import HIDPP

final class ChangeHostTests: XCTestCase {
    private func device(_ transport: MockTransport) -> HIDPPDevice {
        transport.features[0x1814] = 0x09
        transport.features[0x0003] = 0x02
        let d = HIDPPDevice(transport: transport)
        d.attach()
        d.requestTimeout = 0.3
        return d
    }

    func testHostInfo() async throws {
        let t = MockTransport()
        t.responder = { msg in msg.featureIndex == 0x09 && msg.function == 0 ? [3, 1, 1] : nil }
        let info = try await device(t).hostInfo()
        XCTAssertEqual(info, HostInfo(count: 3, current: 1, flags: 1))
    }

    func testIdentityUsesUnitAndModelID() async throws {
        let t = MockTransport()
        // entityCount, unitID(4), transport(2), modelID(6), extendedModelID, capabilities
        t.responder = { msg in
            msg.featureIndex == 0x02 ? [3, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x0E, 0xB0, 0x34, 0x40, 0x82, 0, 0, 0, 0] : nil
        }
        let identity = try await device(t).identity()
        let id = try XCTUnwrap(identity)
        XCTAssertEqual(id.key, "deadbeef")
        XCTAssertEqual(id.modelID, [0xB0, 0x34, 0x40, 0x82, 0, 0])
        XCTAssertNil(DeviceIdentity.decode([3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "all-zero unit ID is not an identity")
    }

    func testSwitchHostSendsSetCurrentHostWithoutWaiting() async throws {
        let t = MockTransport()
        let d = device(t)
        let started = Date()
        try await d.switchHost(to: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "no response is awaited")
        let last = try XCTUnwrap(t.sent.last)
        XCTAssertEqual(last[2], 0x09, "ChangeHost feature index")
        XCTAssertEqual(last[3] >> 4, 1, "fn 1 SetCurrentHost")
        XCTAssertEqual(last[4], 2)
    }
}
