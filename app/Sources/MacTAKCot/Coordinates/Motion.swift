// Motion.swift — a heading, a speed and an accuracy as 5.5's self readout
// writes them (G3.6b): AngleUtilities.format as a bearing, SpeedFormatter,
// and SelfCoordOverlayUpdater's "+/- 5m".

import Foundation

public enum Motion {
    /// AngleUtilities.format(degrees) as a bearing, 1…360, then T for true
    /// north (5.5's north reference default; magnetic needs a model).
    public static func heading(_ course: Double) -> String {
        guard !course.isNaN else { return "---°" }
        var deg = course.truncatingRemainder(dividingBy: 360) + (course < 0 ? 360 : 0)
        if deg < 1 { deg += 360 }
        var rounded = Double(JavaNumber.round(deg))
        if rounded >= 361 { rounded -= 360 }
        return JavaNumber.format(JavaNumber.round(rounded), grouping: true) + "°T"
    }

    /// "+/- 5m", or "+/- ---m" when unknown (NaN).
    public static func accuracy(_ metres: Double) -> String {
        metres.isNaN ? "+/- ---m" : "+/- " + JavaNumber.format(JavaNumber.round(metres)) + "m"
    }
}

/// 5.5's speed_unit_pref (SpeedFormatter): MPH by default.
public enum SpeedUnits: Int, CaseIterable, Sendable {
    case milesPerHour = 0, kilometersPerHour = 1, knots = 2, metersPerSecond = 3

    public var abbreviation: String {
        switch self {
        case .milesPerHour: "MPH"
        case .kilometersPerHour: "km/h"
        case .knots: "Kts"
        case .metersPerSecond: "MPS"
        }
    }

    /// ConversionFactors' m/s factors.
    var factor: Double {
        switch self {
        case .milesPerHour: 2.2369362920544025
        case .kilometersPerHour: 3.6
        case .knots: 1.94384
        case .metersPerSecond: 1
        }
    }

    /// getSpeedFormatted: whole units, or "--- MPH" when unknown.
    public func format(_ metresPerSecond: Double) -> String {
        guard !metresPerSecond.isNaN else { return "--- " + abbreviation }
        return String(JavaNumber.round(factor * metresPerSecond)) + " " + abbreviation
    }
}
