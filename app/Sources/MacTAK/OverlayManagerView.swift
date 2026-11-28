// OverlayManagerView.swift — the Overlay Manager (G3.11b): 5.5's hierarchy
// pane as a section of the map's sidebar, a tree of the map's items by kind
// (OverlayTree, G3.11a). What 5.5 does, and how it shows here:
//
// - the bar (HierarchyListReceiver): search over the titles, the two sorts
//   (Alphabetical, Distance from you or else the map's centre), the
//   filters (Show All, off keeping only what is on screen, kept in the
//   `fov_filter` setting; Self-Authored), and Multi-Select, whose one action
//   here is Delete (decided with the plan; Export waits for import/export);
// - a row (HierarchyListAdapter.getView): its visibility (an eye: shown,
//   partly shown for a list, hidden), its icon in its colour, its title
//   ("[Untitled Item]" when empty, this device's callsign for its uid),
//   and under it a list's count, or an item's position and its range,
//   bearing and altitude from you (adaptLocationItem); a route's first
//   point instead (RouteListModel.getDescription). The selected item's row
//   is green (0x8000AF4F);
// - a click (HierarchyListItemClickListener): a list opens (5.5 pushes it;
//   here it expands in place); an item is gone to (GoTo: the map fits it
//   and focuses a point) and selected, shown if hidden, and a second click
//   unselects it; selecting opens what 5.5's radial and details do here, a
//   point's inspector. A route's click opens its actions (Details, Send,
//   Edit, Delete) under it, shows it and goes to it, unselected
//   (RouteListItem.onClick);
// - a right-click opens the item's actions, as its radial would on the map;
// - Multi-Select checks rows (a list checks all of it), then Delete asks
//   ("Are you sure?", 5.5's delete_items_confirmation) and deletes them.
//
// What each action does to the items is OverlayManager's (MacTAKComms),
// which the tests drive; the map leaves hidden items off (MapMarkerSync).

import AppKit
import Combine
import MacTAKComms
import MacTAKCore
import MacTAKCot
import SwiftUI

@MainActor
final class OverlayManagerModel: ObservableObject {
    enum SortChoice: String, CaseIterable, Identifiable {
        case alphabetical = "Alphabetical", distance = "Distance"
        var id: String { rawValue }
    }

    /// FOVFilter.PREF: true keeps only what is on screen ("Show All" off).
    static let fovFilterKey = "fov_filter"

    @Published var search = "" { didSet { refresh() } }
    @Published var sort = SortChoice.alphabetical { didSet { refresh() } }
    @Published var showAll: Bool {
        didSet {
            settings.set(!showAll, forKey: Self.fovFilterKey)
            refresh()
        }
    }
    @Published var selfAuthored = false { didSet { refresh() } }
    @Published var multiSelect = false { didSet { if !multiSelect { checked = [] } } }
    /// The rows checked in Multi-Select, by node id.
    @Published var checked: Set<String> = []
    /// The lists open, by node id.
    @Published var expanded: Set<String> = []
    /// The item selected (highlighted), by uid.
    @Published private(set) var selected: String?
    /// The route whose actions show.
    @Published private(set) var routeActionsOpen: String?
    @Published var confirmingDelete = false
    @Published var sendingLine: RangeBearingLine?
    @Published var sendFailure: String?
    /// The tree as last built: the lists, or a search's results.
    @Published private(set) var rows: [OverlayTree.Node] = []

    let connections: ServerConnections
    let overlays: OverlayManager
    let host: EngineHost
    let units: UnitPreferences
    let pointActions: PointActions
    let routeActions: RouteActions
    private let settings: UserDefaults
    private let icon: (String) -> MarkerIcon?
    private var watches: [AnyCancellable] = []
    private var timer: Timer?
    private var refreshPending = false

    init(connections: ServerConnections, host: EngineHost, units: UnitPreferences, settings: UserDefaults,
         pointActions: PointActions, routeActions: RouteActions, icon: @escaping (String) -> MarkerIcon?) {
        self.connections = connections
        overlays = connections.overlays
        self.host = host
        self.units = units
        self.settings = settings
        self.pointActions = pointActions
        self.routeActions = routeActions
        self.icon = icon
        showAll = !settings.bool(forKey: Self.fovFilterKey)
        watches = [connections.items.changed.sink { [weak self] in self?.refresh() }]
            + [overlays.objectWillChange, connections.pointEditor.objectWillChange]
            .map { $0.sink { [weak self] _ in self?.scheduleRefresh() } }
        // the view moves and things move: the filter and the distances follow (onMapMoved)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - building

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        let view = host.viewState
        var filters = OverlayTree.Filters()
        if !showAll, let v = view { filters.fieldOfView = Self.fieldOfView(v) }
        if selfAuthored { filters.author = connections.uid }
        let tree = OverlayTree.build(overlays.items(), filters: filters, sort: treeSort(view))
        let next = search.isEmpty ? tree : OverlayTree.search(search, in: tree, sort: treeSort(view))
        if next != rows { rows = next }
        if let s = selected, !Self.contains(tree, uid: s) { selected = nil }
    }

    private func treeSort(_ view: EngineBridge.ViewState?) -> OverlayTree.Sort {
        switch sort {
        case .alphabetical: return .alphabetical
        case .distance: return reference(view).map { .distance(from: $0) } ?? .alphabetical
        }
    }

    /// HierarchyListAdapter.getCurrentLocation: you, else the map's centre.
    private func reference(_ view: EngineBridge.ViewState?) -> CotPoint? {
        if let me = connections.me.location { return me.point }
        guard let c = view?.center, c.lat.isFinite, c.lon.isFinite else { return nil }
        return CotPoint(lat: c.lat, lon: c.lon)
    }

    var reference: CotPoint? { reference(host.viewState) }

    static func fieldOfView(_ v: EngineBridge.ViewState) -> FieldOfView {
        func p(_ c: (lat: Double, lon: Double)) -> CotPoint { CotPoint(lat: c.lat, lon: c.lon) }
        return FieldOfView(upperLeft: p(v.upperLeft), upperRight: p(v.upperRight), lowerRight: p(v.lowerRight),
                           lowerLeft: p(v.lowerLeft), center: p(v.center), continuousScroll: v.continuousScroll)
    }

    private static func contains(_ nodes: [OverlayTree.Node], uid: String) -> Bool {
        nodes.contains { $0.uid == uid && !$0.isList || contains($0.children ?? [], uid: uid) }
    }

    // MARK: - a row

    /// The row's title as HierarchyListAdapter writes it.
    func title(_ node: OverlayTree.Node) -> String {
        let t = node.title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "[Untitled Item]" }
        return t == connections.uid ? connections.callsign : t
    }

    /// The item's icon: a marker's as the map draws it, a line's and a
    /// route's 5.5 drawables in their colour; a list's from its overlay.
    func icon(_ node: OverlayTree.Node) -> (uri: String, color: UInt32?)? {
        guard let item = node.item else {
            return node.icon.map { ($0, node.iconColor.flatMap(AndroidColor.parse)) }
        }
        switch item.type {
        case RangeBearingEvent.type:
            return (OverlayTree.drawable("pairing_line_white"),
                    connections.rangeBearing.lines.first { $0.id == item.id }.map { UInt32(bitPattern: $0.color) })
        case Route.type:
            return (OverlayTree.drawable("ic_route"), connections.routes[item.id].map { UInt32(bitPattern: $0.color) })
        default:
            return icon(item.id).map { ($0.uri, $0.color) }
        }
    }

    /// Under the title: a list's count; a route's first point; else the
    /// item's position, and its range, bearing and altitude from you.
    func description(_ node: OverlayTree.Node) -> (position: String, rangeBearing: String?)? {
        if let count = node.countText { return (count, nil) }
        guard let item = node.item else { return nil }
        if let route = connections.routes[item.id] {
            return route.points.first.map { (units.position($0.point), nil) }
        }
        guard let p = overlays.location(of: item) else { return nil }
        guard let from = reference else { return (units.position(p), nil) }
        let rb = RangeBearing(from: from, to: p).label(units.rangeBearingStyle, magnetic: units.magnetic)
        return (units.position(p), [rb, units.altitude(p)].compactMap { $0 }.joined(separator: "   "))
    }

    // MARK: - visibility

    func visibility(_ node: OverlayTree.Node) -> OverlayManager.Visibility { overlays.visibility(of: node) }

    /// The eye: anything shown hides, a hidden one shows.
    func toggleVisible(_ node: OverlayTree.Node) {
        overlays.setVisible(node, overlays.visibility(of: node) == .hidden)
    }

    // MARK: - clicks

    func click(_ node: OverlayTree.Node) {
        if node.isList {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
            return
        }
        guard let item = node.item else { return }
        if multiSelect {
            goTo(item)
            return
        }
        if connections.routes[item.id] != nil {
            if routeActionsOpen == item.id {
                routeActionsOpen = nil
            } else {
                routeActionsOpen = item.id
                if !overlays.isVisible(node) { overlays.setVisible(node, true) }
                goTo(item)
            }
            return
        }
        if selected == item.id {
            unselect()
            return
        }
        selected = item.id
        goTo(item)
        if !overlays.isVisible(node) { overlays.setVisible(node, true) }
        // what the radial and details widgets open here
        if connections.pointEditor.canEdit(item.id) { pointActions.details(item.id) }
    }

    private func unselect() {
        if let s = selected, connections.pointEditor.inspected == s { connections.pointEditor.inspect(nil) }
        selected = nil
    }

    /// MapTouchController.goTo: a Marker (a contact, a CoT marker) fits
    /// into 1/18th of the view and is focused; an R&B endpoint, a point
    /// without an icon, fits the view and is focused; a line or a route
    /// fits the view.
    private func goTo(_ item: OverlayItem) {
        let marker = connections.contacts[item.id] != nil || connections.markers[item.id] != nil
        switch item.location {
        case .point(let p):
            host.goTo([p], altitude: p.validAltitude, marker: marker, point: true)
        case .line(let points):
            let route = connections.routes[item.id]?.points.map(\.point) ?? points
            host.goTo(route, altitude: route.compactMap(\.validAltitude).max(), marker: false, point: false)
        case nil:
            break
        }
    }

    // MARK: - a route's actions

    func isRouteActionsOpen(_ node: OverlayTree.Node) -> Bool { routeActionsOpen == node.uid }

    func routeDetails(_ id: String) { connections.routeEditor.inspect(id) }
    func routeSend(_ id: String) { routeActions.sending = RouteActions.Target(id: id) }
    func routeEdit(_ id: String) { connections.routeEditor.edit(id) }
    func routeDelete(_ id: String) { routeActions.deleting = RouteActions.Target(id: id) }

    // MARK: - multi-select

    /// A row's check: a list is checked when all of it is.
    func checkState(_ node: OverlayTree.Node) -> OverlayManager.Visibility {
        if checked.contains(node.id) { return .visible }
        guard let children = node.children, !children.isEmpty else { return .hidden }
        let states = children.map(checkState)
        if states.allSatisfy({ $0 == .visible }) { return .visible }
        return states.contains { $0 != .hidden } ? .partial : .hidden
    }

    func toggleChecked(_ node: OverlayTree.Node) {
        let on = checkState(node) != .visible
        setChecked(node, on)
    }

    private func setChecked(_ node: OverlayTree.Node, _ on: Bool) {
        if on { checked.insert(node.id) } else { checked.remove(node.id) }
        for child in node.children ?? [] { setChecked(child, on) }
    }

    /// The checked rows' items, each once.
    var checkedItems: [OverlayTree.Node] {
        var seen = Set<String>()
        var out: [OverlayTree.Node] = []
        func walk(_ nodes: [OverlayTree.Node]) {
            for n in nodes {
                if let item = n.item, checked.contains(n.id), seen.insert(item.id).inserted { out.append(n) }
                walk(n.children ?? [])
            }
        }
        walk(rows)
        return out
    }

    func deleteChecked() {
        overlays.delete(checkedItems)
        multiSelect = false
    }

    // MARK: - an R&B line's Send

    /// `to` nil is everyone.
    func send(_ line: RangeBearingLine, to: [String]?) {
        do {
            try connections.share(line: line.id, to: to, style: units.rangeBearingStyle)
        } catch ServerConnections.ShareError.notRunning {
            sendFailure = "Nothing is connected: start the mesh or a server."
        } catch ServerConnections.ShareError.noPlace {
            sendFailure = "One of its markers has no position here."
        } catch {
            sendFailure = "\(error)"
        }
    }
}

/// Android's Color.parseColor, for the overlays' iconColor: #RRGGBB,
/// #AARRGGBB or one of its names.
enum AndroidColor {
    static let names: [String: UInt32] = [
        "black": 0xFF00_0000, "darkgray": 0xFF44_4444, "gray": 0xFF88_8888, "lightgray": 0xFFCC_CCCC,
        "white": 0xFFFF_FFFF, "red": 0xFFFF_0000, "green": 0xFF00_FF00, "blue": 0xFF00_00FF,
        "yellow": 0xFFFF_FF00, "cyan": 0xFF00_FFFF, "magenta": 0xFFFF_00FF, "aqua": 0xFF00_FFFF,
        "fuchsia": 0xFFFF_00FF, "darkgrey": 0xFF44_4444, "grey": 0xFF88_8888, "lightgrey": 0xFFCC_CCCC,
        "lime": 0xFF00_FF00, "maroon": 0xFF80_0000, "navy": 0xFF00_0080, "olive": 0xFF80_8000,
        "purple": 0xFF80_0080, "silver": 0xFFC0_C0C0, "teal": 0xFF00_8080,
    ]

    static func parse(_ s: String) -> UInt32? {
        if s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) {
            switch s.count {
            case 7: return 0xFF00_0000 | v
            case 9: return v
            default: return nil
            }
        }
        return names[s.lowercased()]
    }
}

/// An icon as 5.5 names it: an asset the engine reads, a base64:// image,
/// or an Android drawable, which macTAK doesn't ship: an SF Symbol stands
/// for it. Tinted by multiplying, as 5.5's PorterDuff.MULTIPLY.
struct OverlayIconView: View {
    let uri: String
    let color: UInt32?
    /// Watched: an asset can be read once the map runs.
    @ObservedObject var host: EngineHost

    /// The drawables 5.5 uses here, and the symbols that stand for them.
    static let drawableSymbols = [
        "shape": "square.on.circle", "ruler": "ruler", "ic_route": "point.topleft.down.to.point.bottomright.curvepath",
        "pairing_line_white": "line.diagonal.arrow",
    ]

    var body: some View {
        Group {
            if uri.hasPrefix(OverlayTree.drawablePrefix) {
                let name = String(uri.dropFirst(OverlayTree.drawablePrefix.count))
                Image(systemName: Self.drawableSymbols[name] ?? "questionmark.square.dashed")
                    .foregroundStyle(tint ?? .primary)
            } else if let image = IconCache.shared.image(uri, host: host) {
                Image(nsImage: image).resizable().interpolation(.high).colorMultiply(tint ?? .white)
            } else {
                Color.clear
            }
        }
        .frame(width: 20, height: 20)
    }

    private var tint: Color? {
        guard let c = color else { return nil }
        return Color(.sRGB, red: Double(c >> 16 & 0xFF) / 255, green: Double(c >> 8 & 0xFF) / 255,
                     blue: Double(c & 0xFF) / 255, opacity: Double(c >> 24 & 0xFF) / 255)
    }
}

/// Icons read once.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var images: [String: NSImage?] = [:]

    func image(_ uri: String, host: EngineHost) -> NSImage? {
        if let known = images[uri] { return known }
        var bytes: [UInt8]?
        if uri.hasPrefix("asset://") {
            bytes = host.asset(String(uri.dropFirst("asset://".count)))
            if bytes == nil, host.state != .running { return nil }   // not cached: ask again once the map runs
        } else if uri.hasPrefix("base64://") {
            let s = String(uri.dropFirst("base64://".count))
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = s + String(repeating: "=", count: (4 - s.count % 4) % 4)
            bytes = Data(base64Encoded: padded).map { [UInt8]($0) }
        }
        let image = bytes.flatMap { NSImage(data: Data($0)) }
        images[uri] = image
        return image
    }
}

struct OverlayManagerSection: View {
    @ObservedObject var model: OverlayManagerModel
    @EnvironmentObject private var connections: ServerConnections

    var body: some View {
        Section {
            bar
            if model.rows.isEmpty {
                Text(model.search.isEmpty ? "Nothing on the map" : "No matches").foregroundStyle(.secondary)
            }
            ForEach(model.rows) { node in
                OverlayNodeView(node: node, model: model, depth: 0)
            }
        } header: {
            HStack {
                Text("Overlay Manager")
                Spacer()
                if model.multiSelect {
                    Button("Delete") { model.confirmingDelete = true }
                        .buttonStyle(.borderless)
                        .disabled(model.checkedItems.isEmpty)
                    Button("Cancel") { model.multiSelect = false }
                        .buttonStyle(.borderless)
                } else {
                    Button { model.multiSelect = true } label: { Image(systemName: "checklist") }
                        .buttonStyle(.borderless)
                        .help("Multi-Select: check items to delete")
                }
            }
        }
        .alert("Are you sure?", isPresented: $model.confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Yes", role: .destructive) { model.deleteChecked() }
        } message: {
            Text("Deleting objects permanently removes them from your device. Continue?")
        }
        .sheet(item: $model.sendingLine) { line in
            SendItemSheet(title: line.title, contacts: connections.contacts) { choice in
                model.sendingLine = nil
                switch choice {
                case .everyone: model.send(line, to: nil)
                case .contacts(let uids): model.send(line, to: uids)
                case .cancel: break
                }
            }
        }
        .alert("Can't send the line", isPresented: Binding(get: { model.sendFailure != nil },
                                                           set: { if !$0 { model.sendFailure = nil } })) {
            Button("OK") { model.sendFailure = nil }
        } message: {
            Text(model.sendFailure ?? "")
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(OverlayManagerModel.SortChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort")
            Menu {
                Toggle("Show All", isOn: $model.showAll)
                Toggle("Self-Authored", isOn: $model.selfAuthored)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter")
        }
    }
}

struct OverlayNodeView: View {
    let node: OverlayTree.Node
    @ObservedObject var model: OverlayManagerModel
    let depth: Int

    var body: some View {
        OverlayRow(node: node, model: model, depth: depth)
        if node.isList, model.expanded.contains(node.id) {
            ForEach(node.children ?? []) { child in
                OverlayNodeView(node: child, model: model, depth: depth + 1)
            }
        }
        if model.isRouteActionsOpen(node), node.item != nil {
            RouteActionsRow(id: node.uid, model: model, depth: depth + 1)
        }
    }
}

struct OverlayRow: View {
    let node: OverlayTree.Node
    @ObservedObject var model: OverlayManagerModel
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            if node.isList {
                Image(systemName: model.expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            leading
            if let icon = model.icon(node) {
                OverlayIconView(uri: icon.uri, color: icon.color, host: model.host)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(node)).lineLimit(1)
                if let d = model.description(node) {
                    Text(d.position).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    if let rb = d.rangeBearing {
                        Text(rb).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture { model.click(node) }
        .listRowBackground(model.selected == node.uid && !node.isList
                           ? Color(.sRGB, red: 0, green: 0xAF / 255.0, blue: 0x4F / 255.0, opacity: 0x80 / 255.0)
                           : nil)
        .contextMenu { if let item = node.item { OverlayItemMenu(item: item, model: model) } }
    }

    @ViewBuilder private var leading: some View {
        if model.multiSelect {
            Button { model.toggleChecked(node) } label: {
                Image(systemName: Self.checkSymbol(model.checkState(node)))
            }
            .buttonStyle(.borderless)
        } else {
            Button { model.toggleVisible(node) } label: {
                Image(systemName: Self.eyeSymbol(model.visibility(node)))
                    .opacity(model.visibility(node) == .partial ? 0.5 : 1)
            }
            .buttonStyle(.borderless)
            .help("Show or hide on the map")
        }
    }

    static func eyeSymbol(_ v: OverlayManager.Visibility) -> String { v == .hidden ? "eye.slash" : "eye" }

    static func checkSymbol(_ v: OverlayManager.Visibility) -> String {
        switch v {
        case .visible: "checkmark.square"
        case .partial: "minus.square"
        case .hidden: "square"
        }
    }
}

/// RouteListItem's actions: Details, Send, Edit, Delete.
struct RouteActionsRow: View {
    let id: String
    @ObservedObject var model: OverlayManagerModel
    let depth: Int

    var body: some View {
        HStack(spacing: 10) {
            Button("Details") { model.routeDetails(id) }
            Button("Send…") { model.routeSend(id) }
            Button("Edit") { model.routeEdit(id) }
            Button("Delete…", role: .destructive) { model.routeDelete(id) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.leading, CGFloat(depth) * 12 + 26)
    }
}

/// What the item's radial offers on the map, as its row's menu.
struct OverlayItemMenu: View {
    let item: OverlayItem
    @ObservedObject var model: OverlayManagerModel

    var body: some View {
        let c = model.connections
        if c.pointEditor.canEdit(item.id) {
            Button("Details") { model.pointActions.details(item.id) }
            Button("Send…") { model.pointActions.send(item.id) }
            Button("Range & Bearing from Here") { model.pointActions.rangeBearing(from: item.id) }
            Button("Move") { model.pointActions.move(item.id) }.disabled(!c.pointEditor.canMove(item.id))
            Divider()
            Button("Delete…") { model.pointActions.delete(item.id) }
        } else if c.routes[item.id] != nil {
            Button("Route Details") { model.routeDetails(item.id) }
            Button("Edit Route") { model.routeEdit(item.id) }
            Button("Send…") { model.routeSend(item.id) }
            Divider()
            Button("Delete Route…") { model.routeDelete(item.id) }
        } else if let line = c.rangeBearing.lines.first(where: { $0.id == item.id }) {
            Button("Send…") { model.sendingLine = line }
            Divider()
            Button("Delete") { c.rangeBearing.remove(id: line.id) }
        }
    }
}
