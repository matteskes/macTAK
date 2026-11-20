// MacTAKApp.swift — the macTAK app (G3): a SwiftUI window around the
// engine's map, beside a sidebar the milestones fill: the TAK servers
// (G3.2d), the mesh (G3.3b), contacts (G3.4), chat (G3.5), coordinates
// (G3.6: the Units settings and the self readout over the map), then
// markers and layers.
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
    private var rangeBearingChanges: AnyCancellable?
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
        connections = ServerConnections(settings: settings, identities: .login, me: me, mesh: mesh,
                                        chatStore: chatStore)
        watcher = InterfaceWatcher { mesh.refresh() }
        markers = MapMarkerSync(host: host, contacts: connections.contacts, cotMarkers: connections.markers,
                                me: me, rangeBearing: connections.rangeBearing, units: units)
        super.init()
        let rangeBearing = rangeBearing, markers = markers
        host.onMapClick = { pick in rangeBearing.click(pick) }
        // a click, a delete or the tool starting shows at once, not at the next tick
        rangeBearingChanges = rangeBearing.objectWillChange.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { markers.refresh() } }
        }
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
                RangeBearingPrompt(lines: rangeBearing)
                    .frame(maxHeight: .infinity, alignment: .top)
                status
                if host.state == .running && units.selfCoordDisplay != .none {
                    SelfReadoutView(me: me, details: me.details, units: units, host: host)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .toolbar {
                RangeBearingToolButton(lines: rangeBearing, mapRunning: host.state == .running)
            }
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
