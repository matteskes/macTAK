// SelfLocation.swift — where this client says it is (G3.4b).
//
// ATAK takes its position from a location provider (GPS) and lets the user
// place themselves by hand ("set my location"); with no provider fix, a
// placed self is reported with how h-e. Here the provider is CoreLocation,
// and the mode (a macTAK setting) picks:
//   device  CoreLocation only
//   manual  the placed position only
//   both    CoreLocation while it has a fix, else the placed position
//           (the default: most Macs have a fix from Wi-Fi, and a desktop
//           without one can still be placed).
// A Mac that stands still may get one fix and no more, so a fix counts until
// CoreLocation fails or is denied, not until it ages.

import CoreLocation
import Foundation
import IOKit.ps

public enum LocationMode: String, Sendable, CaseIterable, Codable {
    case device, manual, both
}

/// A provider's fix: where, and how it is moving.
public struct LocationFix: Sendable, Equatable {
    public var point: CotPoint
    /// m/s; NaN when unknown.
    public var speed: Double
    /// degrees true; NaN when unknown.
    public var course: Double

    public init(point: CotPoint, speed: Double = .nan, course: Double = .nan) {
        self.point = point; self.speed = speed; self.course = course
    }

    /// CoreLocation's reading, as a CoT point: HAE from the ellipsoidal
    /// altitude (CoT's altitude is HAE; CLLocation.altitude is MSL), and
    /// unknown errors where CoreLocation says invalid (negative).
    public init(_ location: CLLocation) {
        let verticalKnown = location.verticalAccuracy >= 0
        self.init(point: CotPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                                  hae: verticalKnown ? location.ellipsoidalAltitude : CotPoint.unknown,
                                  ce: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : CotPoint.unknown,
                                  le: verticalKnown ? location.verticalAccuracy : CotPoint.unknown),
                  speed: location.speed >= 0 ? location.speed : .nan,
                  course: location.course >= 0 ? location.course : .nan)
    }
}

/// A position as typed.
///
/// - `parse(_:as:)` (G3.6b, My Details): any of 5.5's formats, read exactly
///   as 5.5's CoordinateFormatUtilities.convert reads it (owner, 2026-11-17:
///   no more forgiving than 5.5 for now). Only macOS's own substitutions are
///   undone first: a smart dash or typographic minus is a minus (trap 13).
/// - `parse(_:)` (G3.4c): "lat, lon" or "lat, lon, hae" in decimal degrees,
///   how SelfReporter stores a placed position.
public enum TypedPosition {
    /// U+2010…2015 (hyphens, figure dash, en and em dash), U+2212 (minus),
    /// U+FE63 and U+FF0D (small and full-width hyphen-minus).
    static let dashes: Set<Unicode.Scalar> = ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}",
                                             "\u{2015}", "\u{2212}", "\u{FE63}", "\u{FF0D}"]

    public static func parse(_ text: String, as format: CoordinateFormat) throws -> CotPoint? {
        let undashed = String(String.UnicodeScalarView(text.unicodeScalars.map { dashes.contains($0) ? "-" : $0 }))
        guard let p = try Coordinates.parse(undashed, as: format) else { return nil }
        return CotPoint(lat: p.lat, lon: p.lng)
    }

    public static func parse(_ text: String) -> CotPoint? {
        let normalized = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            // macOS's smart dashes, a typographic minus, full-width forms:
            // all read as a minus sign; a degree sign as a space
            if dashes.contains(scalar) { return "-" }
            if scalar == "°" || scalar == "\u{00A0}" { return " " }
            return scalar
        }))
        let tokens = normalized.split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init)
        var numbers: [Double] = []
        for token in tokens {
            let upper = token.uppercased()
            if ["N", "E"].contains(upper), !numbers.isEmpty { continue }
            if ["S", "W"].contains(upper), let last = numbers.popLast() { numbers.append(-abs(last)); continue }
            if let hemisphere = upper.last, "NSEW".contains(hemisphere), let v = Double(upper.dropLast()) {
                numbers.append("SW".contains(hemisphere) ? -abs(v) : abs(v))
                continue
            }
            guard let v = Double(token) else { return nil }
            numbers.append(v)
        }
        guard numbers.count == 2 || numbers.count == 3 else { return nil }
        let p = CotPoint(lat: numbers[0], lon: numbers[1], hae: numbers.count == 3 ? numbers[2] : CotPoint.unknown)
        return p.isValid ? p : nil
    }
}

public enum SelfLocation {
    /// What the self-SA reports: its location (nil when there is none) and
    /// track. A placed position isn't moving.
    public static func choose(mode: LocationMode, fix: LocationFix?, placed: CotPoint?)
        -> (location: SelfEvent.Location?, track: Track) {
        let still = Track(speed: 0, course: 0)
        switch (mode, fix, placed) {
        case let (.device, fix?, _), let (.both, fix?, _):
            return (.init(point: fix.point, source: .provider), Track(speed: fix.speed, course: fix.course))
        case let (.manual, _, placed?), let (.both, nil, placed?):
            return (.init(point: placed, source: .manual), still)
        default:
            return (nil, still)
        }
    }

    /// The battery's charge in percent, 100 on a Mac without one (ATAK's
    /// status battery).
    public static func batteryPercent() -> Int {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return 100 }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = d[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }
            return max(0, min(100, current * 100 / capacity))
        }
        return 100
    }
}

/// CoreLocation's fixes, while the mode wants them.
@MainActor
public final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public enum Status: Equatable, Sendable {
        case off, waiting, denied, located, failed(String)
    }

    @Published public private(set) var fix: LocationFix?
    @Published public private(set) var status: Status = .off
    public var onFix: (@MainActor (LocationFix?) -> Void)?

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Asks for permission the first time, then follows the location.
    public func start() {
        status = .waiting
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
        status = .off
        update(nil)
    }

    private func update(_ fix: LocationFix?) {
        self.fix = fix
        onFix?(fix)
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let fix = LocationFix(last)
        MainActor.assumeIsolated {
            status = .located
            update(fix)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        // kCLErrorLocationUnknown is transient: keep the last fix.
        if code == .locationUnknown { return }
        let reason = error.localizedDescription
        MainActor.assumeIsolated {
            status = code == .denied ? .denied : .failed(reason)
            update(nil)
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state = manager.authorizationStatus
        MainActor.assumeIsolated {
            if state == .denied || state == .restricted {
                status = .denied
                update(nil)
            }
        }
    }
}
