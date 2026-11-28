// MapItemSync.swift — when the MapItemArchive is written (G3.9a), split out
// of ServerConnections by the G3 clean-code audit:
//
// - `restore` takes the kept items back through the importer and starts
//   keeping: from then on, each time MapItems says the items changed, the
//   archive is synced (that signal already comes after the change has
//   landed, one per turn of the main queue).
// - `suspend` writes once more and stops keeping, so clearing the items
//   afterwards (ServerConnections.stop) doesn't remove them from the
//   store; the next `restore` starts again.
//
// What the importer takes and what the items are stays with MapItems,
// which knows the markers, lines and routes.

import Combine
import Foundation

@MainActor
final class MapItemSync {
    private let archive: MapItemArchive
    private let importer: (StoredMapItem) -> MapItemArchive.Import
    private let items: () -> [ArchivedItem]
    /// Whether changes are being written; false before `restore` and
    /// after `suspend`.
    private(set) var isKeeping = false
    private var watch: AnyCancellable?

    /// `items` is every archived item as it is now; each `changed` may
    /// have changed them.
    init(archive: MapItemArchive, importer: @escaping (StoredMapItem) -> MapItemArchive.Import,
         items: @escaping () -> [ArchivedItem], changed: AnyPublisher<Void, Never>) {
        self.archive = archive
        self.importer = importer
        self.items = items
        watch = changed.sink { [weak self] in self?.sync() }
    }

    /// Takes the kept items back and starts keeping.
    func restore() {
        archive.restore(importer, current: items)
        isKeeping = true
    }

    /// Writes the archived items that changed now.
    func sync() {
        guard isKeeping else { return }
        archive.sync(items())
    }

    /// Writes once more, then stops keeping until the next `restore`.
    func suspend() {
        sync()
        isKeeping = false
    }
}
