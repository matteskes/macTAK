// G3.9d: where a click is, as the app's MapLocator says. The ground asks the
// elevation data only where the map has an altitude; an item is where it
// is, with where that place came from: a marker's own precisionlocation, a
// contact's SA's, the self marker's (GPS or USER).

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class MapLocatorTests: XCTestCase {
    private let here = CotPoint(lat: 37.795, lon: -122.445, hae: 15)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)
    private let settings = MemorySettings()
    private lazy var me = SelfReporter.testing(settings, uid: "MACTAK-ME")
    private lazy var contacts = ContactStore(selfUID: me.details.uid)
    private lazy var markers = CotMarkerStore(selfUID: me.details.uid) { [contacts] in contacts[$0] != nil }
    private lazy var locator = MapLocator(markers: markers, contacts: contacts, me: me)

    private func event(_ uid: String, at p: CotPoint, endpoint: Bool, altsrc: String) -> String {
        var detail = CotDetail("detail")
        var contact = CotDetail("contact")
        contact["callsign"] = uid
        if endpoint { contact["endpoint"] = "192.168.1.20:4242:tcp" }
        detail.add(contact)
        detail.add(PrecisionLocation(geopointSource: "GPS", altitudeSource: altsrc).detail!)
        let now = Date()
        return CotEvent(uid: uid, type: "a-f-G", time: now, stale: now.addingTimeInterval(60), how: "m-g",
                        point: p, detail: detail).xml()
    }

    func testTheGroundAsksTheElevationDataOnlyWhereThereIsAnAltitude() {
        var asked: [CotPoint] = []
        locator.altitudeSource = { p in asked.append(p); return "DTED1" }
        XCTAssertEqual(locator.locate(.ground(here)), .clicked(here, altitudeSource: "DTED1"))
        XCTAssertEqual(locator.locate(.ground(there)), .clicked(there, altitudeSource: nil), "no altitude: ???")
        XCTAssertEqual(asked, [here])
    }

    func testTheGroundBeforeTheMapRunsIsUnknown() {
        XCTAssertEqual(locator.locate(.ground(here))?.precision?.altitudeSource, PrecisionLocation.unknown)
    }

    func testAMarkerIsWhereItIsWithItsOwnPrecision() {
        markers.receive(event("hostile-1", at: there, endpoint: false, altsrc: "DTED2"))
        XCTAssertEqual(locator.locate(.item("hostile-1")),
                       SourcedPoint(there, precision: PrecisionLocation(geopointSource: "GPS", altitudeSource: "DTED2")))
    }

    func testAContactIsWhereItsSASays() {
        XCTAssertTrue(contacts.receive(event("peer-1", at: there, endpoint: true, altsrc: "GPS"), via: .mesh))
        XCTAssertEqual(locator.locate(.item("peer-1")),
                       SourcedPoint(there, precision: PrecisionLocation(geopointSource: "GPS", altitudeSource: "GPS")))
    }

    func testTheSelfMarkerIsWhereItWasPlaced() {
        XCTAssertNil(locator.locate(.item("MACTAK-ME")), "not placed yet")
        me.place(here, address: nil)
        XCTAssertEqual(locator.locate(.item("MACTAK-ME")),
                       SourcedPoint(here, precision: PrecisionLocation(geopointSource: "USER", altitudeSource: "USER")))
    }

    func testAnItemNotOnTheMapIsNowhere() {
        XCTAssertNil(locator.locate(.item("gone")))
    }
}
