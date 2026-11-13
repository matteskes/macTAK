// main.swift — mactak-shell, the G2 test harness (host model A, dev/g2/NOTES.md
// §M3): `make test-shell` and `make exit-run` drive it. G3.0 moved it into the
// app package on MacTAKCore (JavaBoot, EngineBridge, MetalView), with the
// same flags, log lines and exit codes; what stays here is the option
// parsing, the scripted input and the gates' window life cycle.
//
// This process owns both lifecycles. AppKit's main thread creates the
// NSWindow + CAMetalLayer, starts the JVM in-process through libjli
// (CJavaBoot), and calls EngineBridge.start across JNI. The JVM spawns its
// own render thread (WindowApp.render) which owns the EGL context
// end-to-end; the main thread never touches EGL. The main thread keeps a
// poll timer: EngineBridge.pollStatus says where the render thread is
// (RENDERING → FRAME_DONE → EXITED); on FRAME_DONE the window lingers for
// --linger ms so a human can eyeball the frame, live (M3.3: the render
// thread keeps presenting; the window resizes, follows the display's backing
// scale and pauses while occluded); then -- or on window close
// or a failure -- the shell asks WindowApp.stop, waits for EXITED (clean
// engine/EGL teardown on the render thread), and exits with WindowApp's
// code. The JVM is never destroyed: DestroyJavaVM blocks on lingering
// non-daemon engine threads, and System.exit is the proven RenderSmoke
// path — here taken by the shell, which owns the process.
//
// Exit codes: WindowApp's (0 PASS, 1 FAIL, 2 usage/environment, 3 EGL init
// failed); the shell adds nothing else — 2 also covers its own usage and
// bootstrap failures (libjli/JVM/class resolution, no Metal device).

import AppKit
import Darwin
import MacTAKCore
import Metal

let SHELL = "mactak-shell"
// Line-buffer stdout: the gate runs redirect it to a file, and Swift's print
// is fully buffered there — without this, the shell's progress lines only
// surface at process exit (or never, when it is killed).
setvbuf(stdout, nil, _IOLBF, 0)

func shellFail(_ msg: String) -> Never {
    fputs("\(SHELL): \(msg)\n", stderr)
    exit(2)
}

struct ShellOptions {
    var classpath: String?
    var libs: [String] = []
    var props: [String] = []
    var egl: String?
    var gles: String?
    var w = 640, h = 480
    var frames = 5
    var settleMs: Int64 = 3000
    var lingerMs: Int64 = 4000
    var wait = false
    var out: String?
    var layers: [String] = []
    var basemaps: [String] = []
    var layerDb: String?
    var res = Double.nan
    var atLat = Double.nan
    var atLon = Double.nan
    var liveMs: Int64 = 0
    var resizeTo: (Int, Int)?
    var frameLog: String?
    var gestures = false
    var tour = false
    var elevations: [String] = []
}

let USAGE = """
usage: \(SHELL) --classpath CP --lib PATH [--lib PATH ...] --egl PATH --gles PATH
                   [--prop JVM_OPTION ...] [--size WxH] [--frames N] [--settle MS]
                   [--linger MS | --wait] [--out FILE.png] [--layer FILE ...]
                   [--basemap FILE ...] [--layer-db DIR] [--res M] [--at LAT,LON]
                   [--elevation PATH ...]
                   [--live MS [--resize-to WxH | --gestures | --tour]] [--frame-log FILE.csv]
  --classpath CP  the JVM classpath (built by dev/g2/shell/run.sh; the JVM
                  starts with -Djava.class.path=CP)
  --lib PATH      native library to System.load, in order (libtakengine,
                  libtakenginejni)
  --egl PATH      ANGLE libEGL.dylib; --gles PATH  ANGLE libGLESv2.dylib
  --prop OPT      a raw JVM option, e.g. -Djava.awt.headless=true (repeatable)
  --size WxH      window size in points (default 640x480); the surface is
                  that times the display's backing scale (2 on Retina)
  --frames N      frames to render (default 5; plus the --settle tail)
  --settle MS     min wall time to keep rendering while layers load (default 3000)
  --linger MS     keep the window up this long after the frame is done, then
                  auto-close (default 4000)
  --wait          no auto-close; close the window yourself
  --out FILE      readback artifact (.png via ImageIO, else binary PPM)
  --layer FILE    vector layer (GeoJSON/GPKG/KML/SHP; repeatable)
  --basemap FILE  raster basemap (MBTiles or a GDAL raster such as GeoTIFF; repeatable)
  --elevation P   elevation: a GeoTIFF DEM file or a DTED directory (repeatable)
  --layer-db DIR  feature store dir (default: temp)
  --res M         camera resolution, metres/pixel (default: fit content bounds)
  --at LAT,LON    camera centre (default: content bounds centre)
  --live MS       after the first frame, a scripted live phase (the M3.3
                  gate): the camera pans every frame for MS, then the live
                  gate checks presents, GL errors, resizes and content
  --resize-to WxH resize the window to WxH points halfway through --live
  --frame-log F   CSV of the live phase's frame times
  --gestures      during --live, post a scripted sequence of real input events
                  into the window (drag, scroll, wheel, option-drag,
                  double-click) instead of the automatic pan; the live gate
                  checks each reached the camera (M3.4)
  --tour          during --live, the G2 exit run's 10 s gesture tour instead:
                  pans, wheel zooms in and out, tilt and turn with option-drag,
                  a trackpad scroll and a double-click (needs --live >= 10500)
"""

func parseSize(_ s: String, _ what: String) -> (Int, Int) {
    let p = s.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]), w > 0, h > 0 else {
        shellFail("bad --\(what) \(s) (want WxH, positive)")
    }
    return (w, h)
}

func parseDouble(_ s: String, _ what: String) -> Double {
    guard let d = Double(s) else { shellFail("bad --\(what) \(s)") }
    return d
}

var o = ShellOptions()
var argv = Array(CommandLine.arguments.dropFirst())
var i = 0

/// The value of the option at argv[i]; advances i onto it. A value option
/// given last used to index past the end of argv, a Swift runtime trap with
/// no message; it is a usage error (exit 2) like any other.
func optionValue() -> String {
    let opt = argv[i]
    i += 1
    guard i < argv.count else { shellFail("\(opt) needs a value") }
    return argv[i]
}
while i < argv.count {
    switch argv[i] {
    case "--classpath":
        o.classpath = optionValue()
    case "--lib": o.libs.append(optionValue())
    case "--prop": o.props.append(optionValue())
    case "--egl": o.egl = optionValue()
    case "--gles": o.gles = optionValue()
    case "--size": (o.w, o.h) = parseSize(optionValue(), "size")
    case "--frames": o.frames = Int(optionValue()) ?? 0
    case "--settle": o.settleMs = Int64(optionValue()) ?? -1
    case "--linger": o.lingerMs = Int64(optionValue()) ?? -1
    case "--wait": o.wait = true
    case "--out": o.out = optionValue()
    case "--layer": o.layers.append(optionValue())
    case "--basemap": o.basemaps.append(optionValue())
    case "--layer-db": o.layerDb = optionValue()
    case "--res": o.res = parseDouble(optionValue(), "res")
    case "--live": o.liveMs = Int64(optionValue()) ?? -1
    case "--resize-to": o.resizeTo = parseSize(optionValue(), "resize-to")
    case "--frame-log": o.frameLog = optionValue()
    case "--gestures": o.gestures = true
    case "--tour": o.tour = true
    case "--elevation": o.elevations.append(optionValue())
    case "--at":
        let at = optionValue()
        let ll = at.split(separator: ",", maxSplits: 1).map(String.init)
        guard ll.count == 2 else { shellFail("bad --at \(at) (want LAT,LON)") }
        o.atLat = parseDouble(ll[0], "at"); o.atLon = parseDouble(ll[1], "at")
    case "-h", "--help", "--usage":
        print(USAGE); exit(0)
    default:
        fputs("\(SHELL): unknown option \(argv[i])\n\(USAGE)\n", stderr); exit(2)
    }
    i += 1
}
guard let cp = o.classpath, !cp.isEmpty else { fputs("\(SHELL): --classpath is required\n\(USAGE)\n", stderr); exit(2) }
guard !o.libs.isEmpty, o.egl != nil, o.gles != nil else { fputs("\(SHELL): --lib/--egl/--gles are required\n\(USAGE)\n", stderr); exit(2) }
guard o.frames >= 1 else { fputs("\(SHELL): --frames must be >= 1\n", stderr); exit(2) }
guard o.settleMs >= 0, o.lingerMs >= 0 else { fputs("\(SHELL): --settle/--linger must be >= 0\n", stderr); exit(2) }
guard o.liveMs >= 0 else { fputs("\(SHELL): --live must be >= 0\n", stderr); exit(2) }
guard o.resizeTo == nil || o.liveMs > 0 else { fputs("\(SHELL): --resize-to needs --live\n", stderr); exit(2) }
guard !o.gestures || o.liveMs > 0 else { fputs("\(SHELL): --gestures needs --live\n", stderr); exit(2) }
guard !o.tour || o.liveMs >= Int64(GestureScript.tourSeconds * 1000) + 500 else {
    fputs("\(SHELL): --tour needs --live >= \(Int(GestureScript.tourSeconds * 1000) + 500)\n", stderr); exit(2)
}
guard !(o.tour && (o.gestures || o.resizeTo != nil)) else {
    fputs("\(SHELL): --tour excludes --gestures and --resize-to\n", stderr); exit(2)
}
// the scripted phase runs inside the linger: keep the window up past it
if o.liveMs > 0 { o.lingerMs = max(o.lingerMs, o.liveMs + 2000) }

// ---- JVM bootstrap and the engine facade (MacTAKCore) ---------------------

func bootFailed(_ e: Error) -> Never { shellFail("\(e)") }

// No Metal device (headless Mac, VM without a GPU): the CAMetalLayer below
// would get no device and eglCreateWindowSurface would misreport that as an
// F1 trigger (#42). Bail here, like the M3.0 smoke does.
guard MTLCreateSystemDefaultDevice() != nil else {
    shellFail("no Metal device (MTLCreateSystemDefaultDevice returned nil)")
}

let jvm: JavaBoot.Started
do { jvm = try JavaBoot.start(classpath: cp, options: o.props) } catch { bootFailed(error) }
print("\(SHELL): libjli \(jvm.libjli)")

let engine: EngineBridge
do { engine = try EngineBridge(jni: jvm.jni) } catch { bootFailed(error) }
engine.onFailure = { msg in fputs("\(SHELL): \(msg)\n", stderr); exit(2) }

// ---- The window (AppKit main thread) -------------------------------------

/// M3.4 --gestures: real input events, posted in-process into the shell's
/// own window during the live phase (no Accessibility permission needed).
/// Mouse events go through NSApp's event queue, so AppKit dispatches them
/// to the view; a synthesized scroll has no window to dispatch by, so it is
/// handed to the view's scrollWheel. Magnify and rotate have no public
/// event constructor: InputBridgeSelfTest covers their mapping, and a real
/// trackpad covers the handlers.
final class GestureScript {
    static let kinds: Int32 = Gesture.drag.bit | Gesture.scroll.bit | Gesture.wheel.bit
        | Gesture.optionDrag.bit | Gesture.doubleClick.bit
    /// Length of the exit run's tour (--tour); the live phase must outlast it.
    static let tourSeconds = 10.0
    private var steps: [(at: TimeInterval, run: () -> Void)] = []
    private let start = Date()
    private let window: NSWindow
    private let view: MetalView

    init(window: NSWindow, view: MetalView, tour: Bool = false) {
        self.window = window
        self.view = view
        let c = NSPoint(x: view.bounds.midX, y: view.bounds.midY)   // window coordinates: the view fills it
        if tour { planTour(c) } else { planGestures(c) }
        steps.sort { $0.at < $1.at }
    }

    /// M3.4's script: one of each gesture kind, about 6 s.
    private func planGestures(_ c: NSPoint) {
        drag(from: c, by: NSPoint(x: 160, y: 0), at: 1.0, flags: [])            // pan east
        for n in 0..<30 { steps.append((2.0 + Double(n) / 60, { self.scroll(c, dx: 0, dy: -6, units: .pixel) })) }
        for n in 0..<3 { steps.append((3.0 + Double(n) / 10, { self.scroll(NSPoint(x: c.x + 60, y: c.y + 40), dx: 0, dy: 1, units: .line) })) }
        drag(from: c, by: NSPoint(x: 0, y: 100), at: 3.6, flags: .option)       // tilt
        drag(from: c, by: NSPoint(x: 100, y: 0), at: 4.5, flags: .option)       // turn
        steps.append((5.6, { self.mouse(.leftMouseDown, c, clicks: 1) }))
        steps.append((5.62, { self.mouse(.leftMouseUp, c, clicks: 1) }))
        steps.append((5.70, { self.mouse(.leftMouseDown, c, clicks: 2) }))
        steps.append((5.72, { self.mouse(.leftMouseUp, c, clicks: 2) }))
    }

    /// The G2 exit run's tour (dev/g2/NOTES.md "The 60 fps gate"): 10 s of
    /// continuous pan, zoom, tilt and turn over the full stack. The returns
    /// (zoom out, turn back, tilt back) are partial, so the gesture gate
    /// still sees every kind move the camera.
    private func planTour(_ c: NSPoint) {
        let off = NSPoint(x: c.x + 80, y: c.y - 50)
        drag(from: NSPoint(x: c.x - 120, y: c.y), by: NSPoint(x: 240, y: 0), at: 0.3, flags: [], steps: 60)   // pan east, 1 s
        for n in 0..<4 { steps.append((1.5 + Double(n) / 8, { self.scroll(off, dx: 0, dy: 1, units: .line) })) }   // zoom in
        drag(from: c, by: NSPoint(x: -160, y: 120), at: 2.2, flags: [], steps: 45)                             // pan north-west
        drag(from: c, by: NSPoint(x: 0, y: 140), at: 3.2, flags: .option, steps: 45)                           // tilt 35 deg
        drag(from: c, by: NSPoint(x: 200, y: 0), at: 4.2, flags: .option, steps: 60)                           // turn 50 deg
        for n in 0..<30 { steps.append((5.4 + Double(n) / 30, { self.scroll(c, dx: 2, dy: 2, units: .pixel) })) }   // trackpad pan
        for n in 0..<3 { steps.append((6.6 + Double(n) / 8, { self.scroll(off, dx: 0, dy: -1, units: .line) })) }  // zoom out
        drag(from: c, by: NSPoint(x: -100, y: 0), at: 7.2, flags: .option, steps: 45)                          // turn back 25 deg
        drag(from: c, by: NSPoint(x: 0, y: -60), at: 8.1, flags: .option, steps: 30)                           // tilt back 15 deg
        steps.append((9.2, { self.mouse(.leftMouseDown, c, clicks: 1) }))
        steps.append((9.22, { self.mouse(.leftMouseUp, c, clicks: 1) }))
        steps.append((9.30, { self.mouse(.leftMouseDown, c, clicks: 2) }))
        steps.append((9.32, { self.mouse(.leftMouseUp, c, clicks: 2) }))                                       // zoom in 2x
        drag(from: c, by: NSPoint(x: -120, y: -60), at: 9.4, flags: [], steps: 30)                             // a last pan
    }

    /// Run every step that is due; true once the script is done.
    func tick() -> Bool {
        let t = Date().timeIntervalSince(start)
        while let first = steps.first, first.at <= t {
            steps.removeFirst()
            first.run()
        }
        return steps.isEmpty
    }

    private func drag(from p: NSPoint, by d: NSPoint, at t: TimeInterval, flags: NSEvent.ModifierFlags, steps n: Int = 30) {
        steps.append((t, { self.mouse(.leftMouseDown, p, flags: flags) }))
        for i in 1...n {
            let f = CGFloat(i) / CGFloat(n)
            let q = NSPoint(x: p.x + d.x * f, y: p.y + d.y * f)
            steps.append((t + Double(i) / 60, { self.mouse(.leftMouseDragged, q, flags: flags) }))
        }
        steps.append((t + Double(n + 1) / 60, { self.mouse(.leftMouseUp, NSPoint(x: p.x + d.x, y: p.y + d.y), flags: flags) }))
    }

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private func scroll(_ p: NSPoint, dx: Int32, dy: Int32, units: CGScrollEventUnit) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                               wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        let onScreen = window.convertPoint(toScreen: p)
        let top = NSScreen.screens.first?.frame.height ?? 0        // CG's global space is top-left
        cg.location = CGPoint(x: onScreen.x, y: top - onScreen.y)
        guard let e = NSEvent(cgEvent: cg) else { return }
        view.scrollWheel(with: e)
    }
}

final class Shell: NSObject, NSApplicationDelegate {
    let window: NSWindow
    let opt: ShellOptions
    let engine: EngineBridge
    var frameDoneLogged = false
    var lingerDeadline: Date?
    var stopRequestedByUs = false
    var stopRequestedAt: Date?
    var lastSt = -1
    var scriptedResizeAt: Date?
    var started = false                 // EngineBridge.start returned
    var view: MetalView?
    var gestureScript: GestureScript?
    var gestureTimer: Timer?

    init(window: NSWindow, opt: ShellOptions, engine: EngineBridge) {
        self.window = window
        self.opt = opt
        self.engine = engine
    }

    func tick() {
        let st = Int(engine.pollStatus().rawValue)
        if st != lastSt {
            print("\(SHELL): poll → \(st)")
            lastSt = st
        }
        if st == 1 && !frameDoneLogged {                       // PHASE_FRAME_DONE
            frameDoneLogged = true
            if opt.gestures || opt.tour, let v = view {
                let script = GestureScript(window: window, view: v, tour: opt.tour)
                gestureScript = script
                print("\(SHELL): live script: posting \(opt.tour ? "the exit-run tour" : "gestures") into the window")
                let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] tm in
                    if script.tick() { tm.invalidate(); self?.gestureScript = nil; print("\(SHELL): gestures posted") }
                }
                RunLoop.main.add(t, forMode: .common)
                gestureTimer = t
            }
            if let (rw, rh) = opt.resizeTo {
                scriptedResizeAt = Date().addingTimeInterval(Double(opt.liveMs) / 2000.0)
                print("\(SHELL): live script: resizing the window to \(rw)x\(rh) pt in \(Double(opt.liveMs) / 2000.0) s")
            }
            if opt.wait {
                print("\(SHELL): frame done — keeping the window up (--wait); close it to exit")
            } else {
                lingerDeadline = Date().addingTimeInterval(Double(opt.lingerMs) / 1000.0)
                print("\(SHELL): frame done — closing in \(Double(opt.lingerMs) / 1000.0) s (run with --wait or --linger N to change)")
            }
        }
        if st == 2 {                                           // PHASE_EXITED
            if !frameDoneLogged { print("\(SHELL): render failed — closing the window") }
            NSApp.terminate(nil)      // shouldTerminate: EXITED → .terminateNow
            return
        }
        if let at = scriptedResizeAt, Date() >= at, let (rw, rh) = opt.resizeTo {
            scriptedResizeAt = nil
            window.setContentSize(NSSize(width: rw, height: rh))
            let s = window.backingScaleFactor
            print("\(SHELL): resized the window to \(rw)x\(rh) pt (\(Int((Double(rw) * s).rounded()))x\(Int((Double(rh) * s).rounded())) px)")
        }
        if let dl = lingerDeadline, Date() >= dl, !opt.wait, !stopRequestedByUs {
            // Linger over: wind the render thread down from here, while the
            // window is still up, and let the next ticks see EXITED before
            // terminating. (Asking AppKit first would wedge — see
            // applicationShouldTerminate.)
            print("\(SHELL): linger elapsed — asking the render thread to wind down")
            engine.stop()
            stopRequestedByUs = true
            stopRequestedAt = Date()
        }
        if stopRequestedByUs, st != 2, let t0 = stopRequestedAt,
           Date().timeIntervalSince(t0) > 30 {
            // Teardown should take well under a second; a hang here means the
            // engine stalled on the render thread. Report and get out.
            fputs("\(SHELL): teardown did not finish within 30 s — exiting anyway\n", stderr)
            exit(engine.exitCode())
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if engine.pollStatus() == .exited { return .terminateNow }
        // User-initiated quit (window close / ⌘Q) while the render thread is
        // still up. Returning .terminateLater here would wedge: AppKit then
        // runs a private nested run-loop mode inside -terminate:, where this
        // delegate's timers never fire, so NSApp.reply could never happen.
        // Instead: ask the render thread to wind down and wait for EXITED
        // with a bounded run-loop pump, then terminate for real.
        engine.stop()
        if !stopRequestedByUs { stopRequestedByUs = true }
        stopRequestedAt = Date()
        let deadline = Date().addingTimeInterval(10)
        while engine.pollStatus() != .exited && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if engine.pollStatus() != .exited {
            fputs("\(SHELL): teardown did not finish within 10 s — exiting anyway\n", stderr)
            exit(engine.exitCode())
        }
        print("\(SHELL): teardown complete — terminating")
        return .terminateNow
    }

    /// M3.3: an occluded window renders nothing; WindowApp's loop pauses.
    @objc func occlusionChanged(_ note: Notification) {
        let shown = window.occlusionState.contains(.visible)
        print("\(SHELL): window \(shown ? "visible" : "occluded")")
        guard started else { return }
        engine.setVisible(shown)
    }

    /// G2 exit run: the process's peak resident memory (JVM, engine, ANGLE
    /// and AppKit together). macOS reports ru_maxrss in bytes.
    func reportPeakMemory() {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return }
        print(String(format: "\(SHELL): peak resident memory %.0f MB", Double(ru.ru_maxrss) / 1_048_576))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true                              // user-close flows into the path above
    }

    /// The last point at which WindowApp's exit code can become ours. Once
    /// applicationShouldTerminate says .terminateNow, -[NSApplication
    /// terminate:] posts this and then calls exit(0) itself: app.run() never
    /// returns, so code after it never ran and a failed render exited 0.
    func applicationWillTerminate(_ notification: Notification) {
        reportPeakMemory()
        let code = engine.exitCode()
        print("\(SHELL): exiting with WindowApp's code \(code)")
        exit(code)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)         // bare binary, no bundle: claim the
app.activate()                            // regular policy so the window is key

let frame = NSRect(x: 0, y: 0, width: CGFloat(o.w), height: CGFloat(o.h))
let view = MetalView(frame: frame, log: { print("\(SHELL): \($0)") })
let window = NSWindow(contentRect: frame,
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered,
                      defer: false)
window.title = "macTAK — shell"
window.isReleasedWhenClosed = false
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
view.syncBacking()   // the window's screen sets the real backing scale

let shell = Shell(window: window, opt: o, engine: engine)
app.delegate = shell

let (pxW, pxH) = view.pixelSize
let layerPtr = UInt(bitPattern: Unmanaged.passUnretained(view.metalLayer).toOpaque())
print("\(SHELL): CAMetalLayer @ 0x\(String(layerPtr, radix: 16)) window=\(o.w)x\(o.h) pt drawable=\(pxW)x\(pxH) px contentsScale=\(view.backingScale) dpi=\(view.dpi)")

var config = MapConfig()
config.libs = o.libs
config.egl = o.egl!
config.gles = o.gles!
config.layers = o.layers
config.basemaps = o.basemaps
config.elevations = o.elevations
config.layerDb = o.layerDb
config.out = o.out
config.res = o.res
config.atLat = o.atLat
config.atLon = o.atLon
config.frames = o.frames
config.settleMs = o.settleMs
config.liveMs = o.liveMs
config.expectResizes = o.resizeTo == nil ? 0 : 1
config.frameLog = o.frameLog
let scriptedInput = o.gestures || o.tour
config.scriptedPan = !scriptedInput                       // the automatic pan
config.gestureKinds = scriptedInput ? GestureScript.kinds : 0
do {
    try engine.start(layer: view.metalLayer, width: pxW, height: pxH, dpi: view.dpi, config: config)
} catch {
    shellFail("calling EngineBridge.start: \(error)")
}

// M3.3: from here on, backing changes (live resize, a display with another
// scale) and occlusion reach the render thread. Both calls are quick
// synchronized setters on the Java side; the main thread never waits on
// the render thread.
view.connect(to: engine)
shell.started = true
shell.view = view
window.makeFirstResponder(view)
NotificationCenter.default.addObserver(shell, selector: #selector(Shell.occlusionChanged(_:)),
                                       name: NSWindow.didChangeOcclusionStateNotification,
                                       object: window)

// The terminate handshake parks the run loop: applicationShouldTerminate
// returning .terminateLater runs it in NSModalPanelRunLoopMode, where timers
// in .default never fire (the reply would never happen). Schedule the poll
// tick in .common so it fires through the handshake too.
let timer = Timer(timeInterval: 0.1, repeats: true) { _ in shell.tick() }
timer.tolerance = 0.02
RunLoop.main.add(timer, forMode: .common)
app.run()

// Not reached on the terminate path: AppKit exits the process from inside
// terminate:, and applicationWillTerminate has already left with WindowApp's
// code (the engine and EGL are down on their own thread by then; the JVM is
// never destroyed). run() returns only after NSApp.stop, which nothing
// calls; if that ever changes, the code still comes from WindowApp.
exit(engine.exitCode())
