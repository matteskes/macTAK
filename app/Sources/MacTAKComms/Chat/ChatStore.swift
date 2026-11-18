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
import SQLite3

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

public struct ChatStoreError: Error, CustomStringConvertible {
    public let description: String
}

public final class ChatStore {
    private var db: OpaquePointer?

    /// The app's store for a settings suite: Application Support/macTAK/
    /// chat.sqlite, or chat-<suite>.sqlite for a --settings-suite copy.
    public static func appStore(suite: String?) throws -> ChatStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("macTAK", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return try ChatStore(url: support.appendingPathComponent(suite.map { "chat-\($0).sqlite" } ?? "chat.sqlite"))
    }

    public init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw ChatStoreError(description: "can't open \(url.path): \(why)")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
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

    deinit { sqlite3_close(db) }

    // MARK: - messages

    /// Adds a line, or replaces the one with its message id.
    public func save(_ line: ChatLine) throws {
        try run("""
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
        try query("""
            SELECT conversationId, conversationName, SUM(CASE WHEN outgoing = 0 AND seen = 0 THEN 1 ELSE 0 END),
              MAX(sentTime) FROM Chat GROUP BY conversationId
            """, []) { row in
            out.append((Self.text(row, 0), Self.text(row, 1), Int(sqlite3_column_int64(row, 2)),
                        Self.date(sqlite3_column_int64(row, 3))))
        }
        return out.map { (id: $0.0, name: $0.1, unread: $0.2, last: $0.3) }
    }

    // MARK: - groups

    public func save(_ group: ChatGroup) throws {
        let members = String(data: try JSONEncoder().encode(group.members), encoding: .utf8)!
        try run("""
            INSERT OR REPLACE INTO Groups(conversationId, conversationName, createdLocally, destinations, parent)
            VALUES(?,?,?,?,?)
            """, [group.uid, group.name, group.createdLocally ? 1 : 0, members, ChatRoom.userGroups])
    }

    /// Removes a group and its history, as ChatDatabase.removeGroup does.
    public func removeGroup(_ uid: String) throws {
        try run("DELETE FROM Groups WHERE conversationId = ?", [uid])
        try run("DELETE FROM Chat WHERE conversationId = ?", [uid])
    }

    public func groups() throws -> [ChatGroup] {
        var out: [ChatGroup] = []
        try query("SELECT conversationId, conversationName, createdLocally, destinations FROM Groups ORDER BY rowid",
                  []) { row in
            let members = (try? JSONDecoder().decode([String].self, from: Data(Self.text(row, 3).utf8))) ?? []
            out.append(ChatGroup(uid: Self.text(row, 0), name: Self.text(row, 1),
                                 members: members, createdLocally: sqlite3_column_int(row, 2) != 0))
        }
        return out
    }

    // MARK: - SQLite

    private func lines(_ clause: String, _ args: [Any?]) throws -> [ChatLine] {
        var out: [ChatLine] = []
        try query("""
            SELECT messageId, conversationId, conversationName, senderUid, senderCallsign, message, sentTime,
              receiveTime, readTime, status, outgoing, seen FROM Chat \(clause)
            """, args) { row in
            func optionalDate(_ i: Int32) -> Date? {
                sqlite3_column_type(row, i) == SQLITE_NULL ? nil : Self.date(sqlite3_column_int64(row, i))
            }
            out.append(ChatLine(messageId: Self.text(row, 0), conversationId: Self.text(row, 1),
                                conversationName: Self.text(row, 2), senderUid: Self.text(row, 3),
                                senderCallsign: Self.text(row, 4), text: Self.text(row, 5),
                                sentTime: Self.date(sqlite3_column_int64(row, 6)), receiveTime: optionalDate(7),
                                readTime: optionalDate(8), status: Self.status(Self.text(row, 9)),
                                outgoing: sqlite3_column_int(row, 10) != 0, seen: sqlite3_column_int(row, 11) != 0))
        }
        return out
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        try query(sql, args) { _ in }
    }

    private func query(_ sql: String, _ args: [Any?], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case let n as Int64: sqlite3_bind_int64(statement, index, n)
            case let n as Int: sqlite3_bind_int64(statement, index, Int64(n))
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    private func error() -> ChatStoreError {
        ChatStoreError(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    /// SQLITE_TRANSIENT: SQLite copies the bound text.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ row: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(row, i).map { String(cString: $0) } ?? ""
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
