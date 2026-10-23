import XCTest
@testable import EventSynth

final class DockSwipeTrackerTests: XCTestCase {
    func testClickWithoutMovement() {
        var t = DockSwipeTracker()
        t.begin()
        XCTAssertNil(t.add(dx: 900, dy: 900, time: 0))  // stale first report
        XCTAssertNil(t.add(dx: 3, dy: 2, time: 0.01))
        XCTAssertEqual(t.end(), .click)
    }

    func testHorizontalSwipeLifecycle() {
        var t = DockSwipeTracker()
        t.begin()
        _ = t.add(dx: 0, dy: 0, time: 0)
        var outputs: [DockSwipeTracker.Output] = []
        for i in 1...10 {
            if let o = t.add(dx: 10, dy: 1, time: Double(i) * 0.01) { outputs.append(o) }
        }
        guard case let .swipe(axis, phase, _, _) = outputs.first else { return XCTFail("no swipe") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(phase, .began)
        guard case let .swipe(_, endPhase, offset, velocity) = t.end() else { return XCTFail("no end") }
        XCTAssertEqual(endPhase, .ended)
        XCTAssertEqual(offset, -100.0 / 700.0, accuracy: 1e-9)
        XCTAssertLessThan(velocity, 0)
    }

    func testVerticalAxisLocks() {
        var t = DockSwipeTracker()
        t.begin()
        _ = t.add(dx: 0, dy: 0, time: 0)
        var first: DockSwipeTracker.Output?
        for i in 1...6 {
            let o = t.add(dx: 1, dy: -10, time: Double(i) * 0.01)
            if first == nil { first = o }
        }
        guard case let .swipe(axis, _, _, _) = first else { return XCTFail("no swipe") }
        XCTAssertEqual(axis, .vertical)
        // Later horizontal motion does not change the locked axis.
        guard case let .swipe(axis2, _, _, _) = t.add(dx: 50, dy: 0, time: 0.2) else { return XCTFail() }
        XCTAssertEqual(axis2, .vertical)
    }
}
