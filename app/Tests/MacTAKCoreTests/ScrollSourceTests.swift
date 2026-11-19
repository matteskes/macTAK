// ScrollSource tells a trackpad scroll (pan) from a wheel (zoom) by the
// gesture phase, not by precise deltas (#211): a smooth-scrolling wheel
// such as an MX Master 3 under Logi Options+ sends precise deltas too.

import AppKit
import XCTest
@testable import MacTAKCore

final class ScrollSourceTests: XCTestCase {
    func testNoPhaseIsAWheel() {
        XCTAssertEqual(ScrollSource(phase: [], momentumPhase: []), .wheel)
    }

    func testGesturePhaseIsASurface() {
        for phase: NSEvent.Phase in [.mayBegin, .began, .changed, .ended, .cancelled] {
            XCTAssertEqual(ScrollSource(phase: phase, momentumPhase: []), .surface, "\(phase)")
        }
    }

    func testMomentumAfterLiftIsASurface() {
        for momentum: NSEvent.Phase in [.began, .changed, .ended] {
            XCTAssertEqual(ScrollSource(phase: [], momentumPhase: momentum), .surface, "\(momentum)")
        }
    }

    func testWheelLines() {
        XCTAssertEqual(ScrollSource.wheelLines(1, precise: false), 1)
        XCTAssertEqual(ScrollSource.wheelLines(-3, precise: false), -3)
        XCTAssertEqual(ScrollSource.wheelLines(10, precise: true), 1)
        XCTAssertEqual(ScrollSource.wheelLines(-25, precise: true), -2.5)
    }

    /// A smooth-scrolled wheel event: pixel units, no phase. It must read as
    /// a wheel even though its deltas are precise.
    func testPixelScrollWithoutPhaseIsAWheel() throws {
        let e = try scrollEvent(units: .pixel, phase: 0)
        XCTAssertTrue(e.hasPreciseScrollingDeltas)
        XCTAssertEqual(ScrollSource(phase: e.phase, momentumPhase: e.momentumPhase), .wheel)
    }

    /// The shell's scripted trackpad pans set the phase on a CGEvent; it has
    /// to survive into NSEvent.phase for them to keep panning.
    func testPixelScrollWithPhaseIsASurface() throws {
        let e = try scrollEvent(units: .pixel, phase: 2)   // kCGScrollPhaseChanged
        XCTAssertEqual(e.phase, .changed)
        XCTAssertEqual(ScrollSource(phase: e.phase, momentumPhase: e.momentumPhase), .surface)
    }

    func testLineScrollIsAWheel() throws {
        let e = try scrollEvent(units: .line, phase: 0)
        XCTAssertFalse(e.hasPreciseScrollingDeltas)
        XCTAssertEqual(ScrollSource(phase: e.phase, momentumPhase: e.momentumPhase), .wheel)
    }

    private func scrollEvent(units: CGScrollEventUnit, phase: Int64) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                       wheel1: 5, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }
}
