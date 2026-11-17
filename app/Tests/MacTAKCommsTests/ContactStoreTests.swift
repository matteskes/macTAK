// G3.4c: the contacts list. An SA makes a contact and a newer one updates
// it; markers and its own SA don't; it goes stale and is removed on ATAK's
// clock; and end to end, two clients on one server list each other with
// their team and role, heard through the server.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class ContactStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sa(_ uid: String, callsign: String, team: String = "Cyan", role: String = "Team Member",
                    staleAfter: TimeInterval = 75, endpoint: String? = "*:-1:stcp", type: String = "a-f-G-U-C",
                    at time: Date? = nil) -> String {
        var s = SelfEvent(uid: uid, callsign: callsign, group: GroupDetail(team: team, role: role))
        s.type = type
        s.endpoint = endpoint
        return s.event(at: time ?? t0, stale: staleAfter).xml()
    }

    func testAnSAMakesAContactAndANewerOneUpdatesIt() throws {
        let store = ContactStore(selfUID: "me")
        XCTAssertTrue(store.receive(sa("peer", callsign: "VIPER", team: "Red", role: "Medic"), via: .mesh, at: t0))
        var c = try XCTUnwrap(store["peer"])
        XCTAssertEqual(c.callsign, "VIPER")
        XCTAssertEqual(c.group?.team, "Red")
        XCTAssertEqual(c.roleLabel, "Medic")
        XCTAssertEqual(c.paths, [.mesh])

        let server = UUID()
        store.receive(sa("peer", callsign: "VIPER-2"), via: .server(server), at: t0.addingTimeInterval(10))
        c = try XCTUnwrap(store["peer"])
        XCTAssertEqual(c.callsign, "VIPER-2")
        XCTAssertEqual(c.paths, [.mesh, .server(server)], "heard both ways")
        XCTAssertEqual(store.contacts.count, 1)
    }

    func testIgnoresMarkersOwnSAAndNonsense() {
        let store = ContactStore(selfUID: "me")
        XCTAssertFalse(store.receive(sa("marker", callsign: "M", endpoint: nil), via: .mesh), "no endpoint: a marker")
        XCTAssertFalse(store.receive(sa("chat", callsign: "C", type: "b-t-f"), via: .mesh), "not an atom")
        XCTAssertFalse(store.receive(sa("me", callsign: "ME"), via: .mesh), "its own SA")
        XCTAssertFalse(store.receive("<event/>", via: .mesh))
        XCTAssertTrue(store.contacts.isEmpty)
    }

    func testStaleAndRemovalFollowATAK() throws {
        let store = ContactStore(selfUID: "me")
        // stale − start = 75 s: stale 112.5 s after arrival, removed 5 min later
        store.receive(sa("peer", callsign: "P", staleAfter: 75), via: .mesh, at: t0)
        let c = try XCTUnwrap(store["peer"])
        XCTAssertFalse(c.isStale(at: t0.addingTimeInterval(112)))
        XCTAssertTrue(c.isStale(at: t0.addingTimeInterval(112.5)))
        store.expire(at: t0.addingTimeInterval(112.5 + 299))
        XCTAssertNotNil(store["peer"], "stale, still listed")
        store.expire(at: t0.addingTimeInterval(112.5 + 300))
        XCTAssertNil(store["peer"])
    }

    func testStaleIsTimedByThisClock() throws {
        let store = ContactStore(selfUID: "me")
        // the peer's clock is an hour behind: its stale is in our past
        store.receive(sa("peer", callsign: "P", staleAfter: 30, at: t0.addingTimeInterval(-3600)), via: .mesh, at: t0)
        XCTAssertFalse(try XCTUnwrap(store["peer"]).isStale(at: t0.addingTimeInterval(44)))
    }

    func testCommoRemovingTheContactRemovesIt() {
        let store = ContactStore(selfUID: "me")
        store.receive(sa("b", callsign: "BRAVO"), via: .mesh)
        store.receive(sa("a", callsign: "alpha"), via: .mesh)
        XCTAssertEqual(store.contacts.map(\.callsign), ["alpha", "BRAVO"], "by callsign, any case")
        store.remove("a")
        XCTAssertEqual(store.contacts.map(\.uid), ["b"])
    }

    func testTwoClientsOnAServerListEachOther() async throws {
        let port = try freePort()
        let server = try FakeServer.cot(port: port)
        defer { server.stop() }
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        let tag = UUID().uuidString.prefix(8).lowercased()

        func client(_ name: String, team: String, role: String) throws -> ServerConnections {
            let settings = MemorySettings()
            let me = SelfReporter.testing(settings, uid: "g3-contacts-\(tag)-\(name)")
            me.details.callsign = name.uppercased()
            me.details.team = team
            me.details.role = role
            me.details.reporting = .every(seconds: 1)
            let connections = ServerConnections(settings: settings, identities: keychain.store, me: me)
            try connections.start()
            connections.add(ServerConfig(description: "fake", address: ConnectString(host: "127.0.0.1", port: port, proto: .tcp)))
            return connections
        }
        let a = try client("alpha", team: "Red", role: "Medic")
        let b = try client("bravo", team: "Blue", role: "Team Lead")
        defer { Task { await a.stop(); await b.stop() } }
        let serverID = try XCTUnwrap(a.servers.first?.id)

        try await waitFor("A lists B") { a.contacts[b.uid]?.group?.team == "Blue" }
        try await waitFor("B lists A") { b.contacts[a.uid]?.roleLabel == "Medic" }
        let bravo = try XCTUnwrap(a.contacts[b.uid])
        XCTAssertEqual(bravo.callsign, "BRAVO")
        XCTAssertEqual(bravo.paths, [.server(serverID)])
        XCTAssertNil(a.contacts[a.uid], "A doesn't list itself")
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
