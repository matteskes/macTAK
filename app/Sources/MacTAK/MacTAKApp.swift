// MacTAKApp.swift — the macTAK app (G3): a SwiftUI window around the
// engine's map, beside a sidebar the milestones fill: the TAK servers
// (G3.2d), the mesh (G3.3b), contacts (G3.4), chat (G3.5), then coordinates
// and layers.
//
// `--settings-suite NAME` keeps this copy's settings (uid, callsign,
// servers, mesh) in the defaults suite NAME instead of the app's own, so a
// second copy on one Mac is a second client.

import AppKit
import MacTAKComms
import MacTAKCore
import SwiftUI

@main
struct MacTAKApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--check-comms-runtime") { CommsRuntime.checkAndExit() }
    }

    var body: some Scene {
        Window("macTAK", id: "map") {
            ContentView()
                .environmentObject(delegate.host)
                .environmentObject(delegate.connections)
                .environmentObject(delegate.mesh)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 800)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = EngineHost()
    /// Peers on the local network, on unless turned off (G3.3).
    let mesh: MeshNetwork
    /// The servers, their certificates in the login keychain (G3.2), and
    /// the commo client the mesh shares.
    let connections: ServerConnections
    private let watcher: InterfaceWatcher

    override init() {
        let settings = Self.settings()
        let mesh = MeshNetwork(settings: settings)
        self.mesh = mesh
        connections = ServerConnections(settings: settings, identities: .login, mesh: mesh)
        watcher = InterfaceWatcher { mesh.refresh() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CommsRuntime.configure()
        do {
            try connections.start()
            watcher.start()
        } catch {
            NSLog("macTAK: commo didn't start: \(error)")
        }
    }

    private static func settings() -> UserDefaults {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--settings-suite"), flag + 1 < arguments.count,
              let suite = UserDefaults(suiteName: arguments[flag + 1]) else { return .standard }
        return suite
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The engine tears down on its render thread before the process goes:
    /// the JVM is never destroyed (DestroyJavaVM blocks on engine threads).
    /// commo shuts down first, so the servers see the client leave.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
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

    var body: some View {
        NavigationSplitView {
            List {
                ServersSection()
                MeshSection()
                Section("Contacts") {
                    Text("Coming in G3.4").foregroundStyle(.secondary)
                }
                Section("Chat") {
                    Text("Coming in G3.5").foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ZStack(alignment: .bottom) {
                MapView(host: host)
                status
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
