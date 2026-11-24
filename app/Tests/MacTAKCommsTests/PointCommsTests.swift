// PointCommsTests.swift — G3.9d's gate, the comms leg: a point dropped on
// one client reaches the other, through commo and
// dev/g1/headless/fake-cot-server.py, each client a ServerConnections as the
// app has it.
//
// The point arrives as 5.5 would take it: its name, type, icon and colour,
// its remarks and address, where its place came from, and who placed it;
// it came with <archive/>, so the other client keeps it. When it is moved
// and sent again, the other client moves it, keeps its remarks and drops
// the address it has left (MarkerImporter).

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class PointCommsTests: XCTestCase {
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

    private let here = CotPoint(lat: 37.795, lon: -122.445, hae: 10)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)

    private func client(_ name: String, port: Int) async throws -> ServerConnections {
        let settings = MemorySettings()
        let c = ServerConnections(settings: settings, identities: try XCTUnwrap(keychain).store,
                                  me: .testing(settings, uid: "g39d-\(name)-\(UUID().uuidString.prefix(8))"))
        c.me.details.callsign = "G39D-\(name.uppercased())"
        clients.append(c)
        try c.start()
        let config = ServerConfig(description: "fake", address: ConnectString(host: "127.0.0.1", port: port, proto: .tcp))
        c.add(config)
        try await waitFor("\(name) connected") { c.status[config.id] == .connected }
        return c
    }

    func testADroppedPointReachesTheOtherClient() async throws {
        let port = try freePort()
        server = try FakeServer.cot(port: port)
        let a = try await client("a", port: port), b = try await client("b", port: port)
        a.mapLocator.altitudeSource = { _ in "DTED1" }

        a.pointDropper.begin(.spotMap(.red))
        let placed = try XCTUnwrap(a.pointDropper.click(.ground(here)))
        a.pointDropper.end()
        a.pointEditor.setRemarks(placed.uid, "north gate")
        let address = AddressDetail(text: "Palace of Fine Arts", geocoder: "Apple Maps", time: Cot.time(Date()))
        XCTAssertTrue(a.pointEditor.setAddress(placed.uid, address, lookedUpAt: here))

        try await share(placed.uid, from: a, until: "B has the point") { b.markers[placed.uid] != nil }
        let got = try XCTUnwrap(b.markers[placed.uid])
        let sent = try XCTUnwrap(a.markers[placed.uid])
        XCTAssertEqual(got.label, "R 1")
        XCTAssertEqual(got.type, PointKind.spotMapType)
        XCTAssertEqual(got.traits.color, PointKind.SpotMapColor.red.argb)
        XCTAssertEqual(got.traits.iconsetPath, PointKind.spotMap(.red).iconsetPath)
        XCTAssertEqual(got.point.lat, here.lat, accuracy: 1e-7)
        XCTAssertEqual(got.point.lon, here.lon, accuracy: 1e-7)
        XCTAssertEqual(got.point.hae, 10)
        XCTAssertEqual(got.remarks, "north gate")
        XCTAssertEqual(got.address, address)
        XCTAssertEqual(got.event.detail("precisionlocation")?["altsrc"], "DTED1")
        let author = try XCTUnwrap(Author(creator: got.event.detail("creator"), orTime: .distantPast))
        XCTAssertEqual([author.uid, author.callsign], [a.uid, "G39D-A"], "A placed it")
        XCTAssertEqual(got.event.detail("link")?["uid"], a.uid)
        XCTAssertTrue(got.archived, "it came with <archive/>, so B keeps it")
        XCTAssertEqual(got.event.detail?.children.map(\.name), sent.event.detail?.children.map(\.name),
                       "every detail A sent")

        // moved and sent again: B moves it, keeps its remarks, drops the address
        XCTAssertTrue(a.pointEditor.move(placed.uid, to: .ground(there)))
        try await share(placed.uid, from: a, until: "B has it moved") {
            b.markers[placed.uid].map { abs($0.point.lat - there.lat) < 1e-7 } == true
        }
        let moved = try XCTUnwrap(b.markers[placed.uid])
        XCTAssertEqual(moved.remarks, "north gate")
        XCTAssertNil(moved.address)
        XCTAssertEqual(moved.event.detail("precisionlocation")?["altsrc"], "???", "no altitude at the new place")
    }

    /// Send the point once a second until `arrived`: commo reports a
    /// connection up before it can send on it (CommoClient's notes), so the
    /// first send can go nowhere. A resend replaces the point.
    private func share(_ uid: String, from c: ServerConnections, until what: String,
                       _ arrived: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !arrived() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try c.share(marker: uid)
            for _ in 0..<10 where !arrived() { try await Task.sleep(for: .milliseconds(100)) }
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
