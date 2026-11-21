// ChatStore.swift — chat history and user groups on disk (G3.5b).
//
// SQLite, as ATAK 5.5's ChatDatabase keeps them (owner decision 1): one
// table of messages and one of user-made groups, with ChatDatabase's column
// names where they carry over (conversationId, messageId, senderUid,
// senderCallsign, message, status, sentTime, receiveTime, readTime;
// conversationName, createdLocally, destinations, parent). What macTAK adds:
// `outgoing`, and `seen` (shown on this Mac, which 5.5 keeps in the
// conversation's unread count instead).
//
// The app keeps one file per settings suite in Application Support; tests
// use a temporary file. It is used from the main actor only.

import Foundation

public struct ChatLine: Sendable, Equatable, Identifiable {
    public var id: String { messageId }
    public var messageId: String
    public var conversationId: String
    public var conversationName: String
    public var senderUid: String
    public var senderCallsign: String
    public var text: String
    /// When it was sent (this client's clock for its own, the event's time
    /// for a peer's).
    public var sentTime: Date
    /// When a peer's message arrived here, or when the peer said it got
    /// this client's (delivered receipt).
    public var receiveTime: Date?
    /// When the peer said it read this client's message (read receipt).
    public var readTime: Date?
    public var status: ChatStatus
    public var outgoing: Bool
    /// Whether this Mac has shown a peer's message (for unread counts and
    /// the read receipt).
    public var seen: Bool

    public init(messageId: String, conversationId: String, conversationName: String, senderUid: String,
                senderCallsign: String, text: String, sentTime: Date, receiveTime: Date? = nil,
                readTime: Date? = nil, status: ChatStatus = .none, outgoing: Bool, seen: Bool) {
        self.messageId = messageId; self.conversationId = conversationId
        self.conversationName = conversationName; self.senderUid = senderUid
        self.senderCallsign = senderCallsign; self.text = text; self.sentTime = sentTime
        self.receiveTime = receiveTime; self.readTime = readTime; self.status = status
        self.outgoing = outgoing; self.seen = seen
    }
}

/// A user-made chat group (ChatDatabase's Groups).
public struct ChatGroup: Sendable, Equatable, Identifiable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    /// Member uids, this client among them.
    public var members: [String]
    /// Made on this Mac (createdLocally): only its maker changes it.
    public var createdLocally: Bool

    public init(uid: String, name: String, members: [String], createdLocally: Bool) {
        self.uid = uid; self.name = name; self.members = members; self.createdLocally = createdLocally
    }
}

public typealias ChatStoreError = SQLiteError

public final class ChatStore {
    private let db: SQLiteDatabase

    /// The app's store for a settings suite: Application Support/macTAK/
    /// chat.sqlite, or chat-<suite>.sqlite for a --settings-suite copy.
    public static func appStore(suite: String?) throws -> ChatStore {
        try ChatStore(url: SQLiteDatabase.appFile("chat", suite: suite))
    }

    public init(url: URL) throws {
        db = try SQLiteDatabase(url: url, schema: """
            CREATE TABLE IF NOT EXISTS Chat(
              messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, conversationName TEXT NOT NULL,
              senderUid TEXT NOT NULL, senderCallsign TEXT NOT NULL, message TEXT NOT NULL,
              sentTime INTEGER NOT NULL, receiveTime INTEGER, readTime INTEGER, status TEXT NOT NULL,
              outgoing INTEGER NOT NULL, seen INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS ChatByConversation ON Chat(conversationId, sentTime);
            CREATE TABLE IF NOT EXISTS Groups(
              conversationId TEXT PRIMARY KEY, conversationName TEXT NOT NULL, createdLocally INTEGER NOT NULL,
              destinations TEXT NOT NULL, parent TEXT NOT NULL);
            """)
    }

    // MARK: - messages

    /// Adds a line, or replaces the one with its message id.
    public func save(_ line: ChatLine) throws {
        try db.run("""
            INSERT OR REPLACE INTO Chat(messageId, conversationId, conversationName, senderUid, senderCallsign,
              message, sentTime, receiveTime, readTime, status, outgoing, seen) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [line.messageId, line.conversationId, line.conversationName, line.senderUid, line.senderCallsign,
                  line.text, Self.millis(line.sentTime), line.receiveTime.map(Self.millis),
                  line.readTime.map(Self.millis), Self.statusName(line.status), line.outgoing ? 1 : 0,
                  line.seen ? 1 : 0])
    }

    public func line(_ messageId: String) throws -> ChatLine? {
        try lines("WHERE messageId = ?", [messageId]).first
    }

    /// A conversation's lines, oldest first.
    public func history(_ conversationId: String) throws -> [ChatLine] {
        try lines("WHERE conversationId = ? ORDER BY sentTime, rowid", [conversationId])
    }

    /// Every conversation with lines, with its name and unread count.
    public func conversations() throws -> [(id: String, name: String, unread: Int, last: Date)] {
        var out: [(String, String, Int, Date)] = []
        try db.query("""
            SELECT conversationId, conversationName, SUM(CASE WHEN outgoing = 0 AND seen = 0 THEN 1 ELSE 0 END),
              MAX(sentTime) FROM Chat GROUP BY conversationId
            """, []) { row in
            out.append((row.text(0), row.text(1), Int(row.int(2)), Self.date(row.int(3))))
        }
        return out.map { (id: $0.0, name: $0.1, unread: $0.2, last: $0.3) }
    }

    // MARK: - groups

    public func save(_ group: ChatGroup) throws {
        let members = String(data: try JSONEncoder().encode(group.members), encoding: .utf8)!
        try db.run("""
            INSERT OR REPLACE INTO Groups(conversationId, conversationName, createdLocally, destinations, parent)
            VALUES(?,?,?,?,?)
            """, [group.uid, group.name, group.createdLocally ? 1 : 0, members, ChatRoom.userGroups])
    }

    /// Removes a group and its history, as ChatDatabase.removeGroup does.
    public func removeGroup(_ uid: String) throws {
        try db.run("DELETE FROM Groups WHERE conversationId = ?", [uid])
        try db.run("DELETE FROM Chat WHERE conversationId = ?", [uid])
    }

    public func groups() throws -> [ChatGroup] {
        var out: [ChatGroup] = []
        try db.query("SELECT conversationId, conversationName, createdLocally, destinations FROM Groups ORDER BY rowid",
                  []) { row in
            let members = (try? JSONDecoder().decode([String].self, from: Data(row.text(3).utf8))) ?? []
            out.append(ChatGroup(uid: row.text(0), name: row.text(1),
                                 members: members, createdLocally: row.int(2) != 0))
        }
        return out
    }

    // MARK: - rows

    private func lines(_ clause: String, _ args: [Any?]) throws -> [ChatLine] {
        var out: [ChatLine] = []
        try db.query("""
            SELECT messageId, conversationId, conversationName, senderUid, senderCallsign, message, sentTime,
              receiveTime, readTime, status, outgoing, seen FROM Chat \(clause)
            """, args) { row in
            func optionalDate(_ i: Int32) -> Date? { row.isNull(i) ? nil : Self.date(row.int(i)) }
            out.append(ChatLine(messageId: row.text(0), conversationId: row.text(1),
                                conversationName: row.text(2), senderUid: row.text(3),
                                senderCallsign: row.text(4), text: row.text(5),
                                sentTime: Self.date(row.int(6)), receiveTime: optionalDate(7),
                                readTime: optionalDate(8), status: Self.status(row.text(9)),
                                outgoing: row.int(10) != 0, seen: row.int(11) != 0))
        }
        return out
    }

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1000) }

    /// ChatLine.Status's names, as ChatDatabase stores them.
    private static func statusName(_ s: ChatStatus) -> String {
        switch s {
        case .none: "NONE"
        case .delivered: "DELIVERED"
        case .read: "READ"
        case .pending: "PENDING"
        }
    }

    private static func status(_ name: String) -> ChatStatus {
        ChatStatus.allCases.first { statusName($0) == name } ?? .none
    }
}
