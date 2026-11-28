// CotModelTests.swift — the CoT model's own rules (G3.4): what it refuses,
// the kernel's defaults it keeps, and the SA details' readings.

import Foundation
import XCTest
@testable import MacTAKCot

final class CotModelTests: XCTestCase {
    private let t = "2026-11-17T12:00:00.000Z"

    private func event(_ body: String, attributes: String = "uid='u' type='a-f-G'") -> String {
        "<event version='2.0' \(attributes) time='\(t)' start='\(t)' stale='\(t)' how='m-g'>\(body)</event>"
    }

    func testRefusesADoctype() {
        let xml = "<!DOCTYPE event [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + event("<detail><remarks>&x;</remarks></detail>")
        XCTAssertThrowsError(try CotEvent.parse(xml)) { XCTAssertEqual($0 as? CotParseError, .doctype) }
    }

    func testRefusesWhatIsNotAnEvent() {
        XCTAssertThrowsError(try CotEvent.parse("<chat/>")) { XCTAssertEqual($0 as? CotParseError, .notAnEvent(root: "chat")) }
        XCTAssertThrowsError(try CotEvent.parse("not xml")) { XCTAssertNotNil($0 as? CotParseError) }
    }

    func testRequiresUidTypeAndAPointsLatLon() {
        XCTAssertThrowsError(try CotEvent.parse(event("", attributes: "type='a-f-G'"))) {
            XCTAssertEqual($0 as? CotParseError, .missing("uid"))
        }
        XCTAssertThrowsError(try CotEvent.parse(event("", attributes: "uid='u'"))) {
            XCTAssertEqual($0 as? CotParseError, .missing("type"))
        }
        XCTAssertThrowsError(try CotEvent.parse(event("<point lat='x' lon='1'/>"))) {
            XCTAssertEqual($0 as? CotParseError, .missing("point lat"))
        }
    }

    func testKeepsTheKernelsPointDefaults() throws {
        let missing = try CotEvent.parse(event(""))
        XCTAssertEqual(missing.point, .zero)
        let nan = try CotEvent.parse(event("<point lat='1' lon='2' hae='NaN' ce='bad'/>"))
        XCTAssertEqual(nan.point, CotPoint(lat: 1, lon: 2))
        XCTAssertEqual(nan.point.hae, CotPoint.unknown)
        XCTAssertEqual(nan.point.ce, CotPoint.unknown)
    }

    // d: the kernel's CotPoint.isInvalid on the CoT side, and the map side's
    // GeoPoint.isAltitudeValid range on top (validAltitude).

    func testCotKeepsAnyAltitudeButTheMapTakesOnlyGeoPointsRange() throws {
        XCTAssertTrue(CotPoint.isInvalid(CotPoint.unknown))
        XCTAssertTrue(CotPoint.isInvalid(.nan))
        XCTAssertFalse(CotPoint.isInvalid(80_000), "CoT keeps it as it came")
        let high = try CotEvent.parse(event("<point lat='1' lon='2' hae='80000'/>")).point
        XCTAssertEqual(high.hae, 80_000)
        XCTAssertNil(high.validAltitude, "above GeoPoint's 76000 m")
        XCTAssertNil(CotPoint(lat: 1, lon: 2, hae: -14_001).validAltitude, "below −14000 m")
        XCTAssertEqual(CotPoint(lat: 1, lon: 2, hae: -14_000).validAltitude, -14_000)
        XCTAssertEqual(CotPoint(lat: 1, lon: 2, hae: 76_000).validAltitude, 76_000)
        XCTAssertNil(CotPoint(lat: 1, lon: 2).validAltitude, "unknown")
    }

    // d: MarkerImporter's autoStaleDuration, (3 × (stale − start)) / 2 in
    // Java's whole milliseconds.

    func testAutoStaleIsOneAndAHalfTimesInWholeMilliseconds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func autoStale(after millis: Double) -> TimeInterval {
            CotEvent(uid: "u", type: "a-f-G", time: start, stale: start.addingTimeInterval(millis / 1000),
                     how: "m-g").autoStaleDuration
        }
        XCTAssertEqual(autoStale(after: 60_000), 90)
        XCTAssertEqual(autoStale(after: 1), 0.001, "3 / 2 is 1 in Java's long division, not 1.5")
        XCTAssertEqual(autoStale(after: 3), 0.004, "9 / 2 is 4")
        XCTAssertEqual(autoStale(after: -5_000), 0, "a stale before the start is 0")
    }

    func testReadsTimesWithAndWithoutFractions() throws {
        let e = try CotEvent.parse("<event uid='u' type='t' time='2026-11-17T12:00:00Z' start='2026-11-17T12:00:00.5Z' stale='junk' how='m-g'/>",
                                   now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Cot.time(e.time), "2026-11-17T12:00:00.000Z")
        XCTAssertEqual(Cot.time(e.start), "2026-11-17T12:00:00.500Z")
        XCTAssertEqual(e.stale, Date(timeIntervalSince1970: 0), "an unreadable stale is now")
    }

    func testOnlyALeafKeepsText() throws {
        let e = try CotEvent.parse(event("<detail><a>  x  </a><b>y<c/></b></detail>"))
        XCTAssertEqual(e.detail("a")?.innerText, "x")
        XCTAssertNil(e.detail("b")?.innerText)
    }

    func testEscapesEverythingItWrites() {
        var s = SelfEvent(uid: "a'b", callsign: "O'BRIEN & <CO>\n")
        s.remarks = "tab\there"
        let xml = s.event(at: Date(timeIntervalSince1970: 0), stale: 30).xml()
        XCTAssertTrue(xml.contains("uid='a&apos;b'"))
        XCTAssertTrue(xml.contains("callsign='O&apos;BRIEN &amp; &lt;CO&gt;&#10;'"))
        XCTAssertTrue(xml.contains("<remarks>tab&#9;here</remarks>"))
        XCTAssertFalse(xml.contains("O'BRIEN"))
        XCTAssertEqual(try CotEvent.parse(xml).detail("contact")?["callsign"], "O'BRIEN & <CO>\n")
    }

    func testGroupReadsLikeTheKernelsHandler() throws {
        let e = try CotEvent.parse(event("<detail><__group name='dark BLUE' role='Medic' exrole='Combat Lifesaver' abbr='CLS' typeicon='TRUE'/></detail>"))
        XCTAssertEqual(GroupDetail(e.detail("__group")),
                       GroupDetail(team: "Dark Blue", role: "Medic", customRole: "Combat Lifesaver",
                                   customRoleAbbreviation: "CLS", displayAsSymbologyGraphic: true))
        XCTAssertEqual(GroupDetail.validTeam("Puce"), "Pink")
        XCTAssertEqual(GroupDetail.validTeam("rad sensor"), "Yellow")
        let bare = try XCTUnwrap(GroupDetail(CotEvent.parse(event("<detail><__group name=''/></detail>")).detail("__group")))
        XCTAssertNil(bare.team)
        XCTAssertEqual(bare.role, GroupDetail.defaultRole)
    }

    func testSelfEventHowFollowsTheSource() {
        var s = SelfEvent(uid: "u", callsign: "c")
        XCTAssertEqual(s.how, "h-g-i-g-o")
        XCTAssertNil(s.precision)
        s.location = .init(point: CotPoint(lat: 1, lon: 2), source: .manual)
        XCTAssertEqual(s.how, "h-e")
        XCTAssertEqual(s.precision, PrecisionLocation(geopointSource: "USER", altitudeSource: "???"))
        s.location = .init(point: CotPoint(lat: 1, lon: 2, hae: 30), source: .manual)
        XCTAssertEqual(s.precision?.altitudeSource, "USER")
        s.location = .init(point: CotPoint(lat: 1, lon: 2, hae: 80_000), source: .manual)
        XCTAssertEqual(s.precision?.altitudeSource, "???", "outside GeoPoint's range is no altitude")
        s.location?.source = .provider
        XCTAssertEqual(s.how, "m-g")
        XCTAssertEqual(s.precision, PrecisionLocation(geopointSource: "GPS", altitudeSource: "GPS"))
    }

    func testSelfEventDetailsInATAKsOrder() {
        var s = SelfEvent(uid: "u", callsign: "c")
        s.remarks = "r"
        s.location = .init(point: CotPoint(lat: 1, lon: 2), source: .provider)
        let names = s.event(stale: 30).detail?.children.map(\.name)
        XCTAssertEqual(names, ["takv", "contact", "remarks", "uid", "precisionlocation", "__group", "status", "track"])
    }

    func testTrackGuardsAgainstNonsense() {
        let d = Track(speed: .nan, course: -.infinity).detail
        XCTAssertEqual(d["speed"], "0.0")
        XCTAssertEqual(d["course"], "0.0")
    }
}
