// RouteEditor.swift — making and editing routes (G3.10c), what ATAK 5.5's
// RouteEditTool, the route menus (b-m-r, b-m-p-w, route_line_menu,
// route_corner_menu) and the route details (RoutePlannerView) do, for a
// Mac:
//
// - the route tool: a new route ("Route n", getNewRoute) or an existing
//   one is edited until the tool ends. A click on the map adds a point at
//   the end: the first a waypoint, the rest control points (MAP_CLICK);
//   an ⌥-click a waypoint (MAP_LONG_PRESS); a click on a marker, a
//   contact or another route's point a waypoint there (ITEM_CLICK on a
//   PointMapItem: a new waypoint at its point). A click on the route's
//   own point adds nothing (5.5 opens its menu);
// - while a route is edited its points drag to move (MovePointAction), and
//   its menus change it: a waypoint becomes a control point
//   (removeMarker), a control point a waypoint (insert_waypoint on a
//   corner: RouteExchangePointAction), a point goes
//   (remove_editable_polyline_vertex), a waypoint or a point goes into
//   the line where it was right-clicked (insert_waypoint and
//   insert_vertex on the line, after the segment hit);
// - Undo takes back the tool's last change, a drag at a time; the names
//   are put right after it (undo's fixSPandVDO(false));
// - when the tool ends a route with two points or more gets its ends
//   made waypoints and named (fixSPandVDO); one with fewer is removed;
// - the inspector (5.5's route details) shows one route and edits it:
//   any route, received ones too, as 5.5 lets their details change.
//   Delete removes it here (the app asks first, as RouteMapReceiver's
//   DELETE_ACTION does).
//
// Not here: 5.5's draw mode (a freehand segment), the route planners,
// navigation and its cues, dimming the other routes while one is edited.

import Foundation
import MacTAKCot

@MainActor
public final class RouteEditor: ObservableObject {
    /// The route the tool edits; nil while the tool is off.
    @Published public private(set) var editing: String?
    /// Whether the tool made the route it edits (5.5's _creatingRoute).
    @Published public private(set) var creating = false
    /// The route the inspector shows; nil while it is closed.
    @Published public private(set) var inspected: String?
    /// The edited route before each of the tool's changes, latest last.
    @Published public private(set) var history: [Route] = []

    private let routes: Routes
    private let locate: (MapPick) -> SourcedPoint?
    private let newID: () -> String
    /// The point a drag is moving: its first move is the undo step.
    private var dragging: String?

    /// `locate` says where a click is: the ground's place, or the clicked
    /// item's (marker, contact, self).
    public init(routes: Routes, locate: @escaping (MapPick) -> SourcedPoint?,
                newID: @escaping () -> String = { UUID().uuidString }) {
        self.routes = routes
        self.locate = locate
        self.newID = newID
    }

    // MARK: - the tool

    /// Starts the tool on a new route (the route toolbar's Create).
    public func begin() {
        end()
        let route = routes.add(points: [])
        editing = route.id
        creating = true
    }

    /// Starts the tool on the route `id` (edit_route).
    public func edit(_ id: String) {
        guard routes[id] != nil, editing != id else { return }
        end()
        editing = id
    }

    /// Ends the tool (onToolEnd).
    public func end() {
        guard let id = editing else { return }
        editing = nil
        creating = false
        history = []
        dragging = nil
        guard let route = routes[id] else { return }
        if route.points.count >= 2 {
            routes.fixEnds(id: id)
        } else {
            delete(id)
        }
    }

    public var canUndo: Bool { !history.isEmpty }

    /// Takes back the tool's last change.
    public func undo() {
        guard editing != nil, let before = history.popLast() else { return }
        dragging = nil
        routes.update(before)
    }

    /// The tool's prompt (5.5's routes_prompt and route_edit, for a
    /// mouse); nil while off.
    public var prompt: String? {
        guard let id = editing else { return nil }
        let title = routes[id]?.title ?? "the route"
        return creating
            ? "Click the map to add points to \(title); ⌥-click adds a checkpoint."
            : "Editing \(title): drag a point to move it, click the map to extend it, right-click the line to insert a point."
    }

    /// A click while the tool is on; returns whether it added a point.
    @discardableResult
    public func click(_ pick: MapPick, checkpoint: Bool = false) -> Bool {
        guard let id = editing, let route = routes[id] else { return false }
        var waypoint = checkpoint || route.points.isEmpty
        let place: CotPoint
        switch pick {
        case .item(let uid):
            if route.index(of: uid) != nil { return false }
            guard let p = point(of: uid) ?? locate(pick)?.point else { return false }
            place = p
            waypoint = true
        case .ground:
            guard let p = locate(pick)?.point else { return false }
            place = p
        }
        guard place.isValid else { return false }
        let point: RoutePoint = waypoint ? .waypoint(place, uid: newID()) : .controlPoint(place, uid: newID())
        return change(id) { $0.insert(point, at: $0.points.count) }
    }

    // MARK: - dragging

    /// Whether `uid` drags: a waypoint or control point of the edited route.
    public func canDrag(_ uid: String) -> Bool {
        guard let route = editing.flatMap({ routes[$0] }), let i = route.index(of: uid) else { return false }
        return route.points[i].isWaypoint || route.points[i].isControlPoint
    }

    /// A press that starts a drag of `uid`.
    public func beginDrag(_ uid: String) { dragging = nil }

    /// The dragged point over the ground at `pick`.
    @discardableResult
    public func drag(_ uid: String, to pick: MapPick) -> Bool {
        guard canDrag(uid), let id = editing, let i = routes[id]?.index(of: uid),
              let p = locate(pick)?.point, p.isValid else { return false }
        let first = dragging != uid
        dragging = uid
        return change(id, undoable: first) { $0.movePoint(at: i, to: p) }
    }

    // MARK: - the menus

    /// The route that has the waypoint or control point `uid`.
    public func route(withPoint uid: String) -> Route? {
        routes.routes.first { r in r.points.contains { $0.uid == uid && ($0.isWaypoint || $0.isControlPoint) } }
    }

    /// Whether `uid` is a point of the route the tool edits.
    public func isEditedPoint(_ uid: String) -> Bool {
        editing.flatMap { routes[$0]?.index(of: uid) } != nil
    }

    /// A waypoint of the edited route becomes a control point.
    public func makeControlPoint(_ uid: String) {
        editPoint(uid) { route, i in route.makeControlPoint(at: i, uid: newID()) }
    }

    /// A control point of the edited route becomes a waypoint.
    public func makeWaypoint(_ uid: String) {
        editPoint(uid) { route, i in route.makeWaypoint(at: i, uid: newID()) }
    }

    /// A point of the edited route goes, and its place in the line.
    public func deletePoint(_ uid: String) {
        editPoint(uid) { route, i in route.removePoint(at: i) }
    }

    /// A new waypoint or control point in the edited route's line where it
    /// was right-clicked, after the segment hit.
    public func insert(_ hit: RouteHit, waypoint: Bool) {
        guard hit.route == editing, hit.point.isValid else { return }
        let point: RoutePoint = waypoint ? .waypoint(hit.point, uid: newID()) : .controlPoint(hit.point, uid: newID())
        change(hit.route) { $0.insert(point, at: hit.segment + 1) }
    }

    private func editPoint(_ uid: String, _ edit: (inout Route, Int) -> Void) {
        guard let id = editing, let i = routes[id]?.index(of: uid) else { return }
        change(id) { edit(&$0, i) }
    }

    // MARK: - the inspector

    /// Shows the route `id` in the inspector; nil closes it.
    public func inspect(_ id: String?) {
        inspected = id.flatMap { routes[$0] != nil ? $0 : nil }
    }

    /// Changes the route `id` (the inspector's fields): an undo step when
    /// the tool edits it. Returns whether it changed.
    @discardableResult
    public func update(_ id: String, _ edit: (inout Route) -> Void) -> Bool {
        change(id, undoable: editing == id, edit)
    }

    /// label_toggle: the route's title on its line, or not.
    public func toggleLabels(_ id: String) {
        update(id) { $0.labelsOn.toggle() }
    }

    /// Removes the route `id` here; the tool and the inspector let it go.
    public func delete(_ id: String) {
        if editing == id {
            editing = nil
            creating = false
            history = []
        }
        if inspected == id { inspected = nil }
        routes.remove(id: id)
    }

    @discardableResult
    private func change(_ id: String, undoable: Bool = true, _ edit: (inout Route) -> Void) -> Bool {
        guard let before = routes[id] else { return false }
        var route = before
        edit(&route)
        guard routes.update(route) else { return false }
        if undoable && editing == id { history.append(before) }
        return true
    }

    /// Where `uid` is when it is a waypoint or control point of a route.
    public func point(of uid: String) -> CotPoint? {
        route(withPoint: uid).flatMap { r in r.points.first { $0.uid == uid }?.point }
    }
}
