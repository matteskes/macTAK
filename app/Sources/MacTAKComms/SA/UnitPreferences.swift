// UnitPreferences.swift — how positions and altitudes show (G3.6b), under
// ATAK 5.5's own preference keys (UnitPreferences, self_coordinate.xml):
//
//   coord_display_pref  MGRS (default), DD, DM, DMS, UTM (ADDR reads as DD)
//   alt_display_pref    MSL (default) or HAE
//   alt_unit_pref       "0" feet (Span.ENGLISH, default) or "1" metres
//   speed_unit_pref     "0" MPH (default), "1" km/h, "2" knots, "3" m/s
//   self_coord_action   what a tap on the self readout does: panto
//                       (default), cyclecoordinate or nothing
//   self_coord_info_display  whether the self readout shows: bottom_right
//                       (default) or none (5.5's bottom_bar reads as
//                       bottom_right: the app has no bottom bar)
//
// Range and bearing (G3.8a), 5.5's Units › Range & Bearing:
//   rab_north_ref_pref     "0" true, "1" magnetic (default), "2" grid
//   rab_brg_units_pref     "0" degrees (default) or "1" mils
//   rab_rng_units_pref     "0" ft/mi, "1" m/km (default), "2" NM
//   rab_dist_slant_range   "clamped" (default, ground range) or "slantrange"
//   rng_feet_display_pref  feet shown up to this, then miles (5280)
//   rng_meters_display_pref  metres shown up to this, then km (2000)
//
// The geoid turns HAE into MSL. It comes from the app bundle; without it
// (a broken bundle) MSL shows unknown rather than an HAE passed off as MSL.

import Combine
import Foundation

@MainActor
public final class UnitPreferences: ObservableObject {
    @Published public var coordinateFormat: CoordinateFormat {
        didSet { settings.set(coordinateFormat.displayName, forKey: Key.coordinateFormat) }
    }
    @Published public var altitudeReference: AltitudeReference {
        didSet { settings.set(altitudeReference.rawValue, forKey: Key.altitudeReference) }
    }
    @Published public var altitudeUnits: AltitudeUnits {
        didSet { settings.set(String(altitudeUnits.rawValue), forKey: Key.altitudeUnits) }
    }
    @Published public var speedUnits: SpeedUnits {
        didSet { settings.set(String(speedUnits.rawValue), forKey: Key.speedUnits) }
    }
    @Published public var selfCoordAction: SelfCoordAction {
        didSet { settings.set(selfCoordAction.rawValue, forKey: Key.selfCoordAction) }
    }
    @Published public var selfCoordDisplay: SelfCoordDisplay {
        didSet { settings.set(selfCoordDisplay.rawValue, forKey: Key.selfCoordDisplay) }
    }

    @Published public var northReference: NorthReference {
        didSet { settings.set(String(northReference.rawValue), forKey: Key.northReference) }
    }
    @Published public var bearingUnits: BearingUnits {
        didSet { settings.set(String(bearingUnits.rawValue), forKey: Key.bearingUnits) }
    }
    @Published public var rangeUnits: RangeUnits {
        didSet { settings.set(String(rangeUnits.rawValue), forKey: Key.rangeUnits) }
    }
    @Published public var slantRange: Bool {
        didSet { settings.set(slantRange ? "slantrange" : "clamped", forKey: Key.slantRange) }
    }
    @Published public var rangeThresholds: RangeBearingText.Thresholds {
        didSet {
            settings.set(String(rangeThresholds.feetToMiles), forKey: Key.feetThreshold)
            settings.set(String(rangeThresholds.metersToKilometers), forKey: Key.metersThreshold)
        }
    }

    public let geoid: Geoid?
    /// Magnetic north (5.5's wmm_cof); without it bearings from magnetic
    /// north show unknown.
    public let magnetic: MagneticModel?
    private let settings: SettingsStore

    /// 5.5's tap_selfoverlay_values.
    public enum SelfCoordAction: String, CaseIterable, Sendable {
        case panTo = "panto"
        case cycleCoordinate = "cyclecoordinate"
        case nothing = "nothing"
    }

    /// 5.5's self_coord_display_values, less bottom_bar.
    public enum SelfCoordDisplay: String, CaseIterable, Sendable {
        case bottomRight = "bottom_right"
        case none = "none"

        /// Anything but none shows the readout, as the box: the app has
        /// no bottom bar.
        init(stored: String?) { self = stored == Self.none.rawValue ? .none : .bottomRight }
    }

    enum Key {
        static let coordinateFormat = "coord_display_pref", altitudeReference = "alt_display_pref"
        static let altitudeUnits = "alt_unit_pref", selfCoordAction = "self_coord_action"
        static let speedUnits = "speed_unit_pref", selfCoordDisplay = "self_coord_info_display"
        static let northReference = "rab_north_ref_pref", bearingUnits = "rab_brg_units_pref"
        static let rangeUnits = "rab_rng_units_pref", slantRange = "rab_dist_slant_range"
        static let feetThreshold = "rng_feet_display_pref", metersThreshold = "rng_meters_display_pref"
    }

    public init(settings: SettingsStore, geoid: Geoid?, magnetic: MagneticModel? = nil) {
        self.settings = settings
        self.geoid = geoid
        self.magnetic = magnetic
        func number(_ key: String) -> Int? { settings.string(forKey: key).flatMap { Int($0) } }
        northReference = number(Key.northReference).flatMap(NorthReference.init(rawValue:)) ?? .magnetic
        bearingUnits = number(Key.bearingUnits).flatMap(BearingUnits.init(rawValue:)) ?? .degrees
        rangeUnits = number(Key.rangeUnits).flatMap(RangeUnits.init(rawValue:)) ?? .metersKilometers
        slantRange = settings.string(forKey: Key.slantRange) == "slantrange"
        rangeThresholds = RangeBearingText.Thresholds(feetToMiles: number(Key.feetThreshold) ?? 5280,
                                                      metersToKilometers: number(Key.metersThreshold) ?? 2000)
        coordinateFormat = CoordinateFormat(displayName: settings.string(forKey: Key.coordinateFormat))
        altitudeReference = settings.string(forKey: Key.altitudeReference).flatMap(AltitudeReference.init(rawValue:))
            ?? .default
        altitudeUnits = settings.string(forKey: Key.altitudeUnits).flatMap(Int.init).flatMap(AltitudeUnits.init(rawValue:))
            ?? .default
        speedUnits = settings.string(forKey: Key.speedUnits).flatMap(Int.init).flatMap(SpeedUnits.init(rawValue:))
            ?? .milesPerHour
        selfCoordAction = settings.string(forKey: Key.selfCoordAction).flatMap(SelfCoordAction.init(rawValue:))
            ?? .panTo
        selfCoordDisplay = SelfCoordDisplay(stored: settings.string(forKey: Key.selfCoordDisplay))
    }

    /// How the R&B preferences say to write a range and bearing.
    public var rangeBearingStyle: RangeBearing.Style {
        RangeBearing.Style(north: northReference, bearingUnits: bearingUnits, rangeUnits: rangeUnits,
                           slantRange: slantRange, thresholds: rangeThresholds)
    }

    /// The app's magnetic model: 5.5's wmm_cof in the bundle's Resources.
    public static func bundledMagneticModel(_ bundle: Bundle = .main) -> MagneticModel? {
        guard let url = bundle.url(forResource: "wmm_cof", withExtension: nil) else {
            NSLog("macTAK: wmm_cof isn't in the bundle; bearings from magnetic north show unknown")
            return nil
        }
        do {
            return try MagneticModel(contentsOf: url)
        } catch {
            NSLog("macTAK: \(error); bearings from magnetic north show unknown")
            return nil
        }
    }

    /// The app's geoid: egm96-15.grid in the bundle's Resources.
    public static func bundledGeoid(_ bundle: Bundle = .main) -> Geoid? {
        guard let url = bundle.url(forResource: "egm96-15", withExtension: "grid") else {
            NSLog("macTAK: egm96-15.grid isn't in the bundle; altitudes in MSL show unknown")
            return nil
        }
        do {
            return try Geoid(contentsOf: url)
        } catch {
            NSLog("macTAK: \(error); altitudes in MSL show unknown")
            return nil
        }
    }

    /// A position in the chosen format (formatToString).
    public func position(_ p: CotPoint) -> String {
        Coordinates.format(lat: p.lat, lng: p.lon, as: coordinateFormat)
    }

    /// A position as 5.5's self readout writes it: MGRS with double spaces
    /// (getFormattedString), the other formats as formatToString.
    public func readoutPosition(_ p: CotPoint) -> String {
        coordinateFormat == .mgrs ? MGRSPoint(lat: p.lat, lng: p.lon).formattedString : position(p)
    }

    /// A point's altitude in the chosen reference and units.
    public func altitude(_ p: CotPoint) -> String {
        Altitude.format(hae: p.hae, lat: p.lat, lng: p.lon, reference: altitudeReference,
                               units: altitudeUnits, geoid: geoid)
    }

    /// What an altitude typed in the chosen reference and units is in HAE
    /// metres, at (lat, lng); nil when MSL can't be turned into HAE.
    public func hae(fromTyped value: Double, lat: Double, lng: Double) -> Double? {
        let metres = altitudeUnits == .feet ? value * Altitude.feetToMeters : value
        switch altitudeReference {
        case .hae: return metres
        case .msl: return geoid?.offset(lat: lat, lng: lng).map { metres + $0 }
        }
    }

    /// An HAE altitude in the chosen reference and units, as a number to
    /// edit; nil when unknown.
    public func typedAltitude(hae: Double, lat: Double, lng: Double) -> Double? {
        guard Altitude.isValid(hae) else { return nil }
        var metres = hae
        if altitudeReference == .msl {
            guard let offset = geoid?.offset(lat: lat, lng: lng) else { return nil }
            metres -= offset
        }
        return altitudeUnits == .feet ? metres * Altitude.metersToFeet : metres
    }

    /// "ft MSL", "m HAE": the units a typed altitude is in.
    public var altitudeLabel: String { altitudeUnits.abbreviation + " " + altitudeReference.rawValue }
}
