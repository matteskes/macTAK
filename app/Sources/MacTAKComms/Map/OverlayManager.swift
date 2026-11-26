// OverlayManager.swift — what the Overlay Manager's rows do to the map's
// items (G3.11b), as 5.5's hierarchy actions do them:
//
// - the items it lists (OverlayItems): the contacts, the CoT markers, the
//   R&B lines where the map last drew them with their ground endpoints,
//   and the routes;
// - Visibility (MapItemHierarchyListItem.setVisible): an item is shown or
//   hidden only when that changes it. A route that changes shows or hides
//   its points with it, the markers it runs through too
//   (EditablePolyline.onVisibleChanged). A list shows or hides each of its
//   rows (AbstractHierarchyListItem2.setVisible), and is shown when all
//   its rows are, partly when some are, hidden when none are (or it has
//   none: getVisibility);
// - Delete (HierarchyListUserDelete): each item, a list's every row. A
//   contact or a CoT marker leaves the map here (removeFromGroup), an R&B
//   line or a route is deleted; an R&B endpoint leaves the list and its
//   line keeps the end where it was (an endpoint has no remove listener in
//   RangeAndBearingMapItem);
// - GoTo's point (MapItemHierarchyListItem.getPoint): a line's end (an
//   Arrow's point 2), a route's centre, a marker's point.
//
// An item that leaves the map takes its visibility with it (MapVisibility).

import Combine
import Foundation
import MacTAKCot

@MainActor
public final class OverlayManager: ObservableObject {
    /// Visibility2's three states.
    public enum Visibility: Sendable, Equatable { case visible, partial, hidden }

    public let visibility: MapVisibility
    private let contacts: ContactStore
    private let markers: CotMarkerStore
    private let rangeBearing: RangeBearingLines
    private let routes: Routes
    private let routeEditor: RouteEditor
    private let pointEditor: PointEditor
    /// The R&B endpoints deleted from the list, by item id.
    @Published public private(set) var removedEndpoints: Set<String> = []
    private var watches: [AnyCancellable] = []
    private var prunePending = false

    public init(contacts: ContactStore, markers: CotMarkerStore, rangeBearing: RangeBearingLines, routes: Routes,
                routeEditor: RouteEditor, pointEditor: PointEditor, visibility: MapVisibility) {
        self.contacts = contacts
        self.markers = markers
        self.rangeBearing = rangeBearing
        self.routes = routes
        self.routeEditor = routeEditor
        self.pointEditor = pointEditor
        self.visibility = visibility
        watches = [contacts.objectWillChange, markers.objectWillChange, rangeBearing.objectWillChange,
                   routes.objectWillChange].map { $0.sink { [weak self] _ in self?.schedulePrune() } }
    }

    // MARK: - the items

    /// Every item the Overlay Manager lists, as it is now.
    public func items() -> [OverlayItem] {
        let lines = rangeBearing.lines.flatMap { line -> [OverlayItem] in
            guard let ends = rangeBearing.placed[line.id] else { return [] }
            return OverlayItem.rangeAndBearing(line, start: ends.start, end: ends.end)
                .filter { !removedEndpoints.contains($0.id) }
        }
        return contacts.contacts.map(OverlayItem.init) + markers.markers.map(OverlayItem.init) + lines
            + routes.routes.map(OverlayItem.init)
    }

    /// Where GoTo takes the map for `item`.
    public func location(of item: OverlayItem) -> CotPoint? {
        switch item.location {
        case .point(let p): p
        case .line(let points) where item.type == RangeBearingEvent.type: points.last
        case .line: routes[item.id]?.center ?? item.center
        case nil: nil
        }
    }

    // MARK: - visibility

    public func visibility(of node: OverlayTree.Node) -> Visibility {
        guard let children = node.children else { return visibility.isVisible(node.uid) ? .visible : .hidden }
        var partial = false, all = true
        for child in children {
            let state = visibility(of: child)
            partial = partial || state != .hidden
            all = all && state == .visible
        }
        return partial && all ? .visible : partial ? .partial : .hidden
    }

    public func isVisible(_ node: OverlayTree.Node) -> Bool { visibility(of: node) != .hidden }

    public func setVisible(_ node: OverlayTree.Node, _ visible: Bool) {
        if let children = node.children {
            for child in children { setVisible(child, visible) }
            return
        }
        guard visibility.isVisible(node.uid) != visible else { return }
        visibility.set(node.uid, visible: visible)
        if let route = routes[node.uid] {
            visibility.set(route.points.map(\.uid), visible: visible)
        }
    }

    // MARK: - delete

    /// Deletes each item, and every row of each list.
    public func delete(_ nodes: [OverlayTree.Node]) {
        for node in nodes {
            if let children = node.children { delete(children) } else if let item = node.item { delete(item) }
        }
    }

    private func delete(_ item: OverlayItem) {
        switch item.type {
        case OverlayItem.rangeAndBearingEndpointType: removedEndpoints.insert(item.id)
        case RangeBearingEvent.type: rangeBearing.remove(id: item.id)
        case Route.type where routes[item.id] != nil: routeEditor.delete(item.id)
        default:
            if markers[item.id] != nil { pointEditor.delete(item.id) } else { contacts.remove(item.id) }
        }
    }

    // MARK: - forgetting what left

    private func schedulePrune() {
        guard !prunePending else { return }
        prunePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.prunePending = false
                self?.prune()
            }
        }
    }

    /// Forgets the visibility of what left the map, and the deleted
    /// endpoints of lines that are gone.
    func prune() {
        var present = Set(contacts.contacts.map(\.uid))
        present.formUnion(markers.markers.map(\.uid))
        for line in rangeBearing.lines {
            present.formUnion([line.id, line.id + ".start", line.id + ".end"])
        }
        for route in routes.routes {
            present.insert(route.id)
            present.formUnion(route.points.map(\.uid))
        }
        visibility.keepOnly(present)
        let endpoints = removedEndpoints.intersection(present)
        if endpoints != removedEndpoints { removedEndpoints = endpoints }
    }
}
