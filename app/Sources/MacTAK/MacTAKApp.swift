// MacTAKApp.swift — the macTAK app (G3): a SwiftUI window around the
// engine's map, beside a sidebar the milestones fill: the TAK servers
// (G3.2d), contacts (G3.4), chat (G3.5), then coordinates and layers.

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
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 800)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = EngineHost()
    /// The servers, their certificates in the login keychain (G3.2).
    let connections = ServerConnections(settings: UserDefaults.standard, identities: .login)

    func applicationDidFinishLaunching(_ notification: Notification) {
        CommsRuntime.configure()
        do {
            try connections.start()
        } catch {
            NSLog("macTAK: commo didn't start: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The engine tears down on its render thread before the process goes:
    /// the JVM is never destroyed (DestroyJavaVM blocks on engine threads).
    /// commo shuts down first, so the servers see the client leave.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
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
