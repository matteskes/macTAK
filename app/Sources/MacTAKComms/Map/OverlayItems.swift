// OverlayItems.swift — the map's items as the Overlay Manager sees them
// (G3.11a): a contact, a CoT marker, an R&B line and a route, each as
// 5.5's MapItem would carry it into the filter overlays (OverlayItem).
//
// - a contact: its callsign, type and point, and its <__group>'s team and
//   role; its SA names no author.
// - a CoT marker: its label, type and point, its <__group>, its iconset
//   path, and its author from its event's <link> and <creator>.
// - an R&B line: "u-rb-a", its title, its two ends where they are now
//   (RangeBearingLines.ends), its <creator>, in the Range & Bearing group;
//   and each end fixed on the ground, which 5.5 makes a marker of its own
//   in that group (RangeAndBearingEndpoint, titled "<line> Endpoint" by
//   RangeAndBearingMapItem.setTitle; addToObjList left on, so listed).
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

    /// `line` with its ends where they are now, as
    /// RangeBearingLines.ends(markers:) gives them: an end whose marker has
    /// gone stays where the marker was last seen (5.5's removePoint).
    public init(_ line: RangeBearingLine, start: CotPoint, end: CotPoint) {
        self.init(id: line.id, title: line.title, type: RangeBearingEvent.type, location: .line([start, end]),
                  author: line.creator?.uid, group: .rangeAndBearing)
    }

    /// RangeAndBearingEndpoint's type.
    public static let rangeAndBearingEndpointType = "u-r-b-endpoint"

    /// What `line` puts in the Range & Bearing group, as 5.5's list shows
    /// it: the line, and for each end fixed on the ground (not tied to a
    /// marker) its endpoint marker, "<title> Endpoint", with no author.
    public static func rangeAndBearing(_ line: RangeBearingLine, start: CotPoint, end: CotPoint) -> [OverlayItem] {
        var items = [OverlayItem(line, start: start, end: end)]
        for (name, end, point) in [("start", line.start, start), ("end", line.end, end)] {
            guard case .point = end else { continue }
            items.append(OverlayItem(id: line.id + "." + name, title: line.title + " Endpoint",
                                     type: rangeAndBearingEndpointType, location: .point(point),
                                     group: .rangeAndBearing))
        }
        return items
    }

    public init(_ route: Route) {
        self.init(id: route.id, title: route.title, type: Route.type, location: .line(route.points.map(\.point)),
                  author: route.creator?.uid,
                  searchNames: route.points.filter(\.isWaypoint).compactMap(\.callsign))
    }
}
