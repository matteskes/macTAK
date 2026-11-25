// RouteEditorView.swift — the route tool's controls and the route details
// (G3.10c), the Mac's stand-in for ATAK 5.5's route toolbar, radial menus
// and RoutePlannerView:
//
// - a toolbar button starts the tool on a new route, or ends it;
// - while it runs, the prompt shows at the top of the map with Undo (⌘Z)
//   and Done (Esc);
// - a right-click on a waypoint, on a control point while its route is
//   edited, or on a route's line opens its menu: Route Details, Edit
//   Route, and while editing the point's or line's own changes; the line's
//   also shows the name on the map, sends and deletes;
// - a click on a waypoint or a line opens the inspector: the route's
//   name, method, direction, type and order, its line, its waypoints with
//   the distance and climb of each leg and the totals, its remarks.
//
// What each change does is RouteEditor's (MacTAKComms), which the tests
// drive; MapMarkerSync draws the routes.

import AppKit
import MacTAKComms
import MacTAKCot
import SwiftUI

struct RouteToolButton: View {
    @ObservedObject var editor: RouteEditor
    let mapRunning: Bool

    var body: some View {
        Button {
            if editor.editing == nil { editor.begin() } else { editor.end() }
        } label: {
            Label("Route", systemImage: editor.editing == nil
                ? "point.topleft.down.to.point.bottomright.curvepath"
                : "point.topleft.down.to.point.bottomright.curvepath.fill")
        }
        .disabled(!mapRunning)
        .help(editor.editing == nil ? "Route: click the map to draw a new route" : "End editing the route")
    }
}

struct RoutePrompt: View {
    @ObservedObject var editor: RouteEditor

    var body: some View {
        if let prompt = editor.prompt {
            HStack(spacing: 12) {
                Text(prompt)
                Button("Undo") { editor.undo() }
                    .keyboardShortcut("z")
                    .disabled(!editor.canUndo)
                Button("Done") { editor.end() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        }
    }
}

/// What the menus or the inspector asked for that needs a sheet or an alert.
@MainActor
final class RouteActions: ObservableObject {
    struct Target: Identifiable, Equatable {
        let id: String
    }

    struct Renaming: Identifiable, Equatable {
        let route: String
        let point: String
        var id: String { point }
    }

    @Published var sending: Target?
    @Published var deleting: Target?
    @Published var renaming: Renaming?
    @Published var sendFailure: String?

    let editor: RouteEditor
    let routes: Routes

    init(editor: RouteEditor, routes: Routes) {
        self.editor = editor
        self.routes = routes
    }

    /// A waypoint's menu (b-m-p-w; waypoint_edit and route_corner_menu
    /// while its route is edited), or a control point's while edited.
    func pointMenu(for uid: String) -> NSMenu? {
        guard let route = editor.route(withPoint: uid), let i = route.index(of: uid) else { return nil }
        let editing = editor.editing == route.id
        if !editing && !route.points[i].isWaypoint { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("Route Details") { [weak self] in self?.editor.inspect(route.id) })
        guard editing else {
            menu.addItem(ActionItem("Edit Route") { [weak self] in self?.editor.edit(route.id) })
            return menu
        }
        menu.addItem(.separator())
        if route.points[i].isWaypoint {
            menu.addItem(ActionItem("Rename…") { [weak self] in self?.renaming = Renaming(route: route.id, point: uid) })
            let make = ActionItem("Make Control Point") { [weak self] in self?.editor.makeControlPoint(uid) }
            make.isEnabled = i != 0 && i != route.points.count - 1
            menu.addItem(make)
        } else {
            menu.addItem(ActionItem("Make Checkpoint") { [weak self] in self?.editor.makeWaypoint(uid) })
        }
        menu.addItem(ActionItem("Delete Point") { [weak self] in self?.editor.deletePoint(uid) })
        return menu
    }

    /// A route line's menu: b-m-r's, with route_line_menu's inserts while
    /// it is edited.
    func lineMenu(for hit: RouteHit) -> NSMenu? {
        guard let route = routes[hit.route] else { return nil }
        let editing = editor.editing == route.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        if editing {
            menu.addItem(ActionItem("Insert Checkpoint Here") { [weak self] in self?.editor.insert(hit, waypoint: true) })
            menu.addItem(ActionItem("Insert Point Here") { [weak self] in self?.editor.insert(hit, waypoint: false) })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Route Details") { [weak self] in self?.editor.inspect(route.id) })
        if !editing {
            menu.addItem(ActionItem("Edit Route") { [weak self] in self?.editor.edit(route.id) })
        }
        let label = ActionItem("Show Name on Map") { [weak self] in self?.editor.toggleLabels(route.id) }
        label.state = route.labelsOn ? .on : .off
        menu.addItem(label)
        menu.addItem(ActionItem("Send…") { [weak self] in self?.sending = Target(id: route.id) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Delete Route…") { [weak self] in self?.deleting = Target(id: route.id) })
        return menu
    }
}

struct RouteInspector: View {
    @ObservedObject var editor: RouteEditor
    @ObservedObject var routes: Routes
    @ObservedObject var actions: RouteActions
    @EnvironmentObject private var units: UnitPreferences
    @State private var name = ""
    @State private var remarks = ""

    var body: some View {
        if let id = editor.inspected, let route = routes[id] {
            form(route)
                .onAppear { load(route) }
                .onChange(of: id) { old, _ in
                    rename(old)
                    load(route)
                }
                .onDisappear { rename(id) }
        } else {
            Text("No route selected").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(_ route: Route) -> some View {
        let id = route.id
        return Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit {
                        rename(id)
                        name = routes[id]?.title ?? name
                    }
                Picker("Method", selection: binding(id, route.method) { $0.setMethod($1) }) {
                    ForEach(Route.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Direction", selection: binding(id, route.direction) { $0.setDirection($1) }) {
                    ForEach(Route.Direction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Type", selection: binding(id, route.kind) { $0.kind = $1 }) {
                    ForEach(Route.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Order", selection: binding(id, route.order) { r, o in r.order = o; r.nameWaypoints() }) {
                    ForEach(Route.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show Name on Map", isOn: binding(id, route.labelsOn) { $0.labelsOn = $1 })
            }
            Section("Line") {
                LabeledContent("Colour") {
                    ColorSwatches(selected: UInt32(bitPattern: route.color)) { argb in
                        editor.update(id) { $0.color = Int32(bitPattern: argb) }
                    }
                }
                Picker("Style", selection: binding(id, route.strokeStyle) { $0.strokeStyle = $1 }) {
                    ForEach(Array(Self.lineStyles.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }
                LabeledContent("Weight") {
                    HStack {
                        Slider(value: binding(id, route.strokeWeight) { $0.strokeWeight = $1 }, in: 1...Self.maxWeight, step: 0.5)
                        Text(route.strokeWeight.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                }
            }
            waypoints(route)
            Section("Remarks") {
                TextEditor(text: $remarks)
                    .frame(minHeight: 60)
                    .onChange(of: remarks) { _, text in
                        editor.update(id) { $0.remarks = text.isEmpty ? nil : text }
                    }
            }
            Section {
                if editor.editing == id {
                    Button("Done Editing") { editor.end() }
                } else {
                    Button("Edit Route") { editor.edit(id) }
                }
                Button("Send…") { actions.sending = .init(id: id) }
                Button("Delete Route…", role: .destructive) { actions.deleting = .init(id: id) }
            }
        }
        .formStyle(.grouped)
    }

    /// RoutePlannerView's totals and waypoint list.
    private func waypoints(_ route: Route) -> some View {
        let details = RouteDetails(route)
        let editing = editor.editing == route.id
        return Section("Checkpoints") {
            LabeledContent("Distance", value: RouteDetails.totalText(details.totalMeters, method: route.method,
                                                                     units: units.rangeUnits,
                                                                     thresholds: units.rangeThresholds))
            LabeledContent("Elevation Gain", value: RouteDetails.gainText(details.totalGain))
            ForEach(details.rows, id: \.uid) { row in
                HStack {
                    Text(row.name)
                    Spacer()
                    Text(RouteDetails.legText(row.meters, method: route.method, units: units.rangeUnits))
                        .monospacedDigit()
                    Text(RouteDetails.gainText(row.gain))
                        .monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 56, alignment: .trailing)
                }
                .contextMenu {
                    Button("Rename…") { actions.renaming = .init(route: route.id, point: row.uid) }
                    if editing, row.uid != details.rows.first?.uid, row.uid != details.rows.last?.uid {
                        Button("Make Control Point") { editor.makeControlPoint(row.uid) }
                    }
                }
            }
        }
    }

    /// 5.5's line_styles.
    static let lineStyles = ["Solid", "Dashed", "Dotted", "Outlined"]
    /// RoutePlannerView.ROUTE_MAX_STROKE_WEIGHT.
    static let maxWeight = 24.0

    private func binding<T>(_ id: String, _ value: T, _ set: @escaping (inout Route, T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: { new in editor.update(id) { set(&$0, new) } })
    }

    private func load(_ route: Route) {
        name = route.title
        remarks = route.remarks ?? ""
    }

    /// updateName: a changed, non-empty name is the route's title.
    private func rename(_ id: String) {
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        editor.update(id) { $0.title = title; $0.nameWaypoints() }
    }
}

/// The sheets and alerts the route actions ask for.
struct RouteActionPresenter: ViewModifier {
    @ObservedObject var actions: RouteActions
    @ObservedObject var routes: Routes
    let connections: ServerConnections
    @State private var newName = ""

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sending) { target in
                SendItemSheet(title: routes[target.id]?.title ?? "the route", contacts: connections.contacts) { choice in
                    actions.sending = nil
                    switch choice {
                    case .everyone: send(target.id, to: nil)
                    case .contacts(let uids): send(target.id, to: uids)
                    case .cancel: break
                    }
                }
            }
            .alert("Delete route: \(actions.deleting.flatMap { routes[$0.id]?.title } ?? "")?",
                   isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                   presenting: actions.deleting) { target in
                Button("Delete", role: .destructive) { actions.editor.delete(target.id) }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Rename", isPresented: Binding(get: { actions.renaming != nil },
                                                  set: { if !$0 { actions.renaming = nil } }),
                   presenting: actions.renaming) { target in
                TextField("Name", text: $newName)
                Button("Done") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { actions.editor.update(target.route) { $0.renamePoint(target.point, to: name) } }
                }
                Button("Cancel", role: .cancel) { }
            }
            .onChange(of: actions.renaming) { _, target in
                newName = target.flatMap { t in routes[t.route]?.points.first { $0.uid == t.point }?.callsign } ?? ""
            }
            .alert("Can't send the route",
                   isPresented: Binding(get: { actions.sendFailure != nil },
                                        set: { if !$0 { actions.sendFailure = nil } })) {
                Button("OK") { actions.sendFailure = nil }
            } message: {
                Text(actions.sendFailure ?? "")
            }
    }

    private func send(_ id: String, to: [String]?) {
        do {
            try connections.share(route: id, to: to)
        } catch ServerConnections.ShareError.notRunning {
            actions.sendFailure = "Nothing is connected: start the mesh or a server."
        } catch {
            actions.sendFailure = "\(error)"
        }
    }
}
