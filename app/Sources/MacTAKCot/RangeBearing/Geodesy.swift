// Geodesy.swift — range, bearing, slant range and grid convergence, as ATAK
// 5.5 computes them for range and bearing (G3.8a).
//
// 5.5 asks the kernel's GeoCalculations, which calls the engine's C++:
// - distance: util/Distance.cpp calculateRange, Vincenty's inverse on
//   WGS84 (a 6378137, b 6356752.3142 as that file has them);
// - bearing: computeDirection (Vincenty after Rainsford, from GeoTools),
//   falling back to a great-circle bearing if it doesn't converge; the
//   Java wrapper adds 360 to a negative bearing; equal points are 0;
// - slant range: the straight line between the two points in ECEF
//   (EcefWGS84.forward), unknown heights as 0;
// - grid convergence: the bearing from the start to the point that far
//   north in its UTM zone (computeGridConvergence over MutableMGRSPoint).
// make test-rab-golden holds these to the engine's answers.

import Foundation

public enum Geodesy {
    // MARK: - GeoCalculations

    /// GeoCalculations.distance: metres along the ellipsoid.
    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        calculateRange(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
    }

    /// GeoCalculations.bearing: degrees true, [0, 360).
    public static func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        var b: Double
        if lat1 == lat2 && lon1 == lon2 {
            b = 0
        } else if let direction = computeDirection(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2) {
            b = direction
        } else {
            b = greatCircleBearing(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        }
        if b < 0 { b += 360 }
        return b
    }

    /// GeoCalculations.slantDistance: metres in a straight line; a NaN
    /// height is 0, as GeoCalculations.toHae has it.
    public static func slantDistance(lat1: Double, lon1: Double, hae1: Double,
                                     lat2: Double, lon2: Double, hae2: Double) -> Double {
        let a = ecef(lat: lat1, lon: lon1, hae: hae1.isNaN ? 0 : hae1)
        let b = ecef(lat: lat2, lon: lon2, hae: hae2.isNaN ? 0 : hae2)
        return ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)).squareRoot()
    }

    /// GeoCalculations.computeGridConvergence(start, end): the bearing of
    /// grid north at the start, over the line's length.
    public static func gridConvergence(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let d = distance(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        var aligned = UTMPoint(lat: lat1, lng: lon1)
        aligned.offset(easting: 0, northing: d)
        let end = aligned.toLatLng()
        return bearing(lat1: lat1, lon1: lon1, lat2: end.lat, lon2: end.lng)
    }

    // MARK: - util/Distance.cpp

    private static let radians = Double.pi / 180
    private static let degrees = 180 / Double.pi
    private static let wgs84A = 6378137.0
    private static let wgs84B = 6356752.3142
    private static let wgs84F = 1.0 - wgs84B / wgs84A
    private static let wgs84A2B21 = (wgs84A * wgs84A) / (wgs84B * wgs84B) - 1.0

    /// The point `distance` metres along the ground from (lat, lon) at
    /// `azimuth` degrees from true north: the engine's
    /// GeoPoint2_pointAtDistance, not quick, which is util/Distance.cpp
    /// pointAtRange (Vincenty's direct formula, that file's constants).
    /// With no inclination (NaN) the kernel's Java returns no height, so
    /// neither does this; with one (degrees) the start's height rises by
    /// tan(inclination) × distance, flat-earth as the engine's own note
    /// says. `hae` NaN is unknown and stays so.
    public static func pointAtDistance(lat: Double, lon: Double, hae: Double, azimuth: Double, distance: Double,
                                       inclination: Double = .nan) -> (lat: Double, lon: Double, hae: Double) {
        let phi1 = radians * lat
        let tanU1 = (1.0 - wgs84F) * tan(phi1)
        let U1 = atan(tanU1)
        let lambda1 = radians * lon
        let alpha1 = radians * azimuth
        let s = distance
        let cosU1 = cos(U1), sinU1 = sin(U1)
        let cosAlpha1 = cos(alpha1), sinAlpha1 = sin(alpha1)
        let sigma1 = atan2(tanU1, cosAlpha1)
        let sinAlpha = cosU1 * sinAlpha1
        let sin2Alpha = sinAlpha * sinAlpha
        let cos2Alpha = 1.0 - sin2Alpha
        let u2 = cos2Alpha * wgs84A2B21
        let A = 1.0 + u2 / 16384.0 * (4096.0 + u2 * (-768.0 + u2 * (320.0 - 175.0 * u2)))
        let B = u2 / 1024.0 * (256.0 + u2 * (-128.0 + u2 * (74.0 - 47.0 * u2)))
        var sigma = s / (wgs84B * A)
        var deltaSigma = 0.0, lastDeltaSigma = 0.0
        var sinSigma = 0.0, cosSigma = 0.0, cos2sigmaM = 0.0, cos2sigmaMSquared = 0.0
        repeat {
            lastDeltaSigma = deltaSigma
            sinSigma = sin(sigma)
            cosSigma = cos(sigma)
            cos2sigmaM = cos(2 * sigma1 + sigma)
            cos2sigmaMSquared = cos2sigmaM * cos2sigmaM
            deltaSigma = B * sinSigma
                * (cos2sigmaM
                    + B / 4.0
                    * (cosSigma * (-1.0 + 2.0 * cos2sigmaMSquared)
                        - (B / 6.0 * cos2sigmaM * (-3.0 + 4.0 * sinSigma * sinSigma)
                            * (-3.0 + 4.0 * cos2sigmaMSquared))))
            sigma = s / (wgs84B * A) + deltaSigma
        } while abs(deltaSigma - lastDeltaSigma) > 1e-12
        let phi2 = atan2(sinU1 * cosSigma + cosU1 * sinSigma * cosAlpha1,
                         (1.0 - wgs84F) * (sin2Alpha + pow(sinU1 * sinSigma - cosU1 * cosSigma * cosAlpha1, 2.0))
                            .squareRoot())
        let lambda = atan2(sinSigma * sinAlpha1, cosU1 * cosSigma - sinU1 * sinSigma * cosAlpha1)
        let C = wgs84F / 16.0 * cos2Alpha * (4.0 + wgs84F * (4.0 - 3.0 * cos2Alpha))
        let L = lambda - (1.0 - C) * wgs84F * sinAlpha
            * (sigma + C * sinSigma * (cos2sigmaM + C * cosSigma * (-1.0 + 2.0 * cos2sigmaMSquared)))
        var height = inclination.isNaN ? .nan : hae
        if !inclination.isNaN && inclination != 0 && !height.isNaN {
            height += tan(inclination * Double.pi / 180.0) * distance
        }
        return (phi2 / radians, (L + lambda1) / radians, height)
    }

    static func calculateRange(lat1 lat1Deg: Double, lon1 lon1Deg: Double,
                               lat2 lat2Deg: Double, lon2 lon2Deg: Double) -> Double {
        let lat1 = lat1Deg * radians, lat2 = lat2Deg * radians
        let lon1 = lon1Deg * radians, lon2 = lon2Deg * radians
        let L = lon2 - lon1
        let U1 = atan((1.0 - wgs84F) * tan(lat1))
        let U2 = atan((1.0 - wgs84F) * tan(lat2))
        let cosU1 = cos(U1), cosU2 = cos(U2), sinU1 = sin(U1), sinU2 = sin(U2)
        let cosU1cosU2 = cosU1 * cosU2, sinU1sinU2 = sinU1 * sinU2
        var sigma = 0.0, cosSqAlpha = 0.0, cos2SM = 0.0, cosSigma = 0.0, sinSigma = 0.0
        var lambda = L
        for _ in 0..<20 {
            let cosLambda = cos(lambda), sinLambda = sin(lambda)
            let t1 = cosU2 * sinLambda
            let t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            let sinSqSigma = t1 * t1 + t2 * t2
            sinSigma = sinSqSigma.squareRoot()
            cosSigma = sinU1sinU2 + cosU1cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = sinSigma == 0 ? 0.0 : cosU1cosU2 * sinLambda / sinSigma
            cosSqAlpha = 1.0 - sinAlpha * sinAlpha
            cos2SM = cosSqAlpha == 0 ? 0.0 : cosSigma - 2.0 * sinU1sinU2 / cosSqAlpha
            let C = (wgs84F / 16.0) * cosSqAlpha * (4.0 + wgs84F * (4.0 - 3.0 * cosSqAlpha))
            let lambdaOrig = lambda
            lambda = L + (1.0 - C) * wgs84F * sinAlpha
                * (sigma + C * sinSigma * (cos2SM + C * cosSigma * (-1.0 + 2.0 * cos2SM * cos2SM)))
            let delta = (lambda - lambdaOrig) / lambda
            if abs(delta) < 1.0e-12 { break }
        }
        let uSquared = cosSqAlpha * wgs84A2B21
        let A = 1 + (uSquared / 16384.0) * (4096.0 + uSquared * (-768.0 + uSquared * (320.0 - 175.0 * uSquared)))
        let B = (uSquared / 1024.0) * (256.0 + uSquared * (-128.0 + uSquared * (74.0 - 47.0 * uSquared)))
        let cos2SMSq = cos2SM * cos2SM
        let deltaSigma = B * sinSigma
            * (cos2SM + (B / 4.0)
                * (cosSigma * (-1.0 + 2.0 * cos2SMSq)
                    - (B / 6.0) * cos2SM * (-3.0 + 4.0 * sinSigma * sinSigma) * (-3.0 + 4.0 * cos2SMSq)))
        return wgs84B * A * (sigma - deltaSigma)
    }

    /// The engine's DistanceConstants for Ellipsoid2.WGS84 (a 6378137,
    /// f 1/298.257223563, b = a(1 − f)).
    private struct Constants {
        let semiMajorAxis = 6378137.0
        let semiMinorAxis: Double
        let f, fo, eccentricitySquared: Double
        let A, B, C, D, E, F: Double
        let T1, T2, T4, T6: Double
        let a01, a02, a03, a21, a22, a23, a42, a43, a63: Double

        init() {
            let flattening = 1.0 / 298.257223563
            semiMinorAxis = semiMajorAxis * (1.0 - flattening)
            f = (semiMajorAxis - semiMinorAxis) / semiMajorAxis
            fo = 1.0 - f
            let f2 = f * f, f3 = f * f2, f4 = f * f3
            eccentricitySquared = f * (2.0 - f)
            let E2 = eccentricitySquared, E4 = E2 * E2, E6 = E4 * E2, E8 = E6 * E2, EX = E8 * E2
            A = 1.0 + 0.75 * E2 + 0.703125 * E4 + 0.68359375 * E6 + 0.67291259765625 * E8 + 0.6661834716796875 * EX
            B = 0.75 * E2 + 0.9375 * E4 + 1.025390625 * E6 + 1.07666015625 * E8 + 1.1103057861328125 * EX
            C = 0.234375 * E4 + 0.41015625 * E6 + 0.538330078125 * E8 + 0.63446044921875 * EX
            D = 0.068359375 * E6 + 0.15380859375 * E8 + 0.23792266845703125 * EX
            E = 0.01922607421875 * E8 + 0.0528717041015625 * EX
            F = 0.00528717041015625 * EX
            T1 = 1.0
            T2 = -0.25 * f * (1.0 + f + f2)
            T4 = 0.1875 * f2 * (1.0 + 2.25 * f)
            T6 = 0.1953125 * f3
            let a = f3 * (1.0 + 2.25 * f)
            a01 = -f2 * (1.0 + f + f2) / 4.0
            a02 = 0.1875 * a
            a03 = -0.1953125 * f4
            a21 = -a01
            a22 = -0.25 * a
            a23 = 0.29296875 * f4
            a42 = 0.03125 * a
            a43 = 0.05859375 * f4
            a63 = 5.0 * f4 / 768.0
        }
    }

    private static let k = Constants()
    private static let tolerance0 = 5.0e-15, tolerance1 = 5.0e-14, tolerance2 = 5.0e-13, tolerance3 = 7.0e-3

    private static func castToAngleRange(_ alpha: Double) -> Double {
        alpha - (2 * Double.pi) * (alpha / (2 * Double.pi) + 0.5).rounded(.down)
    }

    private static func convertAngleToHeading(_ alpha: Double) -> Double {
        alpha < 0 ? alpha + 2 * Double.pi : alpha
    }

    /// computeDirection's azimuth in degrees, or nil where the engine
    /// reports failure (an equatorial line that won't converge).
    static func computeDirection(lat1 lat1Deg: Double, lon1 lon1Deg: Double,
                                 lat2 lat2Deg: Double, lon2 lon2Deg: Double) -> Double? {
        let long1 = radians * lon1Deg, lat1 = radians * lat1Deg
        let long2 = radians * lon2Deg, lat2 = radians * lat2Deg
        let dlon = castToAngleRange(long2 - long1)
        let ss = abs(dlon)
        if ss < tolerance1 {
            return degrees * convertAngleToHeading(lat2 > lat1 ? 0.0 : Double.pi)
        }
        let alimit = Double.pi * k.fo
        if ss >= alimit && lat1 < tolerance3 && lat1 > -tolerance3 && lat2 < tolerance3 && lat2 > -tolerance3 {
            let cons = (Double.pi - ss) / (Double.pi * k.f)
            var az = asin(cons)
            var s: Double, azTemp: Double
            var iter = 0
            repeat {
                iter += 1
                if iter > 8 { return nil }
                s = cos(az)
                let c2 = s * s
                let ao = k.T1 + k.T2 * c2 + k.T4 * c2 * c2 + k.T6 * c2 * c2 * c2
                let cs = cons / ao
                s = asin(cs)
                azTemp = az
                az = s
            } while abs(s - azTemp) >= tolerance2
            let az1 = dlon < 0.0 ? 2.0 * Double.pi - s : s
            return degrees * convertAngleToHeading(castToAngleRange(az1))
        }
        let u1 = atan(k.fo * sin(lat1) / cos(lat1))
        let u2 = atan(k.fo * sin(lat2) / cos(lat2))
        let su1 = sin(u1), cu1 = cos(u1), su2 = sin(u2), cu2 = cos(u2)
        var xy: Double, ssig: Double, slon: Double, clon: Double, sinalf: Double
        var ab = dlon
        var kcount = 1
        repeat {
            clon = cos(ab)
            slon = sin(ab)
            let csig = su1 * su2 + cu1 * cu2 * clon
            ssig = hypot(slon * cu2, su2 * cu1 - su1 * cu2 * clon)
            let sig = atan2(ssig, csig)
            sinalf = cu1 * cu2 * slon / ssig
            let w = 1.0 - sinalf * sinalf
            let t4 = w * w, t6 = w * t4
            let ao = k.f + k.a01 * w + k.a02 * t4 + k.a03 * t6
            let a2 = k.a21 * w + k.a22 * t4 + k.a23 * t6
            let a4 = k.a42 * t4 + k.a43 * t6
            let a6 = k.a63 * t6
            var qo = 0.0
            if w > tolerance0 { qo = -2.0 * su1 * su2 / w }
            let q2 = csig + qo
            let q4 = 2.0 * q2 * q2 - 1.0
            let q6 = q2 * (4.0 * q2 * q2 - 3.0)
            let r2 = 2.0 * ssig * csig
            let r3 = ssig * (3.0 - 4.0 * ssig * ssig)
            let s = sinalf * (ao * sig + a2 * ssig * q2 + a4 * r2 * q4 + a6 * r3 * q6)
            let xz = dlon + s
            xy = abs(xz - ab)
            ab = dlon + s
            kcount += 1
            if kcount > 12 { break }
        } while xy >= tolerance1
        var az1 = dlon < 0 ? Double.pi * (3.0 / 2.0) : Double.pi / 2
        if abs(su1) >= tolerance0 || abs(su2) >= tolerance0 {
            let tana1 = slon * cu2 / (su2 * cu1 - clon * su1 * cu2)
            let sina1 = sinalf / cu1
            az1 = atan2(sina1, sina1 / tana1)
        }
        return degrees * convertAngleToHeading(castToAngleRange(az1))
    }

    /// core/GeoPoint2.cpp greatCircleBearing, degrees in (−180, 180].
    static func greatCircleBearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let rlat1 = lat1 / 180.0 * Double.pi, rlng1 = lon1 / 180.0 * Double.pi
        let rlat2 = lat2 / 180.0 * Double.pi, rlng2 = lon2 / 180.0 * Double.pi
        let rbrng = atan2(sin(rlng2 - rlng1) * cos(rlat2),
                          cos(rlat1) * sin(rlat2) - sin(rlat1) * cos(rlat2) * cos(rlng2 - rlng1))
        return rbrng / Double.pi * 180.0
    }

    /// core/ProjectionFactory3.cpp EcefWGS84.forward, height above the
    /// ellipsoid in metres.
    static func ecef(lat: Double, lon: Double, hae: Double) -> (x: Double, y: Double, z: Double) {
        let a = k.semiMajorAxis, b = k.semiMinorAxis
        let latRad = lat * (Double.pi / 180.0), lonRad = lon * (Double.pi / 180.0)
        let cosLat = cos(latRad), sinLat = sin(latRad), cosLon = cos(lonRad), sinLon = sin(lonRad)
        let a2b2 = (a * a) / (b * b), b2a2 = (b * b) / (a * a)
        let cden = (cosLat * cosLat + b2a2 * (sinLat * sinLat)).squareRoot()
        let lden = (a2b2 * (cosLat * cosLat) + sinLat * sinLat).squareRoot()
        return (((a / cden) + hae) * (cosLat * cosLon),
                ((a / cden) + hae) * (cosLat * sinLon),
                ((b / lden) + hae) * sinLat)
    }
}
