// The R&B tool and its lines (G3.8c) as 5.5's RangeAndBearingTool and
// RangeAndBearingMapItem behave: two clicks make a line, a marker ties an
// end, the same marker twice is ignored, titles take the lowest free number,
// and an end whose marker goes stays where the marker was.

import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class RangeBearingLinesTests: XCTestCase {
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.80, lon: -122.44)

    private func makeLines() -> RangeBearingLines {
        var n = 0
        return RangeBearingLines { n += 1; return "id-\(n)" }
    }

    func testTwoClicksMakeALineAndEndTheTool() {
        let rab = makeLines()
        rab.beginTool()
        XCTAssertEqual(rab.prompt, "Click the point to measure from.")
        XCTAssertNil(rab.click(.ground(here)))
        XCTAssertEqual(rab.startPoint, here, "a place shows the red start point")
        XCTAssertEqual(rab.prompt, "Click the point to measure to.")
        let line = rab.click(.item("contact-1"))
        XCTAssertEqual(line, RangeBearingLine(id: "id-1", title: "R&B 1", start: .point(here), end: .item("contact-1")))
        XCTAssertEqual(rab.tool, .off)
        XCTAssertNil(rab.prompt)
        XCTAssertEqual(rab.lines.count, 1)
    }

    func testAMarkerStartHasNoStartPointAndItsOwnPrompt() {
        let rab = makeLines()
        rab.beginTool()
        rab.click(.item("contact-1"))
        XCTAssertNil(rab.startPoint)
        XCTAssertEqual(rab.prompt, "Click the point to measure range and bearing to.")
    }

    func testTheSameMarkerTwiceIsIgnored() {
        let rab = makeLines()
        rab.beginTool()
        rab.click(.item("contact-1"))
        XCTAssertNil(rab.click(.item("contact-1")))
        XCTAssertEqual(rab.tool, .pickingEnd(.item("contact-1")))
        XCTAssertNotNil(rab.click(.item("contact-2")))
    }

    func testClicksWithTheToolOffDoNothing() {
        let rab = makeLines()
        XCTAssertNil(rab.click(.ground(here)))
        XCTAssertTrue(rab.lines.isEmpty)
    }

    func testCancelMakesNothing() {
        let rab = makeLines()
        rab.beginTool()
        rab.click(.ground(here))
        rab.endTool()
        XCTAssertEqual(rab.tool, .off)
        XCTAssertNil(rab.startPoint)
        XCTAssertTrue(rab.lines.isEmpty)
    }

    func testTitlesTakeTheLowestFreeNumber() {
        let rab = makeLines()
        let one = rab.add(start: .point(here), end: .point(there))
        rab.add(start: .point(here), end: .point(there))
        XCTAssertEqual(rab.lines.map(\.title), ["R&B 1", "R&B 2"])
        rab.remove(id: one.id)
        XCTAssertEqual(rab.add(start: .point(here), end: .point(there)).title, "R&B 1")
        XCTAssertEqual(rab.add(start: .point(here), end: .point(there)).title, "R&B 3")
    }

    func testATiedEndFollowsItsMarker() {
        let rab = makeLines()
        rab.add(start: .point(here), end: .item("c"))
        XCTAssertEqual(rab.ends(markers: ["c": there]).first?.end, there)
        let moved = CotPoint(lat: 37.81, lon: -122.43)
        XCTAssertEqual(rab.ends(markers: ["c": moved]).first?.end, moved)
    }

    func testAnEndWhoseMarkerGoesStaysWhereItWas() {
        let rab = makeLines()
        rab.add(start: .item("c"), end: .point(there))
        _ = rab.ends(markers: ["c": here])
        let ends = rab.ends(markers: [:])
        XCTAssertEqual(ends.first?.start, here)
        XCTAssertEqual(rab.lines.first?.start, .point(here), "the end is a fixed place now")
        XCTAssertEqual(rab.ends(markers: ["c": there]).first?.start, here, "and no longer follows the marker")
    }

    func testALineWhoseMarkerWasNeverSeenWaits() {
        let rab = makeLines()
        rab.add(start: .item("self"), end: .point(there))
        XCTAssertTrue(rab.ends(markers: [:]).isEmpty)
        XCTAssertEqual(rab.lines.first?.start, .item("self"))
        XCTAssertEqual(rab.ends(markers: ["self": here]).first?.start, here)
    }

    func testRemoveAll() {
        let rab = makeLines()
        rab.add(start: .point(here), end: .point(there))
        rab.add(start: .point(here), end: .point(there))
        rab.removeAll()
        XCTAssertTrue(rab.lines.isEmpty)
    }
}
