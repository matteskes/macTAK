// RangeBearingEventTests.swift — G3.8d: a range and bearing line as CoT,
// field by field as 5.5's RangeAndBearingMapItem.toCot (and the detail
// handlers it triggers) writes it, and read back as RangeAndBearingImporter
// reads it.

import Foundation
import XCTest
@testable import MacTAKCot

final class RangeBearingEventTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let start = CotPoint(lat: 37.7749, lon: -122.4194, hae: 10)
    private let end = CotPoint(lat: 37.8044, lon: -122.2712, hae: 50)
    private let creator = RangeBearingEvent.Creator(uid: "ANDROID-1", type: "a-f-G-U-C", callsign: "VIPER",
                                                    time: Date(timeIntervalSince1970: 1_794_999_000))

    private func values(_ e: CotEvent) -> [String] {
        (e.detail?.children ?? []).map { d in
            d.name + d.attributes.map { " \($0.name)=\($0.value)" }.joined()
        }
    }

    func testToCotFieldByField() {
        let style = RangeBearing.Style(north: .grid, bearingUnits: .mils, rangeUnits: .feetMiles)
        let e = RangeBearingEvent.make(uid: "line-1", title: "R&B 1", start: start, end: end,
                                       startUID: nil, endUID: "marker-9", style: style, creator: creator, now: now)
        XCTAssertEqual(e.type, "u-rb-a")
        XCTAssertEqual(e.how, "h-e")
        XCTAssertEqual(e.uid, "line-1")
        XCTAssertEqual(e.time, now)
        XCTAssertEqual(e.start, now)
        XCTAssertEqual(e.stale, now.addingTimeInterval(86_400), "stale a day on (time.addDays(1))")
        XCTAssertEqual(e.point, start, "the point is the start's")
        // the kernel's own numbers for this pair (rab-golden geodesy row 1)
        let rab = RangeBearing(from: start, to: end)
        XCTAssertEqual(rab.range, 13458.23935238407, accuracy: 1e-6)
        XCTAssertEqual(values(e), [
            "range value=\(Cot.number(rab.range))",
            "bearing value=\(Cot.number(rab.bearing))",
            "inclination value=\(Cot.number(rab.depressionAngle))",
            "rangeUID value=marker-9",
            "rangeUnits value=0",
            "bearingUnits value=1",
            "northRef value=2",
            "contact callsign=R&B 1",
            "strokeColor value=-65536",
            "strokeWeight value=3.0",
            "strokeStyle value=solid",
            "color value=-65536",
            "creator uid=ANDROID-1 type=a-f-G-U-C callsign=VIPER time=\(Cot.time(creator.time))",
        ])
        XCTAssertGreaterThan(rab.depressionAngle, 0, "the far end is higher: up")
    }

    func testNoHeightsIsInclinationZeroAndNoUIDsNoCreator() {
        let flat = RangeBearingEvent.make(uid: "l", title: "R&B 2", start: CotPoint(lat: 1, lon: 2),
                                          end: CotPoint(lat: 1.01, lon: 2), startUID: nil, endUID: nil,
                                          style: .atak, creator: nil, now: now)
        let names = (flat.detail?.children ?? []).map(\.name)
        XCTAssertFalse(names.contains("rangeUID"))
        XCTAssertFalse(names.contains("anchorUID"))
        XCTAssertFalse(names.contains("creator"))
        XCTAssertEqual(flat.detail("inclination")?["value"], "0.0", "5.5's _depAngle stays 0 without a slant range")
        XCTAssertEqual(flat.detail("northRef")?["value"], "1", "magnetic by default")
        XCTAssertEqual(flat.detail("rangeUnits")?["value"], "1", "metric by default")
    }

    func testReadBack() throws {
        let e = RangeBearingEvent.make(uid: "line-1", title: "R&B 1", start: start, end: end,
                                       startUID: "anchor-1", endUID: nil, style: .atak, color: -16_776_961,
                                       creator: creator, now: now)
        let parsed = try CotEvent.parse(e.xml(), now: now)
        let r = try XCTUnwrap(RangeBearingEvent.parse(parsed))
        XCTAssertEqual(r.uid, "line-1")
        XCTAssertEqual(r.title, "R&B 1")
        XCTAssertEqual(r.anchorUID, "anchor-1")
        XCTAssertNil(r.rangeUID)
        XCTAssertEqual(r.color, -16_776_961)
        XCTAssertEqual(r.weight, 3)
        XCTAssertEqual(r.creator?.uid, "ANDROID-1")
        XCTAssertEqual(r.creator?.callsign, "VIPER")
        XCTAssertEqual(r.creator?.time, creator.time)
        let far = r.farEnd
        XCTAssertLessThan(Geodesy.distance(lat1: far.lat, lon1: far.lon, lat2: end.lat, lon2: end.lon), 0.01)
        // the engine's flat-earth height: start + tan(inclination) × range,
        // 17 m over the true one at 13 km (no curvature), kept as 5.5 has it
        let rab = RangeBearing(from: start, to: end)
        XCTAssertEqual(far.hae, start.hae + tan(rab.depressionAngle * .pi / 180) * rab.range, accuracy: 1e-6)
    }

    func testImporterDefaults() throws {
        let bare = CotEvent(uid: "x", type: "u-rb-a", time: now, stale: now, how: "h-e", point: start,
                            detail: CotDetail("detail"))
        let r = try XCTUnwrap(RangeBearingEvent.parse(bare))
        XCTAssertNil(r.title, "the caller names it R&B n")
        XCTAssertEqual(r.range, -1)
        XCTAssertEqual(r.bearing, -1)
        XCTAssertTrue(r.inclination.isNaN)
        XCTAssertEqual(r.color, RangeBearingEvent.red)
        XCTAssertNil(r.weight)
        XCTAssertNil(r.creator)
        XCTAssertNil(RangeBearingEvent.parse(CotEvent(uid: "x", type: "a-f-G", time: now, stale: now, how: "h-e")))
    }

    /// StrokeFillDetailHandler runs after the importer: strokeColor wins
    /// (white when it doesn't parse), and strokeWeight 6.0 when it doesn't.
    func testStrokeDetailsWin() throws {
        var d = CotDetail("detail")
        for (name, v) in [("color", "-65536"), ("strokeColor", "-16711936"), ("strokeWeight", "wide")] {
            var c = CotDetail(name); c["value"] = v; d.add(c)
        }
        let e = CotEvent(uid: "x", type: "u-rb-a", time: now, stale: now, how: "h-e", point: start, detail: d)
        let r = try XCTUnwrap(RangeBearingEvent.parse(e))
        XCTAssertEqual(r.color, -16_711_936)
        XCTAssertEqual(r.weight, 6.0)
        var bad = CotDetail("strokeColor"); bad["value"] = "green"
        var d2 = CotDetail("detail"); d2.add(bad)
        let e2 = CotEvent(uid: "x", type: "u-rb-a", time: now, stale: now, how: "h-e", point: start, detail: d2)
        XCTAssertEqual(RangeBearingEvent.parse(e2)?.color, -1, "white")
    }
}
