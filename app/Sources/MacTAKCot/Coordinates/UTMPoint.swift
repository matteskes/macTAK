// UTMPoint.swift — UTM, ported from the kernel's UTMPoint and
// MutableUTMPoint at the pin (G3.6a).
//
// WGS84 only, as ATAK uses it. Like 5.5 it covers −80…84 with no UPS: a
// point beyond clamps to band C or X and comes out as 5.5 writes it (the
// golden fixtures pin the poles). USGS bulletin 1532's series, as the
// kernel writes them.

import Foundation

public struct UTMPoint: Equatable, Sendable {
    /// The latitude band, 0…19 for C…X (-1 for a letter that isn't one,
    /// which 5.5 lets through from a typed zone).
    public internal(set) var latZone: Int
    /// The zone number, 1…60.
    public internal(set) var lngZone: Int
    public internal(set) var easting: Double
    /// From the equator, or from 10,000 km south of it in the south.
    public internal(set) var northing: Double

    static let latZoneChars = Array("CDEFGHJKLMNPQRSTUVWX".utf16)

    init(latZone: Int, lngZone: Int, easting: Double, northing: Double) {
        self.latZone = latZone; self.lngZone = lngZone; self.easting = easting; self.northing = northing
    }

    /// new UTMPoint(zoneDescriptor, easting, northing).
    init(zoneDescriptor: String, easting: Double, northing: Double) throws {
        let zone = JavaString(zoneDescriptor)
        guard let lng = JavaNumber.parseInt(try zone.substring(0, 2)) else { throw JavaException.numberFormat }
        lngZone = lng
        latZone = Self.latZoneChars.firstIndex(of: try zone.charAt(2)) ?? -1
        self.easting = easting
        self.northing = northing
    }

    /// fromLatLng, with Norway's 32V and Svalbard's 31X–37X.
    public init(lat: Double, lng: Double) {
        var lngZone = JavaNumber.int((lng + 180) / 6) + 1
        let latZone = min(max(JavaNumber.int((lat + 80) / 8), 0), 19)
        switch latZone {
        case 17:
            if lng >= 0 && lng < 3 { lngZone = 31 } else if lng >= 3 && lng < 12 { lngZone = 32 }
        case 19:
            if lng >= 0 {
                if lng < 9 { lngZone = 31 } else if lng < 21 { lngZone = 33 } else if lng < 33 { lngZone = 35 } else if lng < 42 { lngZone = 37 }
            }
        default:
            break
        }
        self = Self.fromLatLng(lat: lat, lng: lng, lngZone: lngZone, latZone: latZone)
    }

    private static func fromLatLng(lat: Double, lng: Double, lngZone: Int, latZone: Int) -> UTMPoint {
        let a = Ellipsoid.wgs84.semiMajorAxis
        let eccSquared = Ellipsoid.wgs84.firstEccentricitySquared
        let k0 = 0.9996
        let latRadians = lat * divPi180, lngRadians = lng * divPi180
        let lngOrigin = Double((lngZone - 1) * 6 - 180 + 3)
        let lngOriginRadians = lngOrigin * divPi180
        let eccPrimeSquared = eccSquared / (1 - eccSquared)
        let tanLat = tan(latRadians), sinLat = sin(latRadians), cosLat = cos(latRadians)
        let N = a / (1 - eccSquared * sinLat * sinLat).squareRoot()
        let T = tanLat * tanLat
        let C = eccPrimeSquared * cosLat * cosLat
        let A = cosLat * (lngRadians - lngOriginRadians)
        // The kernel's expressions term by term: floating point isn't
        // associative, and the strings floor these to the metre.
        let M = a * ((1 - eccSquared / 4 - 3 * eccSquared * eccSquared / 64 - 5
                * eccSquared * eccSquared * eccSquared / 256)
                * latRadians
                - (3 * eccSquared / 8 + 3 * eccSquared * eccSquared
                / 32 + 45 * eccSquared * eccSquared
                * eccSquared / 1024)
                * sin(2 * latRadians)
                + (15 * eccSquared * eccSquared / 256 + 45 * eccSquared
                * eccSquared * eccSquared / 1024)
                * sin(4 * latRadians)
                - (35 * eccSquared * eccSquared
                * eccSquared * div3072)
                * sin(6 * latRadians))
        let easting = (k0
                * N
                * (A + (1 - T + C) * A * A * A * div6 + (5 - 18 * T + T * T
                + 72 * C - 58 * eccPrimeSquared)
                * A * A * A * A * A * div120)
                + 500000.0)
        var northing = (k0 * (M + N
                * tanLat
                * (A * A / 2 + (5 - T + 9 * C + 4 * C * C) * A * A * A * A
                * div24
                + (61 - 58 * T + T * T + 600 * C
                - 330 * eccPrimeSquared)
                * A * A * A * A * A * A * div720)))
        if latZone < 10 { northing += 10000000.0 }
        return UTMPoint(latZone: latZone, lngZone: lngZone, easting: easting, northing: northing)
    }

    /// toLatLng: (lat, lng) in degrees.
    public func toLatLng() -> (lat: Double, lng: Double) {
        let k0 = 0.9996
        let a = Ellipsoid.wgs84.semiMajorAxis
        let eccSquared = Ellipsoid.wgs84.firstEccentricitySquared
        let e1 = (1 - (1 - eccSquared).squareRoot()) / (1 + (1 - eccSquared).squareRoot())
        let x = easting - 500000.0
        var y = northing
        if latZone < 10 { y -= 10000000.0 }
        let longOrigin = Double((lngZone - 1) * 6 - 180 + 3)
        let eccPrimeSquared = eccSquared / (1 - eccSquared)
        let M = y / k0
        let mu = M / (a * (1 - eccSquared / 4 - 3 * eccSquared * eccSquared / 64
                           - 5 * eccSquared * eccSquared * eccSquared / 256))
        let phi1Rad = mu + (3 * e1 / 2 - 27 * e1 * e1 * e1 / 32) * sin(2 * mu)
            + (21 * e1 * e1 / 16 - 55 * e1 * e1 * e1 * e1 / 32) * sin(4 * mu)
            + (151 * e1 * e1 * e1 * div96) * sin(6 * mu)
        let sinPhi = sin(phi1Rad), cosPhi = cos(phi1Rad), tanPhi = tan(phi1Rad)
        let N1 = a / (1 - eccSquared * sinPhi * sinPhi).squareRoot()
        let T1 = tanPhi * tanPhi
        let C1 = eccPrimeSquared * cosPhi * cosPhi
        let R1 = a * (1 - eccSquared) / pow(1 - eccSquared * sinPhi * sinPhi, 1.5)
        let D = x / (N1 * k0)
        var lat = phi1Rad
                - (N1 * tanPhi / R1)
                * (D
                * D
                / 2
                - (5 + 3 * T1 + 10 * C1 - 4 * C1 * C1
                - 9 * eccPrimeSquared)
                * D * D * D * D / 24
                + (61 + 90 * T1 + 298 * C1 + 45
                * T1 * T1 - 252 * eccPrimeSquared
                - 3 * C1 * C1)
                * D * D * D * D * D * D * div720)
        lat = lat * div180Pi
        var lon = (D - (1 + 2 * T1 + C1) * D * D * D * div6 + (5 - 2 * C1
                + 28
                * T1
                - 3 * C1 * C1 + 8 * eccPrimeSquared + 24 * T1 * T1)
                * D * D * D * D * D * div120)
                / cosPhi
        lon = longOrigin + lon * div180Pi
        return (lat, lon)
    }

    /// "33T", or nil for a band letter 5.5 couldn't read.
    public var zoneDescriptor: String? {
        guard latZone >= 0 && latZone < Self.latZoneChars.count else { return nil }
        return (lngZone < 10 ? "0" : "") + String(lngZone)
            + String(decoding: [Self.latZoneChars[latZone]], as: UTF16.self)
    }

    public var eastingDescriptor: String { JavaNumber.format(easting.rounded(.down)) }
    public var northingDescriptor: String { JavaNumber.format(northing.rounded(.down)) }

    /// decodeString(String): "33T 500000 4649776", spaces and LRMs optional,
    /// an "m" after each number allowed. nil where 5.5 returns null; throws
    /// where it throws.
    static func decode(_ text: String) throws -> UTMPoint? {
        var s = text.javaReplace(" ", "").javaReplace("\u{200E}", "")
        if !JavaNumber.isDigit(try JavaString(s).charAt(1)) { s = "0" + s }
        let js = JavaString(s)
        var eastingText = "0", northingText = "0"
        if js.length > 5 {
            let compSize = (js.length - 3) / 2
            if compSize > 0 {
                eastingText = try js.substring(3, 3 + compSize).lowercased().javaReplace("m", "")
                northingText = try js.substring(3 + compSize).lowercased().javaReplace("m", "")
            }
        }
        guard let e = JavaNumber.parseDouble(eastingText), let n = JavaNumber.parseDouble(northingText) else { return nil }
        do {
            return try UTMPoint(zoneDescriptor: try js.substring(0, 3), easting: e, northing: n)
        } catch JavaException.numberFormat {
            return nil
        }
    }

    // MARK: - zones (MGRSPoint's helpers)

    static func zoneLatitude(_ latZoneIndex: Int) -> Double { -80 + Double(latZoneIndex) * 8 }
    static func zoneLongitude(_ zoneNumber: Int) -> Double { -180 + Double(zoneNumber - 1) * 6 }
    static func zoneLatitudeSpan(_ latZoneIndex: Int) -> Double { latZoneIndex == 19 ? 12 : 8 }
    static let zoneLongitudeSpan = 6.0

    mutating func offset(easting dx: Double, northing dy: Double) {
        easting += dx
        northing += dy
    }
}

/// The kernel's Ellipsoid, WGS 84 only.
struct Ellipsoid {
    let semiMajorAxis: Double
    let firstEccentricitySquared: Double

    static let wgs84: Ellipsoid = {
        let a = 6378137.0, b = 6356752.3142
        let aSquared = pow(a, 2), bSquared = pow(b, 2)
        return Ellipsoid(semiMajorAxis: a, firstEccentricitySquared: (aSquared - bSquared) / aSquared)
    }()
}

private let div6 = 1.0 / 6.0
private let div24 = 1.0 / 24.0
private let div96 = 1.0 / 96.0
private let div120 = 1.0 / 120.0
private let div720 = 1.0 / 720.0
private let div3072 = 1.0 / 3072.0
private let div180Pi = 180.0 / Double.pi
private let divPi180 = Double.pi / 180.0
