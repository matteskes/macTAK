// SelfReadoutView.swift — the self readout in the map's lower right
// (G3.6b), as 5.5's SelfCoordOverlayUpdater draws it: the source (green,
// or NO GPS in red), the callsign, the position in the chosen format, the
// altitude and heading, the speed and accuracy, in cyan. A click does what
// the Units settings say: pan to me (5.5's default), change the format
// (DD → DM → DMS → UTM → MGRS), or nothing. With no location at all, only
// NO GPS shows, as in 5.5. Settings › Units can hide it (5.5's
// self_coord_info_display).

import MacTAKComms
import SwiftUI

struct SelfReadoutView: View {
    @ObservedObject var me: SelfReporter
    @ObservedObject var details: SelfDetails
    @ObservedObject var units: UnitPreferences
    let host: EngineHost

    var body: some View {
        Group {
            if let location = me.location {
                let r = SelfReadout(callsign: details.callsign, location: location, track: me.track, units: units)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.source).foregroundStyle(r.sourceLive ? .green : .red)
                    Text("Callsign: \(r.callsign)")
                    Text(r.location)
                    pair(r.altitude, r.heading)
                    pair(r.speed, r.accuracy)
                }
                .foregroundStyle(.cyan)
                .fixedSize()        // one box sized to its text: pair's Spacer would stretch it across the map
                .contentShape(Rectangle())
                .onTapGesture { tapped(location.point) }
                .help(help)
            } else {
                Text("NO GPS").foregroundStyle(.red)
                    .help("No location: allow CoreLocation, or place yourself in My Details")
            }
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }

    private func pair(_ left: String, _ right: String) -> some View {
        HStack(spacing: 16) {
            Text(left)
            Spacer(minLength: 0)
            Text(right)
        }
    }

    private var help: String {
        switch units.selfCoordAction {
        case .panTo: "Click to pan the map to you"
        case .cycleCoordinate: "Click to change the coordinate format"
        case .nothing: ""
        }
    }

    private func tapped(_ point: CotPoint) {
        switch units.selfCoordAction {
        case .panTo: host.panTo(lat: point.lat, lon: point.lon)
        case .cycleCoordinate: units.coordinateFormat = units.coordinateFormat.next
        case .nothing: break
        }
    }
}
