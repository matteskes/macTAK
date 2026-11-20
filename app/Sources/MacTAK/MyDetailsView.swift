// MyDetailsView.swift — the My Details sheet (G3.4c).
//
// What this client tells its team about itself, as ATAK's "My Preferences"
// has it: callsign, team, role and 5.5's custom role, unit type, remarks;
// where it is (CoreLocation, a placed position, or both); and how often it
// reports (ReportingRate's strategy and rates). Edits are a draft until
// Save, which applies them to SelfDetails and SelfReporter at once: a
// changed callsign, team or role goes out on the next tick.
//
// A placed position is typed in any of 5.5's formats (G3.6b), read exactly
// as 5.5's CoordinateFormatUtilities reads it (owner, 2026-11-17), and its
// altitude in the Units settings' reference and units. What was placed
// shows in that format; left as shown, it is kept as it was rather than
// re-read (MGRS and UTM floor to the metre).
//
// ADDR (5.5's AddrPane): an address typed and found with the selected
// geocoder places this client there; switching to ADDR with a position
// looks up its address, as 5.5 does when the pane opens. The address is
// kept with the placed position while it stays put.
//
// Saving a new placed position that this client now reports pans the map
// to it, so a place found by address is on screen.

import MacTAKComms
import SwiftUI

struct MyDetailsSheet: View {
    @ObservedObject var details: SelfDetails
    @ObservedObject var me: SelfReporter
    @ObservedObject var units: UnitPreferences
    @ObservedObject var geocoders: GeocoderRegistry
    @EnvironmentObject private var host: EngineHost
    @Environment(\.dismiss) private var dismiss

    @State private var callsign = ""
    @State private var team = "Cyan"
    @State private var role = GroupDetail.defaultRole
    @State private var customRole = ""
    @State private var customRoleAbbreviation = ""
    @State private var useTypeIcon = false
    @State private var unitType = SelfEvent.defaultType
    @State private var remarks = ""
    @State private var mode = LocationMode.both
    @State private var entryFormat = CoordinateFormat.mgrs
    @State private var position = ""
    @State private var altitude = ""
    /// What load() showed, so an untouched field keeps the placed point.
    @State private var shownPosition = ""
    @State private var shownAltitude = ""
    /// ADDR: the address typed, what it was found as, and what load() showed.
    @State private var address = ""
    @State private var shownAddress = ""
    @State private var found: (point: CotPoint, detail: AddressDetail)?
    @State private var looking = false
    @State private var lookupProblem: String?
    @State private var reporting = ReportingRate.Settings.atak
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Callsign", text: $callsign)
                Picker("Team", selection: $team) {
                    ForEach(GroupDetail.teams, id: \.self) { t in
                        Label { Text(t) } icon: { TeamDot(team: t, stale: false) }.tag(t)
                    }
                }
                Picker("Role", selection: $role) {
                    ForEach(SelfDetails.roles, id: \.self) { Text($0).tag($0) }
                }
                TextField("Custom role", text: $customRole, prompt: Text("optional, e.g. Combat Lifesaver"))
                TextField("Abbreviation", text: $customRoleAbbreviation, prompt: Text("optional, e.g. CLS"))
                Toggle("Show my unit type's symbol instead of the role", isOn: $useTypeIcon)
                // ATAK picks it from the 2525 type tree (CoTSelector); that
                // browser comes with the symbols (G3.7)
                TextField("Unit type (CoT)", text: $unitType, prompt: Text(SelfEvent.defaultType))
                    .help("A friendly atom's CoT type, a-f-…; ATAK's default is a-f-G-U-C")
                TextField("Remarks", text: $remarks, axis: .vertical).lineLimit(1...3)
            }
            Section("Location") {
                Picker("Source", selection: $mode) {
                    Text("CoreLocation, else placed").tag(LocationMode.both)
                    Text("CoreLocation only").tag(LocationMode.device)
                    Text("Placed by hand only").tag(LocationMode.manual)
                }
                if let locator = me.locator, mode != .manual {
                    LocatorStatus(locator: locator, units: units)
                }
                Picker("Format", selection: $entryFormat) {
                    ForEach(UnitsSettings.formats, id: \.self) { Text($0.fullName).tag($0) }
                }
                .onChange(of: entryFormat) { old, new in reformat(from: old, to: new) }
                if entryFormat == .address {
                    HStack {
                        TextField("My address", text: $address,
                                  prompt: Text("1600 Pennsylvania Ave NW, Washington, DC"))
                            .onSubmit(find)
                        Button("Find", action: find)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || looking)
                    }
                    addressStatus
                } else {
                    TextField("My position", text: $position, prompt: Text(example))
                }
                TextField("Altitude (\(units.altitudeLabel))", text: $altitude, prompt: Text("optional"))
                if placedProblem != nil {
                    Text(placedProblem ?? "").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Reporting") {
                Picker("Strategy", selection: $reporting.strategy) {
                    Text("Dynamic (by speed)").tag(ReportingRate.Strategy.dynamic)
                    Text("Constant").tag(ReportingRate.Strategy.constant)
                }
                if reporting.strategy == .constant {
                    seconds("Mesh, every", $reporting.constantUnreliable)
                    seconds("Servers, every", $reporting.constantReliable)
                } else {
                    seconds("Mesh, standing still", $reporting.dynamicStationaryUnreliable)
                    seconds("Servers, standing still", $reporting.dynamicStationaryReliable)
                }
            }
            HStack {
                Button("ATAK Defaults") {
                    reporting = .atak
                    unitType = SelfEvent.defaultType
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func seconds(_ label: String, _ value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never)).help("seconds")
    }

    /// What the address field has found, or why not, and who looks it up.
    @ViewBuilder private var addressStatus: some View {
        let via = "Looked up with \(geocoders.selected.title), which receives the address or position."
        if looking {
            HStack { ProgressView().controlSize(.small); Text("Looking up…").font(.caption) }
        } else if let lookupProblem {
            Text(lookupProblem).font(.caption).foregroundStyle(.orange)
        } else if let point = addressPoint {
            Text("At \(Coordinates.format(lat: point.lat, lng: point.lon, as: .dd)). \(via)")
                .font(.caption).foregroundStyle(.secondary)
        } else if address.isEmpty, me.placed != nil {
            HStack {
                Text("No address for your placed position.").font(.caption).foregroundStyle(.secondary)
                Button("Look Up") { if let p = me.placed { lookUpAddress(of: p) } }.controlSize(.small)
            }
        } else {
            Text(via).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Where the address field places this client: what Find found for
    /// the text as it is, or the placed position when the text is untouched.
    private var addressPoint: CotPoint? {
        if let found, found.detail.text == address { return found.point }
        if address == shownAddress, !address.isEmpty { return me.placed }
        return nil
    }

    /// AddrPane's search: the typed address, near where this client is.
    private func find() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !looking else { return }
        let here = me.location?.point ?? me.placed
        lookUp { geocoder in
            guard let r = try await geocoder.locate(text, near: here.map { GeoBox.around(lat: $0.lat, lon: $0.lon) })
            else { return nil }
            return (CotPoint(lat: r.lat, lon: r.lon), r.address)
        } notFound: { "Couldn't find “\(text)” with \($0)" }
    }

    /// AddrPane with no text: the address of a position, which stays put.
    private func lookUpAddress(of p: CotPoint) {
        lookUp { geocoder in
            try await geocoder.address(lat: p.lat, lon: p.lon).map { (p, $0.address) }
        } notFound: { "\($0) has no address at \(Coordinates.format(lat: p.lat, lng: p.lon, as: .dd))" }
    }

    private func lookUp(_ query: @escaping (any Geocoder) async throws -> (CotPoint, String)?,
                        notFound: @escaping (String) -> String) {
        let geocoder = geocoders.selected
        looking = true
        lookupProblem = nil
        Task {
            do {
                if let (point, text) = try await query(geocoder) {
                    found = (point, AddressDetail(text: text, geocoder: geocoder.title, time: Cot.time(Date())))
                    address = text
                } else {
                    lookupProblem = notFound(geocoder.title)
                }
            } catch {
                lookupProblem = "\(geocoder.title): \(error)"
            }
            looking = false
        }
    }

    /// Where a position typed in the format would be: 5.5's own example.
    private var example: String {
        Coordinates.format(lat: 38.8977, lng: -77.0365, as: entryFormat)
            .replacingOccurrences(of: "\u{200E}", with: "")
    }

    /// The placed point, or why there isn't one: .success(nil) when
    /// nothing is typed.
    private var placed: Result<CotPoint?, PlacedError> {
        let byAddress = entryFormat == .address
        let text = (byAddress ? address : position).trimmingCharacters(in: .whitespaces)
        let typedAltitude = altitude.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return typedAltitude.isEmpty ? .success(nil) : .failure(.init("Type a position for the altitude"))
        }
        let untouched = byAddress ? addressPoint == me.placed && me.placed != nil : position == shownPosition
        var p: CotPoint
        if untouched, let kept = me.placed {
            p = kept
        } else if byAddress {
            guard let point = addressPoint else {
                return .failure(.init(looking ? "Looking up “\(text)”…" : "Find “\(text)” to place yourself there"))
            }
            p = point
        } else {
            do {
                guard let read = try TypedPosition.parse(text, as: entryFormat) else {
                    return .failure(.init(unread(text)))
                }
                p = read
            } catch let e as CoordinateError where !e.malformed && !e.description.isEmpty {
                return .failure(.init(e.description))
            } catch {
                return .failure(.init(unread(text)))
            }
        }
        if altitude == shownAltitude, untouched, let kept = me.placed {
            p.hae = kept.hae
        } else if typedAltitude.isEmpty {
            p.hae = CotPoint.unknown
        } else {
            let minus = typedAltitude.replacingOccurrences(of: "\u{2212}", with: "-")
            guard let value = Double(minus) else { return .failure(.init("Couldn't read “\(typedAltitude)” as an altitude")) }
            guard let height = units.hae(fromTyped: value, lat: p.lat, lng: p.lon) else {
                return .failure(.init("Without the geoid an altitude in MSL can't be placed; set Units to HAE"))
            }
            p.hae = height
        }
        return .success(p)
    }

    struct PlacedError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// What the field holds, character codes included, so a substituted
    /// character shows (G3.4c: smart dashes).
    private func unread(_ text: String) -> String {
        let codes = text.unicodeScalars.filter { $0.value > 0x7E && $0 != "°" && $0 != "\u{200E}" }
            .map { String(format: "U+%04X", $0.value) }
        let shown = "“\(text)”" + (codes.isEmpty ? "" : " (non-ASCII: \(codes.joined(separator: " ")))")
        return "Couldn't read \(shown) as \(entryFormat.displayName), written as macTAK writes it (e.g. \(example))"
    }

    private var placedProblem: String? {
        switch placed {
        case let .failure(e): return e.message
        case .success(nil) where mode == .manual: return "Place yourself, or pick a source with CoreLocation"
        case .success: return nil
        }
    }

    /// Shows what's typed in the new format, when it reads in the old one.
    private func reformat(from old: CoordinateFormat, to new: CoordinateFormat) {
        let p: CotPoint?
        let wasShown: Bool
        if old == .address {
            p = addressPoint
            wasShown = p != nil && p == me.placed
        } else {
            let text = position.trimmingCharacters(in: .whitespaces)
            wasShown = position == shownPosition && me.placed != nil
            p = text.isEmpty ? nil : wasShown ? me.placed : (try? TypedPosition.parse(text, as: old)) ?? nil
        }
        guard let p else { return }
        if new == .address {
            lookupProblem = nil
            if let kept = me.addressOfPlaced, p == me.placed {
                address = kept.text
                shownAddress = address
            } else if let found, found.point == p {
                address = found.detail.text
            } else {
                address = ""
                lookUpAddress(of: p)
            }
        } else {
            position = Coordinates.format(lat: p.lat, lng: p.lon, as: new)
            if wasShown { shownPosition = position }
        }
    }

    private var valid: Bool {
        let rates = [reporting.constantUnreliable, reporting.constantReliable,
                     reporting.dynamicStationaryUnreliable, reporting.dynamicStationaryReliable]
        return !callsign.trimmingCharacters(in: .whitespaces).isEmpty && placedProblem == nil
            && rates.allSatisfy { $0 > 0 } && unitType.trimmingCharacters(in: .whitespaces).hasPrefix("a-")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        callsign = details.callsign
        team = details.team
        role = details.role
        customRole = details.customRole
        customRoleAbbreviation = details.customRoleAbbreviation
        useTypeIcon = details.useTypeIcon
        unitType = details.unitType
        remarks = details.remarks
        reporting = details.reporting
        mode = me.mode
        entryFormat = units.coordinateFormat
        address = me.addressOfPlaced?.text ?? ""
        shownAddress = address
        if let p = me.placed {
            position = Coordinates.format(lat: p.lat, lng: p.lon, as: entryFormat == .address ? .dd : entryFormat)
            altitude = units.typedAltitude(hae: p.hae, lat: p.lat, lng: p.lon)
                .map { String(format: "%.0f", $0) } ?? ""
        }
        shownPosition = position
        shownAltitude = altitude
    }

    /// The address that goes with a placed point: what was found for it,
    /// or what it had, while it is where the address was looked up.
    private func addressFor(_ p: CotPoint?) -> AddressDetail? {
        guard let p else { return nil }
        let at = AddressDetail.locationHash(lat: p.lat, lon: p.lon)
        if let found, AddressDetail.locationHash(lat: found.point.lat, lon: found.point.lon) == at {
            return found.detail
        }
        guard let placed = me.placed, AddressDetail.locationHash(lat: placed.lat, lon: placed.lon) == at else {
            return nil
        }
        return me.addressOfPlaced
    }

    private func save() {
        details.callsign = callsign.trimmingCharacters(in: .whitespaces)
        details.team = team
        details.role = role
        details.customRole = customRole.trimmingCharacters(in: .whitespaces)
        details.customRoleAbbreviation = customRoleAbbreviation.trimmingCharacters(in: .whitespaces)
        details.useTypeIcon = useTypeIcon
        details.unitType = unitType.trimmingCharacters(in: .whitespaces)
        details.remarks = remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        details.reporting = reporting
        let before = me.placed
        if case let .success(p) = placed { me.place(p, address: addressFor(p)) }
        me.mode = mode
        // On the new place, if it is where this client now says it is.
        if let p = me.placed, p != before, let now = me.location, now.source == .manual {
            host.panTo(lat: now.point.lat, lon: now.point.lon)
        }
    }
}

private struct LocatorStatus: View {
    @ObservedObject var locator: LocationService
    @ObservedObject var units: UnitPreferences

    var body: some View {
        switch locator.status {
        case .off, .waiting:
            Text("CoreLocation: waiting for a fix…").font(.caption).foregroundStyle(.secondary)
        case .located:
            Text("CoreLocation: \(locator.fix.map { units.position($0.point) } ?? "located")")
                .font(.caption).foregroundStyle(.secondary)
        case .denied:
            Text("CoreLocation is off for macTAK: allow it in System Settings › Privacy & Security › Location Services, or place yourself.")
                .font(.caption).foregroundStyle(.orange)
        case let .failed(why):
            Text("CoreLocation: \(why)").font(.caption).foregroundStyle(.orange)
        }
    }
}
