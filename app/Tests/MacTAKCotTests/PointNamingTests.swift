// G3.9b: a dropped point's name, as 5.5's PlacePointTool makes it
// (genCallsign, placePoint's de-duplication, getCount), and the CoT a placed
// point is kept as. The expected values are read off 5.5's code at the pin.

import Foundation
import XCTest
@testable import MacTAKCot

final class PointNamingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-03 14:32:05 UTC.
    private let t = Date(timeIntervalSince1970: 1_793_716_325)

    func testGenCallsignPrefixesByType() {
        let name = { (type: String) in PointNaming.callsign(type: type, deviceCallsign: "VIPER", at: self.t, timeZone: self.utc) }
        XCTAssertEqual(name("a-h-G"), "R.3.143205", "civ_tgtPrefix, day without a zero, HHmmss")
        XCTAssertEqual(name("a-f-G"), "F.3.143205")
        XCTAssertEqual(name("a-u-G"), "U.3.143205")
        XCTAssertEqual(name("a-n-G"), "N.3.143205")
        XCTAssertEqual(name("b-m-p-s-m"), "S.3.143205")
        XCTAssertEqual(name("b-r-f-h-c"), "MED.3.143205")
        XCTAssertEqual(name("A-H-G"), "R.3.143205", "the type is lowercased first")
        XCTAssertEqual(name("b-m-p-w"), "VIPER.3.143205", "any other type: the device callsign")
    }

    func testLegacyNamingUsesTheDeviceCallsign() {
        XCTAssertEqual(PointNaming.callsign(type: "a-h-G", deviceCallsign: "VIPER", legacy: true, at: t, timeZone: utc),
                       "VIPER.3.143205")
    }

    func testGenCallsignIsInTheLocalTimeZone() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(PointNaming.callsign(type: "a-u-G", deviceCallsign: "x", at: t, timeZone: la), "U.3.063205")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(PointNaming.callsign(type: "a-u-G", deviceCallsign: "x", at: t, timeZone: tokyo), "U.3.233205")
    }

    func testDeduplicationCountsTheNameAndItsDottedForms() {
        XCTAssertEqual(PointNaming.deduplicated("U.3.143205", among: []), "U.3.143205")
        XCTAssertEqual(PointNaming.deduplicated("U.3.143205", among: ["U.3.143205"]), "U.3.143205.1")
        XCTAssertEqual(PointNaming.deduplicated("U.3.143205", among: ["U.3.143205", "U.3.143205.1"]), "U.3.143205.2")
        XCTAssertEqual(PointNaming.deduplicated("U.3.14320", among: ["U.3.143205"]), "U.3.14320",
                       "a longer name isn't a dotted form")
        // 5.5 counts, it doesn't look for a free number: one gap and it repeats a name
        XCTAssertEqual(PointNaming.deduplicated("U.3.143205", among: ["U.3.143205", "U.3.143205.2"]), "U.3.143205.2")
    }

    func testGetCountTakesTheLowestUnusedNumber() {
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: []), 1)
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["W 1", "W 2"]), 3)
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["W 2", "W 1", "W 4"]), 3, "the lowest gap")
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["w 1"]), 2, "the prefix ignores case")
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["Y 1", "Y 2"]), 1, "other colours don't count")
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["W 1", "W 1", "W 2"]), 3, "a repeated number")
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["W one", "W 1"]), 2, "an edited title reads as 0")
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["W 1 extra", "Wombat"]), 1, "other word counts")
        XCTAssertEqual(PointNaming.count(prefix: "W", titles: ["W +1", "W 02"]), 3, "parseInt's signs and zeros")
    }

    func testGetCountWithAnEmptyPrefixReadsEveryTitle() {
        // 5.5's label-only Spot Map point is named by the bare number
        XCTAssertEqual(PointNaming.count(prefix: "", titles: ["1", "3"]), 2)
        XCTAssertEqual(PointNaming.count(prefix: "", titles: ["1", "W 2"]), 2,
                       "a two-word title is compared with the empty prefix's one word, and differs")
        XCTAssertEqual(PointNaming.count(prefix: "", titles: ["1", "W 2 x", "2"]), 3,
                       "a word-count mismatch matches when the prefix is empty")
        XCTAssertEqual(PointNaming.count(prefix: "", titles: [" "]), 1, "a blank title doesn't stop it")
    }

    func testJavaSplit() {
        XCTAssertEqual(PointNaming.javaSplit("W 1"), ["W", "1"])
        XCTAssertEqual(PointNaming.javaSplit("W  1"), ["W", "", "1"])
        XCTAssertEqual(PointNaming.javaSplit("W 1 "), ["W", "1"])
        XCTAssertEqual(PointNaming.javaSplit(" W"), ["", "W"])
        XCTAssertEqual(PointNaming.javaSplit(""), [""])
        XCTAssertEqual(PointNaming.javaSplit("  "), [])
    }

    func testPaletteTypesAndIconsetPaths() {
        XCTAssertEqual(PointKind.affiliation(.hostile).type, "a-h-G")
        XCTAssertEqual(PointKind.affiliation(.hostile).iconsetPath, "COT_MAPPING_2525C/a-h/a-h-G")
        XCTAssertEqual(PointKind.affiliation(.unknown).iconsetPath, "COT_MAPPING_2525C/a-u/a-u-G")
        XCTAssertEqual(PointKind.spotMap(.white).type, "b-m-p-s-m")
        XCTAssertEqual(PointKind.spotMap(.white).iconsetPath, "COT_MAPPING_SPOTMAP/b-m-p-s-m/-1")
        XCTAssertEqual(PointKind.spotMap(.orange).iconsetPath, "COT_MAPPING_SPOTMAP/b-m-p-s-m/-35072")
        XCTAssertEqual(PointKind.spotMap(.brown).argb, 0xFF8B_4513)
        XCTAssertEqual(PointKind.spotMap(.gray).argb, 0xFF77_7777)
        XCTAssertEqual(PointKind.SpotMapColor.allCases.map(\.abbreviation),
                       ["W", "Y", "O", "Br", "R", "P", "B", "Cy", "G", "Gry", "Blk"])
        XCTAssertEqual(PointKind.Affiliation.paletteOrder, [.unknown, .neutral, .hostile, .friendly])
    }

    func testAPlacedPointsCoTFieldByField() throws {
        let p = CotPoint(lat: 37.8, lon: -122.4, hae: 12)
        let author = Author(uid: "MACTAK-1", type: "a-f-G-U-C", callsign: "VIPER", time: t)
        let event = PlacedPoint.event(uid: "pt-1", kind: .spotMap(.red), callsign: "R 1",
                                      at: .clicked(p, altitudeSource: "DTED1"), author: author, now: t)
        let parsed = try CotEvent.parse(event.xml())
        XCTAssertEqual(parsed.type, "b-m-p-s-m")
        XCTAssertEqual(parsed.how, "h-g-i-g-o")
        XCTAssertEqual(parsed.stale.timeIntervalSince(parsed.time), 31_536_000, "a year")
        XCTAssertEqual(parsed.point.hae, 12)
        XCTAssertEqual(parsed.detail?.children.map(\.name),
                       ["status", "archive", "contact", "precisionlocation", "link", "archive", "creator",
                        "usericon", "color"])
        XCTAssertEqual(parsed.detail("status")?["readiness"], "true")
        XCTAssertEqual(parsed.detail("contact")?["callsign"], "R 1")
        XCTAssertEqual(parsed.detail("precisionlocation")?.attributes.map(\.name), ["altsrc"], "no geopointsrc for a click")
        XCTAssertEqual(parsed.detail("precisionlocation")?["altsrc"], "DTED1")
        let link = try XCTUnwrap(parsed.detail("link"))
        XCTAssertEqual([link["uid"], link["type"], link["relation"], link["parent_callsign"], link["production_time"]],
                       ["MACTAK-1", "a-f-G-U-C", "p-p", "VIPER", "2026-11-03T14:32:05.000Z"])
        let creator = try XCTUnwrap(parsed.detail("creator"))
        XCTAssertEqual([creator["uid"], creator["type"], creator["callsign"], creator["time"]],
                       ["MACTAK-1", "a-f-G-U-C", "VIPER", "2026-11-03T14:32:05.000Z"])
        XCTAssertEqual(Author(creator: creator, orTime: .distantPast), author)
        XCTAssertEqual(parsed.detail("color")?["argb"], "-65536")
        XCTAssertEqual(parsed.detail("usericon")?["iconsetpath"], "COT_MAPPING_SPOTMAP/b-m-p-s-m/-65536")

        let hostile = PlacedPoint.event(uid: "pt-2", kind: .affiliation(.hostile), callsign: "R.3.143205",
                                        at: .clicked(CotPoint(lat: 37.8, lon: -122.4), altitudeSource: nil),
                                        author: nil, now: t)
        XCTAssertEqual(hostile.detail("color")?["argb"], "-1", "MarkerCreator's white")
        XCTAssertEqual(hostile.detail("precisionlocation")?["altsrc"], "???", "no elevation data")
        XCTAssertNil(hostile.detail("link"))
        XCTAssertNil(hostile.detail("creator"))
    }
}
