// G3.7c: received CoT markers. An atom with no <contact endpoint> is a
// marker and keeps the details 5.5 picks its icon from; a contact's SA, its
// own uid and anything else are not; it goes stale and is removed on 5.5's
// clock; a delete task stales or removes it.

import Foundation
import XCTest
import MacTAKCot
@testable import MacTAKComms

@MainActor
final class CotMarkerStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ uid: String, type: String = "a-h-G", staleAfter: TimeInterval = 60, how: String = "h-g-i-g-o",
                       detail: String = "") -> String {
        "<event version='2.0' uid='\(uid)' type='\(type)' time='\(Cot.time(t0))' start='\(Cot.time(t0))'"
            + " stale='\(Cot.time(t0.addingTimeInterval(staleAfter)))' how='\(how)'>"
            + "<point lat='37.7955' lon='-122.3937' hae='5' ce='9999999' le='9999999'/>"
            + "<detail>\(detail)</detail></event>"
    }

    private func delete(_ uid: String, force: Bool) -> String {
        event("del-1", type: CotMarkerStore.deleteType, how: "h-g-i-g-o",
              detail: "<link uid='\(uid)' relation='none' type='none'/>" + (force ? "<__forcedelete/>" : ""))
    }

    func testAnAtomWithNoEndpointIsAMarkerWithItsDetails() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        let detail = "<contact callsign='Hostile 1'/><color argb='-65536'/><status readiness='false'/>"
            + "<usericon iconsetpath='COT_MAPPING_2525C/a-h/a-h-G'/>"
        XCTAssertTrue(store.receive(event("m1", detail: detail), at: t0))
        let m = try XCTUnwrap(store["m1"])
        XCTAssertEqual(m.label, "Hostile 1")
        XCTAssertEqual(m.traits, MarkerTraits(type: "a-h-G", how: "h-g-i-g-o", color: 0xFFFF_0000, ready: false,
                                              iconsetPath: "COT_MAPPING_2525C/a-h/a-h-G"))
        XCTAssertEqual(m.point.lat, 37.7955)
    }

    func testLabelIsTheUIDUnlessItIsAUUID() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("ICU-12"), at: t0)
        store.receive(event("8c6b1c10-7a4e-4b8e-9b7e-0f1d2c3b4a59"), at: t0)
        XCTAssertEqual(store["ICU-12"]?.label, "ICU-12")
        XCTAssertEqual(try XCTUnwrap(store["8c6b1c10-7a4e-4b8e-9b7e-0f1d2c3b4a59"]).label, nil)
    }

    func testColourFallsBackToValueThenWhite() {
        XCTAssertEqual(CotMarkerStore.androidColor("-16776961"), 0xFF00_00FF)
        XCTAssertEqual(CotMarkerStore.androidColor("nonsense"), MarkerIcons.white)
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("m", detail: "<color value='-16711936'/>"), at: t0)
        XCTAssertEqual(store["m"]?.traits.color, 0xFF00_FF00)
    }

    func testIgnoresContactsItsOwnUIDAndNonAtoms() {
        let contacts: Set = ["peer"]
        let store = CotMarkerStore(selfUID: "me") { contacts.contains($0) }
        XCTAssertFalse(store.receive(event("me"), at: t0), "its own uid")
        XCTAssertFalse(store.receive(event("peer"), at: t0), "a uid the contacts hold")
        XCTAssertFalse(store.receive(event("chat", type: "b-t-f"), at: t0), "not an atom")
        XCTAssertFalse(store.receive(event("sa", detail: "<contact callsign='S' endpoint='*:-1:stcp'/>"), at: t0),
                       "a contact's SA")
        XCTAssertFalse(store.receive("<event/>", at: t0))
        XCTAssertTrue(store.markers.isEmpty)
    }

    func testAContactsSAUnderAMarkersUIDRemovesTheMarker() {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("u1"), at: t0)
        XCTAssertTrue(store.receive(event("u1", detail: "<contact callsign='S' endpoint='*:-1:stcp'/>"), at: t0))
        XCTAssertNil(store["u1"])
    }

    func testStaleAfterOneAndAHalfTimesItsLifeAndGoneFiveMinutesLater() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("m", staleAfter: 60), at: t0)
        let m = try XCTUnwrap(store["m"])
        XCTAssertFalse(m.isStale(at: t0.addingTimeInterval(89)))
        XCTAssertTrue(m.isStale(at: t0.addingTimeInterval(90)))
        store.expire(at: t0.addingTimeInterval(90 + 299))
        XCTAssertNotNil(store["m"])
        store.expire(at: t0.addingTimeInterval(90 + 300))
        XCTAssertNil(store["m"])
    }

    func testADeleteTaskStalesAMarkerOrWithForceRemovesIt() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("a"), at: t0)
        store.receive(event("b"), at: t0)
        let later = t0.addingTimeInterval(10)
        XCTAssertTrue(store.receive(delete("a", force: false), at: later))
        let a = try XCTUnwrap(store["a"])
        XCTAssertTrue(a.isStale(at: later))
        XCTAssertEqual(a.removeAt, later.addingTimeInterval(ContactStore.removeAfterStale))
        XCTAssertTrue(store.receive(delete("b", force: true), at: later))
        XCTAssertNil(store["b"])
        XCTAssertFalse(store.receive(delete("nobody", force: true), at: later))
    }

    // G3.9a: a marker that came with <archive/> is kept across launches,
    // and so never goes stale or times out.

    func testAnArchivedMarkerNeverGoesStaleAndIgnoresAPlainDelete() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        let xml = event("k", staleAfter: 60, detail: "<archive/>")
        store.receive(xml, at: t0)
        let k = try XCTUnwrap(store["k"])
        XCTAssertTrue(k.archived)
        XCTAssertEqual(k.archivedEvent, xml, "kept as it came")
        XCTAssertFalse(k.isStale(at: t0.addingTimeInterval(86_400 * 365)))
        store.expire(at: t0.addingTimeInterval(86_400 * 365))
        XCTAssertNotNil(store["k"])
        XCTAssertFalse(store.receive(delete("k", force: false), at: t0), "only a force delete")
        XCTAssertTrue(store.receive(delete("k", force: true), at: t0))
        XCTAssertNil(store["k"])
    }

    func testOnceArchivedAnUpdateWithoutItStaysKept() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("k", detail: "<archive/>"), at: t0)
        store.receive(event("k", detail: "<contact callsign='Moved'/>"), at: t0)
        let kept = try CotEvent.parse(try XCTUnwrap(store["k"]?.archivedEvent))
        XCTAssertNotNil(kept.detail("archive"), "kept with <archive/> added")
        XCTAssertEqual(kept.detail("contact")?["callsign"], "Moved", "as the update says")
        store.receive(event("plain"), at: t0)
        XCTAssertNil(store["plain"]?.archivedEvent)
    }
}
