// OverlayItems.swift — the map's items as the Overlay Manager sees them
// (G3.11a): a contact, a CoT marker, an R&B line and a route, each as
// 5.5's MapItem would carry it into the filter overlays (OverlayItem).
//
// - a contact: its callsign, type and point, and its <__group>'s team and
//   role; its SA names no author.
// - a CoT marker: its label, type and point, its <__group>, its iconset
//   path, and its author from its event's <link> and <creator>.
// - an R&B line: "u-rb-a", its title, its two ends where they are now,
//   its <creator>, in the Range & Bearing group.
// - a route: "b-m-r", its title and points, its <creator>; a search finds
//   it by its waypoints' callsigns too.

import Foundation
import MacTAKCot

extension OverlayItem {
    public init(_ contact: Contact) {
        self.init(id: contact.uid, title: contact.callsign, type: contact.type, location: .point(contact.point),
                  team: contact.group?.team, role: contact.group?.role)
    }

    public init(_ marker: CotMarker) {
        self.init(id: marker.uid, title: marker.label ?? "", type: marker.type, location: .point(marker.point),
                  team: marker.traits.group?.team, role: marker.traits.group?.role,
                  author: OverlayItem.markerAuthor(of: marker.event.detail), iconsetPath: marker.traits.iconsetPath)
    }

    /// `line`, its ends tied to markers found by `locate` (an end whose
    /// marker isn't found is left out).
    public init(_ line: RangeBearingLine, locate: (String) -> CotPoint?) {
        let ends = [line.start, line.end].compactMap { end -> CotPoint? in
            switch end {
            case .item(let uid): locate(uid)
            case .point(let p): p
            }
        }
        self.init(id: line.id, title: line.title, type: RangeBearingEvent.type, location: .line(ends),
                  author: line.creator?.uid, group: .rangeAndBearing)
    }

    public init(_ route: Route) {
        self.init(id: route.id, title: route.title, type: Route.type, location: .line(route.points.map(\.point)),
                  author: route.creator?.uid,
                  searchNames: route.points.filter(\.isWaypoint).compactMap(\.callsign))
    }
}
