// FieldOfView.swift — what the map shows, for the Overlay Manager's field-of-
// view filter (G3.11a): "Show All" off keeps only the items on screen, as
// 5.5's FOVFilter does over a MapState.
//
// The view is MapState as the map view builds it: the screen's corners on
// the ground (MapSceneModel.inverse, longitudes unwrapped: past ±180 when
// the view runs over the antimeridian) and its centre.
//
// - its bounds: the corners' extremes. With continuous scroll on
//   (atakContinuousScrollEnabled, 5.5's default) a view running over the
//   antimeridian is two boxes, one each side, and its corners are unwrapped
//   into the centre's hemisphere (pointUnwrap);
// - a point is in view when it is in the bounds and in the corners'
//   quadrilateral (contains, precise);
// - a line is in view when one of its points is in the bounds; else, when
//   the line's bounds (GeoBounds.createFromPoints, wrapped over the
//   antimeridian with continuous scroll) meet the view's, when one of its
//   points, unwrapped to the view's side (GLAntiMeridianHelper.getUnwrap),
//   is in the quadrilateral or one of its segments crosses an edge
//   (Vector2D.segmentArraysIntersect). macTAK's lines (routes, R&B lines)
//   are open, so 5.5's closed-shape test never applies.

import Foundation

public struct FieldOfView: Sendable, Equatable {
    private let north, south: Double
    private let eastUnwrapped, westUnwrapped: Double
    private let continuousScroll: Bool
    /// One box, or the two either side of the antimeridian.
    private let boxes: [GeoBox]
    /// The corners, closed, unwrapped into the centre's hemisphere.
    private let quad: [Plane]
    private let pointUnwrap: Double

    /// MapState(mapView): the screen's corners on the ground, its centre,
    /// and whether the map scrolls continuously.
    public init(upperLeft: CotPoint, upperRight: CotPoint, lowerRight: CotPoint, lowerLeft: CotPoint,
                center: CotPoint, continuousScroll: Bool = true) {
        let corners = [upperLeft, upperRight, lowerRight, lowerLeft]
        north = corners.map(\.lat).max()!
        south = corners.map(\.lat).min()!
        eastUnwrapped = corners.map(\.lon).max()!
        westUnwrapped = corners.map(\.lon).min()!
        self.continuousScroll = continuousScroll
        let crossesIDL = continuousScroll
            && (eastUnwrapped > 180 && westUnwrapped < 180 || westUnwrapped < -180 && eastUnwrapped > -180)
        let east = Self.wrap(eastUnwrapped), west = Self.wrap(westUnwrapped)
        let unwrap: Double
        if crossesIDL {
            boxes = [GeoBox(north, max(east, west), south, 180), GeoBox(north, -180, south, min(east, west))]
            unwrap = center.lon < 0 ? -360 : 360
        } else {
            boxes = [GeoBox(north, west, south, east)]
            unwrap = 0
        }
        pointUnwrap = unwrap
        quad = (corners + [upperLeft]).map { Plane($0, unwrap: unwrap) }
    }

    /// GeoCalculations.wrapLongitude.
    private static func wrap(_ lon: Double) -> Double { lon < -180 ? lon + 360 : lon > 180 ? lon - 360 : lon }

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
        p.isValid && boundsContain(p) && Plane.polygon(quad, contains: Plane(p, unwrap: pointUnwrap))
    }

    private func boundsContain(_ p: CotPoint) -> Bool { boxes.contains { $0.contains(p) } }

    /// FOVFilter.accept(Shape) for an open line.
    private func meets(_ points: [CotPoint]) -> Bool {
        guard points.count >= 2 else { return false }
        if points.contains(where: boundsContain) { return true }
        let bounds = GeoBox(points: points, wrap180: continuousScroll)
        guard boxes.contains(where: { $0.intersects(bounds) }) else { return false }
        let unwrap = continuousScroll ? bounds.unwrap(east: eastUnwrapped, west: westUnwrapped) : 0
        let line = points.map { Plane($0, unwrap: unwrap) }
        if line.contains(where: { Plane.polygon(quad, contains: $0) }) { return true }
        return Plane.segments(line, cross: quad)
    }
}

/// The kernel's GeoBounds, as far as the filter uses it (no altitudes:
/// MapState's bounds have none).
private struct GeoBox: Equatable {
    var south, west, north, east: Double
    var wrap180 = false

    /// GeoBounds(lat0, lng0, lat1, lng1): the extremes of two corners.
    init(_ lat0: Double, _ lng0: Double, _ lat1: Double, _ lng1: Double) {
        south = min(lat0, lat1); north = max(lat0, lat1)
        west = min(lng0, lng1); east = max(lng0, lng1)
    }

    /// GeoBounds.createFromPoints (MutableGeoBounds.set), the kernel's
    /// loop as it is: a point raising the north isn't tried for the south.
    init(points: [CotPoint], wrap180: Bool) {
        let crosses = wrap180 && Self.crossesIDL(points)
        var n = 0.0, s = 0.0, e = 0.0, w = 0.0
        for (i, p) in points.enumerated() {
            var lng = p.lon
            if crosses { lng += lng > 0 ? -360 : lng < 0 ? 360 : 0 }
            if i == 0 {
                n = p.lat; s = p.lat; e = lng; w = lng
            } else {
                if p.lat > n { n = p.lat } else if p.lat < s { s = p.lat }
                if lng > e { e = lng } else if lng < w { w = lng }
            }
        }
        if e > 180 || crosses && e == 180 { e -= 360 }
        if w < -180 || crosses && w == -180 { w += 360 }
        self.init(s, min(e, w), n, max(e, w))
        self.wrap180 = wrap180
    }

    /// GeoCalculations.crossesIDL.
    private static func crossesIDL(_ points: [CotPoint]) -> Bool {
        let lons = points.map(\.lon)
        guard let lo = lons.min(), let hi = lons.max() else { return false }
        return lo < -180 || hi > 180 || hi - lo > 180
    }

    var crossesIDL: Bool { wrap180 && abs(east - west) > 180 }

    func contains(_ p: CotPoint) -> Bool {
        guard p.lat >= south, p.lat <= north else { return false }
        if crossesIDL { return p.lon >= east && p.lon <= west + 360 || p.lon >= east - 360 && p.lon <= west }
        return p.lon >= west && p.lon <= east
    }

    func intersects(_ b: GeoBox) -> Bool {
        if north < b.south || south > b.north { return false }
        let bCross = b.wrap180 && abs(b.east - b.west) > 180
        if crossesIDL { return bCross || !(b.west > west && b.east < east) }
        if bCross { return !(west > b.west && east < b.east) }
        return !(east < b.west || west > b.east)
    }

    /// GLAntiMeridianHelper.getUnwrap: how far to shift this shape's
    /// longitudes onto the view's side.
    func unwrap(east eastUnwrapped: Double, west westUnwrapped: Double) -> Double {
        let wrap = crossesIDL || eastUnwrapped > 180 && west + 360 <= eastUnwrapped
            || westUnwrapped < -180 && east - 360 >= westUnwrapped
        guard wrap else { return 0 }
        if crossesIDL {
            if westUnwrapped < -180 { return -360 }
            if eastUnwrapped > 180 { return 360 }
            if westUnwrapped <= west { return -360 }
            if eastUnwrapped >= east { return 360 }
            return (eastUnwrapped + westUnwrapped) / 2 < 0 ? -360 : 360
        }
        if westUnwrapped < -180 && west > 0 { return -360 }
        if eastUnwrapped > 180 && east < 0 { return 360 }
        return 0
    }
}

/// Vector2D's plane geometry over (lon, lat).
private struct Plane: Equatable {
    var x, y: Double

    /// FOVFilter.geo2Vector: a longitude on the other side of 0 from the
    /// unwrap moves by it.
    init(_ p: CotPoint, unwrap: Double) {
        x = unwrap > 0 && p.lon < 0 || unwrap < 0 && p.lon > 0 ? p.lon + unwrap : p.lon
        y = p.lat
    }

    /// Vector2D.polygonContainsPoint.
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

    /// Vector2D.segmentArraysIntersect: parallel segments never meet.
    static func segments(_ a: [Plane], cross b: [Plane]) -> Bool {
        func cross(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double { ux * vy - uy * vx }
        for i in 0..<max(a.count - 1, 0) {
            for j in 0..<max(b.count - 1, 0) {
                let s0 = (b[j].x - b[j + 1].x, b[j].y - b[j + 1].y)
                let s1 = (a[i + 1].x - a[i].x, a[i + 1].y - a[i].y)
                let c1 = cross(s1.0, s1.1, s0.0, s0.1)
                guard c1 != 0 else { continue }
                let s2 = (b[j + 1].x - a[i].x, b[j + 1].y - a[i].y)
                let t = cross(s2.0, s2.1, s0.0, s0.1) / c1
                let u = cross(s2.0, s2.1, s1.0, s1.1) / c1
                if t >= 0, t <= 1, u >= 0, u <= 1 { return true }
            }
        }
        return false
    }
}
