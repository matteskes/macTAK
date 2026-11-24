// MapItemSync.swift — when the MapItemArchive is written (G3.9a), split out
// of ServerConnections by the G3 clean-code audit:
//
// - `restore` takes the kept items back through the importer and starts
//   keeping: from then on, any change the watched publishers announce
//   schedules one sync, coalesced, run after the change has landed
//   (objectWillChange fires before it does).
// - `suspend` writes once more and stops keeping, so clearing the items
//   afterwards (ServerConnections.stop) doesn't remove them from the
//   store; the next `restore` starts again.
//
// What the importer takes and what the items are stays with the owner,
// which knows the markers and lines.

import Combine
import Foundation

@MainActor
final class MapItemSync {
    private let archive: MapItemArchive
    private let importer: (String) -> MapItemArchive.Import
    private let items: () -> [ArchivedItem]
    /// Whether changes are being written; false before `restore` and
    /// after `suspend`.
    private(set) var isKeeping = false
    private var syncPending = false
    private var watches: [AnyCancellable] = []

    /// `items` is every archived item as it is now; a change any of
    /// `changes` announces may have changed them.
    init(archive: MapItemArchive, importer: @escaping (String) -> MapItemArchive.Import,
         items: @escaping () -> [ArchivedItem], changes: [ObservableObjectPublisher]) {
        self.archive = archive
        self.importer = importer
        self.items = items
        watches = changes.map { $0.sink { [weak self] _ in self?.scheduleSync() } }
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

    private func scheduleSync() {
        guard isKeeping, !syncPending else { return }
        syncPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.syncPending = false
                self?.sync()
            }
        }
    }
}
