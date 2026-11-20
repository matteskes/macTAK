// The R&B label and details table (G3.8a): 5.5's updateLabel and
// RangeAndBearingTableHandler put together from the golden-tested parts
// (RangeBearingTests). These strings were checked against 5.5's code by
// reading: the arrow, three spaces, the north letter straight after the
// unit ("4,145 milsG"), the ground range unless slant range is on and both
// heights are known, and the up or down angle only then.

import XCTest
@testable import MacTAKCot

final class RangeBearingLabelTests: XCTestCase {
    private let dc = CotPoint(lat: 38.8977, lon: -77.0365, hae: 20)
    private let southwest = CotPoint(lat: 38.8893, lon: -77.0502, hae: 10)
    private let northeast = CotPoint(lat: 38.9200, lon: -77.0100, hae: 400)
    private let noHeight = CotPoint(lat: 39.2904, lon: -76.6122, hae: CotPoint.unknown)

    private func label(_ from: CotPoint, _ to: CotPoint, _ style: RangeBearing.Style) -> String? {
        RangeBearing(from: from, to: to).label(style, magnetic: nil)
    }

    func testTheLabelIs5_5s() {
        let trueNorth = RangeBearing.Style(north: .true)
        let gridMilsFeet = RangeBearing.Style(north: .grid, bearingUnits: .mils, rangeUnits: .feetMiles)
        let slantNM = RangeBearing.Style(north: .true, rangeUnits: .nauticalMiles, slantRange: true)
        let slantMils = RangeBearing.Style(north: .grid, bearingUnits: .mils, slantRange: true)

        XCTAssertEqual(label(dc, southwest, trueNorth), "← 232°T   1,511 m", "west of south: the left arrow")
        XCTAssertEqual(label(dc, southwest, gridMilsFeet), "← 4,145 milsG   4,956 ft")
        XCTAssertEqual(label(dc, southwest, slantNM), "← 232°T   0.82 NM   0°↓", "down, rounded to 0")
        XCTAssertEqual(label(dc, southwest, slantMils), "← 4,145 milsG   1,511 m   7 mils↓")

        XCTAssertEqual(label(dc, northeast, trueNorth), "→ 43°T   3.38 km")
        XCTAssertEqual(label(dc, northeast, gridMilsFeet), "→ 785 milsG   2.10 mi")
        XCTAssertEqual(label(dc, northeast, slantNM), "→ 43°T   1.84 NM   6°↑", "the slant range, and up")
        XCTAssertEqual(label(dc, northeast, slantMils), "→ 785 milsG   3.40 km   114 mils↑")

        XCTAssertEqual(label(dc, noHeight, slantNM), "→ 40°T   30.77 NM", "no height: ground range, no angle")
        XCTAssertEqual(label(southwest, dc, slantNM), "→ 52°T   0.82 NM   0°↑")
    }

    func testMagneticNorthNeedsTheModel() throws {
        let rab = RangeBearing(from: dc, to: southwest)
        XCTAssertNil(rab.label(.atak, magnetic: nil), "5.5's default is magnetic")
        let model = try MagneticModel(contentsOf: RangeBearingTests.wmmCof)
        let label = try XCTUnwrap(rab.label(.atak, magnetic: model))
        XCTAssertTrue(label.hasPrefix("← 24") && label.hasSuffix("°M   1,511 m"), label)   // about 10.4° W in DC
    }

    func testTheDetailsTableIs5_5s() throws {
        let t = RangeBearing(from: dc, to: northeast).table(magnetic: nil)
        XCTAssertEqual([t.feetMiles, t.metersKilometers, t.nauticalMiles], ["2.10 mi", "3.38 km", "1.82 NM"])
        XCTAssertEqual([t.trueDegrees, t.trueMils], ["43°T", "762 milsT"])
        XCTAssertNil(t.magneticDegrees)
        XCTAssertEqual(t.cardinal, "NE")
        let model = try MagneticModel(contentsOf: RangeBearingTests.wmmCof)
        // a fixed day: magnetic north moves (about 0.1° a year in DC)
        let day = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        let m = RangeBearing(from: dc, to: northeast).table(magnetic: model, at: day)
        XCTAssertEqual(m.magneticDegrees, "53°M", "42.9° true, declination 10.4° W")
        XCTAssertEqual(m.magneticMils?.hasSuffix(" milsM"), true)
    }
}
