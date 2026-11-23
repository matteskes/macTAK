// MapItemArchive.swift — keeping the archived map items across launches
// (G3.9a), as ATAK 5.5's StateSaver does:
//
// - what is kept: every item marked archive, as its CoT (StateSaverListener
//   on ITEM_PERSIST); this client's own uid never is. Today that is the
//   range and bearing lines (RangeBearingLines) and the received markers
//   that came with <archive/> (CotMarkerStore), and the points placed here
//   (PointDropper, G3.9b), which are archived markers.
// - when: 5.5 writes an item whenever it persists (made, changed, moved);
//   here the owner calls `sync` with every archived item as it is now, and
//   only what changed is written, as one transaction would batch it.
//   An item that is no longer there (deleted, or no longer archived) is
//   removed (ITEM_REMOVED).
// - at launch: the kept events go back through the importers in the
//   store's order (StateSaverPublisher). One an importer defers (a line
//   whose marker isn't loaded yet) is tried again once all the rest are
//   in. Taking them back writes nothing (5.5 doesn't persist an import
//   from the StateSaver), and a row no importer takes is left alone.

import Foundation

/// An archived item as it is now.
public struct ArchivedItem {
    public var uid: String
    public var type: String
    /// What it is now, without the clock in it: the item is written again
    /// only when this changes. Nil leaves it as last stored (it is there,
    /// but can't be written right now).
    public var signature: String?
    /// Its CoT, made when it is written.
    public var event: () -> String

    public init(uid: String, type: String, signature: String?, event: @escaping () -> String) {
        self.uid = uid; self.type = type; self.signature = signature; self.event = event
    }
}

@MainActor
public final class MapItemArchive {
    /// What one kept event came to when taken back.
    public enum Import: Equatable, Sendable { case taken, deferred, ignored }

    private let store: MapItemStore
    private let selfUID: String
    /// The signature each stored item was written with.
    private var written: [String: String] = [:]

    public init(store: MapItemStore, selfUID: String) {
        self.store = store
        self.selfUID = selfUID
    }

    /// Takes the kept events back through `importer`, deferred ones last,
    /// then counts `current` (the items as the import left them) as
    /// written. Returns how many were taken.
    @discardableResult
    public func restore(_ importer: (String) -> Import, current: () -> [ArchivedItem]) -> Int {
        let kept = (try? store.items()) ?? []
        var taken = 0
        var deferred: [String] = []
        for item in kept where item.uid != selfUID {
            switch importer(item.event) {
            case .taken: taken += 1
            case .deferred: deferred.append(item.event)
            case .ignored: break
            }
        }
        for event in deferred where importer(event) != .ignored { taken += 1 }
        written = Dictionary(current().compactMap { item in item.signature.map { (item.uid, $0) } },
                             uniquingKeysWith: { a, _ in a })
        return taken
    }

    /// Writes the archived items that changed since last written and
    /// removes the ones that are gone. A write that fails is tried again
    /// at the next sync.
    public func sync(_ items: [ArchivedItem], now: Date = Date()) {
        var seen = Set<String>()
        for item in items where item.uid != selfUID && seen.insert(item.uid).inserted {
            guard let signature = item.signature, written[item.uid] != signature else { continue }
            let stored = StoredMapItem(uid: item.uid, type: item.type, event: item.event(), lastUpdateTime: now)
            if (try? store.save(stored)) != nil { written[item.uid] = signature }
        }
        for uid in written.keys where !seen.contains(uid) {
            if (try? store.remove(uid: uid)) != nil { written[uid] = nil }
        }
    }
}
