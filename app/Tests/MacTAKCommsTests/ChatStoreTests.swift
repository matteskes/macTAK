// ChatStoreTests.swift — the chat history and user groups on disk (G3.5b).

import Foundation
import XCTest
@testable import MacTAKComms

final class ChatStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func line(_ id: String, in room: String = "ANDROID-viper", at seconds: TimeInterval,
                      outgoing: Bool = false, seen: Bool = false) -> ChatLine {
        ChatLine(messageId: id, conversationId: room, conversationName: "VIPER", senderUid: "ANDROID-viper",
                 senderCallsign: "VIPER", text: "text \(id) — ünïcode & 'quotes'",
                 sentTime: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
                 outgoing: outgoing, seen: seen)
    }

    func testHistorySurvivesReopeningInOrder() throws {
        do {
            let store = try ChatStore(url: url)
            try store.save(line("m2", at: 2))
            try store.save(line("m1", at: 1))
            try store.save(line("other", in: ChatRoom.allChatRooms, at: 3))
        }
        let reopened = try ChatStore(url: url)
        let history = try reopened.history("ANDROID-viper")
        XCTAssertEqual(history.map(\.messageId), ["m1", "m2"])
        XCTAssertEqual(history[0], line("m1", at: 1))
    }

    func testSavingAgainUpdatesStatusAndTimes() throws {
        let store = try ChatStore(url: url)
        var l = line("m", at: 1, outgoing: true, seen: true)
        try store.save(l)
        l.status = .read
        l.receiveTime = Date(timeIntervalSince1970: 1_800_000_005)
        l.readTime = Date(timeIntervalSince1970: 1_800_000_009)
        try store.save(l)
        XCTAssertEqual(try store.line("m"), l)
        XCTAssertEqual(try store.history("ANDROID-viper").count, 1)
        XCTAssertNil(try store.line("missing"))
    }

    func testConversationsCountUnseenIncomingOnly() throws {
        let store = try ChatStore(url: url)
        try store.save(line("in-1", at: 1))
        try store.save(line("in-2", at: 2, seen: true))
        try store.save(line("out", at: 3, outgoing: true, seen: true))
        try store.save(line("all", in: ChatRoom.allChatRooms, at: 4))
        let byId = Dictionary(uniqueKeysWithValues: try store.conversations().map { ($0.id, $0) })
        XCTAssertEqual(byId["ANDROID-viper"]?.unread, 1)
        XCTAssertEqual(byId["ANDROID-viper"]?.last, Date(timeIntervalSince1970: 1_800_000_003))
        XCTAssertEqual(byId[ChatRoom.allChatRooms]?.unread, 1)
    }

    func testGroupsPersistAndGo() throws {
        let group = ChatGroup(uid: "g1", name: "Recon", members: ["a", "b"], createdLocally: true)
        do {
            let store = try ChatStore(url: url)
            try store.save(group)
            try store.save(ChatGroup(uid: "g2", name: "Theirs", members: ["c"], createdLocally: false))
        }
        let store = try ChatStore(url: url)
        XCTAssertEqual(try store.groups().map(\.uid), ["g1", "g2"])
        XCTAssertEqual(try store.groups().first, group)
        try store.save(line("in-g1", in: "g1", at: 1))
        try store.removeGroup("g1")
        XCTAssertEqual(try store.groups().map(\.uid), ["g2"])
        XCTAssertTrue(try store.history("g1").isEmpty, "its history goes with it")
    }

    func testAnUnwritablePathIsAnError() {
        XCTAssertThrowsError(try ChatStore(url: URL(fileURLWithPath: "/nonexistent-dir/chat.sqlite")))
    }
}
