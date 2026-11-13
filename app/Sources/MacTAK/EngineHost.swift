// EngineHost.swift — the app's one engine: boots the JVM, starts the map on
// the first MetalView that is ready (in a window, laid out), and winds the render thread down
// when the app quits. Main thread only (the JNIEnv is bound to it).

import AppKit
import MacTAKCore

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

    /// Start the engine on `view` (once per process: a process gets one JVM).
    func attach(_ view: MetalView) {
        guard state == .idle else { return }
        state = .starting
        do {
            let launch = try LaunchConfig.load()
            let jvm = try JavaBoot.start(classpath: launch.resolvedClasspath, options: launch.resolvedJvmOptions)
            let engine = try EngineBridge(jni: jvm.jni)
            engine.onFailure = { msg in
                fputs("macTAK: engine bridge broke: \(msg)\n", stderr)
                exit(2)
            }
            let (w, h) = view.pixelSize
            try engine.start(layer: view.metalLayer, width: w, height: h, dpi: view.dpi, config: launch.mapConfig)
            view.connect(to: engine)
            self.engine = engine
            self.view = view
            watchOcclusion(of: view.window)
            startPolling()
        } catch {
            state = .failed("\(error)")
        }
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
