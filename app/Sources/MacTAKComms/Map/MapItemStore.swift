// MapItemStore.swift — the map items kept across launches (G3.9a), as
// ATAK 5.5's StateSaver keeps them in statesaver2.sqlite: one row per item
// in table `cotevents`, its CoT XML with its uid and type, whether it is
// shown, when it last changed, and a query order that loads some types
// after the rest (routes 2, jump points 1, all else 0) so what they link
// to is there first.
//
// 5.5's columns, less two it doesn't need here: point_geom (a SpatiaLite
// point, for queries macTAK doesn't make) and json_serialized (always
// empty for CoT). A uid has one row (5.5 checks before it inserts; here a
// unique index does it).
//
// The app keeps one file per settings suite, as the chat history; tests use
// a temporary file. It is used from the main actor only.

import Foundation

/// One kept item.
public struct StoredMapItem: Sendable, Equatable {
    public var uid: String
    public var type: String
    /// The item as a CoT event's XML.
    public var event: String
    public var visible: Bool
    public var lastUpdateTime: Date

    public init(uid: String, type: String, event: String, visible: Bool = true, lastUpdateTime: Date) {
        self.uid = uid; self.type = type; self.event = event; self.visible = visible
        self.lastUpdateTime = lastUpdateTime
    }
}

public final class MapItemStore {
    private let db: SQLiteDatabase

    /// The app's store for a settings suite: Application Support/macTAK/
    /// statesaver.sqlite, or statesaver-<suite>.sqlite.
    public static func appStore(suite: String?) throws -> MapItemStore {
        try MapItemStore(url: SQLiteDatabase.appFile("statesaver", suite: suite))
    }

    public init(url: URL) throws {
        db = try SQLiteDatabase(url: url, schema: """
            CREATE TABLE IF NOT EXISTS cotevents(
              _id INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT, type TEXT, event TEXT,
              visible INTEGER, lastUpdateTime INTEGER, queryOrder INTEGER);
            CREATE UNIQUE INDEX IF NOT EXISTS cotevents_uid ON cotevents(uid);
            """)
    }

    /// Adds the item, or replaces the row with its uid (keeping its place
    /// in the load order among items of the same query order).
    public func save(_ item: StoredMapItem) throws {
        try db.run("""
            INSERT INTO cotevents(uid, type, event, visible, lastUpdateTime, queryOrder) VALUES(?,?,?,?,?,?)
            ON CONFLICT(uid) DO UPDATE SET type = excluded.type, event = excluded.event,
              visible = excluded.visible, lastUpdateTime = excluded.lastUpdateTime, queryOrder = excluded.queryOrder
            """, [item.uid, item.type, item.event, item.visible ? 1 : 0,
                  Int64((item.lastUpdateTime.timeIntervalSince1970 * 1000).rounded()), Self.queryOrder(item.type)])
    }

    public func remove(uid: String) throws {
        try db.run("DELETE FROM cotevents WHERE uid = ?", [uid])
    }

    /// Every kept item in the order 5.5 loads them: by query order, then as
    /// first saved.
    public func items() throws -> [StoredMapItem] {
        var out: [StoredMapItem] = []
        try db.query("SELECT uid, type, event, visible, lastUpdateTime FROM cotevents ORDER BY queryOrder, _id",
                     []) { row in
            out.append(StoredMapItem(uid: row.text(0), type: row.text(1), event: row.text(2),
                                     visible: row.int(3) != 0,
                                     lastUpdateTime: Date(timeIntervalSince1970: TimeInterval(row.int(4)) / 1000)))
        }
        return out
    }

    /// StateSaver.QUERY_ORDER: a type starting with a key loads in that
    /// order; anything else is 0.
    static func queryOrder(_ type: String) -> Int {
        [("b-m-r", 2), ("b-m-p-j-alt", 1), ("b-m-p-j", 1)].first { type.hasPrefix($0.0) }?.1 ?? 0
    }
}
