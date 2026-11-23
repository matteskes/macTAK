// G3.9b: the Point Dropper. Each click places a point while the tool is on;
// a click on an item places it at that item; a point placed here since
// launch isn't placed on; names follow 5.5 (genCallsign made unique among
// the same type placed here, Spot Map's "<abbr> n" over all Spot Map
// points); the point is an archived marker drawn as 5.5 adapts it, kept
// across a relaunch.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class PointDropperTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-03 14:32:05 UTC.
    private let t = Date(timeIntervalSince1970: 1_793_716_325)
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)

    private func dropper(_ markers: CotMarkerStore, places: [String: CotPoint] = [:], legacy: Bool = false)
        -> PointDropper {
        var n = 0
        return PointDropper(markers: markers, locate: locating(markers, places: places),
                            deviceCallsign: { "VIPER" }, legacyNaming: { legacy },
                            newID: { n += 1; return "pt-\(n)" }, timeZone: utc)
    }

    private func received(_ uid: String, type: String, callsign: String, at: CotPoint) -> String {
        var detail = CotDetail("detail")
        var contact = CotDetail("contact")
        contact["callsign"] = callsign
        detail.add(contact)
        return CotEvent(uid: uid, type: type, time: t, stale: t.addingTimeInterval(60), how: "h-g-i-g-o",
                        point: at, detail: detail).xml()
    }

    func testNothingIsPlacedWhileTheToolIsOff() {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let tool = dropper(markers)
        XCTAssertNil(tool.click(.ground(here), at: t))
        XCTAssertNil(tool.prompt)
        XCTAssertTrue(markers.markers.isEmpty)
    }

    func testEachClickPlacesAnArchivedPointAndTheToolStaysOn() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let tool = dropper(markers)
        tool.begin(.affiliation(.hostile))
        XCTAssertEqual(tool.prompt, "Click the map to place Hostile points.")
        let p = try XCTUnwrap(tool.click(.ground(here), at: t))
        XCTAssertEqual(p.uid, "pt-1")
        XCTAssertEqual(p.label, "R.3.143205")
        XCTAssertEqual(p.point, here)
        XCTAssertEqual(p.traits, MarkerTraits(type: "a-h-G", how: "h-g-i-g-o", color: 0xFFFF_FFFF, ready: true,
                                              iconsetPath: "COT_MAPPING_2525C/a-h/a-h-G"))
        XCTAssertTrue(p.archived)
        XCTAssertFalse(p.isStale(at: t.addingTimeInterval(10 * 365 * 86_400)), "archived: never stale")
        XCTAssertNotNil(tool.click(.ground(there), at: t.addingTimeInterval(1)))
        XCTAssertEqual(markers.markers.count, 2, "the tool stays on")
        tool.end()
        XCTAssertNil(tool.click(.ground(here), at: t))
    }

    func testTheSameSecondGetsADotCountAmongPointsOfItsType() {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let tool = dropper(markers)
        tool.begin(.affiliation(.unknown))
        XCTAssertEqual(tool.click(.ground(here), at: t)?.label, "U.3.143205")
        XCTAssertEqual(tool.click(.ground(there), at: t)?.label, "U.3.143205.1")
        XCTAssertEqual(tool.click(.ground(there), at: t)?.label, "U.3.143205.2")
        tool.begin(.affiliation(.friendly))
        XCTAssertEqual(tool.click(.ground(here), at: t)?.label, "F.3.143205", "another type doesn't count")
    }

    func testReceivedAndRestoredPointsDontCountForTheDotCount() {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(received("theirs", type: "a-u-G", callsign: "U.3.143205", at: there), at: t)
        let tool = dropper(markers)
        tool.begin(.affiliation(.unknown))
        XCTAssertEqual(tool.click(.ground(here), at: t)?.label, "U.3.143205",
                       "5.5 counts only its User Objects group")
    }

    func testLegacyNamingUsesTheDeviceCallsign() {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let tool = dropper(markers, legacy: true)
        tool.begin(.affiliation(.neutral))
        XCTAssertEqual(tool.click(.ground(here), at: t)?.label, "VIPER.3.143205")
    }

    func testSpotMapDotsAreNumberedOverEverySpotMapPoint() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(received("theirs", type: "b-m-p-s-m", callsign: "W 1", at: there), at: t)
        let tool = dropper(markers)
        tool.begin(.spotMap(.white))
        let w = try XCTUnwrap(tool.click(.ground(here), at: t))
        XCTAssertEqual(w.label, "W 2", "a received one counts")
        XCTAssertEqual(w.traits.color, 0xFFFF_FFFF)
        XCTAssertEqual(w.traits.iconsetPath, "COT_MAPPING_SPOTMAP/b-m-p-s-m/-1")
        tool.begin(.spotMap(.red))
        let r = try XCTUnwrap(tool.click(.ground(here), at: t))
        XCTAssertEqual(r.label, "R 1")
        XCTAssertEqual(r.traits.color, 0xFFFF_0000)
        XCTAssertEqual(MarkerIcons.icon(r.traits, stale: false) { _ in nil },
                       MarkerIcon(uri: "asset://icons/reference_point.png", color: 0xFFFF_0000))
        markers.receive(CotEvent(uid: "theirs", type: CotMarkerStore.deleteType, time: t, stale: t, how: "h-g-i-g-o",
                                 detail: {
                                     var d = CotDetail("detail")
                                     var link = CotDetail("link")
                                     link["uid"] = "theirs"; link["relation"] = "none"; link["type"] = "none"
                                     d.add(link); d.add(CotDetail("__forcedelete"))
                                     return d
                                 }()).xml(), at: t)
        tool.begin(.spotMap(.white))
        XCTAssertEqual(tool.click(.ground(there), at: t)?.label, "W 1", "the lowest free number")
    }

    func testAClickOnAnItemPlacesThePointThere() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(received("theirs", type: "a-f-G", callsign: "Friend", at: there), at: t)
        let tool = dropper(markers, places: ["contact-1": here])
        tool.begin(.affiliation(.hostile))
        XCTAssertEqual(tool.click(.item("theirs"), at: t)?.point, there, "on a marker")
        XCTAssertEqual(tool.click(.item("contact-1"), at: t)?.point, here, "on a contact")
        XCTAssertNil(tool.click(.item("nowhere"), at: t), "an item with no place here")
    }

    func testAClickOnAPointPlacedHerePlacesNothing() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let tool = dropper(markers)
        tool.begin(.spotMap(.blue))
        let p = try XCTUnwrap(tool.click(.ground(here), at: t))
        XCTAssertNil(tool.click(.item(p.uid), at: t), "5.5 shows its menu instead (G3.9c)")
        XCTAssertEqual(markers.markers.count, 1)
    }

    func testASpotMapPointIsNeverStaleArchivedOrNot() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(received("theirs", type: "b-m-p-s-m", callsign: "W 1", at: there), at: t)
        let m = try XCTUnwrap(markers["theirs"])
        XCTAssertFalse(m.archived)
        XCTAssertFalse(m.isStale(at: t.addingTimeInterval(86_400)), "isAtakSpecialType")
        markers.expire(at: t.addingTimeInterval(86_400))
        XCTAssertNotNil(markers["theirs"])
    }

    func testAPlacedPointSurvivesARelaunch() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statesaver-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        func launch() throws -> ServerConnections {
            let settings = MemorySettings()
            return ServerConnections(settings: settings, identities: keychain.store, me: .testing(settings),
                                     mapItemStore: try MapItemStore(url: url))
        }
        let uid: String
        do {
            let c = try launch()
            c.pointDropper.begin(.spotMap(.green))
            uid = try XCTUnwrap(c.pointDropper.click(.ground(here))).uid
            c.syncArchive()
        }
        let c = try launch()
        let m = try XCTUnwrap(c.markers[uid])
        XCTAssertEqual(m.label, "G 1")
        XCTAssertEqual(m.point, here)
        XCTAssertEqual(m.traits.color, 0xFF00_FF00)
        XCTAssertTrue(m.archived)
    }

    func testTheLegacyNamingPreferenceIsReadFromTheSettings() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        let settings = MemorySettings()
        settings.set("true", forKey: PointNaming.legacyPointDropNamingKey)
        let c = ServerConnections(settings: settings, identities: keychain.store, me: .testing(settings))
        c.pointDropper.begin(.affiliation(.hostile))
        let label = try XCTUnwrap(c.pointDropper.click(.ground(here))?.label)
        XCTAssertTrue(label.hasPrefix(c.callsign + "."), label)
    }
}
