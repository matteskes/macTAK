// SignalQuit.swift — SIGTERM, SIGINT and SIGHUP quit the app as ⌘Q does
// (#226, G3 trap 19).
//
// The JVM installs its own handlers for these when it starts, and they
// call Runtime.exit while the map is still up: the process exits without
// WindowApp's teardown, the engine's C++ statics destroy a Java-backed
// elevation source after the JVM is gone, and it crashes (G2 trap #73).
// So once the JVM is up the app takes the signals back and sends them
// through NSApp.terminate: the render thread tears down (detaching the
// elevation sources) and commo stops, so servers see the client leave.
//
// Not -Xrs: it would also turn off SIGQUIT, which jcmd and jstack need to
// attach to the running app.

import AppKit
import Dispatch

@MainActor
enum SignalQuit {
    static let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
    private static var sources: [DispatchSourceSignal] = []
    private static var quitting = false

    /// Call after the JVM has started, or its handlers replace these.
    static func install() {
        guard sources.isEmpty else { return }
        for sig in signals {
            signal(sig, SIG_IGN)        // a dispatch source sees the signal only if its default action is off
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { quit(on: sig) }
            }
            source.resume()
            sources.append(source)
        }
    }

    private static func quit(on sig: Int32) {
        guard !quitting else { return }   // one quit, however many signals arrive
        quitting = true
        NSLog("macTAK: \(String(cString: strsignal(sig))): quitting")
        // From the run loop, not from this main-queue block: terminate runs
        // AppKit's quit loop in place, and applicationShouldTerminate's Task
        // needs the main queue, which stays blocked until this block returns.
        RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) }
    }
}
