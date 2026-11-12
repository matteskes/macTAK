// main.swift — macTAK G2 M3.2–M3.3: the app shell (host model A, NOTES §M3).
//
// This process owns both lifecycles. AppKit's main thread creates the
// NSWindow + CAMetalLayer, starts the JVM in-process through libjli
// (jni_boot.c), and upcalls WindowApp.start across JNI. The JVM spawns its
// own render thread (WindowApp.render) which owns the EGL context
// end-to-end; the main thread never touches EGL. The main thread keeps a
// poll timer: WindowApp.pollStatus says where the render thread is
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
import Metal
import Darwin

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
}

let USAGE = """
usage: \(SHELL) --classpath CP --lib PATH [--lib PATH ...] --egl PATH --gles PATH
                   [--prop JVM_OPTION ...] [--size WxH] [--frames N] [--settle MS]
                   [--linger MS | --wait] [--out FILE.png] [--layer FILE ...]
                   [--basemap FILE ...] [--layer-db DIR] [--res M] [--at LAT,LON]
                   [--live MS [--resize-to WxH | --gestures]] [--frame-log FILE.csv]
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
  --basemap FILE  raster basemap (MBTiles; repeatable)
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
// the scripted phase runs inside the linger: keep the window up past it
if o.liveMs > 0 { o.lingerMs = max(o.lingerMs, o.liveMs + 2000) }

// ---- JVM bootstrap (jni_boot.c) -----------------------------------------

var errBuf = [CChar](repeating: 0, count: 1024)

guard let libjli = mactak_find_libjli(&errBuf, errBuf.count) else {
    shellFail(String(cString: errBuf))
}
print("\(SHELL): libjli \(String(cString: libjli))")

var jvmOptions = ["-Djava.class.path=\(cp)"] + o.props
var cOptions: [UnsafeMutablePointer<CChar>?] = jvmOptions.map { strdup($0) }
let createRc = cOptions.withUnsafeMutableBufferPointer { p in
    mactak_create_jvm(p.baseAddress, Int32(p.count), &errBuf, errBuf.count)
}
cOptions.forEach { if let p = $0 { free(p) } }
if createRc != 0 {
    shellFail("creating the JVM failed (\(createRc)): \(String(cString: errBuf))")
}

let envNullable = mactak_env()
guard envNullable != nil else { shellFail("no JNIEnv after JNI_CreateJavaVM") }
let env = envNullable!
// env is the JNIEnv* — the pointer every JNI function takes as its first
// argument; its target is the function table (C: (*env)->FindClass(env, ...)).
// Two derefs reach the table struct; `env` itself is passed along each call.
let JNF = env.pointee!.pointee

// ---- JNI upcalls (Swift → WindowApp statics) -----------------------------
//
// The Args forms (CallStatic...MethodA) are used rather than the varargs
// ones: start() has 15 mixed-width parameters, and an explicit jvalue array
// does not depend on how Swift lays out a 15-deep varargs call.

func jniExceptionPending(_ during: String) -> Bool {
    if JNF.ExceptionCheck!(env) != 0 {
        JNF.ExceptionDescribe!(env)
        JNF.ExceptionClear!(env)
        fputs("\(SHELL): JNI exception while \(during)\n", stderr)
        return true
    }
    return false
}

func jniFindClass(_ name: String) -> jclass? {
    let cName = name.cString(using: .utf8)!
    let cls = JNF.FindClass!(env, cName)
    return jniExceptionPending("finding class \(name)") ? nil : cls
}

func jniStaticMethod(_ cls: jclass, _ name: String, _ sig: String) -> jmethodID? {
    let cName = name.cString(using: .utf8)!
    let cSig = sig.cString(using: .utf8)!
    let mid = JNF.GetStaticMethodID!(env, cls, cName, cSig)
    return jniExceptionPending("resolving \(name)\(sig)") ? nil : mid
}

func jniNewString(_ s: String) -> jstring? {
    let cs = s.cString(using: .utf8)!
    let js = JNF.NewStringUTF!(env, cs)
    return jniExceptionPending("creating string") ? nil : js
}

func jniNewStringArray(_ items: [String]) -> jobjectArray? {
    guard let cls = jniFindClass("java/lang/String") else { return nil }
    let arr = JNF.NewObjectArray!(env, jint(items.count), cls, nil)
    if jniExceptionPending("creating array") { return nil }
    for (n, s) in items.enumerated() {
        guard let js = jniNewString(s) else { return nil }
        JNF.SetObjectArrayElement!(env, arr, jint(n), js)
        if jniExceptionPending("filling array") { return nil }
    }
    return arr
}

let windowAppNullable = jniFindClass("mactak/render/WindowApp")
guard windowAppNullable != nil else { exit(2) }
let gWindowApp = windowAppNullable!

func jniCallInt(_ mid: jmethodID) -> jint {
    let v = JNF.CallStaticIntMethodA!(env, gWindowApp, mid, nil)
    if jniExceptionPending("calling") { exit(2) }
    return v
}

func jniCallVoid(_ mid: jmethodID, _ args: [jvalue] = []) {
    var a = args
    a.withUnsafeMutableBufferPointer { p in
        JNF.CallStaticVoidMethodA!(env, gWindowApp, mid, p.baseAddress)
    }
    if jniExceptionPending("calling") { exit(2) }
}

// start(long layerPtr, int w, int h, String[] libs, String egl, String gles,
//       String[] layers, String[] basemaps, String layerDb, String out,
//       double res, double atLat, double atLon, int frames, long settleMs,
//       double dpi, long liveMs, int expectResizes, String frameLog,
//       boolean scriptedPan, int gestureKinds)
let SIG_START = "(JII[Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;"
    + "[Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;DDDIJ"
    + "DJILjava/lang/String;ZI)V"

guard let midStart = jniStaticMethod(gWindowApp, "start", SIG_START),
      let midPoll = jniStaticMethod(gWindowApp, "pollStatus", "()I"),
      let midExit = jniStaticMethod(gWindowApp, "exitCode", "()I"),
      let midStop = jniStaticMethod(gWindowApp, "stop", "()V"),
      let midResize = jniStaticMethod(gWindowApp, "resize", "(IID)V"),
      let midVisible = jniStaticMethod(gWindowApp, "setVisible", "(Z)V"),
      let midInput = jniStaticMethod(gWindowApp, "input", "(IFFFFD)V")
else { exit(2) }

/// InputBridge's gesture kinds (mactak.render.InputBridge), sent across JNI.
enum Gesture: Int32 {
    case drag = 0, scroll, wheel, magnify, rotate, optionDrag, doubleClick
    var bit: Int32 { 1 << rawValue }
}

// No Metal device (headless Mac, VM without a GPU): the CAMetalLayer below
// would get no device and eglCreateWindowSurface would misreport that as an
// F1 trigger (#42). Bail here, like the M3.0 smoke does.
guard MTLCreateSystemDefaultDevice() != nil else {
    shellFail("no Metal device (MTLCreateSystemDefaultDevice returned nil)")
}

// ---- The window (AppKit main thread) -------------------------------------

final class MetalView: NSView {
    let metalLayer: CAMetalLayer
    /// Called with the new drawableSize (pixels) and dpi after every backing
    /// change, once the render thread exists (set after WindowApp.start).
    var onBackingChange: ((Int, Int, Double) -> Void)?
    /// The backing last reported: compared against, not the layer's
    /// drawableSize, which Core Animation may already have moved along with
    /// the layer's bounds by the time setFrameSize runs (trap #58).
    private var reported: (w: Int, h: Int, scale: CGFloat)?

    override init(frame frameRect: NSRect) {
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect)
        self.layer = metalLayer          // set explicitly, Chromium-style: on
        self.wantsLayer = true           // current macOS a +layerClass override
        syncBacking()                    // is ignored for backing layers (M3.0)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Pixels the surface needs: the view's points times the backing scale.
    var pixelSize: (Int, Int) {
        let s = backingScale
        return (max(1, Int((bounds.width * s).rounded())), max(1, Int((bounds.height * s).rounded())))
    }

    /// M3.3 Retina: drawableSize = points x backing scale, contentsScale =
    /// that scale, dpi = 72 x scale. The layer's drawableSize is the host's
    /// truth; the render thread adopts it (WindowApp.resize → EGL recreate).
    func syncBacking() {
        let (w, h) = pixelSize
        let size = CGSize(width: w, height: h)
        let scale = backingScale
        if let r = reported, r.w == w, r.h == h, r.scale == scale { return }
        reported = (w, h, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation of the backing
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        CATransaction.commit()
        print("\(SHELL): backing \(w)x\(h) px @\(scale)x\(onBackingChange == nil ? " (before start)" : "")")
        onBackingChange?(w, h, 72.0 * Double(scale))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncBacking()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncBacking()
    }

    // ---- M3.4: input → WindowApp.input (InputBridge on the render thread) ----
    //
    // Every event goes over as surface pixels from the upper left; the
    // gesture meaning (Apple Maps style) is InputBridge's, JVM-side.

    /// Called with (kind, x, y, dx, dy, amount) once the render thread exists.
    var onGesture: ((Gesture, Float, Float, Float, Float, Double) -> Void)?
    private var lastDrag: (x: CGFloat, y: CGFloat)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The event's position in surface pixels, upper-left origin. A
    /// synthesized scroll event has no window: its location is in screen
    /// coordinates then.
    private func pixels(_ e: NSEvent) -> (x: CGFloat, y: CGFloat) {
        let inWindow = e.window != nil ? e.locationInWindow
                                       : (window?.convertPoint(fromScreen: e.locationInWindow) ?? e.locationInWindow)
        let p = convert(inWindow, from: nil)
        let s = backingScale
        return (p.x * s, (bounds.height - p.y) * s)
    }

    private func send(_ g: Gesture, _ p: (x: CGFloat, y: CGFloat), dx: CGFloat = 0, dy: CGFloat = 0, amount: Double = 0) {
        onGesture?(g, Float(p.x), Float(p.y), Float(dx), Float(dy), amount)
    }

    override func mouseDown(with e: NSEvent) {
        let p = pixels(e)
        lastDrag = p
        if e.clickCount == 2 { send(.doubleClick, p) }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = pixels(e)
        defer { lastDrag = p }
        guard let last = lastDrag else { return }
        send(e.modifierFlags.contains(.option) ? .optionDrag : .drag, p, dx: p.x - last.x, dy: p.y - last.y)
    }

    override func mouseUp(with e: NSEvent) { lastDrag = nil }

    /// Trackpad (precise deltas): pan, the content following the fingers.
    /// Mouse wheel (line deltas): zoom about the pointer, positive = in.
    override func scrollWheel(with e: NSEvent) {
        let p = pixels(e)
        if e.hasPreciseScrollingDeltas {
            let s = backingScale
            send(.scroll, p, dx: e.scrollingDeltaX * s, dy: e.scrollingDeltaY * s)
        } else if e.scrollingDeltaY != 0 {
            send(.wheel, p, amount: Double(e.scrollingDeltaY))
        }
    }

    override func magnify(with e: NSEvent) { send(.magnify, pixels(e), amount: Double(e.magnification)) }

    override func rotate(with e: NSEvent) { send(.rotate, pixels(e), amount: Double(e.rotation)) }
}

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
    private var steps: [(at: TimeInterval, run: () -> Void)] = []
    private let start = Date()
    private let window: NSWindow
    private let view: MetalView

    init(window: NSWindow, view: MetalView) {
        self.window = window
        self.view = view
        let c = NSPoint(x: view.bounds.midX, y: view.bounds.midY)   // window coordinates: the view fills it
        drag(from: c, by: NSPoint(x: 160, y: 0), at: 1.0, flags: [])            // pan east
        for n in 0..<30 { steps.append((2.0 + Double(n) / 60, { self.scroll(c, dx: 0, dy: -6, units: .pixel) })) }
        for n in 0..<3 { steps.append((3.0 + Double(n) / 10, { self.scroll(NSPoint(x: c.x + 60, y: c.y + 40), dx: 0, dy: 1, units: .line) })) }
        drag(from: c, by: NSPoint(x: 0, y: 100), at: 3.6, flags: .option)       // tilt
        drag(from: c, by: NSPoint(x: 100, y: 0), at: 4.5, flags: .option)       // turn
        steps.append((5.6, { self.mouse(.leftMouseDown, c, clicks: 1) }))
        steps.append((5.62, { self.mouse(.leftMouseUp, c, clicks: 1) }))
        steps.append((5.70, { self.mouse(.leftMouseDown, c, clicks: 2) }))
        steps.append((5.72, { self.mouse(.leftMouseUp, c, clicks: 2) }))
        steps.sort { $0.at < $1.at }
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

    private func drag(from p: NSPoint, by d: NSPoint, at t: TimeInterval, flags: NSEvent.ModifierFlags) {
        let n = 30
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
    let midPoll: jmethodID
    let midExit: jmethodID
    let midStop: jmethodID
    var frameDoneLogged = false
    var lingerDeadline: Date?
    var stopRequestedByUs = false
    var stopRequestedAt: Date?
    var lastSt = -1
    var scriptedResizeAt: Date?
    var midVisible: jmethodID?          // WindowApp.setVisible, set after start
    var view: MetalView?
    var gestureScript: GestureScript?
    var gestureTimer: Timer?

    init(window: NSWindow, opt: ShellOptions, midPoll: jmethodID, midExit: jmethodID, midStop: jmethodID) {
        self.window = window
        self.opt = opt
        self.midPoll = midPoll
        self.midExit = midExit
        self.midStop = midStop
    }

    func tick() {
        let st = Int(jniCallInt(midPoll))
        if st != lastSt {
            print("\(SHELL): poll → \(st)")
            lastSt = st
        }
        if st == 1 && !frameDoneLogged {                       // PHASE_FRAME_DONE
            frameDoneLogged = true
            if opt.gestures, let v = view {
                let script = GestureScript(window: window, view: v)
                gestureScript = script
                print("\(SHELL): live script: posting gestures into the window")
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
            jniCallVoid(midStop)
            stopRequestedByUs = true
            stopRequestedAt = Date()
        }
        if stopRequestedByUs, st != 2, let t0 = stopRequestedAt,
           Date().timeIntervalSince(t0) > 30 {
            // Teardown should take well under a second; a hang here means the
            // engine stalled on the render thread. Report and get out.
            fputs("\(SHELL): teardown did not finish within 30 s — exiting anyway\n", stderr)
            exit(Int32(jniCallInt(midExit)))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let st = Int(jniCallInt(midPoll))
        if st == 2 { return .terminateNow }
        // User-initiated quit (window close / ⌘Q) while the render thread is
        // still up. Returning .terminateLater here would wedge: AppKit then
        // runs a private nested run-loop mode inside -terminate:, where this
        // delegate's timers never fire, so NSApp.reply could never happen.
        // Instead: ask the render thread to wind down and wait for EXITED
        // with a bounded run-loop pump, then terminate for real.
        jniCallVoid(midStop)
        if !stopRequestedByUs { stopRequestedByUs = true }
        stopRequestedAt = Date()
        let deadline = Date().addingTimeInterval(10)
        while Int(jniCallInt(midPoll)) != 2 && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if Int(jniCallInt(midPoll)) != 2 {
            fputs("\(SHELL): teardown did not finish within 10 s — exiting anyway\n", stderr)
            exit(Int32(jniCallInt(midExit)))
        }
        print("\(SHELL): teardown complete — terminating")
        return .terminateNow
    }

    /// M3.3: an occluded window renders nothing; WindowApp's loop pauses.
    @objc func occlusionChanged(_ note: Notification) {
        let shown = window.occlusionState.contains(.visible)
        print("\(SHELL): window \(shown ? "visible" : "occluded")")
        guard let mid = midVisible else { return }
        var a = [jvalue](repeating: jvalue(), count: 1)
        a[0].z = jboolean(shown ? JNI_TRUE : JNI_FALSE)
        jniCallVoid(mid, a)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true                              // user-close flows into the path above
    }

    /// The last point at which WindowApp's exit code can become ours. Once
    /// applicationShouldTerminate says .terminateNow, -[NSApplication
    /// terminate:] posts this and then calls exit(0) itself: app.run() never
    /// returns, so code after it never ran and a failed render exited 0.
    func applicationWillTerminate(_ notification: Notification) {
        let code = Int32(jniCallInt(midExit))
        print("\(SHELL): exiting with WindowApp's code \(code)")
        exit(code)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)         // bare binary, no bundle: claim the
app.activate()                            // regular policy so the window is key

let frame = NSRect(x: 0, y: 0, width: CGFloat(o.w), height: CGFloat(o.h))
let view = MetalView(frame: frame)
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

let shell = Shell(window: window, opt: o, midPoll: midPoll, midExit: midExit, midStop: midStop)
app.delegate = shell

// The layer pointer crosses JNI as an opaque jlong; Java never dereferences
// it (the engine's createWindowSurface does). The view keeps the layer alive.
let layerPtr = UInt(bitPattern: unsafeBitCast(view.metalLayer, to: Int.self))
let (pxW, pxH) = view.pixelSize
let startDpi = 72.0 * Double(view.backingScale)
print("\(SHELL): CAMetalLayer @ 0x\(String(layerPtr, radix: 16)) window=\(o.w)x\(o.h) pt drawable=\(pxW)x\(pxH) px contentsScale=\(view.backingScale) dpi=\(startDpi)")

var startArgs = [jvalue](repeating: jvalue(), count: 21)
startArgs[0].j = jlong(bitPattern: layerPtr)
startArgs[1].i = jint(pxW)
startArgs[2].i = jint(pxH)
startArgs[3].l = jniNewStringArray(o.libs)
startArgs[4].l = jniNewString(o.egl!)
startArgs[5].l = jniNewString(o.gles!)
startArgs[6].l = jniNewStringArray(o.layers)
startArgs[7].l = jniNewStringArray(o.basemaps)
startArgs[8].l = o.layerDb.flatMap { jniNewString($0) }
startArgs[9].l = o.out.flatMap { jniNewString($0) }
startArgs[10].d = jdouble(o.res)
startArgs[11].d = jdouble(o.atLat)
startArgs[12].d = jdouble(o.atLon)
startArgs[13].i = jint(o.frames)
startArgs[14].j = jlong(o.settleMs)
startArgs[15].d = jdouble(startDpi)
startArgs[16].j = jlong(o.liveMs)
startArgs[17].i = jint(o.resizeTo == nil ? 0 : 1)
startArgs[18].l = o.frameLog.flatMap { jniNewString($0) }
startArgs[19].z = jboolean(o.gestures ? JNI_FALSE : JNI_TRUE)        // the automatic pan
startArgs[20].i = jint(o.gestures ? GestureScript.kinds : 0)
// 3..7 must exist (libs, egl, gles, layers, basemaps); 8 (layerDb) and
// 9 (out) are nullable by contract — WindowApp substitutes a temp dir and
// skips the frame write respectively.
for (n, a) in startArgs.enumerated() where n >= 3 && n <= 7 && a.l == nil {
    shellFail("jniNewString failed for start() argument \(n)")
}
JNF.CallStaticVoidMethodA!(env, gWindowApp, midStart, &startArgs)
if jniExceptionPending("calling WindowApp.start") { exit(2) }

// M3.3: from here on, backing changes (live resize, a display with another
// scale) and occlusion reach the render thread. Both calls are quick
// synchronized setters on the Java side; the main thread never waits on
// the render thread.
view.onBackingChange = { w, h, dpi in
    var a = [jvalue](repeating: jvalue(), count: 3)
    a[0].i = jint(w); a[1].i = jint(h); a[2].d = jdouble(dpi)
    jniCallVoid(midResize, a)
}
shell.midVisible = midVisible
shell.view = view
view.onGesture = { kind, x, y, dx, dy, amount in
    var a = [jvalue](repeating: jvalue(), count: 6)
    a[0].i = jint(kind.rawValue); a[1].f = jfloat(x); a[2].f = jfloat(y)
    a[3].f = jfloat(dx); a[4].f = jfloat(dy); a[5].d = jdouble(amount)
    jniCallVoid(midInput, a)
}
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
exit(Int32(jniCallInt(midExit)))

// __JNI_AND_WINDOW__