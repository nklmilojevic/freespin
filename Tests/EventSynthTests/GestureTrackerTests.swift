import XCTest
@testable import EventSynth

final class GestureTrackerTests: XCTestCase {
    func testClickBelowThreshold() {
        var g = GestureTracker()
        g.begin()
        g.add(dx: 10, dy: -20)
        XCTAssertEqual(g.finish(), .click)
    }

    func testDropsStaleFirstReportAndJumps() {
        var g = GestureTracker()
        g.begin()
        g.add(dx: -1810, dy: -370)  // stale first report
        g.add(dx: 0, dy: -30)
        g.add(dx: 900, dy: 0)       // implausible jump
        g.add(dx: 0, dy: -30)
        XCTAssertEqual(g.finish(), .up)
    }

    func testDirections() {
        func run(_ dx: Int, _ dy: Int) -> GestureDirection {
            var g = GestureTracker()
            g.begin()
            g.add(dx: 0, dy: 0)
            for _ in 0..<10 { g.add(dx: dx, dy: dy) }
            return g.finish()
        }
        XCTAssertEqual(run(0, -10), .up)
        XCTAssertEqual(run(0, 10), .down)
        XCTAssertEqual(run(-10, 2), .left)
        XCTAssertEqual(run(10, -2), .right)
    }

    func testActionCodableRoundTrip() throws {
        let actions: [ButtonAction] = ButtonAction.catalog + [.keystroke(keyCode: 0x24, modifiers: 0x100000)]
        let data = try JSONEncoder().encode(actions)
        XCTAssertEqual(try JSONDecoder().decode([ButtonAction].self, from: data), actions)
    }
}
