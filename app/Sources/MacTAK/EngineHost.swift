// EngineHost.swift — the app's one engine: boots the JVM, starts the map on
// the first MetalView that is ready (in a window, laid out), and winds the render thread down
// when the app quits. Main thread only (the JNIEnv is bound to it).

import AppKit
import MacTAKComms
import MacTAKCore
import MacTAKCot

@MainActor
final class EngineHost: ObservableObject {
    enum State: Equatable {
        case idle, starting, running
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var engine: EngineBridge?
    private weak var view: MetalView?
    private var poll: Timer?
    /// A single click on the map, as the marker under it or the ground
    /// (G3.8b/c); markers in `unclickable` are looked through.
    var onMapClick: ((MapPick) -> Void)?
    var unclickable: Set<String> = []
    /// Whether a press on the marker `uid` drags it (G3.9c).
    var canDrag: ((String) -> Bool)?
    /// The dragged marker over the ground at a point.
    var onDrag: ((String, CotPoint) -> Void)?
    /// The menu for a right-click on the marker `uid`, or nil (G3.9c).
    var markerMenu: ((String) -> NSMenu?)?
    private var dragged: String?

    /// Start the engine on `view` (once per process: a process gets one JVM).
    func attach(_ view: MetalView) {
        guard state == .idle else { return }
        state = .starting
        do {
            let launch = try LaunchConfig.load()
            launch.applyEnvironment()
            let jvm = try JavaBoot.start(classpath: launch.resolvedClasspath, options: launch.resolvedJvmOptions)
            SignalQuit.install()        // after the JVM: its handlers would replace ours (#226)
            let engine = try EngineBridge(jni: jvm.jni)
            engine.onFailure = { msg in
                fputs("macTAK: engine bridge broke: \(msg)\n", stderr)
                exit(2)
            }
            let (w, h) = view.pixelSize
            try engine.start(layer: view.metalLayer, width: w, height: h, dpi: view.dpi, config: launch.mapConfig)
            view.connect(to: engine)
            view.onClick = { [weak self, weak view] x, y in
                guard let self, let view else { return }
                MainActor.assumeIsolated { self.clicked(x: x, y: y, scale: Float(view.backingScale)) }
            }
            view.grabsItem = { [weak self, weak view] x, y in
                guard let self, let view else { return false }
                return MainActor.assumeIsolated { self.grab(x: x, y: y, scale: Float(view.backingScale)) }
            }
            view.onItemDrag = { [weak self] x, y in
                MainActor.assumeIsolated { self?.drag(x: x, y: y) }
            }
            view.contextMenu = { [weak self, weak view] x, y in
                guard let self, let view else { return nil }
                return self.menu(x: x, y: y, scale: Float(view.backingScale))
            }
            self.engine = engine
            self.view = view
            watchOcclusion(of: view.window)
            startPolling()
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Centre the map on (lat, lon); nothing until the map runs.
    func panTo(lat: Double, lon: Double) {
        guard state == .running else { return }
        engine?.panTo(lat: lat, lon: lon)
    }

    /// Where the altitude at a place comes from; nil until the map runs.
    func altitudeSource(at p: CotPoint) -> String? {
        guard state == .running else { return nil }
        return engine?.altitudeSource(lat: p.lat, lon: p.lon)
    }

    /// Half a 32-point marker icon: a click this near a marker's point picks it.
    static let markerHitPoints: Float = 16

    private func clicked(x: Float, y: Float, scale: Float) {
        guard let onMapClick, let engine = markerEngine else { return }
        if let uid = marker(x: x, y: y, scale: scale) {
            onMapClick(.item(uid))
        } else if let g = ground(engine, x: x, y: y) {
            onMapClick(.ground(g))
        }
    }

    /// The clickable marker under a surface pixel.
    private func marker(x: Float, y: Float, scale: Float) -> String? {
        guard let uid = markerEngine?.markerAt(x: x, y: y, radius: Self.markerHitPoints * scale),
              !unclickable.contains(uid) else { return nil }
        return uid
    }

    private func ground(_ engine: EngineBridge, x: Float, y: Float) -> CotPoint? {
        engine.groundAt(x: x, y: y).map { CotPoint(lat: $0.lat, lon: $0.lon, hae: $0.hae ?? CotPoint.unknown) }
    }

    /// A press: whether it is on a marker that drags.
    private func grab(x: Float, y: Float, scale: Float) -> Bool {
        dragged = marker(x: x, y: y, scale: scale).flatMap { canDrag?($0) == true ? $0 : nil }
        return dragged != nil
    }

    private func drag(x: Float, y: Float) {
        guard let uid = dragged, let engine = markerEngine, let g = ground(engine, x: x, y: y) else { return }
        onDrag?(uid, g)
    }

    private func menu(x: Float, y: Float, scale: Float) -> NSMenu? {
        marker(x: x, y: y, scale: scale).flatMap { markerMenu?($0) }
    }

    /// The engine, once the map runs and takes markers (G3.7b); nil before.
    var markerEngine: EngineBridge? {
        guard state == .running, let engine, engine.markersReady else { return nil }
        return engine
    }

    private func startPolling() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func tick() {
        guard let engine else { return }
        switch engine.pollStatus() {
        case .rendering: break
        case .frameDone: if state != .running { state = .running }
        case .exited:
            poll?.invalidate()
            if case .failed = state { return }
            state = .failed("the map stopped (code \(engine.exitCode())); see the console log")
        }
    }

    private func watchOcclusion(of window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: window, queue: .main) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            let shown = w.occlusionState.contains(.visible)
            MainActor.assumeIsolated { self?.engine?.setVisible(shown) }
        }
    }

    /// Ask the render thread to tear down and wait (bounded) for it, pumping
    /// the run loop: AppKit's terminate path would wedge on .terminateLater
    /// (the G2 shell's applicationShouldTerminate records why).
    func shutdown() {
        guard let engine, engine.pollStatus() != .exited else { return }
        engine.stop()
        let deadline = Date().addingTimeInterval(10)
        while engine.pollStatus() != .exited && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
