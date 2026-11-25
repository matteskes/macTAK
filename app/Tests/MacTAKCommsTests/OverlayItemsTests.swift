// G3.11a: the map's items as the Overlay Manager sees them — a contact's and
// a marker's team and role, a marker's author and icon set, an R&B line's
// ends where they are now, a route's waypoint names.

import Foundation
import XCTest
import MacTAKCot
@testable import MacTAKComms

@MainActor
final class OverlayItemsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ uid: String, type: String, detail: String) -> String {
        "<event version='2.0' uid='\(uid)' type='\(type)' time='\(Cot.time(t0))' start='\(Cot.time(t0))'"
            + " stale='\(Cot.time(t0.addingTimeInterval(60)))' how='h-g-i-g-o'>"
            + "<point lat='37.7955' lon='-122.3937' hae='5' ce='9999999' le='9999999'/>"
            + "<detail>\(detail)</detail></event>"
    }

    func testAContactIsUnderItsTeam() throws {
        let store = ContactStore(selfUID: "me")
        store.receive(event("peer", type: "a-f-G-U-C", detail: "<contact callsign='VIPER' endpoint='*:-1:stcp'/>"
                                + "<__group name='cyan' role='Team Lead'/>"), via: .mesh, at: t0)
        let item = OverlayItem(try XCTUnwrap(store["peer"]))
        XCTAssertEqual(item.title, "VIPER")
        XCTAssertEqual([item.team, item.role], ["Cyan", "Team Lead"])
        XCTAssertNil(item.author)
        XCTAssertEqual(OverlayConfig.place(item), ["friendlyteamleads", "friendlyteamCyan"])
    }

    func testAMarkerCarriesItsAuthorAndIconSet() throws {
        let store = CotMarkerStore(selfUID: "me") { _ in false }
        store.receive(event("m1", type: "a-h-G", detail: "<contact callsign='H1'/>"
                                + "<link uid='me' relation='p-p' type='a-f-G'/>"
                                + "<usericon iconsetpath='set/Google/hiker.png'/>"), at: t0)
        let item = OverlayItem(try XCTUnwrap(store["m1"]))
        XCTAssertEqual(item.title, "H1")
        XCTAssertEqual(item.author, "me")
        XCTAssertEqual(OverlayConfig.place(item), [], "a user icon")
        XCTAssertEqual(item.location, .point(CotPoint(lat: 37.7955, lon: -122.3937, hae: 5, ce: 9_999_999, le: 9_999_999)))
    }

    func testAnRBLineIsWhereItsEndsAreNow() {
        let fixed = CotPoint(lat: 1, lon: 2), marker = CotPoint(lat: 3, lon: 4)
        let line = RangeBearingLine(id: "rb", title: "R&B 1", start: .point(fixed), end: .item("m"),
                                    creator: Author(uid: "me", type: "a-f-G", callsign: "ME", time: t0))
        let item = OverlayItem(line) { $0 == "m" ? marker : nil }
        XCTAssertEqual(item.location, .line([fixed, marker]))
        XCTAssertEqual(item.group, .rangeAndBearing)
        XCTAssertEqual(item.author, "me")
        XCTAssertEqual(OverlayItem(line) { _ in nil }.location, .line([fixed]), "a marker gone leaves one end")
    }

    func testARouteIsFoundByItsWaypointNames() {
        var route = Route(id: "r", title: "Patrol", points: [.waypoint(CotPoint(lat: 0, lon: 0), uid: "a"),
                                                             .controlPoint(CotPoint(lat: 0, lon: 1), uid: "b"),
                                                             .waypoint(CotPoint(lat: 0, lon: 2), uid: "c")])
        route.nameWaypoints()
        let item = OverlayItem(route)
        XCTAssertEqual(item.type, "b-m-r")
        XCTAssertEqual(item.searchNames, ["Patrol SP", "VDO"])
        XCTAssertEqual(OverlayConfig.place(item), ["routes"])
    }
}
