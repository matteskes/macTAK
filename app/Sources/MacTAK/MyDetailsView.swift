// MyDetailsView.swift — the My Details sheet (G3.4c).
//
// What this client tells its team about itself, as ATAK's "My Preferences"
// has it: callsign, team, role and 5.5's custom role, unit type, remarks;
// where it is (CoreLocation, a placed position, or both); and how often it
// reports (ReportingRate's strategy and rates). Edits are a draft until
// Save, which applies them to SelfDetails and SelfReporter at once: a
// changed callsign, team or role goes out on the next tick.

import MacTAKComms
import SwiftUI

struct MyDetailsSheet: View {
    @ObservedObject var details: SelfDetails
    @ObservedObject var me: SelfReporter
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
    @State private var position = ""
    @State private var hae = ""
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
                    LocatorStatus(locator: locator)
                }
                TextField("My position", text: $position, prompt: Text("lat, lon, e.g. 51.5007, -0.1246"))
                TextField("Altitude HAE (m)", text: $hae, prompt: Text("optional"))
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

    /// .some(nil) when no position is given, nil when what's typed isn't one.
    private var placed: CotPoint?? {
        let text = position.trimmingCharacters(in: .whitespaces)
        let h = hae.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return h.isEmpty ? .some(nil) : nil }
        guard var p = TypedPosition.parse(text) else { return nil }
        if !h.isEmpty {
            guard let height = Double(h.replacingOccurrences(of: "\u{2212}", with: "-")) else { return nil }
            p.hae = height
        }
        return .some(p)
    }

    private var placedProblem: String? {
        if placed == nil {
            // what the field holds, character codes included, so a substituted
            // character shows (G3.4c: smart dashes)
            let codes = position.unicodeScalars.filter { $0.value > 0x7E }
                .map { String(format: "U+%04X", $0.value) }
            let shown = "“\(position)”" + (codes.isEmpty ? "" : " (non-ASCII: \(codes.joined(separator: " ")))")
            return "Couldn't read \(shown) as lat, lon in decimal degrees (−90…90, −180…180); altitude in metres"
        }
        if mode == .manual, case .some(nil) = placed { return "Place yourself, or pick a source with CoreLocation" }
        return nil
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
        if let p = me.placed {
            position = "\(p.lat), \(p.lon)"
            hae = p.hae == CotPoint.unknown ? "" : "\(p.hae)"
        }
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
        if case let .some(p) = placed { me.placed = p }
        me.mode = mode
    }
}

private struct LocatorStatus: View {
    @ObservedObject var locator: LocationService

    var body: some View {
        switch locator.status {
        case .off, .waiting:
            Text("CoreLocation: waiting for a fix…").font(.caption).foregroundStyle(.secondary)
        case .located:
            Text("CoreLocation: \(locator.fix.map { Coordinates.text($0.point) } ?? "located")")
                .font(.caption).foregroundStyle(.secondary)
        case .denied:
            Text("CoreLocation is off for macTAK: allow it in System Settings › Privacy & Security › Location Services, or place yourself.")
                .font(.caption).foregroundStyle(.orange)
        case let .failed(why):
            Text("CoreLocation: \(why)").font(.caption).foregroundStyle(.orange)
        }
    }
}
