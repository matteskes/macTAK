// MapItems (G3 clean-code re-audit, N1): the one place the map's item
// kinds are listed. A change to any of them gives one `changed`, after the
// change has landed; a CoT event commo heard reaches each kind; and a line's
// end can be tied to a contact, a marker or this client.

import Combine
import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class MapItemsTests: XCTestCase {
    private let t0 = Date()
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.80, lon: -122.44)
    private lazy var items = MapItems(me: .testing(MemorySettings(), uid: "me"))

    private func sa(_ uid: String) -> String {
        SelfEvent(uid: uid, callsign: "VIPER").event(at: t0, stale: 75).xml()
    }

    private func marker(_ uid: String) -> String {
        "<event version='2.0' uid='\(uid)' type='a-h-G' time='\(Cot.time(t0))' start='\(Cot.time(t0))'"
            + " stale='\(Cot.time(t0.addingTimeInterval(60)))' how='h-g-i-g-o'>"
            + "<point lat='37.7955' lon='-122.3937' hae='5' ce='9999999' le='9999999'/>"
            + "<detail><contact callsign='Hostile 1'/></detail></event>"
    }

    private func line(endUID: String) -> String {
        RangeBearingEvent.make(uid: "line-1", title: "R&B 1", start: here, end: there, startUID: nil, endUID: endUID,
                               style: .atak, color: RangeBearingEvent.red, archive: false, creator: nil,
                               now: t0).xml()
    }

    func testChangesToSeveralKindsGiveOneSignalAfterTheyLanded() async {
        var fired = 0
        var seen: (contact: Bool, hidden: Bool)?
        let signalled = expectation(description: "changed")
        signalled.assertForOverFulfill = false   // a second signal fails the count below, not the run
        let watch = items.changed.sink { [items] in
            fired += 1
            seen = (items.contacts["peer"] != nil, !items.visibility.isVisible("peer"))
            signalled.fulfill()
        }
        items.receive(sa("peer"), via: .mesh)
        items.visibility.set("peer", visible: false)
        XCTAssertEqual(fired, 0, "not while the changes are still being made")
        await fulfillment(of: [signalled], timeout: 2)
        XCTAssertEqual(fired, 1, "one signal for both changes")
        XCTAssertEqual(seen?.contact, true, "the signal comes after the contact landed")
        XCTAssertEqual(seen?.hidden, true, "and after the visibility did")
        watch.cancel()
    }

    func testAHeardEventReachesEachKind() {
        items.receive(sa("peer"), via: .mesh)
        items.receive(marker("m1"), via: .mesh)
        items.receive(line(endUID: "m1"), via: .mesh)
        XCTAssertNotNil(items.contacts["peer"])
        XCTAssertNotNil(items.markers["m1"])
        XCTAssertEqual(items.rangeBearing["line-1"]?.end, .item("m1"), "the line's end is tied to the marker heard")
    }

    func testALinesEndCanBeAContactAMarkerOrThisClient() {
        items.receive(sa("peer"), via: .mesh)
        items.receive(marker("m1"), via: .mesh)
        XCTAssertTrue(items.isMapItem("peer"))
        XCTAssertTrue(items.isMapItem("m1"))
        XCTAssertTrue(items.isMapItem("me"))
        XCTAssertFalse(items.isMapItem("nobody"))
    }
}
