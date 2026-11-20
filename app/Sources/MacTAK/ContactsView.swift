// ContactsView.swift — the sidebar's Contacts section (G3.4c).
//
// "Me" first (callsign, team, where the self-SA says this Mac is, and a
// button to the My Details sheet), then every TAK user heard on a server or
// the mesh: team colour, callsign, role, how long ago, greyed once stale as
// ATAK greys a stale contact. A row's popover has the rest. The work happens
// in ContactStore and SelfReporter (MacTAKComms), which the tests drive.
// Positions and altitudes show as the Units settings say (G3.6b).

import MacTAKComms
import SwiftUI

struct ContactsSection: View {
    @EnvironmentObject private var connections: ServerConnections
    @EnvironmentObject private var me: SelfReporter
    @EnvironmentObject private var units: UnitPreferences
    @EnvironmentObject private var geocoders: GeocoderRegistry
    @State private var editing = false

    var body: some View {
        Section {
            MeRow(details: me.details, units: units, location: me.location) { editing = true }
            ContactRows(store: connections.contacts, servers: connections.servers, units: units, me: me)
        } header: {
            Text("Contacts")
        }
        .sheet(isPresented: $editing) { MyDetailsSheet(details: me.details, me: me, units: units, geocoders: geocoders) }
    }
}

private struct MeRow: View {
    @ObservedObject var details: SelfDetails
    @ObservedObject var units: UnitPreferences
    let location: SelfEvent.Location?
    let edit: () -> Void

    var body: some View {
        HStack {
            TeamDot(team: details.team, stale: false)
            VStack(alignment: .leading) {
                Text("\(details.callsign) (me)")
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(action: edit) { Image(systemName: "person.crop.circle") }
                .buttonStyle(.borderless)
                .help("My Details")
        }
    }

    private var summary: String {
        let role = details.customRoleAbbreviation.isEmpty ? details.role : details.customRoleAbbreviation
        guard let location else { return "\(role) · no location" }
        let source = location.source == .provider ? "CoreLocation" : "placed"
        let p = location.point
        let altitude = Altitude.isValid(p.hae) ? " · \(units.altitude(p))" : ""
        return "\(role) · \(units.position(p))\(altitude) · \(source)"
    }
}

private struct ContactRows: View {
    @ObservedObject var store: ContactStore
    let servers: [ServerConfig]
    let units: UnitPreferences
    let me: SelfReporter

    var body: some View {
        if store.contacts.isEmpty {
            Text("No one heard yet").foregroundStyle(.secondary)
        }
        // ages and stale states move with the clock, not with new SA
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            ForEach(store.contacts) { contact in
                ContactRow(contact: contact, now: timeline.date, servers: servers, units: units, me: me)
            }
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    let now: Date
    let servers: [ServerConfig]
    let units: UnitPreferences
    let me: SelfReporter
    @State private var showing = false

    var body: some View {
        let stale = contact.isStale(at: now)
        HStack {
            TeamDot(team: contact.group?.team, stale: stale)
            VStack(alignment: .leading) {
                Text(contact.callsign).foregroundStyle(stale ? .secondary : .primary)
                Text(detail(stale: stale)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showing = true }
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            ContactDetails(contact: contact, servers: servers, units: units, me: me).padding().frame(width: 340)
        }
    }

    private func detail(stale: Bool) -> String {
        let parts = [contact.roleLabel, Ago.text(from: contact.lastHeard, to: now), stale ? "stale" : nil]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ContactDetails: View {
    let contact: Contact
    let servers: [ServerConfig]
    @ObservedObject var units: UnitPreferences
    @ObservedObject var me: SelfReporter

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 4) {
            row("Callsign", contact.callsign)
            row("Team", contact.group?.team ?? "—")
            row("Role", role)
            row("Position", contact.point == .zero ? "unknown" : units.position(contact.point))
            if contact.point != .zero { row("Altitude", units.altitude(contact.point)) }
            if let address = contact.address { row("Address", "\(address.text) (\(address.geocoder))") }
            if contact.point != .zero, let here = me.location?.point {
                // 5.5's range and bearing from me (RangeAndBearingTableHandler)
                // Each line has its own label: an empty one has no height in
                // a Grid, and its row drew over the one above.
                let t = RangeBearing(from: here, to: contact.point)
                    .table(magnetic: units.magnetic, thresholds: units.rangeThresholds)
                let (preferred, others) = switch units.rangeUnits {
                case .metersKilometers: (t.metersKilometers, [t.feetMiles, t.nauticalMiles])
                case .feetMiles: (t.feetMiles, [t.metersKilometers, t.nauticalMiles])
                case .nauticalMiles: (t.nauticalMiles, [t.metersKilometers, t.feetMiles])
                }
                row("Range", preferred)
                row("Also", others.joined(separator: "   "))
                row("Bearing", [t.magneticDegrees, t.trueDegrees].compactMap { $0 }.joined(separator: "   ")
                    + "   (\(t.cardinal))")
                row("In mils", [t.magneticMils, t.trueMils].compactMap { $0 }.joined(separator: "   "))
            }
            row("Source", source)
            if let track = contact.track, track.speed > 0 {
                row("Moving", String(format: "%.1f m/s, %.0f°", track.speed, track.course))
            }
            if let battery = contact.battery { row("Battery", "\(battery)%") }
            row("Heard via", heard)
            if let takv = contact.takv {
                row("Client", "\(takv.platform) \(takv.version) · \(takv.device), \(takv.os)")
            }
            row("UID", contact.uid)
        }
        .textSelection(.enabled)
    }

    private var role: String {
        guard let g = contact.group else { return "—" }
        guard let custom = g.customRole else { return g.role }
        return "\(custom)\(g.customRoleAbbreviation.map { " (\($0))" } ?? "") · \(g.role)"
    }

    /// how, and precisionlocation's source.
    private var source: String {
        let how = switch contact.how {
        case "m-g": "GPS"
        case "h-e": "placed by hand"
        case "h-g-i-g-o": "no fix"
        default: contact.how
        }
        guard let src = contact.precision?.geopointSource else { return how }
        return "\(how) (\(src))"
    }

    private var heard: String {
        contact.paths.map { path in
            switch path {
            case .mesh: "mesh"
            case let .server(id): servers.first { $0.id == id }?.description ?? "a server"
            }
        }.sorted().joined(separator: ", ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }
}

struct TeamDot: View {
    let team: String?
    let stale: Bool

    var body: some View {
        Circle().fill(stale ? .gray : Self.color(team)).frame(width: 10, height: 10)
            .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 0.5))
    }

    /// ATAK's team colours, exactly as the map's markers use them
    /// (MarkerIcons.teamColor); no team is grey here.
    static func color(_ team: String?) -> Color {
        guard let team else { return .gray }
        let argb = MarkerIcons.teamColor(team)
        return Color(red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                     blue: Double(argb & 0xFF) / 255)
    }
}

enum Ago {
    static func text(from then: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(then)))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}
