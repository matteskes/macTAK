// G3.9d: points as 5.5's CoT. Others' markers are updated as MarkerImporter
// updates them (a detail an update leaves out is kept, but not the old
// point's precisionlocation, nor an address for a place it has left); a
// move says where its place came from and drops an address that no longer
// fits; an address is kept only for where the point still is; a dropped
// point carries where its place came from and who placed it.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class PointCotTests: XCTestCase {
    /// 2026-11-03 14:32:05 UTC.
    private let t = Date(timeIntervalSince1970: 1_793_716_325)
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)
    private let address = AddressDetail(text: "Palace of Fine Arts", geocoder: "Apple Maps", time: "2026-11-03T14:30:00.000Z")

    private func event(at p: CotPoint, _ details: [CotDetail], seconds: TimeInterval = 0) -> String {
        var detail = CotDetail("detail")
        for d in details { detail.add(d) }
        let time = t.addingTimeInterval(seconds)
        return CotEvent(uid: "theirs", type: "a-h-G", time: time, stale: time.addingTimeInterval(60),
                        how: "h-g-i-g-o", point: p, detail: detail).xml()
    }

    private func detail(_ name: String, _ attributes: [String: String] = [:], text: String? = nil) -> CotDetail {
        var d = CotDetail(name)
        for (k, v) in attributes.sorted(by: { $0.key < $1.key }) { d[k] = v }
        d.innerText = text
        return d
    }

    private var full: [CotDetail] {
        [detail("contact", ["callsign": "Other"]), detail("remarks", text: "gate"),
         detail("color", ["argb": "-65536"]), detail("usericon", ["iconsetpath": "COT_MAPPING_2525C/a-h/a-h-G"]),
         detail("precisionlocation", ["altsrc": "DTED1"]), address.detail]
    }

    func testAnUpdateKeepsWhatItLeavesOut() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(event(at: here, full), at: t)
        markers.receive(event(at: here, [detail("contact", ["callsign": "Renamed"])], seconds: 5), at: t)
        var m = try XCTUnwrap(markers["theirs"])
        XCTAssertEqual(m.label, "Renamed", "what it carries replaces")
        XCTAssertEqual(m.remarks, "gate")
        XCTAssertEqual(m.traits.color, 0xFFFF_0000)
        XCTAssertEqual(m.traits.iconsetPath, "COT_MAPPING_2525C/a-h/a-h-G")
        XCTAssertEqual(m.address, address, "still where it was looked up")
        XCTAssertNil(m.event.detail("precisionlocation"), "it went with the old point")

        markers.receive(event(at: there, [], seconds: 10), at: t)
        m = try XCTUnwrap(markers["theirs"])
        XCTAssertEqual(m.point, there)
        XCTAssertEqual(m.label, "Renamed")
        XCTAssertNil(m.address, "looked up for a place it has left")
    }

    func testAnArchivedUpdateIsKeptWithWhatItLeftOut() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(event(at: here, full + [CotDetail("archive")]), at: t)
        markers.receive(event(at: there, [detail("contact", ["callsign": "Other"])], seconds: 5), at: t)
        let kept = try CotEvent.parse(try XCTUnwrap(markers["theirs"]?.archivedEvent))
        XCTAssertEqual(kept.point, there)
        XCTAssertEqual(kept.remarks, "gate")
        XCTAssertNotNil(kept.detail("archive"))
    }

    func testAMoveSaysWhereItsPlaceCameFrom() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let editor = PointEditor(markers: markers, locate: locating(markers))
        markers.receive(event(at: here, full), at: t)
        let nearby = CotPoint(lat: here.lat + 0.000_001, lon: here.lon)
        XCTAssertTrue(editor.move("theirs", to: .ground(nearby)))
        var m = try XCTUnwrap(markers["theirs"])
        XCTAssertEqual(m.event.detail("precisionlocation")?["altsrc"], "???", "the click's")
        XCTAssertNil(m.event.detail("precisionlocation")?["geopointsrc"])
        XCTAssertEqual(m.address, address, "a move within the address's 1.1 m keeps it")
        editor.move("theirs", to: .ground(there))
        m = try XCTUnwrap(markers["theirs"])
        XCTAssertNil(m.address, "no longer where it was looked up")
        XCTAssertEqual(m.event.detail?.children.filter { $0.name == "precisionlocation" }.count, 1)
    }

    func testAnAddressIsKeptOnlyForWhereThePointIs() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let editor = PointEditor(markers: markers, locate: locating(markers))
        markers.receive(event(at: here, []), at: t)
        XCTAssertFalse(editor.setAddress("theirs", address, lookedUpAt: there), "it moved while looking")
        XCTAssertNil(markers["theirs"]?.address)
        XCTAssertTrue(editor.setAddress("theirs", address, lookedUpAt: here))
        XCTAssertEqual(markers["theirs"]?.address, address)
        XCTAssertEqual(markers["theirs"]?.event.detail(AddressDetail.elementName)?["geocoder"], "Apple Maps")
    }

    func testADroppedPointSaysWhereAndWho() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        let settings = MemorySettings()
        let c = ServerConnections(settings: settings, identities: keychain.store,
                                  me: .testing(settings, uid: "MACTAK-ME"))
        c.me.details.callsign = "VIPER"
        c.elevation.source = { _ in "DTED1" }
        c.pointDropper.begin(.affiliation(.hostile))
        let high = CotPoint(lat: here.lat, lon: here.lon, hae: 15)
        let onTerrain = try XCTUnwrap(c.pointDropper.click(.ground(high), at: t))
        XCTAssertEqual(onTerrain.event.detail("precisionlocation")?["altsrc"], "DTED1")
        let author = try XCTUnwrap(Author(creator: onTerrain.event.detail("creator"), orTime: .distantPast))
        XCTAssertEqual([author.uid, author.callsign, author.type], ["MACTAK-ME", "VIPER", c.me.details.unitType])
        XCTAssertEqual(author.time, t)
        XCTAssertEqual(onTerrain.event.detail("link")?["relation"], "p-p")
        let flat = try XCTUnwrap(c.pointDropper.click(.ground(there), at: t))
        XCTAssertEqual(flat.event.detail("precisionlocation")?["altsrc"], "???", "no altitude, nothing asked")

        c.me.place(here, address: nil)
        let onMe = try XCTUnwrap(c.pointDropper.click(.item("MACTAK-ME"), at: t))
        XCTAssertEqual(onMe.point, here)
        XCTAssertEqual(PrecisionLocation(onMe.event.detail("precisionlocation")),
                       PrecisionLocation(geopointSource: "USER", altitudeSource: "???"), "the self marker's")
    }
}
