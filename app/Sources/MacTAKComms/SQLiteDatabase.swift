// SQLiteDatabase.swift — the little SQLite the app's stores share: open a
// file in WAL mode, run statements with bound values, read rows. The chat
// history (ChatStore, G3.5b) and the kept map items (MapItemStore, G3.9a)
// are built on it. It is used from one thread at a time.

import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

final class SQLiteDatabase {
    private var db: OpaquePointer?

    /// Application Support/macTAK/<name>.sqlite, or <name>-<suite>.sqlite
    /// for a --settings-suite copy.
    static func appFile(_ name: String, suite: String?) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("macTAK", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(suite.map { "\(name)-\($0).sqlite" } ?? "\(name).sqlite")
    }

    /// Opens (or makes) the file and runs `schema`.
    init(url: URL, schema: String) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw SQLiteError(description: "can't open \(url.path): \(why)")
        }
        try exec("PRAGMA journal_mode=WAL;\n" + schema)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    /// Runs a statement that returns no rows; `args` bind String, Int,
    /// Int64 or nil.
    func run(_ sql: String, _ args: [Any?]) throws {
        try query(sql, args) { _ in }
    }

    func query(_ sql: String, _ args: [Any?], row: (Row) -> Void) throws {
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
            case SQLITE_ROW: row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    /// One result row's columns, by index.
    struct Row {
        let statement: OpaquePointer

        func text(_ i: Int32) -> String {
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
        }

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }

        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    }

    private func error() -> SQLiteError {
        SQLiteError(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    /// SQLITE_TRANSIENT: SQLite copies the bound text.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
