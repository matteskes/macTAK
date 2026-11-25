// MacTAKApp.swift — the macTAK app (G3): a SwiftUI window around the
// engine's map, beside a sidebar the milestones fill: the TAK servers
// (G3.2d), the mesh (G3.3b), contacts (G3.4), chat (G3.5), coordinates
// (G3.6: the Units settings and the self readout over the map), markers
// (G3.7), range and bearing (G3.8), points (G3.9: dropped, then edited
// from a right-click menu and an inspector beside the map) and routes
// (G3.10: drawn with the route tool, edited from their menus and the
// inspector).
//
// `--settings-suite NAME` keeps this copy's settings (self details,
// servers, mesh) in the defaults suite NAME instead of the app's own, its
// chat history in chat-NAME.sqlite, and suffixes its device uid with
// "-NAME", so a second copy on one Mac is a second client.

import AppKit
import Combine
import MacTAKComms
import MacTAKCore
import SwiftUI

@main
struct MacTAKApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--check-comms-runtime") { CommsRuntime.checkAndExit() }
        if CommandLine.arguments.contains("--check-symbols") { SymbolsRuntime.checkAndExit() }
    }

    var body: some Scene {
        Window("macTAK", id: "map") {
            ContentView()
                .environmentObject(delegate.host)
                .environmentObject(delegate.connections)
                .environmentObject(delegate.mesh)
                .environmentObject(delegate.me)
                .environmentObject(delegate.chatSelection)
                .environmentObject(delegate.units)
                .environmentObject(delegate.geocoders)
                .environmentObject(delegate.rangeBearing)
                .environmentObject(delegate.pointDropper)
                .environmentObject(delegate.pointEditor)
                .environmentObject(delegate.pointActions)
                .environmentObject(delegate.routeEditor)
                .environmentObject(delegate.routeActions)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 800)

        // GeoChat (G3.5c), apart from the map.
        Window("Chat", id: "chat") {
            ChatWindow()
                .environmentObject(delegate.connections)
                .environmentObject(delegate.chatSelection)
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 760, height: 520)

        // ⌘, (G3.6b)
        Settings {
            TabView {
                UnitsSettings()
                    .tabItem { Label("Units", systemImage: "ruler") }
                GeocoderSettings()
                    .tabItem { Label("Address Lookup", systemImage: "mappin.and.ellipse") }
            }
            .environmentObject(delegate.units)
            .environmentObject(delegate.geocoders)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = EngineHost()
    /// Peers on the local network, on unless turned off (G3.3).
    let mesh: MeshNetwork
    /// Who this client says it is and where (G3.4b): the device uid, the
    /// self details, CoreLocation or a placed position.
    let me: SelfReporter
    /// The servers, their certificates in the login keychain (G3.2), and
    /// the commo client the mesh shares.
    let connections: ServerConnections
    /// The room the Chat window shows.
    let chatSelection = ChatSelection()
    /// How positions and altitudes show (G3.6b), and the geoid for MSL.
    let units: UnitPreferences
    /// Address lookup for ADDR: Apple's, and imported Nominatim servers.
    let geocoders: GeocoderRegistry
    /// Range and bearing lines and their tool (G3.8c), shared over CoT (G3.8d).
    var rangeBearing: RangeBearingLines { connections.rangeBearing }
    /// The Point Dropper (G3.9b); one map tool runs at a time.
    var pointDropper: PointDropper { connections.pointDropper }
    /// Editing points (G3.9c), and what its menu asks the windows for.
    var pointEditor: PointEditor { connections.pointEditor }
    let pointActions: PointActions
    /// The route tool and route details (G3.10c).
    var routeEditor: RouteEditor { connections.routeEditor }
    let routeActions: RouteActions
    private var mapChanges: [AnyCancellable] = []
    private let watcher: InterfaceWatcher
    /// The map's markers: the contacts and the self position (G3.7b).
    private let markers: MapMarkerSync

    override init() {
        let (settings, suite) = Self.settings()
        let mesh = MeshNetwork(settings: settings)
        self.mesh = mesh
        let details = SelfDetails(settings: settings, uid: DeviceUID.resolve(suite: suite))
        me = SelfReporter(settings: settings, details: details, locator: LocationService())
        units = UnitPreferences(settings: settings, geoid: UnitPreferences.bundledGeoid(),
                                magnetic: UnitPreferences.bundledMagneticModel())
        geocoders = GeocoderRegistry(settings: settings)
        // Chat history and user groups, one file per settings suite (G3.5b).
        let chatStore: ChatStore?
        do {
            chatStore = try ChatStore.appStore(suite: suite)
        } catch {
            NSLog("macTAK: no chat history: \(error)")
            chatStore = nil
        }
        // The map items kept across launches, one file per suite too (G3.9a).
        let mapItemStore: MapItemStore?
        do {
            mapItemStore = try MapItemStore.appStore(suite: suite)
        } catch {
            NSLog("macTAK: map items won't be kept: \(error)")
            mapItemStore = nil
        }
        connections = ServerConnections(settings: settings, identities: .login, me: me, mesh: mesh,
                                        chatStore: chatStore, mapItemStore: mapItemStore)
        watcher = InterfaceWatcher { mesh.refresh() }
        markers = MapMarkerSync(host: host, contacts: connections.contacts, cotMarkers: connections.markers,
                                me: me, rangeBearing: connections.rangeBearing, routes: connections.routes,
                                routeEditor: connections.routeEditor, units: units)
        pointActions = PointActions(editor: connections.pointEditor, rangeBearing: connections.rangeBearing)
        routeActions = RouteActions(editor: connections.routeEditor, routes: connections.routes)
        super.init()
        let rangeBearing = rangeBearing, pointDropper = pointDropper, editor = pointEditor, markers = markers
        let pointActions = pointActions, routeEditor = routeEditor, routeActions = routeActions
        let noTool = { pointDropper.selected == nil && rangeBearing.tool == .off && editor.moving == nil && routeEditor.editing == nil }
        // a running tool takes the click; else a click on a marker or a route shows it, on the map closes it
        host.onMapClick = { pick in
            if routeEditor.editing != nil {
                routeEditor.click(pick, checkpoint: NSEvent.modifierFlags.contains(.option))
                return
            }
            var pick = pick
            if case .item(let uid) = pick, let place = routeEditor.point(of: uid) {
                // the other tools take a route's point as the ground there
                guard !noTool() else { return routeEditor.inspect(routeEditor.route(withPoint: uid)?.id) }
                pick = .ground(place)
            }
            if pointDropper.selected != nil {
                if case .item(let uid) = pick, pointDropper.isPlacedHere(uid) { editor.inspect(uid) } else { pointDropper.click(pick) }
            } else if rangeBearing.tool != .off {
                rangeBearing.click(pick)
            } else if editor.moving != nil {
                editor.click(pick)
            } else if case .item(let uid) = pick {
                editor.inspect(uid)
            } else {
                editor.inspect(nil)
                routeEditor.inspect(nil)
            }
        }
        // a click on a route's line shows the route while no tool runs; the
        // route tool takes it as the ground, but its own line does nothing
        host.routeLineAt = { [markers] place, radius in RouteHit.nearest(markers.routeLines, to: place, within: radius) }
        host.onLineClick = { hit in
            if routeEditor.editing == hit.route { return true }
            guard noTool() else { return false }
            routeEditor.inspect(hit.route)
            return true
        }
        host.lineMenu = { hit in routeActions.lineMenu(for: hit) }
        // a marker drags to move while no tool runs; the edited route's points while the route tool does
        host.canDrag = { uid in
            routeEditor.editing != nil ? routeEditor.canDrag(uid) : noTool() && editor.canMove(uid)
        }
        host.onDragBegan = { uid in routeEditor.beginDrag(uid) }
        host.onDrag = { uid, point in
            if routeEditor.canDrag(uid) { routeEditor.drag(uid, to: .ground(point)) } else { editor.move(uid, to: .ground(point)) }
        }
        host.markerMenu = { uid in routeActions.pointMenu(for: uid) ?? pointActions.menu(for: uid) }
        // a placed or moved point says where its altitude came from
        connections.mapLocator.altitudeSource = { [host] p in host.altitudeSource(at: p) }
        // a click, a delete, a placed point or a tool starting shows at once, not at the next tick
        let refresh: (()) -> Void = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { markers.refresh() } }
        }
        mapChanges = [
            rangeBearing.objectWillChange.sink(receiveValue: refresh),
            connections.markers.objectWillChange.sink(receiveValue: refresh),
            connections.routes.objectWillChange.sink(receiveValue: refresh),
            routeEditor.objectWillChange.sink(receiveValue: refresh),
            // starting one map tool ends the others
            rangeBearing.$tool.sink { if $0 != .off { pointDropper.end(); editor.endMove(); routeEditor.end() } },
            pointDropper.$selected.sink { if $0 != nil { rangeBearing.endTool(); editor.endMove(); routeEditor.end() } },
            editor.$moving.sink { if $0 != nil { rangeBearing.endTool(); pointDropper.end(); routeEditor.end() } },
            routeEditor.$editing.sink { if $0 != nil { rangeBearing.endTool(); pointDropper.end(); editor.endMove() } },
            // the inspector shows a point or a route
            editor.$inspected.sink { if $0 != nil { routeEditor.inspect(nil) } },
            routeEditor.$inspected.sink { if $0 != nil { editor.inspect(nil) } },
        ]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CommsRuntime.configure()
        markers.start()
        do {
            try connections.start()
            watcher.start()
        } catch {
            NSLog("macTAK: commo didn't start: \(error)")
        }
    }

    /// The settings, and the suite's name when --settings-suite names one.
    private static func settings() -> (UserDefaults, String?) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--settings-suite"), flag + 1 < arguments.count,
              let suite = UserDefaults(suiteName: arguments[flag + 1]) else { return (.standard, nil) }
        return (suite, arguments[flag + 1])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The engine tears down on its render thread before the process goes:
    /// the JVM is never destroyed (DestroyJavaVM blocks on engine threads).
    /// commo shuts down first, so the servers see the client leave.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            markers.stop()
            watcher.stop()
            await connections.stop()
            host.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @EnvironmentObject private var host: EngineHost
    @EnvironmentObject private var me: SelfReporter
    @EnvironmentObject private var units: UnitPreferences
    @EnvironmentObject private var rangeBearing: RangeBearingLines
    @EnvironmentObject private var pointDropper: PointDropper
    @EnvironmentObject private var pointEditor: PointEditor
    @EnvironmentObject private var pointActions: PointActions
    @EnvironmentObject private var routeEditor: RouteEditor
    @EnvironmentObject private var routeActions: RouteActions
    @EnvironmentObject private var connections: ServerConnections

    var body: some View {
        NavigationSplitView {
            List {
                ServersSection()
                MeshSection()
                ContactsSection()
                ChatSection()
                RangeBearingSection(lines: rangeBearing)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ZStack(alignment: .bottom) {
                MapView(host: host)
                VStack {
                    RangeBearingPrompt(lines: rangeBearing)
                    PointDropperPrompt(dropper: pointDropper)
                    PointMovePrompt(editor: pointEditor)
                    RoutePrompt(editor: routeEditor)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                status
                if host.state == .running && units.selfCoordDisplay != .none {
                    SelfReadoutView(me: me, details: me.details, units: units, host: host)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .inspector(isPresented: Binding(get: { pointEditor.inspected != nil || routeEditor.inspected != nil },
                                            set: { if !$0 { pointEditor.inspect(nil); routeEditor.inspect(nil) } })) {
                Group {
                    if routeEditor.inspected != nil {
                        RouteInspector(editor: routeEditor, routes: connections.routes, actions: routeActions)
                    } else {
                        PointInspector(editor: pointEditor, markers: connections.markers, actions: pointActions)
                    }
                }
                .inspectorColumnWidth(min: 240, ideal: 300, max: 380)
            }
            .toolbar {
                PointDropperToolButton(dropper: pointDropper, mapRunning: host.state == .running)
                RangeBearingToolButton(lines: rangeBearing, mapRunning: host.state == .running)
                RouteToolButton(editor: routeEditor, mapRunning: host.state == .running)
            }
            .modifier(PointActionPresenter(actions: pointActions, markers: connections.markers,
                                           connections: connections))
            .modifier(RouteActionPresenter(actions: routeActions, routes: connections.routes,
                                           connections: connections))
        }
    }

    @ViewBuilder private var status: some View {
        switch host.state {
        case .idle, .starting:
            Text("Starting the map…").padding(8).background(.regularMaterial, in: Capsule()).padding()
        case .failed(let why):
            Text(why).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
        case .running:
            EmptyView()
        }
    }
}

/// The engine's Metal view inside SwiftUI. The view is made once and kept:
/// the engine renders into its layer from its own thread.
struct MapView: NSViewRepresentable {
    let host: EngineHost

    func makeNSView(context: Context) -> MetalView {
        let view = MetalView(frame: .zero, log: { _ in })
        // Start one run-loop turn after the view is first sized: SwiftUI
        // resizes it again while it settles the window's layout, and the
        // engine's window surface must be created at the layer's final
        // drawable size (G3 trap 1).
        view.onReady = { v in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    host.attach(v)
                    v.window?.makeFirstResponder(v)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: MetalView, context: Context) { }
}
