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
        XCTAssertEqual(line.map { [$0.id, $0.title] }, ["id-1", "R&B 1"])
        XCTAssertEqual(line?.start, .point(here))
        XCTAssertEqual(line?.end, .item("contact-1"))
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

// G3.8d: lines heard over CoT.
@MainActor
final class RangeBearingReceiveTests: XCTestCase {
    private let now = Date()
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.80, lon: -122.44)

    private func xml(uid: String = "remote-1", title: String = "R&B 7", startUID: String? = nil,
                     endUID: String? = nil, color: Int32 = RangeBearingEvent.red, archive: Bool = false,
                     creator: Author? = nil) -> String {
        RangeBearingEvent.make(uid: uid, title: title, start: here, end: there, startUID: startUID, endUID: endUID,
                               style: .atak, color: color, archive: archive, creator: creator, now: now).xml()
    }

    func testAHeardLineIsAdded() {
        let rab = RangeBearingLines()
        XCTAssertTrue(rab.receive(xml(endUID: "m1")) { $0 == "m1" })
        let line = rab["remote-1"]
        XCTAssertEqual(line?.title, "R&B 7")
        XCTAssertEqual(line?.end, .item("m1"))
        XCTAssertEqual(line?.received, true)
    }

    func testAnUnknownMarkerBecomesAPlace() {
        let rab = RangeBearingLines()
        rab.receive(xml(startUID: "gone", endUID: "gone-too")) { _ in false }
        guard case .point(let s) = rab["remote-1"]?.start, case .point(let e) = rab["remote-1"]?.end else {
            return XCTFail("both ends are places")
        }
        XCTAssertEqual(s.lat, here.lat, accuracy: 1e-7)
        XCTAssertLessThan(Geodesy.distance(lat1: e.lat, lon1: e.lon, lat2: there.lat, lon2: there.lon), 0.01)
    }

    func testAnUpdateReplacesIt() {
        let rab = RangeBearingLines()
        rab.receive(xml()) { _ in false }
        rab.receive(xml(title: "renamed", color: -16_711_936)) { _ in false }
        XCTAssertEqual(rab.lines.count, 1)
        XCTAssertEqual(rab["remote-1"]?.title, "renamed")
        XCTAssertEqual(rab["remote-1"]?.color, -16_711_936)
    }

    /// RangeAndBearingImporter on an existing line: an end the event names
    /// no marker for stays tied to its marker; a fixed end moves.
    func testAnUpdateKeepsATiedEndAndMovesAFixedOne() {
        let rab = RangeBearingLines()
        let mine = rab.add(start: .item("self"), end: .point(CotPoint(lat: 1, lon: 1)))
        XCTAssertTrue(rab.receive(xml(uid: mine.id)) { _ in false })
        XCTAssertEqual(rab[mine.id]?.start, .item("self"))
        guard case .point(let e) = rab[mine.id]?.end else { return XCTFail("the end is a place") }
        XCTAssertLessThan(Geodesy.distance(lat1: e.lat, lon1: e.lon, lat2: there.lat, lon2: there.lon), 0.01)
        XCTAssertEqual(rab[mine.id]?.received, false, "still a line made here")
        XCTAssertFalse(rab.receive(xml(uid: mine.id)) { _ in false }, "the same again changes nothing")
    }

    func testRemoveSaysWhetherTheLineWasHere() {
        let rab = RangeBearingLines()
        rab.receive(xml()) { _ in false }
        XCTAssertTrue(rab.remove(id: "remote-1"))
        XCTAssertNil(rab["remote-1"])
        XCTAssertFalse(rab.remove(id: "remote-1"))
    }

    func testColourWeightAndCreatorComeWithIt() {
        let rab = RangeBearingLines()
        let creator = Author(uid: "ANDROID-1", type: "a-f-G-U-C", callsign: "VIPER",
                                                time: Date(timeIntervalSince1970: 1_794_999_000))
        let event = RangeBearingEvent.make(uid: "remote-2", title: "R&B 9", start: here, end: there, startUID: nil,
                                           endUID: nil, style: .atak, color: -16_776_961, weight: 5,
                                           creator: creator, now: now)
        rab.receive(event.xml()) { _ in false }
        XCTAssertEqual(rab["remote-2"]?.color, -16_776_961)
        XCTAssertEqual(rab["remote-2"]?.weight, 5)
        XCTAssertEqual(rab["remote-2"]?.creator, creator, "kept, to send on")
    }

    func testALineMadeHereHasThisClientAsCreator() {
        let rab = RangeBearingLines()
        let me = Author(uid: "MACTAK-1", type: "a-f-G-U-C", callsign: "ME", time: now)
        rab.author = { me }
        XCTAssertEqual(rab.add(start: .point(here), end: .point(there)).creator, me)
    }

    func testOtherEventsAreIgnored() {
        let rab = RangeBearingLines()
        let sa = CotEvent(uid: "c", type: "a-f-G-U-C", time: now, stale: now, how: "m-g", point: here).xml()
        XCTAssertFalse(rab.receive(sa) { _ in false })
        XCTAssertTrue(rab.lines.isEmpty)
    }

    // G3.9a: which lines are kept across launches, and taking them back.

    func testALineMadeHereIsKeptAHeardOneOnlyWithArchive() {
        let rab = RangeBearingLines()
        XCTAssertTrue(rab.add(start: .point(here), end: .point(there)).archived, "the tool's lines persist")
        rab.receive(xml(uid: "plain")) { _ in false }
        rab.receive(xml(uid: "kept", archive: true)) { _ in false }
        XCTAssertEqual(rab["plain"]?.archived, false)
        XCTAssertEqual(rab["kept"]?.archived, true)
        rab.receive(xml(uid: "kept", title: "renamed")) { _ in false }
        XCTAssertEqual(rab["kept"]?.archived, true, "an update without <archive/> doesn't unkeep it")
    }

    func testRestoreDefersUntilItsMarkerIsIn() throws {
        let rab = RangeBearingLines()
        var markers: Set<String> = []
        let kept = try CotEvent.parse(xml(endUID: "m1", archive: true))
        XCTAssertEqual(rab.restore(kept, isMarker: markers.contains, selfUID: "me"), .deferred)
        guard case .point = rab["remote-1"]?.end else { return XCTFail("a fixed end meanwhile") }
        markers.insert("m1")
        XCTAssertEqual(rab.restore(kept, isMarker: markers.contains, selfUID: "me"), .success)
        XCTAssertEqual(rab["remote-1"]?.end, .item("m1"), "tied once the marker is in")
        XCTAssertEqual(rab.lines.count, 1)
    }

    func testARestoredLineIsThisClientsWhenItMadeIt() throws {
        let rab = RangeBearingLines()
        let mine = Author(uid: "me", type: "a-f-G-U-C", callsign: "ME", time: now)
        let theirs = Author(uid: "peer", type: "a-f-G-U-C", callsign: "PEER", time: now)
        rab.restore(try CotEvent.parse(xml(uid: "a", archive: true, creator: mine)), isMarker: { _ in false },
                    selfUID: "me")
        rab.restore(try CotEvent.parse(xml(uid: "b", archive: true, creator: theirs)), isMarker: { _ in false },
                    selfUID: "me")
        XCTAssertEqual(rab["a"]?.received, false)
        XCTAssertEqual(rab["b"]?.received, true)
        XCTAssertEqual(rab["a"]?.archived, true)
        let sa = CotEvent(uid: "c", type: "a-f-G-U-C", time: now, stale: now, how: "m-g", point: here)
        XCTAssertEqual(rab.restore(sa, isMarker: { _ in false }, selfUID: "me"), .failure)
    }
}
