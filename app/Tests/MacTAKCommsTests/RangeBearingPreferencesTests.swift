// G3.8a: the R&B preferences under 5.5's keys and defaults.

import XCTest
@testable import MacTAKComms

@MainActor
final class RangeBearingPreferencesTests: XCTestCase {
    func testDefaultsAre5_5s() {
        let units = UnitPreferences(settings: MemorySettings(), geoid: nil)
        XCTAssertEqual(units.rangeBearingStyle, .atak)
        XCTAssertEqual(units.northReference, .magnetic)
        XCTAssertEqual(units.bearingUnits, .degrees)
        XCTAssertEqual(units.rangeUnits, .metersKilometers)
        XCTAssertFalse(units.slantRange)
        XCTAssertEqual(units.rangeThresholds, RangeBearingText.Thresholds(feetToMiles: 5280, metersToKilometers: 2000))
    }

    func testChoicesAreKeptUnder5_5sKeys() {
        let settings = MemorySettings()
        let units = UnitPreferences(settings: settings, geoid: nil)
        units.northReference = .grid
        units.bearingUnits = .mils
        units.rangeUnits = .nauticalMiles
        units.slantRange = true
        units.rangeThresholds = RangeBearingText.Thresholds(feetToMiles: 1000, metersToKilometers: 500)
        XCTAssertEqual(["rab_north_ref_pref", "rab_brg_units_pref", "rab_rng_units_pref", "rab_dist_slant_range",
                        "rng_feet_display_pref", "rng_meters_display_pref"].map { settings.string(forKey: $0) },
                       ["2", "1", "2", "slantrange", "1000", "500"])
        let reopened = UnitPreferences(settings: settings, geoid: nil)
        XCTAssertEqual(reopened.rangeBearingStyle, units.rangeBearingStyle)
    }

    func testAProfilesValuesRead() {
        // what a device profile or data package from ATAK carries
        let settings = MemorySettings()
        settings.set("0", forKey: "rab_north_ref_pref")
        settings.set("0", forKey: "rab_rng_units_pref")
        settings.set("clamped", forKey: "rab_dist_slant_range")
        settings.set("bogus", forKey: "rab_brg_units_pref")
        let units = UnitPreferences(settings: settings, geoid: nil)
        XCTAssertEqual(units.northReference, .true)
        XCTAssertEqual(units.rangeUnits, .feetMiles)
        XCTAssertFalse(units.slantRange)
        XCTAssertEqual(units.bearingUnits, .degrees, "unreadable: the default")
    }

    func testTheBundledModelIsFoundOrSaysSo() {
        XCTAssertNil(UnitPreferences.bundledMagneticModel(Bundle(for: Self.self)), "no wmm_cof in the test bundle")
    }
}
