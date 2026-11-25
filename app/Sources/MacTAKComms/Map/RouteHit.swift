// RouteHit.swift — which route line a click is on (G3.10c), the Mac's
// stand-in for 5.5's hit test on a route (GLEditablePolylineFeature's
// LINE result, with the segment as hit_index): the nearest line within a
// radius of the clicked ground, and the segment it is on.
//
// The engine gives the ground under a pixel, not a line under it, so the
// app turns its click radius into metres there and this measures each
// segment on a local flat plane around the click: at a click's few
// pixels the earth's curve is far below a pixel.

import Foundation
import MacTAKCot

public struct RouteHit: Equatable, Sendable {
    /// The route's id.
    public var route: String
    /// The segment hit: between point `segment` and `segment + 1`.
    public var segment: Int
    /// Where the click was (5.5 inserts there: last_touch).
    public var point: CotPoint

    public init(route: String, segment: Int, point: CotPoint) {
        self.route = route; self.segment = segment; self.point = point
    }

    /// The line nearest `click` within `radius` metres, of `lines` (each a
    /// route's id and its points in order); nil when none is that near.
    public static func nearest(_ lines: [(route: String, points: [CotPoint])], to click: CotPoint,
                               within radius: Double) -> RouteHit? {
        let metersPerLat = 111_132.954, metersPerLon = metersPerLat * cos(click.lat * .pi / 180)
        func plane(_ p: CotPoint) -> (x: Double, y: Double) {
            var dLon = p.lon - click.lon
            if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
            return (dLon * metersPerLon, (p.lat - click.lat) * metersPerLat)
        }
        var best: (hit: RouteHit, distance: Double)?
        for line in lines {
            for (i, (a, b)) in zip(line.points, line.points.dropFirst()).enumerated() {
                let d = distanceToOrigin(plane(a), plane(b))
                if d <= radius, d < (best?.distance ?? .infinity) {
                    best = (RouteHit(route: line.route, segment: i, point: click), d)
                }
            }
        }
        return best?.hit
    }

    /// The distance from (0, 0) to the segment a–b.
    private static func distanceToOrigin(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let t = length2 == 0 ? 0 : min(max(-(a.x * dx + a.y * dy) / length2, 0), 1)
        let x = a.x + t * dx, y = a.y + t * dy
        return (x * x + y * y).squareRoot()
    }
}
