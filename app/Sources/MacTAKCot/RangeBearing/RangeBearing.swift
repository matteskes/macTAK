// RangeBearing.swift — the range and bearing between two points, and the two
// ways ATAK 5.5 writes it (G3.8a):
//
// - the R&B line's label (RangeAndBearingMapItem.onPointChanged and
//   updateLabel): an arrow (← for a bearing in (180, 360), else →), the
//   bearing from the chosen north with its letter (T, M, G), then the
//   ground or slant range, then, with slant range on and both heights
//   known, the up or down angle;
// - an item's details from me (RangeAndBearingTableHandler): the range in
//   all three unit systems, the bearing magnetic and true in degrees and
//   mils, and the compass point of the magnetic bearing.
//
// Kept from 5.5: the depression angle is acos(ground / slant) in degrees,
// up when the far point is as high or higher; with slant range on, a line
// whose slant range can't be had (a height unknown) falls back to the
// ground range, and the angle is left off.

import Foundation

public struct RangeBearing: Sendable, Equatable {
    public let from: CotPoint
    public let to: CotPoint
    /// Metres along the ellipsoid.
    public let range: Double
    /// Degrees from true north.
    public let bearing: Double
    /// Metres in a straight line; NaN unless both heights are known.
    public let slantRange: Double

    public init(from: CotPoint, to: CotPoint) {
        self.from = from
        self.to = to
        range = Geodesy.distance(lat1: from.lat, lon1: from.lon, lat2: to.lat, lon2: to.lon)
        bearing = Geodesy.bearing(lat1: from.lat, lon1: from.lon, lat2: to.lat, lon2: to.lon)
        slantRange = Self.heightKnown(from) && Self.heightKnown(to)
            ? Geodesy.slantDistance(lat1: from.lat, lon1: from.lon, hae1: from.hae,
                                    lat2: to.lat, lon2: to.lon, hae2: to.hae)
            : .nan
    }

    /// GeoPoint.isAltitudeValid (CoT's unknown, 9999999, isn't).
    static func heightKnown(_ p: CotPoint) -> Bool { Altitude.isValid(p.hae) }

    /// The up (+) or down (−) angle to the far point, degrees; NaN without
    /// a slant range.
    public var depressionAngle: Double {
        guard !slantRange.isNaN else { return .nan }
        let offset: Double = from.hae <= to.hae ? 1 : -1
        return offset * (acos(range / slantRange) * (180.0 / Double.pi))
    }

    /// The bearing from `north`, degrees; nil for magnetic without a model.
    public func bearing(from north: NorthReference, magnetic: MagneticModel?, at date: Date) -> Double? {
        switch north {
        case .true:
            return bearing
        case .magnetic:
            return magnetic?.magnetic(fromTrue: bearing, lat: from.lat, lon: from.lon, at: date)
        case .grid:
            let convergence = Geodesy.gridConvergence(lat1: from.lat, lon1: from.lon, lat2: to.lat, lon2: to.lon)
            return RangeBearingText.wrapDeg(bearing - convergence)
        }
    }

    /// What the R&B preferences say: 5.5's keys and defaults.
    public struct Style: Sendable, Equatable {
        public var north: NorthReference
        public var bearingUnits: BearingUnits
        public var rangeUnits: RangeUnits
        /// rab_dist_slant_range "slantrange"; 5.5's default is "clamped".
        public var slantRange: Bool
        public var thresholds: RangeBearingText.Thresholds

        public init(north: NorthReference = .magnetic, bearingUnits: BearingUnits = .degrees,
                    rangeUnits: RangeUnits = .metersKilometers, slantRange: Bool = false,
                    thresholds: RangeBearingText.Thresholds = .atak) {
            self.north = north
            self.bearingUnits = bearingUnits
            self.rangeUnits = rangeUnits
            self.slantRange = slantRange
            self.thresholds = thresholds
        }

        public static let atak = Style()
    }

    /// The R&B line's label; nil when the bearing can't be had (magnetic
    /// north with no model).
    public func label(_ style: Style, magnetic: MagneticModel?, at date: Date = Date()) -> String? {
        guard let b = bearing(from: style.north, magnetic: magnetic, at: date) else { return nil }
        let bs = RangeBearingText.angle(b, style.bearingUnits) + style.north.letter
        let direction = bearing > 180 && bearing < 360 ? "\u{2190}" : "\u{2192}"
        var text = direction + " " + bs + "   "
        if !slantRange.isNaN {
            text += RangeBearingText.range(style.slantRange ? slantRange : range, style.rangeUnits,
                                           thresholds: style.thresholds)
            if style.slantRange {
                let dep = depressionAngle
                text += "   " + RangeBearingText.angle(abs(dep), style.bearingUnits, isBearing: false)
                if dep > 0 { text += "\u{2191}" } else if dep < 0 { text += "\u{2193}" }
            }
        } else {
            text += RangeBearingText.range(range, style.rangeUnits, thresholds: style.thresholds)
        }
        return text
    }

    /// One row of an item's range and bearing from me.
    public struct Table: Sendable, Equatable {
        public var feetMiles: String
        public var metersKilometers: String
        public var nauticalMiles: String
        public var magneticDegrees: String?
        public var trueDegrees: String
        public var magneticMils: String?
        public var trueMils: String
        /// The compass point of the magnetic bearing, else the true one.
        public var cardinal: String
    }

    /// RangeAndBearingTableHandler.update(from, to).
    public func table(magnetic: MagneticModel?, at date: Date = Date(),
                      thresholds: RangeBearingText.Thresholds = .atak) -> Table {
        let m = bearing(from: .magnetic, magnetic: magnetic, at: date)
        return Table(feetMiles: RangeBearingText.range(range, .feetMiles, thresholds: thresholds),
                     metersKilometers: RangeBearingText.range(range, .metersKilometers, thresholds: thresholds),
                     nauticalMiles: RangeBearingText.range(range, .nauticalMiles, thresholds: thresholds),
                     magneticDegrees: m.map { RangeBearingText.angle($0, .degrees) + "M" },
                     trueDegrees: RangeBearingText.angle(bearing, .degrees) + "T",
                     magneticMils: m.map { RangeBearingText.angle($0, .mils) + "M" },
                     trueMils: RangeBearingText.angle(bearing, .mils) + "T",
                     cardinal: RangeBearingText.cardinal(m ?? bearing))
    }
}
