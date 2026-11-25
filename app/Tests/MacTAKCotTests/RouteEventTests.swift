// RouteEventTests.swift — a b-m-r event read as ATAK 5.5's RouteImporter
// reads it (G3.10a): its defaults, its links, what it refuses, and the
// details the handlers set after <link_attr>. What a route writes is the
// golden test's (GoldenTests.testRoutesAreWhatTheKernelBuilds).

import XCTest
@testable import MacTAKCot

final class RouteEventTests: XCTestCase {
    private let time = Cot.parseTime("2026-11-24T18:20:00.000Z")!

    private func event(_ details: String) throws -> CotEvent {
        try CotEvent.parse("""
            <event version='2.0' uid='r-1' type='b-m-r' time='2026-11-24T18:20:00.000Z' \
            start='2026-11-24T18:20:00.000Z' stale='2026-11-25T18:20:00.000Z' how='h-e'>\
            <point lat='0' lon='0' hae='9999999' ce='9999999' le='9999999'/><detail>\(details)</detail></event>
            """, now: time)
    }

    private let twoLinks = """
        <link point='37.79,-122.44' type='b-m-p-w' uid='a' relation='c' callsign='Route 1 SP' remarks=''/>\
        <link point='37.80,-122.43,15.5' type='b-m-p-w' uid='b' relation='c' callsign='VDO' remarks='end'/>
        """

    private func read(_ e: CotEvent, onto existing: Route? = nil, items: Set<String> = []) -> Route? {
        var n = 0
        return RouteEvent.read(e, onto: existing, isItem: { items.contains($0) },
                               newUID: { n += 1; return "made-\(n)" }, newTitle: { "Route 9" })
    }

    func testANewRouteWithoutLinkAttrTakesTheImportersDefaults() throws {
        let r = try XCTUnwrap(read(event(twoLinks)))
        XCTAssertEqual(r.title, "Route 9", "no contact: getNewRoute's name")
        XCTAssertEqual(r.color, Route.white)
        XCTAssertEqual(r.transportType, Route.vehicle, "setRouteMethod(Driving) runs after setTransportationType(On Foot)")
        XCTAssertEqual([r.method, r.direction, r.kind, r.order] as [AnyHashable],
                       [Route.Method.driving, Route.Direction.infil, Route.Kind.primary, Route.Order.ascending] as [AnyHashable])
        XCTAssertEqual(r.planningMethod, "Infil")
        XCTAssertEqual(r.prefix, "CP")
        XCTAssertEqual(r.strokeWeight, 3)
        XCTAssertEqual(r.points.map(\.callsign), ["Route 1 SP", "VDO"])
        XCTAssertEqual(r.points[1].remarks, "end")
        XCTAssertEqual(r.points[1].point.hae, 15.5)
    }

    func testLinkAttrSetsWhatItHas() throws {
        let r = try XCTUnwrap(read(event(twoLinks + """
            <link_attr color='-65536' stroke='5' style='2' type='Boat' method='Walking' direction='Exfil' \
            routetype='Tertiary' order='Descending' planningmethod='Exfil' prefix='WP'/><contact callsign='Patrol'/>
            """)))
        XCTAssertEqual(r.title, "Patrol")
        XCTAssertEqual(r.color, -65536)
        XCTAssertEqual(r.transportType, Route.onFoot, "the method sets the transport after type")
        XCTAssertEqual([r.method, r.direction, r.kind, r.order] as [AnyHashable],
                       [Route.Method.walking, Route.Direction.exfil, Route.Kind.tertiary, Route.Order.descending] as [AnyHashable])
        XCTAssertEqual(r.planningMethod, "Exfil")
        XCTAssertEqual(r.prefix, "WP")
        XCTAssertEqual(r.strokeWeight, 5)
        XCTAssertEqual(r.strokeStyle, 2)
    }

    func testValuesFiveFiveDoesntKnowAreIgnored() throws {
        let r = try XCTUnwrap(read(event(twoLinks + """
            <link_attr color='-1' type='Hovercraft' method='Teleport' direction='Sideways' routetype='Best' \
            order='Random' stroke='3.5'/>
            """)))
        XCTAssertEqual(r.transportType, "Hovercraft", "no method to set it again")
        XCTAssertEqual(r.method, .driving)
        XCTAssertEqual(r.direction, .infil)
        XCTAssertEqual(r.kind, .primary)
        XCTAssertEqual(r.order, .ascending)
        XCTAssertEqual(r.strokeWeight, 3, "stroke isn't an int: parseInt fails and it is left")
    }

    func testAColourThatIsntANumberRefusesTheRoute() throws {
        XCTAssertNil(read(try event(twoLinks + "<link_attr color='red'/>")))
        XCTAssertNil(read(try event(twoLinks + "<link_attr type='Vehicle'/>")), "Integer.parseInt(null)")
    }

    func testFewerThanTwoPointsRefusesTheRoute() throws {
        XCTAssertNil(read(try event("<link point='37.79,-122.44' type='b-m-p-w' uid='a'/>")))
        XCTAssertNil(read(try event("<link point='37.79,-122.44' uid='a'/><link point='nowhere' uid='b'/>")),
                     "a link whose point doesn't parse is dropped")
        XCTAssertNil(read(try event("")))
    }

    func testALinkWithoutUIDOrTypeIsAControlPoint() throws {
        let r = try XCTUnwrap(read(event("""
            <link point='37.79,-122.44' callsign='ignored'/><link point='37.80,-122.43' uid='b' callsign='x'/>
            """)))
        XCTAssertEqual(r.points.map(\.uid), ["made-1", "b"])
        XCTAssertEqual(r.points.map(\.type), [Route.controlPointType, Route.controlPointType])
        XCTAssertEqual(r.points.map(\.callsign), [nil, nil], "a control point has no name")
    }

    func testAnotherTypeIsTheItemWhenItIsHereElseAControlPoint() throws {
        let e = try event("""
            <link point='37.79,-122.44' uid='marker-1' type='a-f-G'/><link point='37.80,-122.43' uid='gone' type='a-h-G'/>
            """)
        let r = try XCTUnwrap(read(e, items: ["marker-1"]))
        XCTAssertEqual(r.points.map(\.type), ["a-f-G", Route.controlPointType])
        XCTAssertEqual(r.points.map(\.uid), ["marker-1", "gone"])
    }

    func testTheStrokeDetailsSetTheLineAfterLinkAttr() throws {
        let r = try XCTUnwrap(read(event(twoLinks + """
            <link_attr color='-65536' stroke='3' style='0'/><strokeColor value='-16776961'/>\
            <strokeWeight value='4.5'/><strokeStyle value='dotted'/><labels_on value='true'/>
            """)))
        XCTAssertEqual(r.color, -16776961)
        XCTAssertEqual(r.strokeWeight, 4.5)
        XCTAssertEqual(r.strokeStyle, 2)
        XCTAssertTrue(r.labelsOn)
        let bad = try XCTUnwrap(read(event(twoLinks + """
            <strokeColor value='blue'/><strokeWeight value='thick'/><strokeStyle value='wavy'/>
            """)))
        XCTAssertEqual([bad.color, Int32(bad.strokeWeight), Int32(bad.strokeStyle)], [Route.white, 6, 0],
                       "StrokeFillDetailHandler's fallbacks: white, 6.0, solid")
    }

    func testAnUpdateKeepsWhatItLeavesOut() throws {
        var old = try XCTUnwrap(read(event(twoLinks + "<link_attr color='-65536' method='Walking' prefix='WP'/>")))
        old.remarks = "keep off the road"
        let r = try XCTUnwrap(read(event(twoLinks), onto: old))
        XCTAssertEqual(r.color, -65536)
        XCTAssertEqual(r.method, .walking)
        XCTAssertEqual(r.prefix, "WP")
        XCTAssertEqual(r.remarks, "keep off the road", "the remarks meta stays")
    }

    func testWhatARouteWritesReadsBackTheSame() throws {
        var route = Route(id: "r-1", title: "Patrol", points: [
            .waypoint(CotPoint(lat: 37.79, lon: -122.44, hae: 12.5), uid: "a"),
            .controlPoint(CotPoint(lat: 37.795, lon: -122.435), uid: "b"),
            .waypoint(CotPoint(lat: 37.80, lon: -122.43), uid: "c"),
        ], color: -16711936, strokeWeight: 4, strokeStyle: 1, direction: .exfil, kind: .secondary,
                          order: .descending, prefix: "WP", remarks: "via the bridge",
                          creator: Author(uid: "me", type: "a-f-G", callsign: "VIPER", time: time))
        route.setMethod(.flying)
        route.points[2].remarks = "pick-up"
        route.fixEnds()
        let written = RouteEvent.make(route, center: PrecisionLocation(geopointSource: nil, altitudeSource: "DTED2"), now: time)
        XCTAssertEqual(written.point, .zero, "toCot never sets the point")
        XCTAssertEqual(written.stale.timeIntervalSince(written.time), 24 * 3600)
        let back = try XCTUnwrap(read(CotEvent.parse(written.xml(), now: time)))
        XCTAssertEqual(RouteEvent.make(back, center: PrecisionLocation(geopointSource: nil, altitudeSource: "DTED2"),
                                       now: time).xml(), written.xml())
        XCTAssertEqual([back.title, back.prefix, back.transportType], ["Patrol", "WP", Route.vehicle])
        XCTAssertEqual(back.points.map(\.callsign), ["Patrol TGT", nil, "EP"])
        XCTAssertEqual(back.creator, route.creator)
    }

    func testDecimate() {
        XCTAssertEqual(RouteEvent.decimate(CotPoint(lat: 37.79612345678, lon: -122.44312345678)), "37.7961235,-122.4431235")
        XCTAssertEqual(RouteEvent.decimate(CotPoint(lat: 1, lon: 2, hae: 12.34567)), "1.0,2.0,12.346")
        XCTAssertEqual(RouteEvent.decimate(CotPoint(lat: 1, lon: 2, hae: 99_999)), "1.0,2.0", "an altitude out of range isn't written")
    }

    func testTheCentreIsTheAverageOfThePoints() throws {
        let r = Route(id: "r", title: "t", points: [
            .waypoint(CotPoint(lat: 10, lon: 20), uid: "a"), .waypoint(CotPoint(lat: 20, lon: 40), uid: "b"),
        ])
        XCTAssertEqual(r.center?.lat ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(r.center?.lon ?? 0, 30, accuracy: 1e-9)
        let idl = Route(id: "r", title: "t", points: [
            .waypoint(CotPoint(lat: 0, lon: 179), uid: "a"), .waypoint(CotPoint(lat: 0, lon: -177), uid: "b"),
        ])
        XCTAssertEqual(idl.center?.lon ?? 0, -179, accuracy: 1e-9, "across the antimeridian")
        XCTAssertNil(Route(id: "r", title: "t").center)
    }
}
