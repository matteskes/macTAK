// SelfReadout.swift — the text of the self readout over the map (G3.6b),
// as 5.5's SelfCoordOverlayUpdater builds it:
//
//   CoreLocation                 the location source (5.5's provider), or
//   Callsign: VIPER              NO GPS in red when nothing provides one
//   18S  UJ  23487  06483        the position in the chosen format
//   245 ft MSL       123°T       altitude, heading (true north)
//   3 MPH            +/- 5m      speed (speed_unit_pref), accuracy
//
// With no location at all, 5.5 shows only its NO GPS message (`noFix`).

import Foundation

public struct SelfReadout: Equatable, Sendable {
    /// "CoreLocation", or "NO GPS" when no provider gives the position.
    public var source: String
    /// The source is a live provider (5.5's green), not NO GPS (red).
    public var sourceLive: Bool
    public var callsign: String
    public var location: String
    public var altitude: String
    public var heading: String
    public var speed: String
    public var accuracy: String

    @MainActor
    public init(callsign: String, location: SelfEvent.Location, track: Track, units: UnitPreferences) {
        let p = location.point
        sourceLive = location.source == .provider
        source = sourceLive ? "CoreLocation" : "NO GPS"
        // 5.5 cuts a callsign at 40 characters (ATAK-8010)
        self.callsign = String(callsign.prefix(40))
        self.location = units.readoutPosition(p)
        altitude = Altitude.isValid(p.hae) ? units.altitude(p) : "--- ft MSL"
        heading = Motion.heading(track.course)
        speed = units.speedUnits.format(track.speed)
        accuracy = Motion.accuracy(p.ce == CotPoint.unknown ? .nan : p.ce)
    }
}
