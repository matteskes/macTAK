// RangeBearingCommsTests.swift — G3.8d's gate, the comms leg: one client's
// range and bearing line on the other's map, through commo and
// dev/g1/headless/fake-cot-server.py, each client a ServerConnections as
// the app has it.
//
// A line from a fixed place to a CoT marker both clients have arrives tied
// to that marker (anchorUID/rangeUID); a line between two places arrives
// with its far end where 5.5's importer puts it (range along bearing).

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class RangeBearingCommsTests: XCTestCase {
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

    /// A CoT marker both clients have heard (as from a third party).
    private func marker(_ uid: String) -> String {
        let now = Date()
        let event = CotEvent(uid: uid, type: "a-h-G", time: now, stale: now.addingTimeInterval(600),
                             how: "h-g-i-g-o", point: there)
        return event.xml()
    }

    private func client(_ name: String, port: Int) async throws -> ServerConnections {
        let settings = MemorySettings()
        let c = ServerConnections(settings: settings, identities: try XCTUnwrap(keychain).store,
                                  me: .testing(settings, uid: "g3-rab-\(name)-\(UUID().uuidString.prefix(8))"))
        clients.append(c)
        try c.start()
        let config = ServerConfig(description: "fake", address: ConnectString(host: "127.0.0.1", port: port, proto: .tcp))
        c.add(config)
        try await waitFor("\(name) connected") { c.status[config.id] == .connected }
        return c
    }

    func testALineReachesTheOtherClient() async throws {
        let port = try freePort()
        server = try FakeServer.cot(port: port)
        let a = try await client("a", port: port), b = try await client("b", port: port)
        let markerUID = "g38d-marker-\(UUID().uuidString.prefix(8))"
        for c in [a, b] { c.markers.receive(marker(markerUID)) }

        // tied to a marker both have
        let tied = a.rangeBearing.add(start: .point(here), end: .item(markerUID))
        try await share(tied.id, from: a, until: "B has the tied line") { b.rangeBearing[tied.id] != nil }
        let got = try XCTUnwrap(b.rangeBearing[tied.id])
        XCTAssertEqual(got.title, "R&B 1")
        XCTAssertEqual(got.end, .item(markerUID), "the end follows B's own copy of the marker")
        guard case .point(let start) = got.start else { return XCTFail("the start is a place: \(got.start)") }
        XCTAssertEqual(start.lat, here.lat, accuracy: 1e-7)
        XCTAssertEqual(start.lon, here.lon, accuracy: 1e-7)
        XCTAssertEqual(got.color, RangeBearingEvent.red)
        XCTAssertTrue(got.received)

        // between two places: B puts the far end range along bearing
        let free = a.rangeBearing.add(start: .point(here), end: .point(there))
        try await share(free.id, from: a, until: "B has the second line") { b.rangeBearing[free.id] != nil }
        let second = try XCTUnwrap(b.rangeBearing[free.id])
        XCTAssertEqual(second.title, "R&B 2")
        guard case .point(let end) = second.end else { return XCTFail("the end is a place: \(second.end)") }
        XCTAssertLessThan(Geodesy.distance(lat1: end.lat, lon1: end.lon, lat2: there.lat, lon2: there.lon), 0.01,
                          "within a centimetre of A's end")

        // A's own lines stay A's
        XCTAssertFalse(a.rangeBearing[tied.id]?.received ?? true)
    }

    func testSharingWithoutAPlaceSaysSo() async throws {
        let settings = MemorySettings()
        let c = ServerConnections(settings: settings, identities: try XCTUnwrap(keychain).store, me: .testing(settings))
        clients.append(c)
        XCTAssertThrowsError(try c.share(line: "nope", style: .atak)) {
            XCTAssertEqual($0 as? ServerConnections.ShareError, .notRunning)
        }
        try c.start()
        XCTAssertThrowsError(try c.share(line: "nope", style: .atak)) {
            XCTAssertEqual($0 as? ServerConnections.ShareError, .noLine)
        }
        let line = c.rangeBearing.add(start: .point(here), end: .item("nobody"))
        XCTAssertThrowsError(try c.share(line: line.id, style: .atak)) {
            XCTAssertEqual($0 as? ServerConnections.ShareError, .noPlace)
        }
    }

    /// Send the line once a second until `arrived`: commo reports a
    /// connection up before it can send on it (CommoClient's notes), so the
    /// first send can go nowhere. A resend replaces the line, as 5.5's does.
    private func share(_ id: String, from c: ServerConnections, until what: String,
                       _ arrived: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !arrived() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try c.share(line: id, style: .atak)
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
