// ChatServiceTests.swift — GeoChat's rules (G3.5b), with clients joined by
// an in-memory network instead of commo: each room kind reaches the right
// members, receipts follow ATAK 5.5 (delivered and read in one-to-one only,
// pending read but never sent), and the contact lookups ChatMessageParser
// makes. ChatCommsTests runs the same legs through commo.

import Foundation
import XCTest
@testable import MacTAKComms

/// Clients that hear each other: a broadcast reaches every other client, a
/// send only the uids named. Every event sent is kept.
@MainActor
final class LoopbackNet {
    final class Transport: ChatTransport, @unchecked Sendable {
        weak var net: LoopbackNet?
        let from: String
        init(net: LoopbackNet, from: String) { self.net = net; self.from = from }
        func broadcast(_ xml: String, via route: SendRoute) async throws {
            await net?.deliver(xml, from: from, to: nil, route: route)
        }
        func send(_ xml: String, to uids: [String]) async throws {
            await net?.deliver(xml, from: from, to: uids, route: nil)
        }
    }

    struct Sent { let xml: String; let from: String; let to: [String]?; let route: SendRoute? }

    private(set) var sent: [Sent] = []
    private var clients: [String: ChatService] = [:]

    func join(_ uid: String, _ chat: ChatService) {
        clients[uid] = chat
        chat.attach(Transport(net: self, from: uid))
    }

    func deliver(_ xml: String, from: String, to: [String]?, route: SendRoute?) {
        sent.append(Sent(xml: xml, from: from, to: to, route: route))
        for (uid, chat) in clients where uid != from && (to?.contains(uid) ?? true) {
            chat.receive(xml)
        }
    }

    /// Lets every queued send land, including the ones they cause.
    func settle() async {
        for _ in 0..<4 { for chat in clients.values { await chat.flush() } }
    }

    func sentTypes(from uid: String) -> [String] {
        sent.filter { $0.from == uid }.compactMap { try? CotEvent.parse($0.xml).type }
    }
}

@MainActor
final class ChatServiceTests: XCTestCase {
    /// One client: its store, its contacts and its chat.
    @MainActor
    final class Peer {
        /// What the service asks for whenever it needs it.
        final class Me {
            var identity: ChatIdentity
            init(_ identity: ChatIdentity) { self.identity = identity }
        }

        let uid: String
        let me: Me
        let contacts: ContactStore
        let chat: ChatService
        let url: URL
        var callsign: String { me.identity.sender.callsign }
        var team: String { me.identity.team }
        var role: String {
            get { me.identity.role }
            set { me.identity.role = newValue }
        }

        init(_ name: String, team: String = "Cyan", role: String = "Team Member") throws {
            uid = "ANDROID-\(name)"
            let me = Me(ChatIdentity(sender: ChatSender(uid: uid, callsign: name.uppercased(), address: "10.0.0.1"),
                                     team: team, role: role))
            self.me = me
            url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).sqlite")
            contacts = ContactStore(selfUID: uid)
            chat = ChatService(store: try ChatStore(url: url), contacts: contacts) { me.identity }
        }

        /// This peer's SA, as another client hears it.
        var sa: String {
            SelfEvent(uid: uid, callsign: callsign, group: GroupDetail(team: team, role: role)).event(stale: 60).xml()
        }

        func hears(_ peers: Peer...) {
            for p in peers { contacts.receive(p.sa, via: .mesh) }
            chat.refresh()
        }

        func lines(_ room: String) -> [ChatLine] { chat.history(room) }

        func remove() {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
    }

    private var net: LoopbackNet!
    private var peers: [Peer] = []

    override func setUp() async throws {
        net = LoopbackNet()
    }

    override func tearDown() async throws {
        // 5.5 never sends a pending receipt, so no test may make one go out.
        XCTAssertFalse(net.sent.contains { $0.xml.contains("b-t-f-p") }, "a pending receipt was sent")
        peers.forEach { $0.remove() }
    }

    private func peer(_ name: String, team: String = "Cyan", role: String = "Team Member") throws -> Peer {
        let p = try Peer(name, team: team, role: role)
        peers.append(p)
        net.join(p.uid, p.chat)
        return p
    }

    /// Three clients that all hear each other.
    private func three() throws -> (Peer, Peer, Peer) {
        let a = try peer("alpha"), b = try peer("bravo"), c = try peer("charlie", team: "Red", role: "Medic")
        a.hears(b, c); b.hears(a, c); c.hears(a, b)
        return (a, b, c)
    }

    // MARK: - rooms

    func testRoomsFollowTheContactsTeamsAndRoles() throws {
        let (a, b, c) = try three()
        let rooms = Dictionary(uniqueKeysWithValues: a.chat.conversations.map { ($0.id, $0) })
        XCTAssertEqual(a.chat.conversations.first?.id, ChatRoom.allChatRooms)
        XCTAssertEqual(rooms["Cyan"]?.members, [b.uid])
        XCTAssertEqual(rooms["Red"]?.members, [c.uid])
        XCTAssertEqual(rooms["Cyan"]?.writable, true, "A's own team")
        XCTAssertEqual(rooms["Red"]?.writable, false, "another team's room")
        XCTAssertEqual(rooms["Medic"]?.members, [c.uid])
        XCTAssertEqual(rooms["Medic"]?.writable, false, "A isn't a medic")
        XCTAssertNil(rooms["HQ"], "an empty role room is hidden")
        XCTAssertNil(rooms["Team Member"], "there is no Team Member room")
        XCTAssertEqual(rooms[b.uid]?.kind, .direct)
        XCTAssertEqual(rooms[b.uid]?.name, "BRAVO")
        XCTAssertEqual(GroupDetail.teams.filter { rooms[$0] != nil }.count, 14, "every team has a room")
    }

    func testAnotherTeamsRoomRefusesToSend() throws {
        let (a, _, _) = try three()
        XCTAssertThrowsError(try a.chat.send("hi", to: "Red"))
        XCTAssertThrowsError(try a.chat.send("hi", to: "nowhere"))
    }

    // MARK: - one room kind each

    func testAllChatRoomsReachesEveryoneWithNoReceipt() async throws {
        let (a, b, c) = try three()
        try a.chat.send("radio check", to: ChatRoom.allChatRooms)
        await net.settle()
        XCTAssertEqual(net.sent.first?.route, .any)
        for p in [b, c] {
            XCTAssertEqual(p.lines(ChatRoom.allChatRooms).map(\.text), ["radio check"])
            XCTAssertEqual(p.lines(ChatRoom.allChatRooms).first?.senderUid, a.uid)
        }
        XCTAssertEqual(net.sentTypes(from: b.uid), [], "no receipt in a room")
        XCTAssertEqual(a.lines(ChatRoom.allChatRooms).first?.status, ChatStatus.none)
    }

    func testOneToOneIsDeliveredThenRead() async throws {
        let (a, b, c) = try three()
        let sent = try a.chat.send("at the RV in 5", to: b.uid)
        await net.settle()

        let got = try XCTUnwrap(b.lines(a.uid).first, "filed under the sender")
        XCTAssertEqual(got.text, "at the RV in 5")
        XCTAssertEqual(got.conversationName, "ALPHA")
        XCTAssertTrue(c.lines(a.uid).isEmpty && c.lines(b.uid).isEmpty, "C got nothing")
        XCTAssertEqual(net.sentTypes(from: b.uid), ["b-t-f-d"])
        XCTAssertEqual(a.lines(b.uid).first?.status, .delivered)
        XCTAssertNotNil(a.lines(b.uid).first?.receiveTime)
        XCTAssertEqual(a.chat.conversation(b.uid)?.unread, 0, "A's own line")
        XCTAssertEqual(b.chat.conversation(a.uid)?.unread, 1)

        b.chat.markSeen(a.uid)
        await net.settle()
        XCTAssertEqual(net.sentTypes(from: b.uid), ["b-t-f-d", "b-t-f-r"])
        XCTAssertEqual(a.chat.store.line(sent.messageId)?.status, .read)
        XCTAssertNotNil(a.lines(b.uid).first?.readTime)
        XCTAssertEqual(b.chat.conversation(a.uid)?.unread, 0)

        b.chat.markSeen(a.uid)
        await net.settle()
        XCTAssertEqual(net.sentTypes(from: b.uid).count, 2, "read is sent once")
    }

    func testTeamRoomReachesTheTeamOnlyWithNoReceipt() async throws {
        let (a, b, c) = try three()
        try a.chat.send("Cyan, move north", to: "Cyan")
        await net.settle()
        XCTAssertEqual(net.sent.first?.to, [b.uid])
        XCTAssertEqual(b.lines("Cyan").map(\.text), ["Cyan, move north"])
        XCTAssertTrue(c.lines("Cyan").isEmpty, "C is on Red")
        XCTAssertEqual(net.sentTypes(from: b.uid), [])
        b.chat.markSeen("Cyan")
        await net.settle()
        XCTAssertEqual(net.sentTypes(from: b.uid), [], "no read receipt in a room")
    }

    func testRoleRoomReachesThatRoleOnly() async throws {
        let (a, b, c) = try three()
        a.role = "Medic"
        a.chat.refresh()
        try a.chat.send("casualty at the bridge", to: "Medic")
        await net.settle()
        XCTAssertEqual(c.lines("Medic").map(\.text), ["casualty at the bridge"])
        XCTAssertTrue(b.lines("Medic").isEmpty)
        XCTAssertEqual(net.sentTypes(from: c.uid), [])
    }

    func testUserGroupReachesItsMembersAndArrivesAsAGroup() async throws {
        let (a, b, c) = try three()
        let d = try peer("delta")
        a.hears(d); d.hears(a)
        let group = a.chat.createGroup(name: "Recon", members: [b.uid, c.uid])
        XCTAssertEqual(group.members, [b.uid, c.uid, a.uid])
        try a.chat.send("recon group up", to: group.uid)
        await net.settle()

        XCTAssertEqual(Set(net.sent.first?.to ?? []), [b.uid, c.uid])
        for p in [b, c] {
            let theirs = try XCTUnwrap(p.chat.store.groups().first)
            XCTAssertEqual(theirs.uid, group.uid)
            XCTAssertEqual(theirs.name, "Recon")
            XCTAssertFalse(theirs.createdLocally)
            XCTAssertEqual(Set(theirs.members), [a.uid, b.uid, c.uid])
            XCTAssertEqual(p.chat.conversation(group.uid)?.kind, .group)
            XCTAssertEqual(p.lines(group.uid).map(\.text), ["recon group up"])
        }
        XCTAssertTrue(d.lines(group.uid).isEmpty)
        XCTAssertEqual(net.sentTypes(from: b.uid), [], "no receipt in a group")

        // A reply: the owner's group isn't changed by a member's hierarchy.
        try b.chat.send("copy", to: group.uid)
        await net.settle()
        XCTAssertEqual(a.lines(group.uid).map(\.text), ["recon group up", "copy"])
        XCTAssertEqual(a.chat.store.groups().first, group)
    }

    func testDeletingAGroupTellsItsMembers() async throws {
        let (a, b, _) = try three()
        let group = a.chat.createGroup(name: "Recon", members: [b.uid])
        try a.chat.send("x", to: group.uid)
        await net.settle()
        XCTAssertEqual(b.chat.store.groups().count, 1)
        a.chat.deleteGroup(group.uid)
        await net.settle()
        XCTAssertEqual(a.chat.store.groups().count, 0)
        XCTAssertEqual(b.chat.store.groups().count, 0)
        XCTAssertNil(b.chat.conversation(group.uid))
    }

    // MARK: - receipts

    func testPendingIsShownAndStatusNeverGoesDown() async throws {
        let (a, b, _) = try three()
        let sent = try a.chat.send("x", to: b.uid)
        await net.settle()
        func receipt(_ status: ChatStatus) -> String {
            ChatReceipt(status, messageId: sent.messageId, conversationId: a.uid, conversationName: "ALPHA",
                        to: a.uid).event(from: ChatSender(uid: b.uid, callsign: "BRAVO", address: "10.0.0.2"))!.xml()
        }
        a.chat.receive(receipt(.read))
        XCTAssertEqual(a.chat.store.line(sent.messageId)?.status, .read)
        a.chat.receive(receipt(.delivered))
        XCTAssertEqual(a.chat.store.line(sent.messageId)?.status, .read, "a lower status is ignored")
        a.chat.receive(receipt(.pending))
        XCTAssertEqual(a.chat.store.line(sent.messageId)?.status, .pending, "5.5's order: pending after read")
    }

    func testAReceiptForAnUnknownMessageIsIgnored() throws {
        let (a, _, _) = try three()
        let before = a.chat.revision
        a.chat.receive(ChatReceipt(.read, messageId: "nope", conversationId: "x", conversationName: "x", to: "x")
            .event(from: ChatSender(uid: "ANDROID-bravo", callsign: "BRAVO", address: "1.1.1.1"))!.xml())
        XCTAssertEqual(a.chat.revision, before)
    }

    func testASenderWithNoSAGetsNoReceipt() async throws {
        let a = try peer("alpha"), stranger = try peer("stranger")
        stranger.hears(a)   // A has never heard the stranger
        try stranger.chat.send("hello?", to: a.uid)
        await net.settle()
        XCTAssertEqual(a.lines(stranger.uid).map(\.text), ["hello?"])
        XCTAssertEqual(net.sentTypes(from: a.uid), [])
    }

    // MARK: - receiving

    func testAMessageHeardTwiceIsKeptOnce() async throws {
        let (a, b, _) = try three()
        try a.chat.send("x", to: ChatRoom.allChatRooms)
        await net.settle()
        b.chat.receive(net.sent[0].xml)
        XCTAssertEqual(b.lines(ChatRoom.allChatRooms).count, 1)
    }

    func testItsOwnMessagesComingBackAreIgnored() async throws {
        let (a, _, _) = try three()
        try a.chat.send("x", to: ChatRoom.allChatRooms)
        await net.settle()
        a.chat.receive(net.sent[0].xml)
        XCTAssertEqual(a.lines(ChatRoom.allChatRooms).count, 1)
        XCTAssertTrue(a.lines(ChatRoom.allChatRooms)[0].outgoing)
    }

    /// 5.5's Chat Preferences › Clear History (GeoChatService.clearMessageDB,
    /// ChatDatabase.clearAll): the history and the user groups go, and, as
    /// 5.5 deletes the file securely, nothing of them is left on disk.
    func testClearHistoryRemovesTheHistoryAndGroupsFromDisk() async throws {
        let (a, b, _) = try three()
        try a.chat.send("secret-words", to: ChatRoom.allChatRooms)
        a.chat.createGroup(name: "Squad", members: [b.uid])
        await net.settle()
        XCTAssertFalse(a.lines(ChatRoom.allChatRooms).isEmpty)
        try a.chat.clearHistory()
        XCTAssertTrue(a.lines(ChatRoom.allChatRooms).isEmpty)
        XCTAssertFalse(a.chat.conversations.contains { $0.kind == .group }, "the user group went too")
        for suffix in ["", "-wal"] {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: a.url.path + suffix))) ?? Data()
            XCTAssertNil(data.range(of: Data("secret-words".utf8)), "left in the file\(suffix)")
            XCTAssertNil(data.range(of: Data("Squad".utf8)), "left in the file\(suffix)")
        }
    }

    /// A clear that fails part way may already have removed lines: the rooms
    /// are rebuilt anyway, so the window doesn't show what's gone.
    func testAFailedClearStillRebuildsTheRooms() async throws {
        let (a, _, _) = try three()
        try a.chat.send("x", to: ChatRoom.allChatRooms)
        await net.settle()
        XCTAssertNotNil(a.chat.conversation(ChatRoom.allChatRooms)?.lastMessage)
        _ = try SQLiteDatabase(url: a.url, schema: "DROP TABLE Groups;")   // Chat goes, then Groups fails
        XCTAssertThrowsError(try a.chat.clearHistory())
        XCTAssertNil(a.chat.conversation(ChatRoom.allChatRooms)?.lastMessage)
    }

    /// Clean-code audit d: a received message the store can't save says so
    /// with 5.5's toast text (ChatDatabase, chat_text14), not silently.
    func testAMessageThatCantBeSavedSaysSo() async throws {
        let (a, b, _) = try three()
        _ = try SQLiteDatabase(url: b.url, schema: "DROP TABLE Chat;")   // B's store breaks
        try a.chat.send("x", to: ChatRoom.allChatRooms)
        await net.settle()
        XCTAssertEqual(b.chat.lastError, ChatStore.notSaved)
        XCTAssertNil(a.chat.lastError, "the sender's own store is fine")
    }

    /// 5.5 saves a receipt's status through addChat, so its failure gets the
    /// same toast.
    func testAReceiptThatCantBeSavedSaysSo() async throws {
        let (a, b, _) = try three()
        try a.chat.send("x", to: b.uid)
        _ = try SQLiteDatabase(url: a.url, schema: """
            CREATE TRIGGER broken BEFORE INSERT ON Chat BEGIN SELECT RAISE(ABORT, 'broken'); END;
            """)   // A's store breaks after its own line is kept
        await net.settle()
        XCTAssertEqual(a.chat.lastError, ChatStore.notSaved)
        XCTAssertNil(b.chat.lastError)
    }

    /// 5.5's HierarchyParser saves a received group through addGroup, which
    /// toasts on failure.
    func testAGroupThatCantBeSavedSaysSo() async throws {
        let (a, b, c) = try three()
        let group = a.chat.createGroup(name: "Recon", members: [b.uid, c.uid])
        _ = try SQLiteDatabase(url: b.url, schema: "DROP TABLE Groups;")   // B's groups break
        try a.chat.send("recon group up", to: group.uid)
        await net.settle()
        XCTAssertEqual(b.chat.lastError, ChatStore.notSaved)
        XCTAssertNil(c.chat.lastError)
    }

    func testOldGeoChatIsResolvedByCallsign() throws {
        let (a, b, _) = try three()
        let t = Cot.time(Date())
        a.chat.receive("<event version='2.0' uid='GeoChat.BRAVO.ALPHA.0042' type='b-t-f' time='\(t)' start='\(t)' "
            + "stale='\(t)' how='h-g-i-g-o'><point lat='0' lon='0'/><detail><__chat chatroom='ALPHA' "
            + "senderCallsign='BRAVO'/><remarks source='BAO.F.ATAK.BRAVO'>old client</remarks></detail></event>")
        let got = try XCTUnwrap(a.lines(b.uid).first, "ALPHA is A itself: a one-to-one from B")
        XCTAssertEqual(got.senderUid, b.uid)
        XCTAssertEqual(got.messageId, "0042")
    }

    func testALegacyGroupIsMadeFromTheChatgrp() throws {
        let (a, b, c) = try three()
        let t = Cot.time(Date())
        a.chat.receive("<event version='2.0' uid='GeoChat.\(b.uid).old-group.m9' type='b-t-f' time='\(t)' "
            + "start='\(t)' stale='\(t)' how='h-g-i-g-o'><point lat='0' lon='0'/><detail><__chat id='old-group' "
            + "chatroom='Old Group' senderCallsign='BRAVO'><chatgrp id='old-group' uid0='\(b.uid)' uid1='\(a.uid)' "
            + "uid2='\(c.uid)'/></__chat><remarks source='BAO.F.ATAK.\(b.uid)'>legacy</remarks></detail></event>")
        let group = try XCTUnwrap(a.chat.store.groups().first)
        XCTAssertEqual(group.uid, "old-group")
        XCTAssertEqual(group.name, "Old Group")
        XCTAssertEqual(group.members, [b.uid, a.uid, c.uid])
        XCTAssertEqual(a.lines("old-group").map(\.text), ["legacy"])
    }

    func testOnlyChatIsTaken() throws {
        let (a, b, _) = try three()
        let before = a.chat.revision
        a.chat.receive(b.sa)
        a.chat.receive("not xml")
        XCTAssertEqual(a.chat.revision, before)
    }
}
