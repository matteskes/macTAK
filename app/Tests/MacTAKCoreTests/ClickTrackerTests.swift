// ClickTracker tells a click (a press that stays put) from a drag (G3.8b):
// only a click picks a place or a marker for the range and bearing tool.

import XCTest
@testable import MacTAKCore

final class ClickTrackerTests: XCTestCase {
    func testPressInPlaceIsAClick() {
        var t = ClickTracker()
        t.down(at: (100, 100), scale: 2)
        t.moved(to: (105, 103))   // under 4 points (8 px) of hand movement
        XCTAssertTrue(t.up())
    }

    func testDragIsNotAClick() {
        var t = ClickTracker()
        t.down(at: (100, 100), scale: 2)
        t.moved(to: (120, 100))
        XCTAssertFalse(t.up())
    }

    func testDragBackToStartIsStillADrag() {
        var t = ClickTracker()
        t.down(at: (100, 100), scale: 1)
        t.moved(to: (140, 100))
        t.moved(to: (100, 100))
        XCTAssertFalse(t.up())
    }

    func testSlopScalesWithTheBacking() {
        var t = ClickTracker()
        t.down(at: (0, 0), scale: 1)
        t.moved(to: (6, 0))   // 6 px is 6 points at 1x: past the slop
        XCTAssertFalse(t.up())
    }

    func testUpWithoutDownIsNotAClick() {
        var t = ClickTracker()
        XCTAssertFalse(t.up())
    }
}
