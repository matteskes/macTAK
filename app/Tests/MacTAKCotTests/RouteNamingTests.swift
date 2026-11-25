// RouteNamingTests.swift — G3.10a's naming gate: a route's name and its
// waypoints' names follow ATAK 5.5's Route (getNewRoute,
// getFirstWaypointName, getLastWaypointName, isAutomaticName,
// validateWaypointNamesNoSync, fixSPandVDO), each expectation read off
// 5.5's code at the pin.

import XCTest
@testable import MacTAKCot

final class RouteNamingTests: XCTestCase {
    private func place(_ n: Int) -> CotPoint { CotPoint(lat: 37.79 + Double(n) * 0.001, lon: -122.44) }

    private func route(_ types: [String], method: Route.Method = .driving, direction: Route.Direction = .infil,
                       order: Route.Order = .ascending, prefix: String = "CP") -> Route {
        var r = Route(id: "r", title: "Route 1",
                      points: types.enumerated().map { RoutePoint(uid: "p\($0.offset)", type: $0.element, point: place($0.offset)) },
                      direction: direction, order: order, prefix: prefix)
        r.setMethod(method)
        return r
    }

    private let w = Route.waypointType, c = Route.controlPointType

    func testANewRouteIsRouteNOneMoreThanTheRoutesThere() {
        XCTAssertEqual(Route.newTitle(among: []), "Route 1")
        XCTAssertEqual(Route.newTitle(among: ["Route 1"]), "Route 2")
        XCTAssertEqual(Route.newTitle(among: ["Patrol", "Recce"]), "Route 3", "every route counts, named or not")
        XCTAssertEqual(Route.newTitle(among: ["Route 2"]), "Route 3", "a name in use is skipped")
        XCTAssertEqual(Route.newTitle(among: ["Route 4", "Route 3", "Route 5"]), "Route 6")
    }

    func testTheEndsAreNamedByMethodAndDirection() {
        let cases: [(Route.Method, Route.Direction, String, String)] = [
            (.driving, .infil, "Route 1 SP", "VDO"),
            (.driving, .exfil, "Route 1 VPU", "EP"),
            (.walking, .infil, "Route 1 SP", "TGT"),
            (.walking, .exfil, "Route 1 TGT", "EP"),
            (.flying, .infil, "Route 1 SP", "TGT"),
            (.swimming, .exfil, "Route 1 TGT", "EP"),
            (.watercraft, .infil, "Route 1 SP", "TGT"),
        ]
        for (method, direction, first, last) in cases {
            let r = route([w, w], method: method, direction: direction)
            XCTAssertEqual([r.firstWaypointName, r.lastWaypointName], [first, last], "\(method) \(direction)")
        }
    }

    func testAutomaticNames() {
        let r = route([w, w])
        for name in [nil, "SP", "VDO", "EP", "TGT", "VPU", "Route 1 SP", "Old title VDO", "CP", "CP1", "CP27", "CP\u{0663}"] {
            XCTAssertTrue(r.isAutomaticName(name), name ?? "nil")
        }
        for name in ["", "Ferry wharf", "CPx", "CP1a", "cp1", "WP1", "SPX", "Route 1SP"] {
            XCTAssertFalse(r.isAutomaticName(name), name)
        }
        let noPrefix = route([w, w], prefix: "")
        XCTAssertTrue(noPrefix.isAutomaticName(""), "the empty prefix and no digits")
        XCTAssertTrue(noPrefix.isAutomaticName("12"))
    }

    func testWaypointsAreNumberedUpBetweenTheEnds() {
        var r = route([w, c, w, w, c, w])
        r.nameWaypoints()
        XCTAssertEqual(r.points.map { $0.callsign }, ["Route 1 SP", nil, "CP1", "CP2", nil, "VDO"])
    }

    func testDescendingCountsDownToOne() {
        var r = route([w, w, w, w, w], order: .descending)
        r.nameWaypoints()
        XCTAssertEqual(r.points.map { $0.callsign }, ["Route 1 SP", "CP3", "CP2", "CP1", "VDO"])
    }

    func testAUserNameIsKeptAndStillTakesItsNumber() {
        var r = route([w, w, w, w, w])
        r.points[2].callsign = "Ferry wharf"
        r.nameWaypoints()
        XCTAssertEqual(r.points.map { $0.callsign }, ["Route 1 SP", "CP1", "Ferry wharf", "CP3", "VDO"])
        r.order = .descending
        r.nameWaypoints()
        XCTAssertEqual(r.points.map { $0.callsign }, ["Route 1 SP", "CP3", "Ferry wharf", "CP1", "VDO"])
    }

    func testRenamingTheRouteOrChangingItsMethodRenamesTheEnds() {
        var r = route([w, w, w])
        r.nameWaypoints()
        r.title = "Patrol"
        r.setMethod(.walking)
        r.direction = .exfil
        XCTAssertTrue(r.nameWaypoints())
        XCTAssertEqual(r.points.map { $0.callsign }, ["Patrol TGT", "CP1", "EP"])
        XCTAssertFalse(r.nameWaypoints(), "nothing left to change")
    }

    func testAnotherItemOnTheRouteIsNotAWaypoint() {
        var r = route([w, "a-f-G", w, w])
        r.nameWaypoints()
        XCTAssertEqual(r.points.map { $0.callsign }, ["Route 1 SP", nil, "CP1", "VDO"])
    }

    func testFixEndsMakesTheEndsWaypoints() {
        var r = route([c, c, w, c])
        var n = 0
        r.fixEnds { n += 1; return "new-\(n)" }
        XCTAssertEqual(r.points.map(\.uid), ["new-1", "p1", "p2", "new-2"], "an end that isn't a waypoint is replaced")
        XCTAssertEqual(r.points.map(\.type), [w, c, w, w])
        XCTAssertEqual(r.points.first?.point, place(0), "in its place")
        XCTAssertEqual(r.points.map { $0.callsign }, ["Route 1 SP", nil, "CP1", "VDO"])
    }

    func testFixEndsLeavesAOnePointRouteAlone() {
        var r = route([c])
        r.fixEnds { "new" }
        XCTAssertEqual(r.points.map(\.type), [c])
    }

    func testTheMethodSetsTheTransport() {
        var r = route([w, w])
        XCTAssertEqual(r.transportType, Route.vehicle, "Driving")
        for (method, transport) in [(Route.Method.walking, Route.onFoot), (.swimming, Route.onFoot),
                                    (.flying, Route.vehicle), (.watercraft, Route.vehicle)] {
            r.setMethod(method)
            XCTAssertEqual(r.transportType, transport, "\(method)")
        }
    }
}
