// G3.3's gate: two clients on one Mac see each other with no server.
//
// The clients run the mesh on lo0, with multicast loopback on (two clients
// on one host need it) and ports off ATAK's defaults, so a real ATAK or
// macTAK on the network neither hears nor disturbs the test. They share the
// SA and chat ports (commo binds with address reuse, as ATAK does) and each
// has its own unicast UDP and TCP port. Only client A can take direct TCP:
// commo advertises port 4242 for everyone.
//
// commo names the interface a CoT event came in on "*:<port>:udp" or
// "*:<port>:tcp", which tells the SA group, the chat group and direct TCP
// apart.

import XCTest
@testable import MacTAKComms

final class MeshTests: XCTestCase {
    static let saPort = 16969, chatPort = 27012

    /// The mesh config for one test client on lo0; `slot` picks its own ports.
    /// Slot 1 listens on TCP 4242, the only port peers send to directly
    /// (MeshConfig.tcpPort), so it fails if something on this Mac holds it.
    static func config(slot: Int, saPort: Int = saPort) -> MeshConfig {
        MeshConfig(sa: .init(address: "239.2.3.1", port: saPort),
                   chat: .init(address: "224.10.10.1", port: chatPort),
                   udpPort: 14250 + slot, tcpPort: slot == 1 ? 4242 : 14240 + slot,
                   ttl: 1, loopback: true)
    }

    private var clients: [TwoClients.Client] = []

    override func tearDown() async throws {
        for client in clients { await client.close() }
        clients = []
    }

    private func meshClient(_ name: String, slot: Int, saPort: Int = saPort,
                            mesh: Bool = true) async throws -> TwoClients.Client {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let client = try TwoClients.Client(uid: "g3-mesh-\(tag)-\(name)")
        clients.append(client)
        if mesh {
            try await client.commo.startMesh(Self.config(slot: slot, saPort: saPort), interfaces: ["lo0"])
        }
        await client.commo.startBeacon(every: .seconds(1))
        return client
    }

    func testPeersSeeEachOthersPresence() async throws {
        let a = try await meshClient("a", slot: 1)
        let b = try await meshClient("b", slot: 2)

        try await a.seen.wait("A sees B as a contact", timeout: 15) { $0 == .contactAdded(uid: b.commo.uid) }
        try await a.seen.wait("A gets B's SA on the SA group", timeout: 15) {
            Self.isCot($0, uid: b.commo.uid, on: "*:\(Self.saPort):udp")
        }
        try await b.seen.wait("B gets A's SA on the SA group", timeout: 15) {
            Self.isCot($0, uid: a.commo.uid, on: "*:\(Self.saPort):udp")
        }
    }

    func testPresenceAdvertisesTheDirectTcpEndpoint() async throws {
        let a = try await meshClient("a", slot: 1)
        let b = try await meshClient("b", slot: 2)
        try await b.seen.wait("A's SA names its address and TCP 4242", timeout: 15) { event in
            guard Self.isCot(event, uid: a.commo.uid, on: nil), case let .cot(xml, _) = event else { return false }
            return Self.attribute("endpoint", in: xml) == "127.0.0.1:4242:tcp"
        }
    }

    func testChatGoesOutOnTheChatGroup() async throws {
        let a = try await meshClient("a", slot: 1)
        let b = try await meshClient("b", slot: 2)
        try await a.seen.wait("A sees B", timeout: 15) { $0 == .contactAdded(uid: b.commo.uid) }

        let message = "\(b.commo.uid)-chat"
        try await b.commo.broadcast(Self.chat(uid: message, from: b.commo.uid))
        try await a.seen.wait("A gets B's chat on the chat group", timeout: 15) {
            Self.isCot($0, uid: message, on: "*:\(Self.chatPort):udp")
        }
        try await a.seen.never("B's chat on the SA group", within: 1) {
            Self.isCot($0, uid: message, on: "*:\(Self.saPort):udp")
        }
    }

    func testDirectSendGoesOverTcp() async throws {
        let a = try await meshClient("a", slot: 1)
        let b = try await meshClient("b", slot: 2)
        try await b.seen.wait("B sees A", timeout: 15) { $0 == .contactAdded(uid: a.commo.uid) }

        let marker = "\(b.commo.uid)-direct"
        try await b.commo.send(TwoClients.marker(uid: marker), to: [a.commo.uid])
        try await a.seen.wait("A gets B's marker over TCP", timeout: 15) {
            Self.isCot($0, uid: marker, on: "*:4242:tcp")
        }
    }

    func testNoMeshHearsNothing() async throws {
        let a = try await meshClient("a", slot: 1)
        let quiet = try await meshClient("quiet", slot: 3, mesh: false)
        try await a.seen.wait("A's mesh is up", timeout: 15, TwoClients.isInterfaceUp)
        try await quiet.seen.never("a client with no mesh gets A's SA", within: 4) {
            TwoClients.isCot($0, uid: a.commo.uid)
        }
    }

    func testAnotherSaPortHearsNothing() async throws {
        let a = try await meshClient("a", slot: 1)
        let other = try await meshClient("other", slot: 3, saPort: Self.saPort + 1)
        try await other.seen.wait("the other mesh is up", timeout: 15, TwoClients.isInterfaceUp)
        try await other.seen.never("a mesh on another SA port gets A's SA", within: 4) {
            TwoClients.isCot($0, uid: a.commo.uid)
        }
    }

    func testStartTwiceIsRefusedAndInterfacesComeAndGo() async throws {
        let a = try await meshClient("a", slot: 1)
        do {
            try await a.commo.startMesh(Self.config(slot: 1), interfaces: ["lo0"])
            XCTFail("a second startMesh was accepted")
        } catch {}
        var names = await a.commo.meshInterfaces
        XCTAssertEqual(names, ["lo0"])

        // Removing an interface's last commo interface once read freed
        // memory in commo (trap 11): this is the case that crashed.
        await a.commo.removeMeshInterface("lo0")
        names = await a.commo.meshInterfaces
        XCTAssertEqual(names, [])

        let ids = try await a.commo.addMeshInterface("lo0")
        XCTAssertEqual(ids.count, 5, "SA, chat and unicast in; SA and chat out")
        try await a.seen.wait("lo0 back up", timeout: 15) { event in
            if case let .interfaceUp(endpoint) = event { endpoint == "out:lo0:239.2.3.1:\(Self.saPort)" } else { false }
        }
        await a.commo.stopMesh()
        names = await a.commo.meshInterfaces
        XCTAssertEqual(names, [])
    }

    func testMeshCapableSkipsLoopbackTunnelsAndAwdl() {
        let up = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        XCTAssertTrue(NetworkInterfaces.isMeshCapable(name: "en0", flags: up))
        XCTAssertFalse(NetworkInterfaces.isMeshCapable(name: "lo0", flags: up | UInt32(IFF_LOOPBACK)))
        XCTAssertFalse(NetworkInterfaces.isMeshCapable(name: "utun3", flags: up))
        XCTAssertFalse(NetworkInterfaces.isMeshCapable(name: "awdl0", flags: up))
        XCTAssertFalse(NetworkInterfaces.isMeshCapable(name: "en5", flags: up | UInt32(IFF_POINTOPOINT)))
        XCTAssertFalse(NetworkInterfaces.isMeshCapable(name: "en1", flags: UInt32(IFF_UP | IFF_RUNNING)),
                       "no multicast")
        XCTAssertFalse(NetworkInterfaces.meshCapable().contains("lo0"))
    }

    /// The first value of attribute `name` in xml, quoted either way
    /// (commo re-serializes what it receives with double quotes).
    static func attribute(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "\(name)=[\"'][^\"']*[\"']", options: .regularExpression) else { return nil }
        return String(xml[r].dropFirst(name.count + 2).dropLast())
    }

    @Sendable static func isCot(_ event: CommoEvent, uid: String, on endpoint: String?) -> Bool {
        guard TwoClients.isCot(event, uid: uid), case let .cot(_, from) = event else { return false }
        return endpoint == nil || from == endpoint
    }

    /// A GeoChat message to All Chat Rooms; commo sends an event with a
    /// __chat detail as chat.
    static func chat(uid: String, from sender: String) -> String {
        let t = Cot.time(Date()), stale = Cot.time(Date().addingTimeInterval(120))
        return "<event version='2.0' uid='\(uid)' type='b-t-f' access='Undefined'"
            + " time='\(t)' start='\(t)' stale='\(stale)' how='h-g-i-g-o'>"
            + "<point lat='0.0' lon='0.0' ce='9999999' le='9999999' hae='0.0'/>"
            + "<detail><__chat parent='RootContactGroup' groupOwner='false'"
            + " chatroom='All Chat Rooms' id='All Chat Rooms' senderCallsign='\(sender.uppercased())'>"
            + "<chatgrp uid0='\(sender)' uid1='All Chat Rooms' id='All Chat Rooms'/></__chat>"
            + "<remarks source='BAO.F.ATAK.\(sender)' time='\(t)'>mesh test</remarks>"
            + "</detail></event>"
    }
}
