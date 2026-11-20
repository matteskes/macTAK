// MagneticModel.swift — magnetic north, as ATAK 5.5 turns a true bearing
// into a magnetic one (G3.8a).
//
// 5.5: GeoCalculations.convertFromTrueToMagnetic(point, angle) takes the
// declination at the point at sea level now (GeomagneticField with the
// latitude and longitude cast to float, height 0f, the date from a
// java.util.Calendar in the default time zone), and subtracts it, wrapping
// into [0, 360). The declination comes back as a float. The model is NOAA's
// library over 5.5's wmm_cof (CMagnetic).

import CMagnetic
import Foundation

public final class MagneticModel: @unchecked Sendable {
    private let wmm: OpaquePointer

    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Reads a WMM coefficient file (5.5's wmm_cof).
    public init(contentsOf url: URL) throws {
        guard let wmm = mactak_wmm_open(url.path) else {
            throw LoadError(description: "can't read the magnetic model \(url.lastPathComponent)")
        }
        self.wmm = wmm
    }

    deinit { mactak_wmm_close(wmm) }

    /// The engine's GeomagneticField_getDeclination: degrees east of true
    /// north, for a day as Calendar gives it (month 0–11); nil for a date
    /// the engine refuses.
    public func declination(lat: Double, lon: Double, hae: Double, year: Int, month: Int, day: Int) -> Double? {
        var value = 0.0
        guard mactak_wmm_declination(wmm, lat, lon, hae, Int32(year), Int32(month), Int32(day), &value) == 0 else {
            return nil
        }
        return value
    }

    /// GeoCalculations.magneticDeclination(point, datetime): float
    /// latitude and longitude, height 0, the float the JNI returns.
    public func declination(lat: Double, lon: Double, at date: Date, timeZone: TimeZone = .current) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = d.year, let month = d.month, let day = d.day,
              let value = declination(lat: Double(Float(lat)), lon: Double(Float(lon)), hae: Double(Float(0)),
                                      year: year, month: month - 1, day: day)
        else { return nil }
        return Double(Float(value))
    }

    /// GeoCalculations.convertFromTrueToMagnetic: the bearing from magnetic
    /// north, [0, 360); nil without a declination.
    public func magnetic(fromTrue bearing: Double, lat: Double, lon: Double, at date: Date,
                         timeZone: TimeZone = .current) -> Double? {
        guard let dec = declination(lat: lat, lon: lon, at: date, timeZone: timeZone) else { return nil }
        let mag = bearing - dec
        if mag >= 360 { return mag - 360 }
        if mag < 0 { return mag + 360 }
        return mag
    }
}
