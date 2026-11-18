// CoordinateFormat.swift — how a position is written and read, ported
// from ATAK 5.5's CoordinateFormat and CoordinateFormatUtilities (G3.6a).
//
// The strings are 5.5's, character for character: N/S and E/W instead of
// signs, a left-to-right mark (U+200E) before each space so the text stays
// in order in right-to-left layouts, HALF_UP rounding, and its quirks
// (59.99999′ rounds to "60.0000'"; UTM and MGRS floor to the metre). The
// kernel's leg of the golden test runs 5.5's own Java over the same
// fixtures (dev/g3/test/coord-golden, make test-coord-golden).
//
// ADDR (an address) is in the list, as in 5.5, but writes and reads DD
// until macTAK has a geocoder; the app doesn't offer it.

import Foundation

public enum CoordinateFormat: String, CaseIterable, Sendable {
    case mgrs = "MGRS"
    case dd = "DD"
    case dm = "DM"
    case dms = "DMS"
    case address = "ADDR"
    case utm = "UTM"

    /// 5.5's `coord_display_pref` default.
    public static let `default` = CoordinateFormat.mgrs

    /// CoordinateFormat.find(displayName): MGRS for anything else.
    public init(displayName: String?) {
        self = displayName.flatMap(CoordinateFormat.init(rawValue:)) ?? .mgrs
    }

    public var displayName: String { rawValue }

    public var fullName: String {
        switch self {
        case .mgrs: "Military Grid Reference System"
        case .dd: "Decimal Degrees"
        case .dm: "Degrees, Minutes"
        case .dms: "Degrees, Minutes, Seconds"
        case .address: "Address"
        case .utm: "Universal Transverse Mercator Coordinate System"
        }
    }

    /// The order a tap on 5.5's self readout steps through
    /// (SelfCoordOverlayUpdater.toggleCoorDisplay): DD, DM, DMS, UTM, MGRS.
    public var next: CoordinateFormat {
        switch self {
        case .dd: .dm
        case .dm: .dms
        case .dms: .utm
        case .utm: .mgrs
        case .mgrs: .dd
        case .address: .address
        }
    }
}

/// A coordinate 5.5 would refuse, with its message.
public struct CoordinateError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// Not an IllegalArgumentException in 5.5 (a NumberFormatException or
    /// an index out of range from MGRSPoint or UTMPoint), so no message of
    /// its own.
    public let malformed: Bool

    static func invalid(_ message: String) -> CoordinateError { CoordinateError(description: message, malformed: false) }
    static let malformed = CoordinateError(description: "Invalid input entered for a numerical field.", malformed: true)
}

public enum Coordinates {
    // MARK: - writing

    /// formatToString (`short` false) or formatToShortString (`short`
    /// true, which drops DM's minutes to two places and DMS's seconds to
    /// none).
    public static func format(lat: Double, lng: Double, as format: CoordinateFormat, short: Bool = false) -> String {
        switch format {
        case .mgrs:
            let m = MGRSPoint(lat: lat, lng: lng)
            return m.zoneDescriptor + lrmSpace + m.gridDescriptor + lrmSpace + m.eastingDescriptor + lrmSpace + m.northingDescriptor
        case .utm:
            let u = UTMPoint(lat: lat, lng: lng)
            return (u.zoneDescriptor ?? "null") + lrmSpace + u.eastingDescriptor + lrmSpace + u.northingDescriptor
        case .dd, .address:
            var (latS, lonS) = (decDeg(lat), decDeg(lng))
            latS = hemisphere(latS, negative: "S", positive: "N") + deg
            lonS = hemisphere(lonS, negative: "W", positive: "E") + deg
            return latS + lrmSpace + lrmSpace + lonS
        case .dm:
            let (latD, latM) = degMin(lat, precise: !short), (lonD, lonM) = degMin(lng, precise: !short)
            return hemisphere(latD, negative: "S", positive: "N") + deg + lrmSpace + latM + min
                + lrmSpace + lrmSpace + hemisphere(lonD, negative: "W", positive: "E") + deg + lrmSpace + lonM + min
        case .dms:
            let la = degMinSec(lat, precise: !short), lo = degMinSec(lng, precise: !short)
            return hemisphere(la.d, negative: "S", positive: "N") + deg + lrmSpace + la.m + min + lrmSpace + la.s + sec
                + lrmSpace + lrmSpace
                + hemisphere(lo.d, negative: "W", positive: "E") + deg + lrmSpace + lo.m + min + lrmSpace + lo.s + sec
        }
    }

    /// "-" becomes "S‎ " (or W); otherwise "N‎ " (or E) goes in front.
    private static func hemisphere(_ s: String, negative: String, positive: String) -> String {
        s.contains("-") ? s.javaReplace("-", negative + lrmSpace) : positive + lrmSpace + s
    }

    private static func decDeg(_ v: Double) -> String {
        let s = JavaNumber.format(v, minInt: 1, fraction: 5)
        return JavaNumber.isNegative(v) && !s.contains("-") ? "-" + s : s
    }

    private static func degMin(_ v: Double, precise: Bool) -> (String, String) {
        let (d, m) = toDegreesMinutes(v)
        var degrees = JavaNumber.format(d)
        if d == 0 && JavaNumber.isNegative(d) { degrees = "-0" }
        return (degrees, JavaNumber.format(m, minInt: 2, fraction: precise ? 4 : 2))
    }

    private static func degMinSec(_ v: Double, precise: Bool) -> (d: String, m: String, s: String) {
        let (d, m, s) = toDegreesMinutesSeconds(v)
        var degrees = JavaNumber.format(d)
        if d == 0 && JavaNumber.isNegative(d) { degrees = "-0" }
        return (degrees, JavaNumber.format(m, minInt: 2), JavaNumber.format(s, minInt: 2, fraction: precise ? 2 : 0))
    }

    /// toDegreesMinutes: whole degrees (signed) and decimal minutes.
    public static func toDegreesMinutes(_ dd: Double) -> (Double, Double) {
        let neg = JavaNumber.isNegative(dd)
        var coordinate = abs(dd)
        var degrees = coordinate.rounded(.down)
        coordinate -= degrees
        if neg { degrees *= -1 }
        coordinate *= 60
        return (degrees, coordinate)
    }

    /// toDegreesMinutesSeconds: whole degrees (signed, -0 kept), whole
    /// minutes and decimal seconds.
    public static func toDegreesMinutesSeconds(_ dd: Double) -> (Double, Double, Double) {
        let neg = JavaNumber.isNegative(dd)
        var coordinate = abs(dd)
        var degrees = coordinate.rounded(.down)
        coordinate -= degrees
        if neg {
            degrees *= -1
            if degrees == 0 { degrees = -0.0 }
        }
        coordinate *= 60
        let minutes = coordinate.rounded(.down)
        coordinate -= minutes
        return (degrees, minutes, coordinate * 60)
    }

    // MARK: - reading

    /// convert(String, format): the position a typed coordinate names. nil
    /// where 5.5 returns null (a DD with other than two numbers, a UTM it
    /// can't read); throws where 5.5 throws, with its message.
    public static func parse(_ text: String, as format: CoordinateFormat) throws -> (lat: Double, lng: Double)? {
        do {
            switch format {
            case .mgrs: return try MGRSPoint.decode(text).toLatLng()
            case .utm: return try UTMPoint.decode(text)?.toLatLng()
            case .dd, .address: return try parseDecDeg(text)
            case .dm: return try parseDegMin(text)
            case .dms: return try parseDegMinSec(text)
            }
        } catch is JavaException {
            throw CoordinateError.malformed
        }
    }

    private static func parseDecDeg(_ text: String) throws -> (lat: Double, lng: Double)? {
        var c = text
        c = c.javaReplace(" " + lrm, " ").javaReplace("N" + lrm, "N").javaReplace("E" + lrm, "E")
        c = c.javaReplace("S" + lrmSpace, "-").javaReplace("W" + lrmSpace, "-")
        c = c.javaReplace("S", "-").javaReplace("W", "-")
        c = c.javaReplace("N", "").javaReplace("E", "").javaReplace(deg, "")
        c = c.javaReplace(",", lrmSpace).javaReplace(":", lrmSpace).javaReplace(";", lrmSpace)
        c = c.javaReplace(lrm, " ")
        let parts = splitWhitespace(JavaNumber.trimmed(c))
        guard parts.count == 2 else { return nil }
        guard let lat = JavaNumber.parseDouble(parts[0]), let lng = JavaNumber.parseDouble(parts[1]) else {
            throw CoordinateError.invalid(numberError)
        }
        return try decDeg(lat, lng)
    }

    private static func decDeg(_ lat: Double, _ lng: Double) throws -> (lat: Double, lng: Double) {
        if abs(lat) <= 90 && abs(lng) <= 180 { return (lat, lng) }
        var error = 0
        if abs(lat) > 90 { error += rangeLat }
        if abs(lng) > 180 { error += rangeLon }
        throw CoordinateError.invalid(errorMessage("Decimal Degrees", error, lat: [], lon: []))
    }

    private static func parseDegMin(_ text: String) throws -> (lat: Double, lng: Double) {
        var c = text
        c = c.javaReplace(" " + lrm, " ").javaReplace("N" + lrm, "N").javaReplace("E" + lrm, "E")
        c = c.javaReplace("S" + lrmSpace, "-").javaReplace("W" + lrmSpace, "-")
        c = c.javaReplace("S", "-").javaReplace("W", "-")
        c = c.javaReplace("N", "").javaReplace("E", "").javaReplace(min, "")
        c = c.javaReplace(deg + lrmSpace, ":").javaReplace(deg, ":")
        c = c.javaReplace(";", lrmSpace).javaReplace(lrm, " ")
        let latLon = splitWhitespace(JavaNumber.trimmed(c))
        guard latLon.count == 2 else { throw CoordinateError.invalid(numberError) }
        let lat = javaSplit(latLon[0], ":"), lon = javaSplit(latLon[1], ":")
        guard lat.count == 2, lon.count == 2 else { throw CoordinateError.invalid(numberError) }
        guard let latDeg = JavaNumber.parseDouble(lat[0]), let latMin = JavaNumber.parseDouble(lat[1]),
              let lonDeg = JavaNumber.parseDouble(lon[0]), let lonMin = JavaNumber.parseDouble(lon[1]) else {
            throw CoordinateError.invalid(numberError)
        }
        guard abs(latDeg) <= 90, latMin < 60, latMin >= 0, abs(lonDeg) <= 180, lonMin < 60, lonMin >= 0 else {
            var error = 0
            var latError: [String] = [], lonError: [String] = []
            if abs(latDeg) > 90 || latMin >= 60 || latMin < 0 {
                error += rangeLat
                if abs(latDeg) > 90 { latError.append("Degrees") }
                if latMin >= 60 || latMin < 0 { latError.append("Minutes") }
            }
            if abs(lonDeg) > 180 || lonMin >= 60 || lonMin < 0 {
                error += rangeLon
                if abs(lonDeg) > 180 { lonError.append("Degrees") }
                if lonMin >= 60 || lonMin < 0 { lonError.append("Minutes") }
            }
            throw CoordinateError.invalid(errorMessage("Degrees, Minutes", error, lat: latError, lon: lonError))
        }
        return (signed(latDeg, minutes: latMin), signed(lonDeg, minutes: lonMin))
    }

    private static func parseDegMinSec(_ text: String) throws -> (lat: Double, lng: Double) {
        var c = text
        c = c.javaReplace(" " + lrm, " ").javaReplace(sec + lrm, sec)
        c = c.javaReplace("N" + lrm, "N").javaReplace("E" + lrm, "E")
        c = c.javaReplace("S" + lrmSpace, "-").javaReplace("W" + lrmSpace, "-")
        c = c.javaReplace("S", "-").javaReplace("W", "-")
        c = c.javaReplace("N", "").javaReplace("E", "").javaReplace(sec, "")
        c = c.javaReplace(deg + lrmSpace, ":").javaReplace(deg, ":")
        c = c.javaReplace(min + lrmSpace, ":").javaReplace(min, ":")
        c = c.javaReplace(";", lrmSpace).javaReplace(lrm, " ")
        let latLon = splitWhitespace(JavaNumber.trimmed(c))
        guard latLon.count == 2 else { throw CoordinateError.invalid(numberError) }
        let lat = javaSplit(latLon[0], ":"), lon = javaSplit(latLon[1], ":")
        guard lat.count == 3, lon.count == 3 else { throw CoordinateError.invalid(numberError) }
        guard let latDeg = JavaNumber.parseDouble(lat[0]), let latMin = JavaNumber.parseDouble(lat[1]),
              let latSec = JavaNumber.parseDouble(lat[2]), let lonDeg = JavaNumber.parseDouble(lon[0]),
              let lonMin = JavaNumber.parseDouble(lon[1]), let lonSec = JavaNumber.parseDouble(lon[2]) else {
            throw CoordinateError.invalid(numberError)
        }
        guard abs(latDeg) <= 90, latMin < 60, latMin >= 0, latSec < 60, latSec >= 0,
              abs(lonDeg) <= 180, lonMin < 60, lonMin >= 0, lonSec < 60, lonSec >= 0 else {
            var error = 0
            var latError: [String] = [], lonError: [String] = []
            if abs(latDeg) > 90 || latMin >= 60 || latMin < 0 || latSec >= 60 || latSec < 0 {
                error += rangeLat
                if abs(latDeg) > 90 { latError.append("Degrees") }
                if latMin >= 60 || latMin < 0 { latError.append("Minutes") }
                if latSec >= 60 || latSec < 0 { latError.append("Seconds") }
            }
            if abs(lonDeg) > 180 || lonMin >= 60 || lonMin < 0 || lonSec >= 60 || lonSec < 0 {
                error += rangeLon
                if abs(lonDeg) > 180 { lonError.append("Degrees") }
                if lonMin >= 60 || lonMin < 0 { lonError.append("Minutes") }
                if lonSec >= 60 || lonSec < 0 { lonError.append("Seconds") }
            }
            throw CoordinateError.invalid(errorMessage("Degrees, Minutes, Seconds", error, lat: latError, lon: lonError))
        }
        return (signed(latDeg, minutes: latMin, seconds: latSec), signed(lonDeg, minutes: lonMin, seconds: lonSec))
    }

    /// Degrees with minutes (and seconds) away from zero, -0 kept.
    private static func signed(_ degrees: Double, minutes: Double, seconds: Double? = nil) -> Double {
        let neg = JavaNumber.isNegative(degrees)
        var v = degrees
        if neg {
            v -= minutes * divMin
            if let seconds { v -= seconds * divSec }
        } else {
            v += minutes * divMin
            if let seconds { v += seconds * divSec }
        }
        if v == 0 && neg { v = -0.0 }
        return v
    }

    /// _buildErrorMessage.
    private static func errorMessage(_ type: String, _ error: Int, lat: [String], lon: [String]) -> String {
        switch error {
        case rangeLat:
            if lat.isEmpty { return "Latitude out of range. Enter a valid Latitude." }
            return "Latitude's " + lat.map { $0 + " " }.joined() + "out of range. Enter "
                + (lat.count == 1 ? "a valid field." : "valid fields.")
        case rangeLon:
            if lon.isEmpty { return "Longitude out of range. Enter a valid Longitude." }
            return "Longitude's " + lon.map { $0 + " " }.joined() + "out of range. Enter "
                + (lon.count == 1 ? "a valid field." : "valid fields.")
        case rangeLat + rangeLon:
            if lat.isEmpty && lon.isEmpty { return "Latitude and Longitude out of range. Enter valid fields." }
            return "Latitude's " + lat.map { $0 + " " }.joined() + " and Longitude's "
                + lon.map { $0 + " " }.joined() + "out of range. Enter valid fields."
        case number:
            return numberError
        default:
            // 5.5's builder has no case for 0 (a NaN fails every range
            // test and sets no flag): an empty message
            return ""
        }
    }

    /// String.split("\\s+") on a trimmed string: runs of [ \t\n\x0B\f\r].
    private static func splitWhitespace(_ s: String) -> [String] {
        if s.isEmpty { return [""] }
        return s.split(whereSeparator: { " \t\n\u{0B}\u{0C}\r".contains($0) }).map(String.init)
    }

    /// String.split(":"): empty pieces kept, trailing empty ones dropped.
    private static func javaSplit(_ s: String, _ separator: Character) -> [String] {
        var parts = s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, parts.last == "" { parts.removeLast() }
        if parts == [""] && !s.isEmpty { return [] }
        return parts
    }

    private static let lrm = "\u{200E}"
    private static let lrmSpace = "\u{200E} "
    private static let deg = "\u{00B0}"
    private static let min = "'"
    private static let sec = "\""
    private static let divMin = 1.0 / 60.0
    private static let divSec = 1.0 / 3600.0
    private static let rangeLat = 0x2
    private static let rangeLon = 0x4
    private static let number = 0x8
    private static let numberError = "Invalid input entered for a numerical field."
}
