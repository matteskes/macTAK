// ChatCommsTests.swift — G3.5's gate: a chat leg per room kind, with
// receipts, through commo (G3.5b).
//
// Over a server: three clients through dev/g1/headless/fake-cot-server.py.
// The fake server relays every event to every other client, so a point-to-
// point send also reaches clients it wasn't for; the room checks therefore
// look at what each client's ChatService filed, which is what a user sees.
// One-to-one gets its delivered and read receipts back through the server.
//
// On the mesh (lo0, MeshTests' ports): All Chat Rooms goes out on the chat
// group and a one-to-one over direct TCP. Only one client per Mac can take
// direct TCP on 4242 (MeshTests), so a receipt can't come back on the mesh
// here; the server legs cover receipts.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class ChatCommsTests: XCTestCase {
    /// One app's worth of chat: commo, contacts and a ChatService.
    @MainActor
    final class Peer {
        let commo: CommoClient
        let seen = Recorder()
        let contacts: ContactStore
        let chat: ChatService
        let url: URL
        /// The team and role the service checks rooms against; start sets them.
        private let group = GroupBox()
        private var pump: Task<Void, Never>?

        final class GroupBox { var team = "Cyan", role = GroupDetail.defaultRole }

        init(uid: String) throws {
            commo = try CommoClient(uid: uid, callsign: uid.uppercased())
            url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).sqlite")
            let contacts = ContactStore(selfUID: uid)
            self.contacts = contacts
            let callsign = uid.uppercased()
            let box = group
            chat = ChatService(store: try ChatStore(url: url), contacts: contacts) {
                ChatIdentity(sender: ChatSender(uid: uid, callsign: callsign, address: "127.0.0.1"),
                             team: box.team, role: box.role)
            }
            chat.attach(commo)
            let (events, seen, chat) = (commo.events, seen, chat)
            pump = Task { @MainActor in
                for await event in events {
                    await seen.add(event)
                    if case let .cot(xml, _) = event {
                        contacts.receive(xml, via: .mesh)
                        chat.receive(xml)
                    }
                }
            }
        }

        func start(team: String, role: String) async {
            group.team = team
            group.role = role
            await commo.updateSelf { $0.group = GroupDetail(team: team, role: role) }
            await commo.startReporting(.every(seconds: 1))
        }

        var uid: String { commo.uid }

        /// Waits until `check` holds for this client, its rooms refreshed.
        func waitFor(_ what: String, timeout: TimeInterval = 15,
                     _ check: @MainActor () -> Bool) async throws {
            try await MacTAKCommsTests.waitFor(what, timeout: timeout) {
                chat.refresh()
                return check()
            }
        }

        func close() async {
            await chat.flush()
            await commo.shutdown()
            await pump?.value
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
    }

    private var peers: [Peer] = []
    private var server: FakeServer?

    override func tearDown() async throws {
        for p in peers { await p.close() }
        peers = []
        server?.stop()
        server = nil
    }

    private func peer(_ name: String, tag: String) throws -> Peer {
        let p = try Peer(uid: "g3-chat-\(tag)-\(name)")
        peers.append(p)
        return p
    }

    /// Three clients on one fake server: A and B on Cyan, C on Red; A and C
    /// medics. Returns once each sees the other two.
    private func onAServer() async throws -> (Peer, Peer, Peer) {
        let port = try freePort()
        server = try FakeServer.cot(port: port)
        let tag = UUID().uuidString.prefix(8).lowercased()
        let a = try peer("a", tag: tag), b = try peer("b", tag: tag), c = try peer("c", tag: tag)
        for (p, team, role) in [(a, "Cyan", "Medic"), (b, "Cyan", "Team Member"), (c, "Red", "Medic")] {
            await p.start(team: team, role: role)
            try await p.commo.connect(host: "127.0.0.1", port: port)
            try await p.seen.wait("\(p.uid) up", timeout: 15, TwoClients.isInterfaceUp)
        }
        for p in [a, b, c] {
            for other in [a, b, c] where other !== p {
                try await p.waitFor("\(p.uid) hears \(other.uid)") { p.contacts[other.uid] != nil }
            }
        }
        return (a, b, c)
    }

    func testEveryRoomKindOverAServer() async throws {
        let (a, b, c) = try await onAServer()

        // All Chat Rooms
        try a.chat.send("radio check", to: ChatRoom.allChatRooms)
        for p in [b, c] {
            try await p.waitFor("\(p.uid) gets All Chat Rooms") {
                p.chat.history(ChatRoom.allChatRooms).map(\.text) == ["radio check"]
            }
        }

        // a team room: B shares A's team, C doesn't
        try await a.waitFor("A's Cyan room has B") { a.chat.conversation("Cyan")?.members == [b.uid] }
        try a.chat.send("Cyan, move north", to: "Cyan")
        try await b.waitFor("B gets the Cyan message") { b.chat.history("Cyan").count == 1 }

        // a role room: C is the other medic
        try await a.waitFor("A's Medic room has C") { a.chat.conversation("Medic")?.members == [c.uid] }
        try a.chat.send("casualty at the bridge", to: "Medic")
        try await c.waitFor("C gets the Medic message") { c.chat.history("Medic").count == 1 }

        // a user group of A and C
        let group = try a.chat.createGroup(name: "Recon", members: [c.uid])
        try a.chat.send("recon group up", to: group.uid)
        try await c.waitFor("C gets the group and its message") {
            c.chat.conversation(group.uid)?.kind == .group && c.chat.history(group.uid).count == 1
        }
        try c.chat.send("copy", to: group.uid)
        try await a.waitFor("A gets C's reply in the group") { a.chat.history(group.uid).count == 2 }

        // nobody answered a room message with a receipt
        for p in [a, b, c] {
            for room in [ChatRoom.allChatRooms, "Cyan", "Medic", group.uid] {
                XCTAssertTrue(p.chat.history(room).allSatisfy { $0.status == .none }, "\(p.uid) \(room)")
            }
        }
    }

    func testOneToOneReceiptsComeBackOverAServer() async throws {
        let (a, b, _) = try await onAServer()
        let sent = try a.chat.send("at the RV in 5", to: b.uid)
        try await b.waitFor("B gets A's message, filed under A") {
            b.chat.history(a.uid).map(\.text) == ["at the RV in 5"]
        }
        try await a.waitFor("A's message is delivered") { (try? a.chat.store.line(sent.messageId))??.status == .delivered }
        b.chat.markSeen(a.uid)
        try await a.waitFor("A's message is read") { (try? a.chat.store.line(sent.messageId))??.status == .read }
    }

    func testChatOnTheMesh() async throws {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let a = try peer("a", tag: tag), b = try peer("b", tag: tag)
        for (slot, p) in [(1, a), (2, b)] {
            try await p.commo.startMesh(MeshTests.config(slot: slot), interfaces: ["lo0"])
            await p.start(team: "Cyan", role: "Team Member")
        }
        try await a.waitFor("A hears B") { a.contacts[b.uid] != nil }
        try await b.waitFor("B hears A") { b.contacts[a.uid] != nil }

        try b.chat.send("mesh check", to: ChatRoom.allChatRooms)
        try await a.waitFor("A gets All Chat Rooms on the chat group") {
            a.chat.history(ChatRoom.allChatRooms).map(\.text) == ["mesh check"]
        }
        try await a.seen.wait("…on the chat group", timeout: 5) { event in
            guard case let .cot(xml, endpoint) = event else { return false }
            return endpoint == "*:\(MeshTests.chatPort):udp" && xml.contains("mesh check")
        }

        try b.chat.send("direct", to: a.uid)   // A holds TCP 4242
        try await a.waitFor("A gets B's one-to-one") { a.chat.history(b.uid).map(\.text) == ["direct"] }
        XCTAssertEqual(b.chat.history(ChatRoom.allChatRooms).count, 1, "B's own echo isn't filed twice")
    }
}
