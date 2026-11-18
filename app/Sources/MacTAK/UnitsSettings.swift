// UnitsSettings.swift — the Settings window's Units pane (G3.6b): ATAK
// 5.5's Display Preferences › Units and its self coordinate preference.
// Each choice is saved at once under ATAK's key (UnitPreferences).

import MacTAKComms
import SwiftUI

struct UnitsSettings: View {
    @EnvironmentObject private var units: UnitPreferences

    /// The formats the app offers: 5.5's, less ADDR (no geocoder yet).
    static let formats: [CoordinateFormat] = [.mgrs, .dd, .dm, .dms, .utm]

    var body: some View {
        Form {
            Picker("Coordinate format", selection: $units.coordinateFormat) {
                ForEach(Self.formats, id: \.self) { f in
                    Text("\(f.displayName) — \(f.fullName)").tag(f)
                }
            }
            LabeledContent("Example") {
                Text(Coordinates.format(lat: 38.8977, lng: -77.0365, as: units.coordinateFormat))
                    .textSelection(.enabled)
            }
            Picker("Altitude reference", selection: $units.altitudeReference) {
                Text("MSL — above mean sea level").tag(AltitudeReference.msl)
                Text("HAE — above the WGS84 ellipsoid").tag(AltitudeReference.hae)
            }
            if units.geoid == nil && units.altitudeReference == .msl {
                Text("The geoid isn't in this build, so altitudes in MSL show unknown.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Altitude units", selection: $units.altitudeUnits) {
                Text("Feet").tag(AltitudeUnits.feet)
                Text("Meters").tag(AltitudeUnits.meters)
            }
            Picker("Speed units", selection: $units.speedUnits) {
                Text("Miles per hour").tag(SpeedUnits.milesPerHour)
                Text("Kilometers per hour").tag(SpeedUnits.kilometersPerHour)
                Text("Knots").tag(SpeedUnits.knots)
                Text("Meters per second").tag(SpeedUnits.metersPerSecond)
            }
            Picker("Tapping my coordinates", selection: $units.selfCoordAction) {
                Text("Pans to me").tag(UnitPreferences.SelfCoordAction.panTo)
                Text("Changes the coordinate format").tag(UnitPreferences.SelfCoordAction.cycleCoordinate)
                Text("Does nothing").tag(UnitPreferences.SelfCoordAction.nothing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
