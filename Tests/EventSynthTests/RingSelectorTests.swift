import XCTest
@testable import EventSynth

final class RingSelectorTests: XCTestCase {
    func pick(_ dx: Int, _ dy: Int, steps: Int = 10) -> Int? {
        var r = RingSelector(slices: 8)
        r.add(dx: 999, dy: 999)  // stale first report is skipped
        for _ in 0..<steps { r.add(dx: dx, dy: dy) }
        return r.selected
    }

    func testDeadZone() {
        XCTAssertNil(pick(2, 2))
    }

    func testCardinalAndDiagonalSlices() {
        XCTAssertEqual(pick(0, -20), 0)   // up
        XCTAssertEqual(pick(20, -20), 1)  // up-right
        XCTAssertEqual(pick(20, 0), 2)    // right
        XCTAssertEqual(pick(0, 20), 4)    // down
        XCTAssertEqual(pick(-20, 0), 6)   // left
        XCTAssertEqual(pick(-20, -20), 7) // up-left
    }

    func testRadiusIsClampedSoReversalIsQuick() {
        var r = RingSelector(slices: 8)
        r.add(dx: 0, dy: 0)
        for _ in 0..<100 { r.add(dx: 50, dy: 0) }
        XCTAssertEqual(r.selected, 2)
        for _ in 0..<8 { r.add(dx: -50, dy: 0) }
        XCTAssertEqual(r.selected, 6)
    }
}
