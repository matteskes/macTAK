// Altitude.swift — an altitude as 5.5 shows it (G3.6a): UnitPreferences'
// reference (`alt_display_pref`, MSL by default, or HAE) and units
// (`alt_unit_pref`, feet by default, or metres), through EGM96.formatMSL /
// formatHAE and SpanUtilities.format.
//
// CoT carries height above the ellipsoid (hae); MSL subtracts the geoid.
// Whole feet or metres with thousands grouped ("1,234 ft MSL"). An
// altitude CoT marks unknown, or outside GeoPoint's −14000…76000 m,
// is "-- ft MSL" (or HAE) whatever the units, as in 5.5.

import Foundation

public enum AltitudeReference: String, CaseIterable, Sendable {
    case msl = "MSL"
    case hae = "HAE"

    public static let `default` = AltitudeReference.msl
}

public enum AltitudeUnits: Int, CaseIterable, Sendable {
    /// Span.ENGLISH, 5.5's default.
    case feet = 0
    /// Span.METRIC.
    case meters = 1

    public static let `default` = AltitudeUnits.feet

    public var abbreviation: String { self == .feet ? "ft" : "m" }
}

public enum Altitude {
    /// GeoPoint.isAltitudeValid.
    public static func isValid(_ hae: Double) -> Bool { !hae.isNaN && hae <= 76000 && hae >= -14000 }

    /// UnitPreferences.formatAltitude for a point (lat, lng, hae), without
    /// AGL (5.5's off-by-default `alt_display_agl`, which needs elevation
    /// data).
    public static func format(hae: Double, lat: Double, lng: Double, reference: AltitudeReference,
                              units: AltitudeUnits, geoid: Geoid?) -> String {
        // UnitPreferences: a point off the earth is R.string.ft_msl2
        guard isValidPosition(lat: lat, lng: lng) else { return "-- ft MSL" }
        switch reference {
        case .msl:
            guard isValid(hae) else { return "-- ft MSL" }
            // No geoid at all (a broken bundle): unknown, where the engine
            // would subtract 0 and pass HAE off as MSL.
            guard let geoid else { return "-- ft MSL" }
            // EGM96.getMSL: UNKNOWN (NaN) when the geoid has no answer,
            // which Math.round writes as 0
            let msl = geoid.offset(lat: lat, lng: lng).map { hae - $0 } ?? .nan
            return spanFormat(msl, units) + " MSL"
        case .hae:
            guard isValid(hae) else { return "-- ft HAE" }
            return spanFormat(hae, units) + " HAE"
        }
    }

    /// SpanUtilities.format(value, METER, to) for feet or metres: whole
    /// units, grouped.
    static func spanFormat(_ metres: Double, _ units: AltitudeUnits) -> String {
        let out = units == .feet ? metres * metersToFeet : metres
        return JavaNumber.format(JavaNumber.round(out), grouping: true) + " " + units.abbreviation
    }

    /// GeoPoint.isValid.
    private static func isValidPosition(lat: Double, lng: Double) -> Bool {
        abs(lat) <= 90 && abs(lng) <= 180
    }

    /// ConversionFactors.METERS_TO_FEET and FEET_TO_METERS.
    public static let metersToFeet = 3.280839895
    public static let feetToMeters = 0.3048
}
