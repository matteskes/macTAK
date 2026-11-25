// G3.10c: a route's details as 5.5's route details show them
// (Route.getRouteDetails, RoutePlannerView's totals, SpanUtilities), and
// the route's edits (InsertPointAction, RouteRemovePointAction,
// removeMarker, RouteExchangePointAction, RouteSetPointName, the details
// dialog's direction).

import MacTAKCot
import XCTest

final class RouteDetailsTests: XCTestCase {
    private func p(_ n: Double, hae: Double = CotPoint.unknown) -> CotPoint {
        CotPoint(lat: 37.79 + n * 0.001, lon: -122.44, hae: hae)
    }

    private func d(_ a: CotPoint, _ b: CotPoint) -> Double {
        Geodesy.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    private func route(_ points: [RoutePoint]) -> Route {
        var r = Route(id: "r1", title: "Patrol", points: points)
        r.nameWaypoints()
        return r
    }

    // MARK: - getRouteDetails

    func testARowPerWaypointEachLegThroughItsControlPoints() {
        let r = route([.waypoint(p(0), uid: "a"), .controlPoint(p(1), uid: "b"), .waypoint(p(3), uid: "c"),
                       .controlPoint(p(4), uid: "d"), .waypoint(p(5), uid: "e")])
        let details = RouteDetails(r)
        XCTAssertEqual(details.rows.map(\.uid), ["a", "c", "e"])
        XCTAssertEqual(details.rows.map(\.name), ["Patrol SP", "CP1", "VDO"])
        XCTAssertNil(details.rows[0].meters, "the first row has no leg")
        XCTAssertEqual(details.rows[1].meters!, d(p(0), p(1)) + d(p(1), p(3)), accuracy: 1e-6)
        XCTAssertEqual(details.rows[2].meters!, d(p(3), p(4)) + d(p(4), p(5)), accuracy: 1e-6)
        XCTAssertEqual(details.totalMeters, d(p(0), p(5)), accuracy: 1e-3)
    }

    func testAMarkerOnTheRouteOnlyAddsDistance() {
        let r = route([.waypoint(p(0), uid: "a"), RoutePoint(uid: "h", type: "a-h-G", point: p(1)),
                       .waypoint(p(2), uid: "c")])
        XCTAssertEqual(RouteDetails(r).rows.map(\.uid), ["a", "c"])
    }

    func testTheLineWhereItIsNow() {
        let r = route([.waypoint(p(0), uid: "a"), .waypoint(p(1), uid: "b")])
        let details = RouteDetails(r, points: [p(0), p(2)])
        XCTAssertEqual(details.rows[1].meters!, d(p(0), p(2)), accuracy: 1e-6)
    }

    func testAnUnnamedWaypointIsWptN() {
        var r = route([.waypoint(p(0), uid: "a"), .waypoint(p(1), uid: "b")])
        r.points[1].callsign = ""
        XCTAssertEqual(RouteDetails(r).rows.map(\.name), ["Patrol SP", "Wpt#2"])
    }

    func testAClimbOnlyWhenBothAltitudesAreKnownAndItClimbs() {
        let r = route([.waypoint(p(0, hae: 10), uid: "a"), .waypoint(p(1, hae: 40), uid: "b"),
                       .waypoint(p(2, hae: 20), uid: "c"), .waypoint(p(3), uid: "d"), .waypoint(p(4, hae: 90), uid: "e")])
        let details = RouteDetails(r)
        XCTAssertEqual(details.rows.map(\.gain), [nil, 30, nil, nil, nil])
        XCTAssertEqual(details.totalGain, 80, "the highest less the lowest")
        XCTAssertNil(RouteDetails(route([.waypoint(p(0), uid: "a"), .waypoint(p(1), uid: "b")])).totalGain)
    }

    // MARK: - the text

    func testLegsAreKilometresWhenMetricElseMilesOrNauticalMiles() {
        XCTAssertEqual(RouteDetails.legText(1234.5, method: .driving, units: .metersKilometers), "1.23 km")
        XCTAssertEqual(RouteDetails.legText(150, method: .driving, units: .metersKilometers), "0.15 km",
                       "never metres: format(METER, KILOMETER)")
        XCTAssertEqual(RouteDetails.legText(1609.344, method: .walking, units: .feetMiles), "1.00 mi")
        XCTAssertEqual(RouteDetails.legText(1852, method: .flying, units: .feetMiles), "1.00 NM")
        XCTAssertEqual(RouteDetails.legText(1852, method: .watercraft, units: .nauticalMiles), "1.00 NM")
        XCTAssertEqual(RouteDetails.legText(1852, method: .flying, units: .metersKilometers), "1.85 km")
        XCTAssertEqual(RouteDetails.legText(nil, method: .driving, units: .feetMiles), "--")
    }

    func testFixedUnitsAsSpanUtilitiesFormat() {
        XCTAssertEqual(RangeBearingText.fixed(150_000, .kilometers), "150.0 km")
        XCTAssertEqual(RangeBearingText.fixed(2_345_678, .kilometers), "2,346 km")
        XCTAssertEqual(RangeBearingText.fixed(30.48, .feet), "100 ft")
        XCTAssertEqual(RangeBearingText.fixed(1000, .feet), "3,281 ft")
    }

    func testClimbsInFeet() {
        XCTAssertEqual(RouteDetails.gainText(30), "+ 98 ft")
        XCTAssertEqual(RouteDetails.gainText(nil), "--")
        XCTAssertEqual(RouteDetails.gainText(0), "--")
    }

    func testTotalsInTheRangeUnitsOwnWay() {
        XCTAssertEqual(RouteDetails.totalText(1500, method: .driving, units: .metersKilometers), "1,500 m")
        XCTAssertEqual(RouteDetails.totalText(2500, method: .driving, units: .metersKilometers), "2.50 km")
        XCTAssertEqual(RouteDetails.totalText(500, method: .driving, units: .feetMiles), "1,640 ft")
        XCTAssertEqual(RouteDetails.totalText(1852, method: .flying, units: .feetMiles), "1.00 NM")
    }

    // MARK: - the edits

    func testInsertAndRemoveRenameTheWaypoints() {
        var r = route([.waypoint(p(0), uid: "a"), .waypoint(p(2), uid: "c")])
        r.insert(.waypoint(p(1), uid: "b"), at: 1)
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol SP", "CP1", "VDO"])
        r.removePoint(at: 1)
        XCTAssertEqual(r.points.map(\.uid), ["a", "c"])
        r.insert(.controlPoint(p(9), uid: "z"), at: 99)
        XCTAssertEqual(r.points.last?.uid, "z", "clamped to the end")
    }

    func testAWaypointBecomesAControlPointWhereItIs() {
        var r = route([.waypoint(p(0), uid: "a"), .waypoint(p(1), uid: "b"), .waypoint(p(2), uid: "c")])
        r.makeControlPoint(at: 1, uid: "n")
        XCTAssertEqual(r.points[1], .controlPoint(p(1), uid: "n"))
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol SP", nil, "VDO"])
        r.makeWaypoint(at: 1, uid: "m")
        XCTAssertEqual(r.points[1].uid, "m")
        XCTAssertEqual(r.points[1].callsign, "CP1")
    }

    func testANamedWaypointKeepsItsName() {
        var r = route([.waypoint(p(0), uid: "a"), .waypoint(p(1), uid: "b"), .waypoint(p(2), uid: "c")])
        r.renamePoint("b", to: "Bridge")
        r.insert(.waypoint(p(0.5), uid: "x"), at: 1)
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol SP", "CP1", "Bridge", "VDO"])
    }

    func testExfilSetsDescendingCheckPoints() {
        var r = route([.waypoint(p(0), uid: "a"), .waypoint(p(1), uid: "b"), .waypoint(p(2), uid: "c"),
                       .waypoint(p(3), uid: "d")])
        r.setDirection(.exfil)
        XCTAssertEqual(r.order, .descending)
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol VPU", "CP2", "CP1", "EP"])
        r.setDirection(.infil)
        XCTAssertEqual(r.order, .ascending)
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol SP", "CP1", "CP2", "VDO"])
    }
}
