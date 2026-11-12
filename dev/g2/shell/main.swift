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
}

let USAGE = """
usage: \(SHELL) --classpath CP --lib PATH [--lib PATH ...] --egl PATH --gles PATH
                   [--prop JVM_OPTION ...] [--size WxH] [--frames N] [--settle MS]
                   [--linger MS | --wait] [--out FILE.png] [--layer FILE ...]
                   [--basemap FILE ...] [--layer-db DIR] [--res M] [--at LAT,LON]
                   [--live MS [--resize-to WxH]] [--frame-log FILE.csv]
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
//       double dpi, long liveMs, int expectResizes, String frameLog)
let SIG_START = "(JII[Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;"
    + "[Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;DDDIJ"
    + "DJILjava/lang/String;)V"

guard let midStart = jniStaticMethod(gWindowApp, "start", SIG_START),
      let midPoll = jniStaticMethod(gWindowApp, "pollStatus", "()I"),
      let midExit = jniStaticMethod(gWindowApp, "exitCode", "()I"),
      let midStop = jniStaticMethod(gWindowApp, "stop", "()V"),
      let midResize = jniStaticMethod(gWindowApp, "resize", "(IID)V"),
      let midVisible = jniStaticMethod(gWindowApp, "setVisible", "(Z)V")
else { exit(2) }

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

var startArgs = [jvalue](repeating: jvalue(), count: 19)
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