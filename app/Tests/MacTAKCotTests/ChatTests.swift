// ChatTests.swift — GeoChat's events (G3.5a): what this client sends equals
// the ATAK-shaped fixtures in dev/g3/test/cot-golden/parse (which the
// kernel's leg also round-trips), and what peers send reads as 5.5 reads it.

import Foundation
import XCTest
@testable import MacTAKCot

final class ChatTests: XCTestCase {
    private let me = "MACTAK-00000000-0000-0000-0000-000000000001"
    private let now = Cot.parseTime("2026-11-17T12:00:00.000Z")!
    private var sender: ChatSender {
        ChatSender(uid: me, callsign: "MAC-ONE",
                   point: CotPoint(lat: 47.6062095, lon: -122.3320708, hae: 56.25, ce: 12.5, le: 8.0),
                   address: "192.168.1.10")
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Golden.root.appendingPathComponent("parse/\(name).xml"), encoding: .utf8)
    }

    private func assertSends(_ event: CotEvent?, _ name: String, line: UInt = #line) throws {
        let event = try XCTUnwrap(event, line: line)
        XCTAssertEqual(try Golden.canonical(event.xml()), try Golden.canonical(fixture(name)), name, line: line)
    }

    // MARK: - Sending: one fixture per room kind

    func testAllChatRoomsIsAddressedToTheRoomItself() throws {
        let m = OutgoingChat(messageId: "4f1c0a52-0001", conversationId: ChatRoom.allChatRooms,
                             conversationName: ChatRoom.allChatRooms, text: "radio check",
                             destinations: [ChatRoom.allChatRooms])
        try assertSends(m.event(from: sender, at: now), "chat-all-chat-rooms")
    }

    func testOneToOneNamesItsPeerInRemarksTo() throws {
        let m = OutgoingChat(messageId: "4f1c0a52-0002", conversationId: "ANDROID-viper", conversationName: "VIPER",
                             text: "at the RV in 5", destinations: ["ANDROID-viper"])
        try assertSends(m.event(from: sender, at: now), "chat-one-to-one")
    }

    func testTeamRoomGoesToItsMembersUnderTeamGroups() throws {
        let m = OutgoingChat(messageId: "4f1c0a52-0003", conversationId: "Cyan", conversationName: "Cyan",
                             text: "Cyan, move north", destinations: ["ANDROID-viper", "ANDROID-cobra"],
                             parent: ChatRoom.teamGroups)
        try assertSends(m.event(from: sender, at: now), "chat-team")
    }

    func testRoleRoomWithAHiddenPositionSendsZero() throws {
        var hidden = sender
        hidden.point = .zero
        let m = OutgoingChat(messageId: "4f1c0a52-0004", conversationId: "Medic", conversationName: "Medic",
                             text: "casualty at the bridge", destinations: ["ANDROID-cobra"])
        try assertSends(m.event(from: hidden, at: now), "chat-role")
    }

    func testUserGroupCarriesItsHierarchy() throws {
        var m = OutgoingChat(messageId: "4f1c0a52-0005", conversationId: "c0ffee00-group", conversationName: "Recon",
                             text: "recon group up", destinations: ["ANDROID-viper", "ANDROID-cobra", me],
                             parent: ChatRoom.userGroups)
        m.groupOwner = true
        m.hierarchy = .userGroup(uid: "c0ffee00-group", name: "Recon",
                                 members: [("ANDROID-viper", "VIPER"), ("ANDROID-cobra", "COBRA"), (me, "MAC-ONE")])
        try assertSends(m.event(from: sender, at: now), "chat-user-group")
    }

    func testTextAndRoomNameAreEscaped() throws {
        let m = OutgoingChat(messageId: "4f1c0a52-0006", conversationId: "ANDROID-viper",
                             conversationName: "O'NEIL & CO", text: "line one\na <b> & \"c\"",
                             destinations: ["ANDROID-viper"])
        try assertSends(m.event(from: sender, at: now), "chat-escaped-text")
    }

    func testRemarksToIsDroppedOnceAnyDestinationIsNotTheRoom() {
        let m = OutgoingChat(conversationId: "ANDROID-viper", conversationName: "VIPER", text: "x",
                             destinations: [me, "ANDROID-viper", "ANDROID-cobra"])
        XCTAssertNil(m.event(from: sender, at: now).detail("remarks")?["to"])
    }

    func testOutgoingMessageIdsAreFresh() {
        let a = OutgoingChat(conversationId: "c", conversationName: "c", text: "", destinations: [])
        let b = OutgoingChat(conversationId: "c", conversationName: "c", text: "", destinations: [])
        XCTAssertNotEqual(a.messageId, b.messageId)
    }

    // MARK: - Receipts

    func testDeliveredAndReadReceiptsSwapSenderAndReceiver() throws {
        for (status, name) in [(ChatStatus.delivered, "receipt-delivered"), (.read, "receipt-read")] {
            let r = ChatReceipt(status, messageId: "4f1c0a52-peer-0007", conversationId: "ANDROID-viper",
                                conversationName: "VIPER", to: "ANDROID-viper")
            try assertSends(r.event(from: sender, at: now), name)
        }
    }

    func testNoReceiptIsBuiltForNone() {
        XCTAssertNil(ChatReceipt(.none, messageId: "m", conversationId: "c", conversationName: "c", to: "c")
            .event(from: sender, at: now))
    }

    func testStatusOnlyMovesUpIn55sOrderPendingLast() {
        XCTAssertEqual(ChatStatus(cotType: "b-t-f-d"), .delivered)
        XCTAssertEqual(ChatStatus(cotType: "b-t-f-r"), .read)
        XCTAssertEqual(ChatStatus(cotType: "b-t-f-p"), .pending)
        XCTAssertEqual(ChatStatus(cotType: "b-t-f"), .none)
        XCTAssertTrue(ChatStatus.none.takes(.delivered))
        XCTAssertTrue(ChatStatus.delivered.takes(.read))
        XCTAssertFalse(ChatStatus.read.takes(.delivered))
        XCTAssertFalse(ChatStatus.read.takes(.read))
        // 5.5's quirk, kept: PENDING's ordinal is above READ's.
        XCTAssertTrue(ChatStatus.read.takes(.pending))
    }

    // MARK: - Receiving

    private func received(_ name: String) throws -> ReceivedChat {
        try XCTUnwrap(ReceivedChat(CotEvent.parse(fixture(name))))
    }

    func testReadsAnATAKOneToOne() throws {
        let c = try received("chat-from-atak-one-to-one")
        XCTAssertEqual(c.kind, .message)
        XCTAssertEqual(c.version, .chat3)
        XCTAssertEqual(c.messageId, "9a8b7c6d-0008")
        // The room is this client's uid: the service files it under the sender.
        XCTAssertEqual(c.conversationId, me)
        XCTAssertEqual(c.senderUid, "ANDROID-viper")
        XCTAssertEqual(c.senderCallsign, "VIPER")
        XCTAssertEqual(c.destinations, ["ANDROID-viper", me])
        XCTAssertEqual(c.parent, ChatRoom.rootGroup)
        XCTAssertEqual(c.text, "copy that")
        XCTAssertEqual(c.linkUid, "ANDROID-viper")
        XCTAssertFalse(c.isLegacyGroupCandidate)
    }

    func testReadsWhatItSendsBack() throws {
        let team = try received("chat-team")
        XCTAssertEqual(team.conversationId, "Cyan")
        XCTAssertEqual(team.parent, ChatRoom.teamGroups)
        XCTAssertEqual(team.destinations, [me, "ANDROID-viper", "ANDROID-cobra"])

        let group = try received("chat-user-group")
        XCTAssertTrue(group.groupOwner)
        XCTAssertEqual(group.hierarchy?.uid, ChatRoom.userGroups)
        XCTAssertEqual(group.hierarchy?.contactUIDs, ["ANDROID-viper", "ANDROID-cobra", me])
        XCTAssertEqual(group.destinations, [me, "ANDROID-viper", "ANDROID-cobra"], "chatgrp's duplicate self is dropped")

        let escaped = try received("chat-escaped-text")
        XCTAssertEqual(escaped.text, "line one\na <b> & \"c\"")
        XCTAssertEqual(escaped.chatroom, "O'NEIL & CO")
    }

    func testReadsAReceiptByTheEventUid() throws {
        let r = try received("receipt-pending-from-peer")
        XCTAssertEqual(r.kind, .receipt(.pending))
        XCTAssertEqual(r.messageId, "4f1c0a52-0002")
        XCTAssertEqual(r.senderCallsign, "VIPER")
    }

    func testOldGeoChatNamesRoomAndSenderByCallsign() throws {
        let c = try received("chat-legacy-geochat")
        XCTAssertEqual(c.version, .geoChat)
        XCTAssertNil(c.conversationId, "found by callsign in the contacts")
        XCTAssertNil(c.senderUid, "found by callsign in the contacts")
        XCTAssertEqual(c.uidSenderSection, "VIPER")
        XCTAssertEqual(c.fallbackConversationId, ChatRoom.allChatRooms, "the uid's room, All Streaming renamed")
        XCTAssertEqual(c.chatroom, ChatRoom.allChatRooms, "All Streaming reads as All Chat Rooms")
        XCTAssertEqual(c.destinations, [ChatRoom.allChatRooms])
        XCTAssertEqual(c.messageId, "0011")
    }

    func testChat3WithoutAnIdFallsBackToTheEventUid() throws {
        let xml = "<event uid='GeoChat.S.Room-7.m1' type='b-t-f' time='2026-11-17T12:00:00Z' start='2026-11-17T12:00:00Z' "
            + "stale='2026-11-18T12:00:00Z' how='h-g-i-g-o'><detail><__chat chatroom='R'><chatgrp uid0='S'/></__chat>"
            + "<remarks sourceID='WINTAK-S' source='BAO.F.WinTAK.S'>hi</remarks></detail></event>"
        let c = try XCTUnwrap(ReceivedChat(CotEvent.parse(xml)))
        XCTAssertEqual(c.conversationId, "Room-7")
        XCTAssertEqual(c.senderUid, "WINTAK-S", "WinTAK's sourceID wins")
        XCTAssertEqual(c.messageId, "m1")
    }

    func testLegacyGroupNeedsNoParentHierarchyOrDelete() throws {
        let xml = "<event uid='GeoChat.A.G1.m' type='b-t-f' time='2026-11-17T12:00:00Z' start='2026-11-17T12:00:00Z' "
            + "stale='2026-11-18T12:00:00Z' how='h-g-i-g-o'><detail><__chat id='G1' chatroom='Old group'>"
            + "<chatgrp id='G1' uid0='A' uid1='B'/></__chat><remarks source='BAO.F.ATAK.A'>x</remarks></detail></event>"
        XCTAssertTrue(try XCTUnwrap(ReceivedChat(CotEvent.parse(xml))).isLegacyGroupCandidate)
    }

    func testOnlyBTFEventsAreChat() throws {
        let sa = try CotEvent.parse(fixture("atak-sa-extended-roles"))
        XCTAssertNil(ReceivedChat(sa))
    }
}
