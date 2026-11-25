// RouteDetails.swift — a route's waypoint list and totals (G3.10c), as
// ATAK 5.5's route details show them (RoutePlannerView over
// Route.getRouteDetails):
//
// - one row per waypoint, in order: its name ("Wpt#n" when it has none),
//   the distance along the route from the waypoint before (the first row
//   has none: "--"), and the climb from that waypoint when both
//   altitudes are known and it climbs ("+ n ft"; else "--");
// - a leg's distance is in kilometres when the R&B range units are metric
//   (rab_rng_units_pref), else nautical miles for a flying or watercraft
//   route and miles for the rest: SpanUtilities.format into that one
//   unit, never switching to feet or metres;
// - the totals: the whole line's length (Polyline.getTotalDistance) in
//   the range units' own way (formatType: metres below the threshold),
//   nautical miles for flying and watercraft unless metric; the climb is
//   the highest point less the lowest ("+ n ft", "--" without altitudes).
//
// Only waypoints get rows: control points and other map items on the
// route only add to the distance (getRouteDetails reads indexToMarker,
// which holds waypoints alone).

import Foundation

public struct RouteDetails: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        /// The waypoint's uid.
        public var uid: String
        public var name: String
        /// Metres along the route from the waypoint before; nil for none.
        public var meters: Double?
        /// Metres climbed from the waypoint before; nil unless it climbs.
        public var gain: Double?
    }

    public var rows: [Row]
    /// The line's length, in metres.
    public var totalMeters: Double
    /// The highest point less the lowest; nil without altitudes.
    public var totalGain: Double?

    /// `route`'s details, its points at `points` (where the line is now:
    /// RouteGraphics follows a marker on the route; the route's own by
    /// default).
    public init(_ route: Route, points: [CotPoint]? = nil) {
        let at = points ?? route.points.map(\.point)
        var rows: [Row] = []
        var leg = 0.0
        var last: CotPoint?
        for (i, p) in route.points.enumerated() where i < at.count {
            if i > 0 { leg += Self.distance(at[i - 1], at[i]) }
            guard p.isWaypoint else { continue }
            var gain: Double?
            if let last, Altitude.isValid(last.hae), Altitude.isValid(at[i].hae), at[i].hae > last.hae {
                gain = at[i].hae - last.hae
            }
            let name = p.callsign.flatMap { $0.isEmpty ? nil : $0 } ?? "Wpt#\(rows.count + 1)"
            rows.append(Row(uid: p.uid, name: name, meters: leg > 0 ? leg : nil, gain: gain))
            leg = 0
            last = at[i]
        }
        self.rows = rows
        totalMeters = zip(at, at.dropFirst()).reduce(0) { $0 + Self.distance($1.0, $1.1) }
        let heights = at.map(\.hae).filter(Altitude.isValid)
        totalGain = heights.max().flatMap { max in heights.min().map { max - $0 } }
    }

    private static func distance(_ a: CotPoint, _ b: CotPoint) -> Double {
        Geodesy.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    // MARK: - text

    /// A row's distance as the list writes it.
    public static func legText(_ meters: Double?, method: Route.Method, units: RangeUnits) -> String {
        guard let meters, !meters.isNaN, meters > 0 else { return "--" }
        if units == .metersKilometers { return RangeBearingText.fixed(meters, .kilometers) }
        if method == .flying || method == .watercraft { return RangeBearingText.range(meters, .nauticalMiles) }
        return RangeBearingText.fixed(meters, .miles)
    }

    /// A climb as the list writes it.
    public static func gainText(_ meters: Double?) -> String {
        guard let meters, meters > 0 else { return "--" }
        return "+ " + RangeBearingText.fixed(meters, .feet)
    }

    /// The total distance as the details write it.
    public static func totalText(_ meters: Double, method: Route.Method, units: RangeUnits,
                                 thresholds: RangeBearingText.Thresholds = .atak) -> String {
        guard !meters.isNaN else { return "--" }
        if units == .metersKilometers { return RangeBearingText.range(meters, .metersKilometers, thresholds: thresholds) }
        let english: RangeUnits = method == .flying || method == .watercraft ? .nauticalMiles : .feetMiles
        return RangeBearingText.range(meters, english, thresholds: thresholds)
    }
}
