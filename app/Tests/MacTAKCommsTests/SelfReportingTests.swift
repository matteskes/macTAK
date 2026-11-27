// G3.4b, end to end through commo: ATAK's two SA streams go where ATAK
// sends them (reliable to servers only, unreliable to the mesh only), and a
// self-detail change reaches a peer at once instead of at the next
// interval.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class SelfReportingTests: XCTestCase {
    private var clients: [TwoClients.Client] = []
    private var reporters: [SelfReporter] = []

    override func tearDown() async throws {
        for me in reporters { me.detach() }
        reporters = []
        for client in clients { await client.close() }
        clients = []
    }

    private func client(_ name: String) throws -> TwoClients.Client {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let client = try TwoClients.Client(uid: "g3-sa-\(tag)-\(name)")
        clients.append(client)
        return client
    }

    func testReliableGoesToServersAndUnreliableToTheMesh() async throws {
        let port = try freePort()
        let server = try FakeServer.cot(port: port)
        defer { server.stop() }
        let a = try client("a")      // on the server and the mesh
        let b = try client("b")      // the mesh only
        let c = try client("c")      // the server only
        try await a.commo.startMesh(MeshTests.config(slot: 1), interfaces: ["lo0"])
        try await b.commo.startMesh(MeshTests.config(slot: 2), interfaces: ["lo0"])
        let aServer = try await a.commo.connect(host: "127.0.0.1", port: port)
        let cServer = try await c.commo.connect(host: "127.0.0.1", port: port)
        try await a.seen.wait("A on the server", timeout: 15) { $0 == .interfaceUp(endpoint: aServer) }
        try await c.seen.wait("C on the server", timeout: 15) { $0 == .interfaceUp(endpoint: cServer) }
        try await b.seen.wait("B hears the mesh", timeout: 15, TwoClients.isListening(onPort: MeshTests.saPort))

        let toServer = "\(a.commo.uid)-server", toMesh = "\(a.commo.uid)-mesh"
        try await resend("C gets the server broadcast",
                         { try await a.commo.broadcast(TwoClients.marker(uid: toServer), via: .server) },
                         until: c.seen) { TwoClients.isCot($0, uid: toServer) }
        try await resend("B gets the mesh broadcast",
                         { try await a.commo.broadcast(TwoClients.marker(uid: toMesh), via: .mesh) },
                         until: b.seen) { TwoClients.isCot($0, uid: toMesh) }
        try await b.seen.never("B gets the server broadcast", within: 2) { TwoClients.isCot($0, uid: toServer) }
        try await c.seen.never("C gets the mesh broadcast", within: 2) { TwoClients.isCot($0, uid: toMesh) }
    }

    func testADetailChangeReachesAPeerAtOnce() async throws {
        let a = try client("a"), b = try client("b")
        try await a.commo.startMesh(MeshTests.config(slot: 1), interfaces: ["lo0"])
        try await b.commo.startMesh(MeshTests.config(slot: 2), interfaces: ["lo0"])
        // A reports once as it attaches, then not for 30 s: B must hear the
        // mesh first, or the test waits on a report that went nowhere
        try await b.seen.wait("B hears the mesh", timeout: 15, TwoClients.isListening(onPort: MeshTests.saPort))
        let settings = MemorySettings()
        let me = SelfReporter.testing(settings, uid: a.commo.uid)
        reporters.append(me)
        me.mode = .manual
        me.placed = CotPoint(lat: 47.6, lon: -122.3)
        me.attach(a.commo)   // ATAK's pace: Dynamic, 30 s on the mesh when still

        func sa(team: String) -> @Sendable (CommoEvent) -> Bool {
            let uid = a.commo.uid
            return { event in
                guard case let .cot(xml, _) = event, let e = try? CotEvent.parse(xml), e.uid == uid else { return false }
                return GroupDetail(e.detail("__group"))?.team == team && e.how == "h-e"
                    && PrecisionLocation(e.detail("precisionlocation"))?.geopointSource == "USER"
            }
        }
        try await b.seen.wait("B gets A's placed SA", timeout: 15, sa(team: "Cyan"))
        me.details.team = "Red"
        try await b.seen.wait("B gets A's new team well before 30 s", timeout: 5, sa(team: "Red"))
    }
}
