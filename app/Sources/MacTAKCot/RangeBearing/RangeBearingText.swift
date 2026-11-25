// RangeBearingText.swift — angles, ranges and directions written as ATAK
// 5.5 writes them (G3.8a): the kernel's AngleUtilities and SpanUtilities,
// the app's DirectionType, and the units and north references of its
// preferences (Angle, Span, NorthReference, by their stored values).
//
// Quirks kept: a bearing under 1° (and 0) writes as 360°; mils are 6400
// to the circle, "mils" after a space; ranges switch to km above 2000 m
// and to mi above 5280 ft (both thresholds are preferences), with two
// decimals under 100, one under 1000, none above; metres and feet are
// whole, grouped with commas. make test-rab-golden holds these to the
// kernel's answers.

import Foundation

/// 5.5's Angle, as rab_brg_units_pref stores it.
public enum BearingUnits: Int, CaseIterable, Sendable {
    case degrees = 0
    case mils = 1

    public var abbreviation: String { self == .degrees ? "°" : "mils" }
}

/// 5.5's Span unit systems, as rab_rng_units_pref stores them.
public enum RangeUnits: Int, CaseIterable, Sendable {
    case feetMiles = 0
    case metersKilometers = 1
    case nauticalMiles = 2
}

/// 5.5's NorthReference, as rab_north_ref_pref stores it, with the letter
/// the R&B label puts after a bearing.
public enum NorthReference: Int, CaseIterable, Sendable {
    case `true` = 0
    case magnetic = 1
    case grid = 2

    public var letter: String {
        switch self {
        case .true: "T"
        case .magnetic: "M"
        case .grid: "G"
        }
    }
}

public enum RangeBearingText {
    // MARK: - AngleUtilities

    /// AngleUtilities.format(value, Angle.DEGREE, to, isBearing): whole
    /// units; degrees wrapped (a bearing into (0, 360], else (−180, 180]).
    public static func angle(_ degrees: Double, _ units: BearingUnits, isBearing: Bool = true) -> String {
        var out = units == .mils ? degrees * (6400.0 / 360.0) : degrees
        if units == .degrees { out = Double(roundDeg(out, 0, isBearing: isBearing)) }
        return JavaNumber.format(JavaNumber.round(out), grouping: true)
            + (units == .degrees ? "" : " ") + units.abbreviation
    }

    /// AngleUtilities.wrapDeg(deg, isBearing).
    static func wrapDeg(_ value: Double, isBearing: Bool) -> Double {
        var deg = value
        if isBearing {
            deg = deg.truncatingRemainder(dividingBy: 360) + (deg < 0 ? 360 : 0)
            if deg < 1 { deg += 360 }
        } else {
            deg = deg.truncatingRemainder(dividingBy: 360)
            if deg > 180 {
                deg = -180 + deg.truncatingRemainder(dividingBy: 180)
            } else if deg < -180 {
                deg = 180 + deg.truncatingRemainder(dividingBy: 180)
            }
        }
        return deg
    }

    /// AngleUtilities.wrapDeg(deg): as a bearing.
    public static func wrapDeg(_ value: Double) -> Double { wrapDeg(value, isBearing: true) }

    /// AngleUtilities.roundDeg(deg, dec, isBearing), cast to int as the
    /// one-decimal-free overload does.
    static func roundDeg(_ deg: Double, _ dec: Int, isBearing: Bool) -> Int {
        let exp = pow(10.0, Double(dec))
        var out = Double(JavaNumber.round(wrapDeg(deg, isBearing: isBearing) * exp)) / exp
        if out >= 361 { out -= 360 }
        return JavaNumber.int(out)
    }

    // MARK: - SpanUtilities

    /// SpanUtilities' thresholds: rng_feet_display_pref and
    /// rng_meters_display_pref, 5280 and 2000 by default.
    public struct Thresholds: Sendable, Equatable {
        public var feetToMiles: Int
        public var metersToKilometers: Int

        public init(feetToMiles: Int = 5280, metersToKilometers: Int = 2000) {
            self.feetToMiles = feetToMiles
            self.metersToKilometers = metersToKilometers
        }

        public static let atak = Thresholds()
    }

    static let metersToFeet = 3.280839895
    /// ConversionFactors' own: not exactly 1/5280.
    static let feetToMiles = 0.000189394
    static let metersToKilometers = 0.001
    static let metersToNauticalMiles = 0.000539957

    /// SpanUtilities.formatType(type, metres, Span.METER).
    public static func range(_ meters: Double, _ units: RangeUnits, thresholds: Thresholds = .atak) -> String {
        var out: Double
        let abbreviation: String
        var whole = false
        switch units {
        case .metersKilometers:
            out = meters
            if out > Double(thresholds.metersToKilometers) {
                out = out * metersToKilometers
                abbreviation = "km"
            } else {
                abbreviation = "m"
                whole = true
            }
        case .feetMiles:
            out = meters * metersToFeet
            if out > Double(thresholds.feetToMiles) {
                out = out * feetToMiles
                abbreviation = "mi"
            } else {
                abbreviation = "ft"
                whole = true
            }
        case .nauticalMiles:
            out = meters * metersToNauticalMiles
            abbreviation = "NM"
        }
        if whole {
            return JavaNumber.format(out, grouping: true, halfEven: true) + " " + abbreviation
        }
        if out < 100 {
            return JavaNumber.format(Double(JavaNumber.round(out * 100)) / 100, fraction: 2, grouping: true)
                + " " + abbreviation
        } else if out < 1000 {
            return JavaNumber.format(Double(JavaNumber.round(out * 10)) / 10, fraction: 1, grouping: true)
                + " " + abbreviation
        }
        return JavaNumber.format(JavaNumber.round(out), grouping: true) + " " + abbreviation
    }

    /// One unit SpanUtilities.format(value, from, to) writes into.
    public enum FixedUnit: Sendable {
        case kilometers, miles, feet

        var perMeter: Double {
            switch self {
            case .kilometers: metersToKilometers
            // ConversionFactors.METERS_TO_MILES
            case .miles: 0.000621371192
            case .feet: metersToFeet
            }
        }

        var abbreviation: String {
            switch self {
            case .kilometers: "km"
            case .miles: "mi"
            case .feet: "ft"
            }
        }
    }

    /// SpanUtilities.format(metres, Span.METER, to): always in `unit`;
    /// feet whole, else two decimals under 100, one under 1000, none
    /// above (each Math.round first).
    public static func fixed(_ meters: Double, _ unit: FixedUnit) -> String {
        let out = meters * unit.perMeter
        let text: String
        if unit == .feet || out >= 1000 {
            text = JavaNumber.format(JavaNumber.round(out), grouping: true)
        } else if out < 100 {
            text = JavaNumber.format(Double(JavaNumber.round(out * 100)) / 100, fraction: 2, grouping: true)
        } else {
            text = JavaNumber.format(Double(JavaNumber.round(out * 10)) / 10, fraction: 1, grouping: true)
        }
        return text + " " + unit.abbreviation
    }

    // MARK: - DirectionType

    /// DirectionType.getDirection(bearing).getAbbreviation(): the eight
    /// compass points.
    public static func cardinal(_ bearing: Double) -> String {
        var b = bearing
        if b < 0 { b += 360 }
        switch b {
        case ..<22.5: return "N"
        case ..<67.5: return "NE"
        case ..<112.5: return "E"
        case ..<157.5: return "SE"
        case ..<202.5: return "S"
        case ..<247.5: return "SW"
        case ..<292.5: return "W"
        case ..<337.5: return "NW"
        default: return "N"
        }
    }
}
