// PointEditorView.swift — editing points on the map (G3.9c), the Mac's
// stand-in for ATAK 5.5's radial menu and details drop-down:
//
// - a right-click (or control-click) on a CoT marker opens its menu:
//   Details, Send…, Range & Bearing from Here, Move, Delete…;
// - a click on one opens the inspector beside the map: name, affiliation,
//   colour (5.5's ColorPalette, when it has an icon set path), remarks,
//   where it is with its address (Look Up asks the chosen geocoder, as 5.5's
//   address pane does for a point), and the menu's actions as buttons;
// - Move shows a prompt at the top of the map; the next click places it.
//   A marker also drags to move;
// - Delete asks first, as 5.5's RemoveBroadcastReceiver does.
//
// What each edit changes is PointEditor's (MacTAKComms), which the tests
// drive.

import AppKit
import MacTAKComms
import MacTAKCot
import SwiftUI

/// What the menu or the inspector asked for that needs a sheet or an alert.
@MainActor
final class PointActions: ObservableObject {
    struct Target: Identifiable, Equatable {
        let id: String
    }

    @Published var sending: Target?
    @Published var deleting: Target?
    @Published var sendFailure: String?

    let editor: PointEditor
    let rangeBearing: RangeBearingLines

    init(editor: PointEditor, rangeBearing: RangeBearingLines) {
        self.editor = editor
        self.rangeBearing = rangeBearing
    }

    func details(_ uid: String) { editor.inspect(uid) }
    func send(_ uid: String) { sending = Target(id: uid) }
    func rangeBearing(from uid: String) { rangeBearing.beginTool(from: uid) }
    func move(_ uid: String) { editor.beginMove(uid) }
    func delete(_ uid: String) { deleting = Target(id: uid) }

    /// The marker's right-click menu.
    func menu(for uid: String) -> NSMenu? {
        guard editor.canEdit(uid) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("Details") { [weak self] in self?.details(uid) })
        menu.addItem(ActionItem("Send…") { [weak self] in self?.send(uid) })
        menu.addItem(ActionItem("Range & Bearing from Here") { [weak self] in self?.rangeBearing(from: uid) })
        let move = ActionItem("Move") { [weak self] in self?.move(uid) }
        move.isEnabled = editor.canMove(uid)
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Delete…") { [weak self] in self?.delete(uid) })
        return menu
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("no nib") }

    @objc private func fire() { run() }
}

struct PointInspector: View {
    @ObservedObject var editor: PointEditor
    @ObservedObject var markers: CotMarkerStore
    @ObservedObject var actions: PointActions
    @EnvironmentObject private var units: UnitPreferences
    @EnvironmentObject private var geocoders: GeocoderRegistry
    @State private var name = ""
    @State private var remarks = ""
    /// The point whose address is being looked up: a lookup belongs to
    /// its point, not to whichever the inspector shows when it ends.
    @State private var lookingUp: String?
    @State private var addressProblem: (uid: String, text: String)?

    var body: some View {
        if let uid = editor.inspected, let m = markers[uid] {
            form(uid, m)
                .onAppear { load(m) }
                .onChange(of: uid) { old, _ in
                    editor.rename(old, to: name)
                    load(m)
                }
                .onDisappear { editor.rename(uid, to: name) }
        } else {
            Text("No point selected").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(_ uid: String, _ m: CotMarker) -> some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit {
                        editor.rename(uid, to: name)
                        name = markers[uid]?.label ?? name
                    }
                if m.event.hasEditableAffiliation, let a = m.event.affiliation {
                    Picker("Affiliation", selection: Binding(get: { a }, set: { editor.setAffiliation(uid, $0) })) {
                        ForEach(PointKind.Affiliation.paletteOrder, id: \.self) { Text($0.name).tag($0) }
                    }
                }
                LabeledContent("Type", value: m.type)
                if m.traits.iconsetPath != nil {
                    LabeledContent("Colour") {
                        ColorSwatches(selected: m.traits.color) { editor.setColor(uid, $0) }
                    }
                }
            }
            Section("Location") {
                Text(units.position(m.point)).font(.body.monospacedDigit()).textSelection(.enabled)
                LabeledContent("Altitude", value: units.altitude(m.point))
                LabeledContent("Address") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let address = m.address { Text(address.text).textSelection(.enabled) }
                        Button(lookingUp == uid ? "Looking Up…" : "Look Up") { lookUpAddress(uid, at: m.point) }
                            .disabled(lookingUp == uid)
                    }
                }
                if let problem = addressProblem, problem.uid == uid {
                    Text(problem.text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Remarks") {
                TextEditor(text: $remarks)
                    .frame(minHeight: 80)
                    .onChange(of: remarks) { _, text in editor.setRemarks(uid, text) }
            }
            Section {
                Button("Send…") { actions.send(uid) }
                Button("Range & Bearing from Here") { actions.rangeBearing(from: uid) }
                Button("Move") { actions.move(uid) }.disabled(!m.movable)
                Button("Delete…", role: .destructive) { actions.delete(uid) }
            }
        }
        .formStyle(.grouped)
    }

    private func load(_ m: CotMarker) {
        name = m.label ?? ""
        remarks = m.remarks ?? ""
        addressProblem = nil
    }

    /// The address where the point is, kept if it hasn't moved meanwhile.
    private func lookUpAddress(_ uid: String, at p: CotPoint) {
        let geocoder = geocoders.selected
        lookingUp = uid
        addressProblem = nil
        Task {
            do {
                if let found = try await geocoder.address(lat: p.lat, lon: p.lon) {
                    let address = AddressDetail(text: found.address, geocoder: geocoder.title, time: Cot.time(Date()))
                    editor.setAddress(uid, address, lookedUpAt: p)
                } else {
                    addressProblem = (uid, "\(geocoder.title) has no address here.")
                }
            } catch {
                addressProblem = (uid, "\(geocoder.title): \(error)")
            }
            if lookingUp == uid { lookingUp = nil }
        }
    }
}

/// 5.5's ColorPalette as swatches; the chosen one is ringed.
struct ColorSwatches: View {
    let selected: UInt32?
    let choose: (UInt32) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 5), spacing: 4) {
            ForEach(PointColors.palette, id: \.self) { argb in
                Button { choose(argb) } label: {
                    RoundedRectangle(cornerRadius: 3).fill(Color(argb: argb))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(argb == selected ? Color.accentColor : .secondary,
                                    lineWidth: argb == selected ? 2 : 0.5))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The Move prompt with Cancel (Esc).
struct PointMovePrompt: View {
    @ObservedObject var editor: PointEditor

    var body: some View {
        if let prompt = editor.prompt {
            HStack(spacing: 12) {
                Text(prompt)
                Button("Cancel") { editor.endMove() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        }
    }
}

/// The sheets and alerts the point actions ask for.
struct PointActionPresenter: ViewModifier {
    @ObservedObject var actions: PointActions
    @ObservedObject var markers: CotMarkerStore
    let connections: ServerConnections

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sending) { target in
                SendItemSheet(title: markers[target.id]?.label ?? "the point", contacts: connections.contacts) { choice in
                    actions.sending = nil
                    switch choice {
                    case .everyone: send(target.id, to: nil)
                    case .contacts(let uids): send(target.id, to: uids)
                    case .cancel: break
                    }
                }
            }
            .alert("Remove \(actions.deleting.flatMap { markers[$0.id]?.label } ?? "the point")?",
                   isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                   presenting: actions.deleting) { target in
                Button("Remove", role: .destructive) { actions.editor.delete(target.id) }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Can't send the point",
                   isPresented: Binding(get: { actions.sendFailure != nil },
                                        set: { if !$0 { actions.sendFailure = nil } })) {
                Button("OK") { actions.sendFailure = nil }
            } message: {
                Text(actions.sendFailure ?? "")
            }
    }

    private func send(_ uid: String, to: [String]?) {
        do {
            try connections.share(marker: uid, to: to)
        } catch ServerConnections.ShareError.notRunning {
            actions.sendFailure = "Nothing is connected: start the mesh or a server."
        } catch {
            actions.sendFailure = "\(error)"
        }
    }
}
