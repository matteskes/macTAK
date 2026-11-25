// RouteCommsTests.swift — G3.10a's gate, the comms leg: a route made on one
// client is on the other's map, through commo and
// dev/g1/headless/fake-cot-server.py, each client a ServerConnections as the
// app has it.
//
// The route arrives as 5.5 would take it: its points in order with their
// uids, types and names, its line and details, and who made it. Changed
// and sent again, it is updated in place.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class RouteCommsTests: XCTestCase {
    private var keychain: TemporaryKeychain?
    private var server: FakeServer?
    private var clients: [ServerConnections] = []

    override func setUp() async throws {
        keychain = try TemporaryKeychain()
    }

    override func tearDown() async throws {
        for c in clients { await c.stop() }
        clients = []
        server?.stop()
        server = nil
        keychain?.delete()
    }

    private func place(_ n: Int) -> CotPoint { CotPoint(lat: 37.79 + Double(n) * 0.001, lon: -122.44, hae: 10 + Double(n)) }

    private func client(_ name: String, port: Int) async throws -> ServerConnections {
        let settings = MemorySettings()
        let c = ServerConnections(settings: settings, identities: try XCTUnwrap(keychain).store,
                                  me: .testing(settings, uid: "g310a-\(name)-\(UUID().uuidString.prefix(8))"))
        c.me.details.callsign = "G310A-\(name.uppercased())"
        clients.append(c)
        try c.start()
        let config = ServerConfig(description: "fake", address: ConnectString(host: "127.0.0.1", port: port, proto: .tcp))
        c.add(config)
        try await waitFor("\(name) connected") { c.status[config.id] == .connected }
        return c
    }

    func testARouteMadeOnOneClientIsOnTheOthersMap() async throws {
        let port = try freePort()
        server = try FakeServer.cot(port: port)
        let a = try await client("a", port: port), b = try await client("b", port: port)

        var route = a.routes.add(points: [.waypoint(place(0), uid: UUID().uuidString),
                                          .controlPoint(place(1), uid: UUID().uuidString),
                                          .waypoint(place(2), uid: UUID().uuidString),
                                          .controlPoint(place(3), uid: UUID().uuidString)])
        route.color = -65536
        route.strokeWeight = 5
        route.direction = .exfil
        route.kind = .secondary
        route.remarks = "via the bridge"
        route.points[2].remarks = "rally"
        XCTAssertTrue(a.routes.update(route))
        let sent = try XCTUnwrap(a.routes[route.id])

        try await resend("B has the route", { try a.share(route: route.id) }, until: { b.routes[route.id] != nil })
        let got = try XCTUnwrap(b.routes[route.id])
        XCTAssertTrue(got.received)
        XCTAssertEqual(got.title, "Route 1")
        XCTAssertEqual(got.points.map(\.uid), sent.points.map(\.uid))
        XCTAssertEqual(got.points.map(\.type), [Route.waypointType, Route.controlPointType, Route.waypointType,
                                                Route.waypointType])
        XCTAssertEqual(got.points.map(\.callsign), ["Route 1 VPU", nil, "CP1", "EP"])
        XCTAssertEqual(got.points[2].remarks, "rally")
        for (g, s) in zip(got.points, sent.points) {
            XCTAssertEqual(g.point.lat, s.point.lat, accuracy: 1e-7)
            XCTAssertEqual(g.point.lon, s.point.lon, accuracy: 1e-7)
            XCTAssertEqual(g.point.hae, s.point.hae, accuracy: 1e-3)
        }
        XCTAssertEqual(got.color, -65536)
        XCTAssertEqual(got.strokeWeight, 5)
        XCTAssertEqual([got.method, got.direction, got.kind, got.order] as [AnyHashable],
                       [Route.Method.driving, Route.Direction.exfil, Route.Kind.secondary, Route.Order.ascending] as [AnyHashable])
        XCTAssertEqual(got.prefix, "CP")
        XCTAssertEqual(got.remarks, "via the bridge")
        XCTAssertEqual([got.creator?.uid, got.creator?.callsign], [a.uid, "G310A-A"], "A made it")

        // changed and sent again: B updates it in place
        route = try XCTUnwrap(a.routes[route.id])
        route.title = "Patrol"
        XCTAssertTrue(a.routes.update(route))
        try await resend("B has it renamed", { try a.share(route: route.id) }, until: { b.routes[route.id]?.title == "Patrol" })
        XCTAssertEqual(b.routes[route.id]?.points.first?.callsign, "Patrol VPU")
        XCTAssertEqual(b.routes.routes.count, 1)
    }
}
