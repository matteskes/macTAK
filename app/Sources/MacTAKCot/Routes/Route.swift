// Route.swift — a route as ATAK 5.5 holds it (G3.10a): Route, the
// EditablePolyline it extends, and the markers on it.
//
// - A route is points in order. Each is a marker 5.5 links by uid: a
//   waypoint (b-m-p-w, named), a control point (b-m-p-c, a shape point
//   with no name), or another map item a route runs through (its own
//   type). A route is never closed.
// - Its line: a colour (Android's signed int, white by default), a stroke
//   weight (3) and a basic line style (0, solid).
// - What 5.5's route details set: the method (Driving), direction (Infil),
//   type (Primary), order (Ascending Check Points), the planning method
//   ("Infil", a free string) and the waypoint prefix (the waypointPrefix
//   preference, "CP"). The transport type is a free string too; setting
//   the method sets it ("On Foot" for Walking and Swimming, else
//   "Vehicle", setRouteMethod).
//
// Naming, as Route does it:
//
// - a new route is "Route n": n one more than the routes there are, and up
//   until no route has the name (RouteMapReceiver.getNewRoute);
// - the first waypoint is the title and SP (Infil) or, for Exfil, VPU
//   when driving and TGT otherwise (getFirstWaypointName); the last is VDO
//   when driving and TGT otherwise (Infil), or EP (Exfil)
//   (getLastWaypointName); the ones between are the prefix and a number,
//   1 up (Ascending) or down to 1 (Descending)
//   (validateWaypointNamesNoSync);
// - a name is only changed while it is automatic: none, an end's name
//   (alone or after a space), or the prefix and digits (isAutomaticName).
//   A name the user gave stays, and still takes its number;
// - `fixEnds` is fixSPandVDO(true): an end that isn't a waypoint becomes a
//   new one in its place, then the names are put right.

import Foundation

public struct RoutePoint: Sendable, Equatable {
    /// The marker's uid (5.5 links the point by it).
    public var uid: String
    /// b-m-p-w, b-m-p-c, or the type of the map item it is.
    public var type: String
    public var point: CotPoint
    /// The marker's callsign meta; nil until it is named.
    public var callsign: String?
    /// The marker's remarks meta.
    public var remarks: String?

    public init(uid: String, type: String, point: CotPoint, callsign: String? = nil, remarks: String? = nil) {
        self.uid = uid; self.type = type; self.point = point; self.callsign = callsign; self.remarks = remarks
    }

    public var isWaypoint: Bool { type == Route.waypointType }
    public var isControlPoint: Bool { type == Route.controlPointType }

    public static func waypoint(_ point: CotPoint, uid: String, callsign: String? = nil) -> RoutePoint {
        RoutePoint(uid: uid, type: Route.waypointType, point: point, callsign: callsign)
    }

    public static func controlPoint(_ point: CotPoint, uid: String) -> RoutePoint {
        RoutePoint(uid: uid, type: Route.controlPointType, point: point)
    }
}

public struct Route: Sendable, Equatable, Identifiable {
    public static let type = "b-m-r"
    public static let waypointType = "b-m-p-w"
    public static let controlPointType = "b-m-p-c"
    /// DEFAULT_ROUTE_COLOR, Color.WHITE.
    public static let white: Int32 = -1
    /// DEFAULT_STROKE_WEIGHT.
    public static let defaultStrokeWeight = 3.0
    /// The waypointPrefix preference's default.
    public static let defaultPrefix = "CP"
    /// routes_text33 and routes_text34.
    public static let vehicle = "Vehicle", onFoot = "On Foot"
    /// The planning method a new route gets.
    public static let defaultPlanningMethod = "Infil"

    public enum Method: String, CaseIterable, Sendable {
        case driving = "Driving", walking = "Walking", flying = "Flying", swimming = "Swimming",
             watercraft = "Watercraft"
    }

    public enum Direction: String, CaseIterable, Sendable {
        case infil = "Infil", exfil = "Exfil"
    }

    public enum Kind: String, CaseIterable, Sendable {
        case primary = "Primary", secondary = "Secondary", tertiary = "Tertiary"
    }

    public enum Order: String, CaseIterable, Sendable {
        case ascending = "Ascending Check Points", descending = "Descending Check Points"

        /// setRouteOrder takes the text or the enum's name.
        public init?(named text: String) {
            switch text {
            case Self.ascending.rawValue, "Ascending": self = .ascending
            case Self.descending.rawValue, "Descending": self = .descending
            default: return nil
            }
        }
    }

    public let id: String
    public var title: String
    public var points: [RoutePoint]
    public var color: Int32
    public var strokeWeight: Double
    /// The basic line style: 0 solid, 1 dashed, 2 dotted, 3 outlined.
    public var strokeStyle: Int
    public var transportType: String
    public private(set) var method: Method
    public var direction: Direction
    public var kind: Kind
    public var order: Order
    public var planningMethod: String?
    public var prefix: String
    /// The route's own remarks meta.
    public var remarks: String?
    /// The labels_on meta (LabelDetailHandler): off for a new route.
    public var labelsOn = false
    /// Who made it and when (setAuthorInformation), or a received route's <creator>.
    public var creator: Author?
    /// Kept across launches: every route is (Route sets archive).
    public var archived: Bool
    /// Heard from another client, not made here.
    public var received: Bool

    public init(id: String, title: String, points: [RoutePoint] = [], color: Int32 = white,
                strokeWeight: Double = defaultStrokeWeight, strokeStyle: Int = 0, method: Method = .driving,
                direction: Direction = .infil, kind: Kind = .primary, order: Order = .ascending,
                planningMethod: String? = defaultPlanningMethod, prefix: String = defaultPrefix,
                remarks: String? = nil, creator: Author? = nil, archived: Bool = true, received: Bool = false) {
        self.id = id; self.title = title; self.points = points; self.color = color
        self.strokeWeight = strokeWeight; self.strokeStyle = strokeStyle
        self.method = method; self.transportType = Self.transportType(for: method)
        self.direction = direction; self.kind = kind; self.order = order
        self.planningMethod = planningMethod; self.prefix = prefix; self.remarks = remarks
        self.creator = creator; self.archived = archived; self.received = received
    }

    /// setRouteMethod: the method, and the transport type it implies.
    public mutating func setMethod(_ method: Method) {
        self.method = method
        transportType = Self.transportType(for: method)
    }

    static func transportType(for method: Method) -> String {
        method == .walking || method == .swimming ? onFoot : vehicle
    }

    /// "Route n" for a new route among `titles` (getNewRoute).
    public static func newTitle(among titles: [String]) -> String {
        let taken = Set(titles)
        var n = titles.count + 1
        while taken.contains("Route \(n)") { n += 1 }
        return "Route \(n)"
    }

    // MARK: - naming

    /// getFirstWaypointName.
    public var firstWaypointName: String {
        let end = switch (direction, method) {
        case (.infil, _): "SP"
        case (.exfil, .driving): "VPU"
        case (.exfil, _): "TGT"
        }
        return title + " " + end
    }

    /// getLastWaypointName.
    public var lastWaypointName: String {
        switch (direction, method) {
        case (.infil, .driving): "VDO"
        case (.infil, _): "TGT"
        case (.exfil, _): "EP"
        }
    }

    private static let endNames = ["VDO", "EP", "TGT", "VPU", "SP"]

    /// isAutomaticName: a name the naming may change.
    public func isAutomaticName(_ name: String?) -> Bool {
        guard let name else { return true }
        if Self.endNames.contains(where: { name == $0 || name.hasSuffix(" " + $0) }) { return true }
        guard name.hasPrefix(prefix) else { return false }
        // Character.isDigit: Unicode's decimal digits
        return name.dropFirst(prefix.count).unicodeScalars.allSatisfy { $0.properties.generalCategory == .decimalNumber }
    }

    /// validateWaypointNamesNoSync: each waypoint with an automatic name
    /// gets the one its place among the waypoints gives. Returns whether
    /// any changed.
    @discardableResult
    public mutating func nameWaypoints() -> Bool {
        var seen = Set<String>()
        let waypoints = points.indices.filter { points[$0].isWaypoint && seen.insert(points[$0].uid).inserted }
        let count = waypoints.count
        var number = order == .ascending ? 1 : count - 2
        let step = order == .ascending ? 1 : -1
        var changed = false
        for (k, i) in waypoints.enumerated() {
            let name: String
            if k == 0 {
                name = firstWaypointName
            } else if k == count - 1 {
                name = lastWaypointName
            } else {
                name = prefix + String(number)
                number += step
            }
            guard isAutomaticName(points[i].callsign), points[i].callsign != name else { continue }
            for j in points.indices where points[j].uid == points[i].uid { points[j].callsign = name }
            changed = true
        }
        return changed
    }

    /// fixSPandVDO(true): the ends made waypoints, then the waypoints
    /// named. `newUID` makes a new waypoint's uid.
    public mutating func fixEnds(newUID: () -> String = { UUID().uuidString }) {
        guard points.count >= 2 else { return }
        for i in [points.startIndex, points.endIndex - 1] where !points[i].isWaypoint {
            points[i] = .waypoint(points[i].point, uid: newUID())
        }
        nameWaypoints()
    }

    // MARK: - the line

    /// Where the route's centre is (EditablePolyline.getCenter: the
    /// kernel's GeoCalculations.computeAverage of its points, across the
    /// antimeridian when they cross it); nil with no points.
    public var center: CotPoint? {
        guard let first = points.first else { return nil }
        let lons = points.map(\.point.lon)
        let crosses = (lons.min()! < -180 || lons.max()! > 180) || lons.max()! - lons.min()! > 180
        let east = first.point.lon >= 0
        var lat = 0.0, lon = 0.0
        let share = 1.0 / Double(points.count)
        for p in points {
            var l = p.point.lon
            if crosses { l = east ? (l < 0 ? l + 360 : l) : (l > 0 ? l - 360 : l) }
            lat += p.point.lat * share
            lon += l * share
        }
        if crosses { lon = lon > 180 ? lon - 360 : (lon < -180 ? lon + 360 : lon) }
        return CotPoint(lat: lat, lon: lon)
    }
}

// MARK: - editing (G3.10c)

extension Route {
    /// The index of the point with `uid`, nil if none.
    public func index(of uid: String) -> Int? { points.firstIndex { $0.uid == uid } }

    /// InsertPointAction: `point` at `index` (clamped to the ends), the
    /// waypoints named again.
    public mutating func insert(_ point: RoutePoint, at index: Int) {
        points.insert(point, at: min(max(index, 0), points.count))
        nameWaypoints()
    }

    /// RouteRemovePointAction: the point and its place in the line go.
    public mutating func removePoint(at index: Int) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
        nameWaypoints()
    }

    /// removeMarker(index): a waypoint stops being one; a control point
    /// (createControlPoint, a new uid) keeps its place in the line.
    public mutating func makeControlPoint(at index: Int, uid: String) {
        guard points.indices.contains(index), points[index].isWaypoint else { return }
        points[index] = .controlPoint(points[index].point, uid: uid)
        nameWaypoints()
    }

    /// RouteExchangePointAction with createWayPoint: the point becomes a
    /// new waypoint (`uid`) where it is.
    public mutating func makeWaypoint(at index: Int, uid: String) {
        guard points.indices.contains(index), !points[index].isWaypoint else { return }
        points[index] = .waypoint(points[index].point, uid: uid)
        nameWaypoints()
    }

    /// MovePointAction: the point at `index` goes to `point`.
    public mutating func movePoint(at index: Int, to point: CotPoint) {
        guard points.indices.contains(index) else { return }
        points[index].point = point
    }

    /// RouteSetPointName: the waypoint `uid` is named `name` (a name the
    /// user gives isn't automatic, so it stays).
    public mutating func renamePoint(_ uid: String, to name: String) {
        guard let i = index(of: uid), points[i].isWaypoint else { return }
        for j in points.indices where points[j].uid == uid { points[j].callsign = name }
        nameWaypoints()
    }

    /// RouteCreationDialog's direction: Infil sets Ascending check points,
    /// Exfil Descending; the names follow.
    public mutating func setDirection(_ direction: Direction) {
        self.direction = direction
        order = direction == .infil ? .ascending : .descending
        nameWaypoints()
    }
}
