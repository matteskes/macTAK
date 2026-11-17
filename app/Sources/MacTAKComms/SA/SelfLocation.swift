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
