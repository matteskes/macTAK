// FieldOfView.swift — what the map shows, for the Overlay Manager's field-of-
// view filter (G3.11a): "Show All" off keeps only the items on screen, as
// 5.5's FOVFilter does over a MapState.
//
// The view is its four corners on the ground (the screen's corners,
// MapSceneModel.inverse), so a rotated map is a turned quadrilateral, and
// its bounds are the corners' extremes.
//
// - a point is in view when it is inside the bounds and inside the
//   quadrilateral (contains, precise);
// - a line is in view when one of its points is inside the bounds, or,
//   when the line's bounds meet the view's, one of its points is inside
//   the quadrilateral or one of its segments crosses an edge
//   (Vector2D.segmentArraysIntersect). macTAK's lines (routes, R&B lines)
//   are open, so 5.5's closed-shape test (the view's centre inside the
//   shape) never applies.
//
// The map doesn't scroll across the antimeridian, so a view never crosses
// it (MapState's crossesIDL needs continuous scroll).

import Foundation

public struct FieldOfView: Sendable, Equatable {
    public var upperLeft, upperRight, lowerRight, lowerLeft: CotPoint

    public init(upperLeft: CotPoint, upperRight: CotPoint, lowerRight: CotPoint, lowerLeft: CotPoint) {
        self.upperLeft = upperLeft; self.upperRight = upperRight
        self.lowerRight = lowerRight; self.lowerLeft = lowerLeft
    }

    private var corners: [CotPoint] { [upperLeft, upperRight, lowerRight, lowerLeft] }
    private var north: Double { corners.map(\.lat).max()! }
    private var south: Double { corners.map(\.lat).min()! }
    private var east: Double { corners.map(\.lon).max()! }
    private var west: Double { corners.map(\.lon).min()! }

    /// FOVFilter.accept(MapItem).
    public func contains(_ location: OverlayItem.Location?) -> Bool {
        switch location {
        case .point(let p): contains(p)
        case .line(let points): meets(points)
        case nil: false
        }
    }

    /// MapState.contains(point, precise: true).
    public func contains(_ p: CotPoint) -> Bool {
        p.isValid && boundsContain(p) && Plane.polygon(corners.map(Plane.init), contains: Plane(p))
    }

    private func boundsContain(_ p: CotPoint) -> Bool {
        (south...north).contains(p.lat) && (west...east).contains(p.lon)
    }

    /// FOVFilter.accept(Shape) for an open line.
    private func meets(_ points: [CotPoint]) -> Bool {
        guard points.count >= 2 else { return false }
        if points.contains(where: boundsContain) { return true }
        let lats = points.map(\.lat), lons = points.map(\.lon)
        guard lats.min()! <= north, lats.max()! >= south, lons.min()! <= east, lons.max()! >= west else {
            return false
        }
        let quad = corners.map(Plane.init), line = points.map(Plane.init)
        if line.contains(where: { Plane.polygon(quad, contains: $0) }) { return true }
        return Plane.segments(line, cross: quad + [quad[0]])
    }
}

/// Vector2D's plane geometry over (lon, lat).
private struct Plane {
    var x, y: Double

    init(_ p: CotPoint) { x = p.lon; y = p.lat }

    /// Vector2D.polygonContainsPoint: an even-odd ray cast.
    static func polygon(_ polygon: [Plane], contains p: Plane) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Vector2D.segmentArraysIntersect: whether a segment of polyline `a`
    /// crosses one of polyline `b`.
    static func segments(_ a: [Plane], cross b: [Plane]) -> Bool {
        for (a0, a1) in zip(a, a.dropFirst()) {
            for (b0, b1) in zip(b, b.dropFirst()) where intersect(a0, a1, b0, b1) { return true }
        }
        return false
    }

    private static func intersect(_ p1: Plane, _ p2: Plane, _ q1: Plane, _ q2: Plane) -> Bool {
        func cross(_ o: Plane, _ a: Plane, _ b: Plane) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func within(_ o: Plane, _ a: Plane, _ p: Plane) -> Bool {
            min(o.x, a.x) <= p.x && p.x <= max(o.x, a.x) && min(o.y, a.y) <= p.y && p.y <= max(o.y, a.y)
        }
        let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2), d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
        if (d1 > 0) != (d2 > 0), d1 != 0, d2 != 0, (d3 > 0) != (d4 > 0), d3 != 0, d4 != 0 { return true }
        return d1 == 0 && within(q1, q2, p1) || d2 == 0 && within(q1, q2, p2)
            || d3 == 0 && within(p1, p2, q1) || d4 == 0 && within(p1, p2, q2)
    }
}
