// Routes.swift — the routes this client has (G3.10a), made here or heard,
// as ATAK 5.5's RouteMapReceiver keeps them:
//
// - a new route is "Route n" (Route.newTitle), made by this client now
//   (setAuthorInformation, as RouteCreationDialog does), archived; its ends
//   are made waypoints and its waypoints named (fixSPandVDO, which 5.5 runs
//   when a route is added to the map);
// - a b-m-r event adds a route or updates the one with its uid, whoever
//   made it (RouteImporter, RouteEvent.read); a route 5.5 refuses (fewer
//   than two points, a colour that isn't a number) changes nothing. Its
//   ends and names are put right as for a new one;
// - a delete task removes a route through MapItems.importDelete;
// - routes are kept across launches (Route sets archive): the
//   MapItemArchive stores them and gives them back through `restore`,
//   after the markers (5.5's query order puts b-m-r last), so a link to a
//   marker finds it.
//
// The map side is RouteGraphics (G3.10b), the route tool RouteEditor
// (G3.10c); this file holds what the routes are.

import Foundation
import MacTAKCot

@MainActor
public final class Routes: ObservableObject {
    @Published public private(set) var routes: [Route] = []
    private let newID: () -> String

    /// This client as a route's author, at the moment asked
    /// (setAuthorInformation); nil leaves routes made here without one.
    public var author: (() -> Author)?

    public init(newID: @escaping () -> String = { UUID().uuidString }) {
        self.newID = newID
    }

    public subscript(id: String) -> Route? { routes.first { $0.id == id } }

    /// A new route through `points`, as getNewRoute makes it with the
    /// waypoint prefix given (the waypointPrefix preference); its ends made
    /// waypoints and named.
    @discardableResult
    public func add(points: [RoutePoint], prefix: String = Route.defaultPrefix) -> Route {
        var route = Route(id: newID(), title: Route.newTitle(among: routes.map(\.title)), points: points,
                          prefix: prefix, creator: author?())
        route.fixEnds(newUID: newID)
        routes.append(route)
        return route
    }

    /// Replaces the route with `route`'s uid, its waypoints named again
    /// (5.5 renames them after every edit); returns whether it changed.
    @discardableResult
    public func update(_ route: Route) -> Bool {
        guard let i = routes.firstIndex(where: { $0.id == route.id }) else { return false }
        var route = route
        route.nameWaypoints()
        guard routes[i] != route else { return false }
        routes[i] = route
        return true
    }

    /// fixSPandVDO(true) on the route `id`, as the route tool does when it
    /// ends (RouteEditTool.onToolEnd): its ends made waypoints, its
    /// waypoints named.
    public func fixEnds(id: String) {
        guard let i = routes.firstIndex(where: { $0.id == id }) else { return }
        var route = routes[i]
        route.fixEnds(newUID: newID)
        if routes[i] != route { routes[i] = route }
    }

    /// Takes in a CoT event commo received: a b-m-r route is added or
    /// updated; anything else is ignored. `isItem` says whether a uid is a
    /// map item here. Returns whether the routes changed.
    @discardableResult
    public func receive(_ event: CotEvent, isItem: (String) -> Bool) -> Bool {
        take(event, isItem: isItem, received: true)
    }

    /// Takes back a route kept across launches. It is this client's own
    /// (not shown as received) when its creator is `selfUID`.
    public func restore(_ event: CotEvent, isItem: (String) -> Bool, selfUID: String) -> ImportResult {
        guard event.type == Route.type else { return .failure }
        let mine = Author(creator: event.detail("creator"), orTime: event.time)?.uid == selfUID
        take(event, isItem: isItem, received: !mine)
        return self[event.uid] != nil ? .success : .failure
    }

    @discardableResult
    private func take(_ event: CotEvent, isItem: (String) -> Bool, received: Bool) -> Bool {
        let existing = routes.firstIndex { $0.id == event.uid }
        let old = existing.map { routes[$0] }
        let titles = routes.map(\.title)
        guard var route = RouteEvent.read(event, onto: old, isItem: isItem, newUID: newID,
                                          newTitle: { Route.newTitle(among: titles) }) else { return false }
        route.received = old?.received ?? received
        route.fixEnds(newUID: newID)
        if let existing {
            guard routes[existing] != route else { return false }
            routes[existing] = route
        } else {
            routes.append(route)
        }
        return true
    }

    /// Removes the route `id`; returns whether it was here.
    @discardableResult
    public func remove(id: String) -> Bool {
        guard self[id] != nil else { return false }
        routes.removeAll { $0.id == id }
        return true
    }

    public func removeAll() {
        routes.removeAll()
    }
}
