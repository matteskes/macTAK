// RouteGraphics.swift — what a route draws on the map (G3.10b), as ATAK
// 5.5 draws a Route:
//
// - one line through all its points, in order (GLPolyline over the
//   EditablePolyline): the route's colour, its stroke weight as the width,
//   its basic line style (solid, dashed, dotted, outlined), never closed.
//   A point that is another map item (a marker the route runs through) is
//   where that item is now: 5.5's route holds the marker itself, so the
//   line follows it. Fewer than two points draw no line;
// - the line's label is the route's title (EditablePolyline.setTitle sets
//   the line label), drawn only while labels are on (GLPolyline
//   validateLabels: labels_on), which a new route has off;
// - each waypoint is a marker: b-m-p-w's icon (icon_filters.xml:
//   gugpgpow, the waypoint symbol) tinted with the route's colour (Route
//   sets the waypoint's "color" meta to it), labelled with its name;
// - control points draw nothing (ControlPointMapItem is setVisible(false));
// - nothing else: 5.5 draws no leg distances on the map. They are the
//   route details' waypoint list (Route.getRouteDetails), G3.10c's
//   inspector.

import MacTAKCot

public struct RouteGraphics: Equatable, Sendable {
    /// 5.5's basic line styles (Shape.BASIC_LINE_STYLE_*), a route's
    /// strokeStyle.
    public enum LineStyle: Int, Sendable {
        case solid, dashed, dotted, outlined
    }

    public struct Line: Equatable, Sendable {
        public var uid: String
        public var points: [CotPoint]
        /// ARGB.
        public var color: UInt32
        public var width: Float
        public var style: LineStyle
        public var label: String?
    }

    public struct Waypoint: Equatable, Sendable {
        public var uid: String
        public var point: CotPoint
        public var icon: MarkerIcon
        public var label: String?
    }

    public var line: Line?
    public var waypoints: [Waypoint]

    /// The map uid of a route's line, apart from every marker's.
    public static func lineUID(_ routeID: String) -> String { "mactak-route-" + routeID }

    /// What `route` draws. `places` gives where a map item the route runs
    /// through is now, by uid (nil: where the route last had it).
    public init(_ route: Route, places: (String) -> CotPoint? = { _ in nil }) {
        let color = UInt32(bitPattern: route.color)
        let points = route.points.map { p in
            p.isWaypoint || p.isControlPoint ? p.point : places(p.uid) ?? p.point
        }
        line = points.count < 2 ? nil : Line(
            uid: Self.lineUID(route.id), points: points, color: color, width: Float(route.strokeWeight),
            style: LineStyle(rawValue: route.strokeStyle) ?? .solid,
            label: route.labelsOn && !route.title.isEmpty ? route.title : nil)
        let icon = MarkerIcons.icon(MarkerTraits(type: Route.waypointType, how: Self.waypointHow, color: color),
                                    stale: false) { _ in nil }
        waypoints = route.points.filter(\.isWaypoint).map {
            Waypoint(uid: $0.uid, point: $0.point, icon: icon, label: $0.callsign.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Route.createWayPoint: a waypoint is placed by hand.
    static let waypointHow = "h-g-i-g-o"
}
