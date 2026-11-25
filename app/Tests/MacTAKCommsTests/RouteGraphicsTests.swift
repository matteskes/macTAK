// RouteGraphicsTests.swift — what a route draws (G3.10b), each expectation
// read off 5.5 at the pin: the line (GLPolyline over the route), its label
// (labels_on), the waypoints (b-m-p-w's icon in the route's colour, their
// names), control points hidden, a marker on the route followed.

import MacTAKCot
import XCTest
@testable import MacTAKComms

final class RouteGraphicsTests: XCTestCase {
    private func place(_ n: Int) -> CotPoint { CotPoint(lat: 37.79 + Double(n) * 0.001, lon: -122.44) }

    private func route(_ points: [RoutePoint]) -> Route {
        var r = Route(id: "r1", title: "Patrol", points: points)
        r.nameWaypoints()
        return r
    }

    private let threePoints: [RoutePoint] = [
        .waypoint(CotPoint(lat: 37.79, lon: -122.44), uid: "a"),
        .controlPoint(CotPoint(lat: 37.791, lon: -122.44), uid: "b"),
        .waypoint(CotPoint(lat: 37.792, lon: -122.44), uid: "c"),
    ]

    func testOneLineThroughEveryPointInItsColourWeightAndStyle() throws {
        var r = route(threePoints)
        r.color = -65536   // Color.RED
        r.strokeWeight = 5
        r.strokeStyle = 1
        let line = try XCTUnwrap(RouteGraphics(r).line)
        XCTAssertEqual(line.uid, "mactak-route-r1")
        XCTAssertEqual(line.points, [place(0), place(1), place(2)], "control points shape the line")
        XCTAssertEqual(line.color, 0xFFFF_0000)
        XCTAssertEqual(line.width, 5)
        XCTAssertEqual(line.style, .dashed)
        XCTAssertNil(line.label, "labels are off on a new route")
    }

    func testANewRouteIsAWhiteSolidLineThreeWide() throws {
        let line = try XCTUnwrap(RouteGraphics(route(threePoints)).line)
        XCTAssertEqual(line.color, 0xFFFF_FFFF)
        XCTAssertEqual(line.width, 3)
        XCTAssertEqual(line.style, .solid)
    }

    func testTheStylesAreFiveFivesBasicLineStyles() throws {
        var r = route(threePoints)
        for (value, style) in [(0, RouteGraphics.LineStyle.solid), (1, .dashed), (2, .dotted), (3, .outlined), (9, .solid)] {
            r.strokeStyle = value
            XCTAssertEqual(RouteGraphics(r).line?.style, style, "\(value)")
        }
    }

    func testWithLabelsOnTheLineIsLabelledWithTheTitle() {
        var r = route(threePoints)
        r.labelsOn = true
        XCTAssertEqual(RouteGraphics(r).line?.label, "Patrol")
        r.title = ""
        XCTAssertNil(RouteGraphics(r).line?.label)
    }

    func testWaypointsAreMarkersInTheRouteColourNamedControlPointsAreNot() {
        var r = route(threePoints)
        r.color = -16711936   // Color.GREEN
        let waypoints = RouteGraphics(r).waypoints
        XCTAssertEqual(waypoints.map(\.uid), ["a", "c"])
        XCTAssertEqual(waypoints.map(\.point), [place(0), place(2)])
        XCTAssertEqual(waypoints.map(\.label), ["Patrol SP", "VDO"])
        for w in waypoints {
            XCTAssertEqual(w.icon, MarkerIcon(uri: "asset://icons/gugpgpow------.png", color: 0xFF00_FF00))
        }
    }

    func testAMarkerOnTheRouteIsWhereItIsNow() throws {
        let r = route([threePoints[0], RoutePoint(uid: "hostile-1", type: "a-h-G", point: place(5)), threePoints[2]])
        let moved = CotPoint(lat: 37.8, lon: -122.45)
        let places = ["hostile-1": moved, "a": place(9)]
        let line = try XCTUnwrap(RouteGraphics(r) { places[$0] }.line)
        XCTAssertEqual(line.points, [place(0), moved, place(2)], "a waypoint is the route's own, not a marker's")
        XCTAssertEqual(RouteGraphics(r).line?.points[1], place(5), "gone from the map: where the route had it")
        XCTAssertEqual(RouteGraphics(r).waypoints.map(\.uid), ["a", "c"], "the marker isn't a waypoint")
    }

    func testFewerThanTwoPointsDrawNoLine() {
        XCTAssertNil(RouteGraphics(Route(id: "r", title: "Route 1")).line)
        let one = RouteGraphics(Route(id: "r", title: "Route 1", points: [.waypoint(place(0), uid: "a")]))
        XCTAssertNil(one.line)
        XCTAssertEqual(one.waypoints.map(\.uid), ["a"])
    }

    func testAnUnnamedWaypointHasNoLabel() {
        var r = Route(id: "r", title: "Route 1", points: threePoints)
        r.points[0].callsign = ""
        XCTAssertEqual(RouteGraphics(r).waypoints.map(\.label), [nil, nil])
    }
}
