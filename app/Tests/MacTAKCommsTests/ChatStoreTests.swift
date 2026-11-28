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
            store.save(line("m2", at: 2))
            store.save(line("m1", at: 1))
            store.save(line("other", in: ChatRoom.allChatRooms, at: 3))
        }
        let reopened = try ChatStore(url: url)
        let history = reopened.history("ANDROID-viper")
        XCTAssertEqual(history.map(\.messageId), ["m1", "m2"])
        XCTAssertEqual(history[0], line("m1", at: 1))
    }

    func testSavingAgainUpdatesStatusAndTimes() throws {
        let store = try ChatStore(url: url)
        var l = line("m", at: 1, outgoing: true, seen: true)
        store.save(l)
        l.status = .read
        l.receiveTime = Date(timeIntervalSince1970: 1_800_000_005)
        l.readTime = Date(timeIntervalSince1970: 1_800_000_009)
        store.save(l)
        XCTAssertEqual(store.line("m"), l)
        XCTAssertEqual(store.history("ANDROID-viper").count, 1)
        XCTAssertNil(store.line("missing"))
    }

    func testConversationsCountUnseenIncomingOnly() throws {
        let store = try ChatStore(url: url)
        store.save(line("in-1", at: 1))
        store.save(line("in-2", at: 2, seen: true))
        store.save(line("out", at: 3, outgoing: true, seen: true))
        store.save(line("all", in: ChatRoom.allChatRooms, at: 4))
        let byId = Dictionary(uniqueKeysWithValues: store.conversations().map { ($0.id, $0) })
        XCTAssertEqual(byId["ANDROID-viper"]?.unread, 1)
        XCTAssertEqual(byId["ANDROID-viper"]?.last, Date(timeIntervalSince1970: 1_800_000_003))
        XCTAssertEqual(byId[ChatRoom.allChatRooms]?.unread, 1)
    }

    func testGroupsPersistAndGo() throws {
        let group = ChatGroup(uid: "g1", name: "Recon", members: ["a", "b"], createdLocally: true)
        do {
            let store = try ChatStore(url: url)
            store.save(group)
            store.save(ChatGroup(uid: "g2", name: "Theirs", members: ["c"], createdLocally: false))
        }
        let store = try ChatStore(url: url)
        XCTAssertEqual(store.groups().map(\.uid), ["g1", "g2"])
        XCTAssertEqual(store.groups().first, group)
        store.save(line("in-g1", in: "g1", at: 1))
        store.removeGroup("g1")
        XCTAssertEqual(store.groups().map(\.uid), ["g2"])
        XCTAssertTrue(store.history("g1").isEmpty, "its history goes with it")
    }

    func testMarkSeenReturnsTheUnseenIncomingLinesOnce() throws {
        let store = try ChatStore(url: url)
        store.save(line("in-2", at: 2))
        store.save(line("in-1", at: 1))
        store.save(line("shown", at: 3, seen: true))
        store.save(line("out", at: 4, outgoing: true, seen: true))
        store.save(line("other", in: ChatRoom.allChatRooms, at: 5))
        XCTAssertEqual(store.markSeen("ANDROID-viper").map(\.messageId), ["in-1", "in-2"])
        XCTAssertEqual(store.line("in-1")?.seen, true)
        XCTAssertTrue(store.markSeen("ANDROID-viper").isEmpty, "already seen")
        XCTAssertEqual(store.conversations().first { $0.id == ChatRoom.allChatRooms }?.unread, 1, "another room")
    }

    /// As ChatDatabase does: a failure is logged and the reader gets nothing;
    /// only a message or group that can't be saved (addChat, addGroup) toasts.
    func testABrokenStoreGoesOnAndToastsOnlyForSaves() throws {
        let store = try ChatStore(url: url)
        var toasts: [String] = []
        store.onNotSaved = { toasts.append($0) }
        store.save(line("in", at: 1))
        _ = try SQLiteDatabase(url: url, schema: "DROP TABLE Chat; DROP TABLE Groups;")
        XCTAssertNil(store.line("in"))
        XCTAssertTrue(store.history("ANDROID-viper").isEmpty)
        XCTAssertTrue(store.markSeen("ANDROID-viper").isEmpty)
        XCTAssertTrue(store.conversations().isEmpty)
        XCTAssertTrue(store.groups().isEmpty)
        store.removeGroup("g1")
        XCTAssertTrue(toasts.isEmpty, "reads and removeGroup only log")
        store.save(line("in", at: 1))
        store.save(ChatGroup(uid: "g1", name: "Recon", members: ["a"], createdLocally: true))
        XCTAssertEqual(toasts, [ChatStore.notSaved, ChatStore.notSaved])
    }

    /// clearAll turns secure_delete on for itself only: macOS's SQLite starts
    /// at FAST (2), and later deletes must keep it, a failed clear too.
    func testClearAllPutsSecureDeleteBack() throws {
        let store = try ChatStore(url: url)
        let before = try store.secureDelete()
        try store.clearAll()
        XCTAssertEqual(try store.secureDelete(), before)
        _ = try SQLiteDatabase(url: url, schema: "DROP TABLE Groups;")
        XCTAssertThrowsError(try store.clearAll())
        XCTAssertEqual(try store.secureDelete(), before, "after a failed clear")
    }

    func testAnUnwritablePathIsAnError() {
        XCTAssertThrowsError(try ChatStore(url: URL(fileURLWithPath: "/nonexistent-dir/chat.sqlite")))
    }
}
