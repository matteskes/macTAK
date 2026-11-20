// UnitPreferencesTests.swift — the Units settings under ATAK's keys, the
// self readout's text, and typed positions in any format (G3.6b). The
// strings themselves are CoordinateTests' (held to 5.5's own code).

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class UnitPreferencesTests: XCTestCase {
    static let geoid = try! Geoid(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/egm96-15.grid"))

    /// At 0,0 the geoid is 17.162 m above the ellipsoid (17.16200066 as the
    /// grid's float32).
    static let gulfOfGuinea = CotPoint(lat: 0, lon: 0, hae: 117.162, ce: 4.5, le: 3)

    func testATAKDefaults() {
        let units = UnitPreferences(settings: MemorySettings(), geoid: Self.geoid)
        XCTAssertEqual(units.coordinateFormat, .mgrs)
        XCTAssertEqual(units.altitudeReference, .msl)
        XCTAssertEqual(units.altitudeUnits, .feet)
        XCTAssertEqual(units.speedUnits, .milesPerHour)
        XCTAssertEqual(units.selfCoordAction, .panTo)
        XCTAssertEqual(units.selfCoordDisplay, .bottomRight)
    }

    func testChoicesPersistUnderATAKKeys() {
        let settings = MemorySettings()
        do {
            let units = UnitPreferences(settings: settings, geoid: nil)
            units.coordinateFormat = .dms
            units.altitudeReference = .hae
            units.altitudeUnits = .meters
            units.speedUnits = .knots
            units.selfCoordAction = .cycleCoordinate
        }
        XCTAssertEqual(settings.string(forKey: "coord_display_pref"), "DMS")
        XCTAssertEqual(settings.string(forKey: "alt_display_pref"), "HAE")
        XCTAssertEqual(settings.string(forKey: "alt_unit_pref"), "1")
        XCTAssertEqual(settings.string(forKey: "speed_unit_pref"), "2")
        XCTAssertEqual(settings.string(forKey: "self_coord_action"), "cyclecoordinate")
        let again = UnitPreferences(settings: settings, geoid: nil)
        XCTAssertEqual(again.coordinateFormat, .dms)
        XCTAssertEqual(again.altitudeReference, .hae)
        XCTAssertEqual(again.altitudeUnits, .meters)
        XCTAssertEqual(again.speedUnits, .knots)
        XCTAssertEqual(again.selfCoordAction, .cycleCoordinate)
    }

    func testWhatATAKWouldHaveWrittenReadsBack() {
        // a data package or device profile can carry ATAK's own values
        let settings = MemorySettings()
        settings.set("UTM", forKey: "coord_display_pref")
        settings.set("nonsense", forKey: "alt_display_pref")
        settings.set("9", forKey: "alt_unit_pref")
        let units = UnitPreferences(settings: settings, geoid: nil)
        XCTAssertEqual(units.coordinateFormat, .utm)
        XCTAssertEqual(units.altitudeReference, .msl)
        XCTAssertEqual(units.altitudeUnits, .feet)
    }

    func testSelfReadoutDisplayUnderATAKsKey() {
        let settings = MemorySettings()
        UnitPreferences(settings: settings, geoid: nil).selfCoordDisplay = .none
        XCTAssertEqual(settings.string(forKey: "self_coord_info_display"), "none")
        XCTAssertEqual(UnitPreferences(settings: settings, geoid: nil).selfCoordDisplay, .none)

        for stored in ["bottom_right", "bottom_bar", "nonsense"] {
            settings.set(stored, forKey: "self_coord_info_display")
            XCTAssertEqual(UnitPreferences(settings: settings, geoid: nil).selfCoordDisplay, .bottomRight, stored)
        }
    }

    func testAltitudeBothWays() throws {
        let units = UnitPreferences(settings: MemorySettings(), geoid: Self.geoid)
        let p = Self.gulfOfGuinea
        XCTAssertEqual(units.altitude(p), "328 ft MSL")
        XCTAssertEqual(try XCTUnwrap(units.typedAltitude(hae: p.hae, lat: 0, lng: 0)), 100 * Altitude.metersToFeet, accuracy: 1e-5)
        // 328 ft MSL typed back is 99.97 m MSL, 117.14 m HAE
        XCTAssertEqual(try XCTUnwrap(units.hae(fromTyped: 328, lat: 0, lng: 0)), 328 * 0.3048 + 17.162, accuracy: 1e-3)
        units.altitudeReference = .hae
        units.altitudeUnits = .meters
        XCTAssertEqual(units.altitude(p), "117 m HAE")
        XCTAssertEqual(units.hae(fromTyped: 50, lat: 0, lng: 0), 50)
        XCTAssertNil(units.typedAltitude(hae: CotPoint.unknown, lat: 0, lng: 0))
    }

    func testWithoutTheGeoidMSLIsUnknownNotHAE() {
        let units = UnitPreferences(settings: MemorySettings(), geoid: nil)
        XCTAssertEqual(units.altitude(Self.gulfOfGuinea), "-- ft MSL")
        XCTAssertNil(units.hae(fromTyped: 100, lat: 0, lng: 0))
        units.altitudeReference = .hae
        XCTAssertEqual(units.altitude(Self.gulfOfGuinea), "384 ft HAE")
    }

    func testTheReadoutAs55BuildsIt() {
        let units = UnitPreferences(settings: MemorySettings(), geoid: Self.geoid)
        let gps = SelfEvent.Location(point: Self.gulfOfGuinea, source: .provider)
        let r = SelfReadout(callsign: "VIPER", location: gps, track: Track(speed: 10, course: 0), units: units)
        XCTAssertEqual(r.source, "CoreLocation")
        XCTAssertTrue(r.sourceLive)
        XCTAssertEqual(r.callsign, "VIPER")
        XCTAssertEqual(r.location, "31N  AA  66021  00000")   // getFormattedString for MGRS
        XCTAssertEqual(r.altitude, "328 ft MSL")
        XCTAssertEqual(r.heading, "360°T")
        XCTAssertEqual(r.speed, "22 MPH")
        XCTAssertEqual(r.accuracy, "+/- 5m")

        units.coordinateFormat = .dd
        let placed = SelfEvent.Location(point: CotPoint(lat: 0, lon: 0), source: .manual)
        let p = SelfReadout(callsign: String(repeating: "X", count: 50), location: placed,
                            track: Track(speed: 0, course: 0), units: units)
        XCTAssertEqual(p.source, "NO GPS")
        XCTAssertFalse(p.sourceLive)
        XCTAssertEqual(p.callsign.count, 40)
        XCTAssertEqual(p.location, "N\u{200E} 0.00000°\u{200E} \u{200E} E\u{200E} 0.00000°")
        XCTAssertEqual(p.altitude, "--- ft MSL")
        XCTAssertEqual(p.accuracy, "+/- ---m")
    }

    func testTypedPositionsReadExactlyAs55() throws {
        // each format as macTAK writes it reads back
        for f in [CoordinateFormat.mgrs, .utm, .dd, .dm, .dms] {
            let text = Coordinates.format(lat: 38.8977, lng: -77.0365, as: f)
            let p = try XCTUnwrap(try TypedPosition.parse(text, as: f), f.rawValue)
            XCTAssertEqual(p.lat, 38.8977, accuracy: 1e-4, f.rawValue)
            XCTAssertEqual(p.lon, -77.0365, accuracy: 1e-4, f.rawValue)
        }
        XCTAssertEqual(try TypedPosition.parse("18S UJ 23487 06483", as: .mgrs)?.lat ?? 0, 38.88950, accuracy: 1e-5)
        // a smart dash from macOS's text substitution is a minus (trap 13)
        XCTAssertEqual(try TypedPosition.parse("38.8977, \u{2013}77.0365", as: .dd)?.lon, -77.0365)
        // no more forgiving than 5.5 (owner, 2026-11-17): plain spaces after W don't read
        XCTAssertNil(try TypedPosition.parse("N 38.89770° W 77.03650°", as: .dd))
        XCTAssertThrowsError(try TypedPosition.parse("91 0", as: .dd)) { error in
            XCTAssertEqual((error as? CoordinateError)?.description, "Latitude out of range. Enter a valid Latitude.")
        }
        XCTAssertThrowsError(try TypedPosition.parse("18S", as: .mgrs)) { error in
            XCTAssertEqual((error as? CoordinateError)?.malformed, true)
        }
    }
}
