// RoutesTests.swift — the routes this client has (G3.10a): one made here
// (named, authored, archived, its ends waypoints), routes heard (added,
// updated, refused, removed by a force delete only), and G3.10a's gate
// that a route survives a relaunch, each launch a ServerConnections as the
// app makes it on the same statesaver file.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class RoutesTests: XCTestCase {
    private let now = Cot.parseTime("2026-11-24T18:20:00.000Z")!
    private func place(_ n: Int) -> CotPoint { CotPoint(lat: 37.79 + Double(n) * 0.001, lon: -122.44) }

    private func numbered() -> () -> String {
        var n = 0
        return { n += 1; return "id-\(n)" }
    }

    private func heard(uid: String = "remote-1", title: String? = "Patrol", creator: String = "other",
                       links: Int = 3) -> String {
        var route = Route(id: uid, title: title ?? "", points: (0..<links).map {
            $0 == 0 || $0 == links - 1 ? .waypoint(place($0), uid: "\(uid)-p\($0)") : .controlPoint(place($0), uid: "\(uid)-p\($0)")
        }, creator: Author(uid: creator, type: "a-f-G", callsign: "OTHER", time: now))
        route.nameWaypoints()
        return RouteEvent.make(route, center: nil, now: now).xml()
    }

    func testANewRouteIsNamedAuthoredArchivedAndItsEndsAreWaypoints() {
        let routes = Routes(newID: numbered())
        routes.author = { Author(uid: "me", type: "a-f-G-U-C", callsign: "VIPER", time: self.now) }
        let r = routes.add(points: [.controlPoint(place(0), uid: "c0"), .controlPoint(place(1), uid: "c1"),
                                    .controlPoint(place(2), uid: "c2")], prefix: "WP")
        XCTAssertEqual(r.title, "Route 1")
        XCTAssertEqual(r.id, "id-1")
        XCTAssertEqual(r.creator?.uid, "me")
        XCTAssertTrue(r.archived)
        XCTAssertFalse(r.received)
        XCTAssertEqual(r.prefix, "WP")
        XCTAssertEqual(r.points.map(\.type), [Route.waypointType, Route.controlPointType, Route.waypointType])
        XCTAssertEqual(r.points.map(\.callsign), ["Route 1 SP", nil, "VDO"])
        XCTAssertEqual(routes.add(points: []).title, "Route 2")
    }

    func testAnUpdateRenamesTheWaypoints() throws {
        let routes = Routes(newID: numbered())
        var r = routes.add(points: [.waypoint(place(0), uid: "a"), .waypoint(place(1), uid: "b")])
        r.points.insert(.waypoint(place(2), uid: "c"), at: 1)
        r.title = "Patrol"
        XCTAssertTrue(routes.update(r))
        XCTAssertEqual(try XCTUnwrap(routes[r.id]).points.map(\.callsign), ["Patrol SP", "CP1", "VDO"])
        XCTAssertFalse(routes.update(try XCTUnwrap(routes[r.id])), "the same again changes nothing")
        XCTAssertFalse(routes.update(Route(id: "nowhere", title: "x")))
    }

    func testAHeardRouteIsAddedThenUpdated() throws {
        let routes = Routes(newID: numbered())
        XCTAssertTrue(routes.receive(heard()) { _ in false })
        let r = try XCTUnwrap(routes["remote-1"])
        XCTAssertTrue(r.received)
        XCTAssertEqual(r.title, "Patrol")
        XCTAssertEqual(r.creator?.uid, "other")
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol SP", nil, "VDO"])
        XCTAssertFalse(routes.receive(heard()) { _ in false }, "the same again changes nothing")
        XCTAssertTrue(routes.receive(heard(links: 4)) { _ in false })
        XCTAssertEqual(routes["remote-1"]?.points.count, 4)
        XCTAssertEqual(routes.routes.count, 1)
    }

    func testAHeardRouteWithoutANameIsRouteN() throws {
        let routes = Routes(newID: numbered())
        routes.add(points: [])
        routes.receive(heard(title: nil)) { _ in false }
        XCTAssertEqual(routes["remote-1"]?.title, "Route 2")
    }

    func testAHeardRouteGetsWaypointEnds() throws {
        var route = Route(id: "r", title: "Patrol", points: [.controlPoint(place(0), uid: "a"), .controlPoint(place(1), uid: "b")])
        route.color = -65536
        let routes = Routes(newID: numbered())
        routes.receive(RouteEvent.make(route, center: nil, now: now).xml()) { _ in false }
        let r = try XCTUnwrap(routes["r"])
        XCTAssertEqual(r.points.map(\.type), [Route.waypointType, Route.waypointType], "fixSPandVDO when it is added")
        XCTAssertEqual(r.points.map(\.callsign), ["Patrol SP", "VDO"])
    }

    func testARouteFiveFiveRefusesChangesNothing() {
        let routes = Routes(newID: numbered())
        XCTAssertFalse(routes.receive(heard(links: 1)) { _ in false })
        XCTAssertTrue(routes.routes.isEmpty)
        XCTAssertFalse(routes.receive("<event/>") { _ in false })
    }

    private func delete(_ uid: String, force: Bool) -> String {
        var d = CotDetail("detail")
        var link = CotDetail("link")
        link["uid"] = uid; link["relation"] = "none"; link["type"] = "none"
        d.add(link)
        if force { d.add(CotDetail("__forcedelete")) }
        return CotEvent(uid: "del", type: CotMarkerStore.deleteType, time: now, stale: now, how: "h-g-i-g-o",
                        point: place(0), detail: d).xml()
    }

    func testOnlyAForceDeleteRemovesARoute() {
        let routes = Routes(newID: numbered())
        routes.receive(heard()) { _ in false }
        let mine = routes.add(points: [.waypoint(place(0), uid: "a"), .waypoint(place(1), uid: "b")])
        XCTAssertFalse(routes.receive(delete("remote-1", force: false)) { _ in false })
        XCTAssertNotNil(routes["remote-1"], "a plain delete only greys markers")
        XCTAssertTrue(routes.receive(delete("remote-1", force: true)) { _ in false })
        XCTAssertNil(routes["remote-1"])
        XCTAssertTrue(routes.receive(delete(mine.id, force: true)) { _ in false })
        XCTAssertNil(routes[mine.id], "a route made here goes too")
    }

    func testARestoredRouteIsMineWhenIMadeIt() {
        let routes = Routes(newID: numbered())
        XCTAssertEqual(routes.restore(heard(uid: "mine", creator: "me"), isItem: { _ in false }, selfUID: "me"), .restored)
        XCTAssertEqual(routes.restore(heard(uid: "theirs"), isItem: { _ in false }, selfUID: "me"), .restored)
        XCTAssertEqual(routes.restore("<event/>", isItem: { _ in false }, selfUID: "me"), .ignored)
        XCTAssertEqual(routes["mine"]?.received, false)
        XCTAssertEqual(routes["theirs"]?.received, true)
    }

    // ---- the gate: a route survives a relaunch -------------------------------

    func testARouteSurvivesARelaunch() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statesaver-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        func launch() throws -> ServerConnections {
            let settings = MemorySettings()
            return ServerConnections(settings: settings, identities: keychain.store, me: .testing(settings),
                                     mapItemStore: try MapItemStore(url: url))
        }
        let marker = CotEvent(uid: "hostile-1", type: "a-h-G", time: Date(), stale: Date().addingTimeInterval(60),
                              how: "h-g-i-g-o", point: place(5), detail: {
                                  var d = CotDetail("detail"); d.add(CotDetail("archive")); return d
                              }())
        let made: Route
        do {
            let c = try launch()
            c.mapLocator.altitudeSource = { _ in "DTED1" }
            XCTAssertTrue(c.markers.receive(marker.xml()))
            var r = c.routes.add(points: [.waypoint(place(0), uid: "a"), .controlPoint(place(1), uid: "b"),
                                          RoutePoint(uid: "hostile-1", type: "a-h-G", point: place(5)),
                                          .waypoint(place(2), uid: "c")])
            r.setMethod(.walking)
            r.points[3].callsign = "Ferry wharf"
            XCTAssertTrue(c.routes.update(r))
            c.routes.receive(heard()) { _ in false }
            made = try XCTUnwrap(c.routes[r.id])
            c.syncArchive()
            let stored = try MapItemStore(url: url).items()
            XCTAssertEqual(stored.filter { $0.type == Route.type }.count, 2)
            let event = try CotEvent.parse(try XCTUnwrap(stored.first { $0.uid == r.id }).event)
            XCTAssertEqual(event.detail("precisionlocation")?["altsrc"], "DTED1", "its centre's altitude source")
        }
        let c = try launch()
        let back = try XCTUnwrap(c.routes[made.id])
        XCTAssertEqual(back.title, "Route 1")
        XCTAssertEqual(back.method, .walking)
        XCTAssertEqual(back.transportType, Route.onFoot)
        XCTAssertEqual(back.points.map(\.uid), made.points.map(\.uid))
        XCTAssertEqual(back.points.map(\.type), [Route.waypointType, Route.controlPointType, "a-h-G", Route.waypointType],
                       "the marker it runs through is back first (5.5's query order), so it stays the marker")
        XCTAssertEqual(back.points.map(\.callsign), ["Route 1 SP", nil, nil, "Ferry wharf"])
        XCTAssertEqual(back.creator, made.creator)
        XCTAssertFalse(back.received, "made here")
        XCTAssertEqual(c.routes["remote-1"]?.received, true)
    }
}
