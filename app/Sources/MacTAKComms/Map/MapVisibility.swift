// MapVisibility.swift — which map items are hidden (G3.11b): 5.5's
// MapItem.getVisible / setVisible, kept by uid here because macTAK's items
// live in several stores (contacts, CoT markers, R&B lines, routes).
//
// - an item is shown unless hidden; the Overlay Manager hides and shows it
//   (MapItemHierarchyListItem.setVisible), and the map draws a hidden item
//   nothing (MapMarkerSync);
// - an update to the item (a new CoT for it) leaves its visibility as it is,
//   as 5.5's importers do when no "visible" extra comes with the event;
// - an item that leaves the map takes its visibility with it: the same uid
//   coming back is a new item, shown (`keepOnly`);
// - an archived item's visibility is kept across launches in the store's
//   `visible` column (StateSaverListener) and given back when it loads
//   (StateSaverPublisher's "visible" extra), by ServerConnections.

import Combine
import Foundation

@MainActor
public final class MapVisibility: ObservableObject {
    @Published public private(set) var hidden: Set<String> = []

    public init() {}

    public func isVisible(_ uid: String) -> Bool { !hidden.contains(uid) }

    /// Shows or hides each of `uids`.
    public func set(_ uids: some Sequence<String>, visible: Bool) {
        var next = hidden
        for uid in uids {
            if visible { next.remove(uid) } else { next.insert(uid) }
        }
        if next != hidden { hidden = next }
    }

    public func set(_ uid: String, visible: Bool) { set([uid], visible: visible) }

    /// Forgets the hidden items that are no longer on the map.
    public func keepOnly(_ present: Set<String>) {
        let next = hidden.intersection(present)
        if next != hidden { hidden = next }
    }
}
