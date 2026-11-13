// EngineBridge.swift — the Swift side of the engine facade (G3.0).
//
// Swift reaches the engine only through mactak.engine.EngineBridge's
// statics (dev/g2/render/src/mactak/engine): the hybrid, JVM-first engine
// decision (docs/atak-feature-coverage.md §The app-layer decision). v0 is the
// map window's life cycle; map items, layers and coordinates come later.
//
// Every call is quick and non-blocking on the Java side, and must be made on
// the main thread (JNI.swift). A Java exception from a call after start is a
// broken contract between the two halves, not a runtime condition, so it
// goes to `onFailure` rather than through `throws`.

import CJavaBoot
import Darwin
import QuartzCore

/// The map window's starting configuration: mactak.engine.MapConfig.
public struct MapConfig {
    // the engine and ANGLE
    public var libs: [String] = []
    public var egl = ""
    public var gles = ""
    // data
    public var layers: [String] = []
    public var basemaps: [String] = []
    public var elevations: [String] = []
    public var layerDb: String?
    // camera: NaN frames on the content bounds
    public var res = Double.nan
    public var atLat = Double.nan
    public var atLon = Double.nan
    // the first-frame gate
    public var frames = 5
    public var settleMs: Int64 = 3000
    public var out: String?
    /// The first frame must show the attached data (the gates); the app sets false.
    public var contentGate = true
    // the G2 gates' scripted live phase (0 / off for the app)
    public var liveMs: Int64 = 0
    public var expectResizes = 0
    public var frameLog: String?
    public var scriptedPan = true
    public var gestureKinds: Int32 = 0

    public init() { }
}

/// InputBridge's gesture kinds (mactak.render.InputBridge), sent across JNI.
public enum Gesture: Int32 {
    case drag = 0, scroll, wheel, magnify, rotate, optionDrag, doubleClick
    public var bit: Int32 { 1 << rawValue }
}

public final class EngineBridge {
    public enum Phase: Int32 { case rendering = 0, frameDone = 1, exited = 2 }

    private let jni: JNI
    private let cls: jclass
    private let configCls: jclass
    private let configCtor: jmethodID
    private let midStart, midPoll, midExit, midStop, midResize, midVisible, midInput: jmethodID
    /// Called when a call across JNI raises; defaults to printing and exit(2).
    public var onFailure: (String) -> Never = { msg in
        fputs("EngineBridge: \(msg)\n", stderr)
        exit(2)
    }

    public init(jni: JNI) throws {
        self.jni = jni
        cls = try jni.findClass("mactak/engine/EngineBridge")
        configCls = try jni.findClass("mactak/engine/MapConfig")
        configCtor = try jni.method(configCls, "<init>", "()V")
        midStart = try jni.staticMethod(cls, "start", "(JIIDLmactak/engine/MapConfig;)V")
        midPoll = try jni.staticMethod(cls, "pollStatus", "()I")
        midExit = try jni.staticMethod(cls, "exitCode", "()I")
        midStop = try jni.staticMethod(cls, "stop", "()V")
        midResize = try jni.staticMethod(cls, "resize", "(IID)V")
        midVisible = try jni.staticMethod(cls, "setVisible", "(Z)V")
        midInput = try jni.staticMethod(cls, "input", "(IFFFFD)V")
    }

    /// Start the render thread on `layer` (w x h pixels at dpi) and return.
    /// The layer crosses as an opaque jlong; Java never dereferences it (the
    /// engine's createWindowSurface does). The caller keeps the layer alive.
    public func start(layer: CAMetalLayer, width: Int, height: Int, dpi: Double, config c: MapConfig) throws {
        let obj = try jni.newObject(configCls, configCtor)
        for (name, value) in Self.javaFields(of: c) {
            switch value {
            case .string(let v): try jni.set(obj, configCls, name, string: v)
            case .strings(let v): try jni.set(obj, configCls, name, strings: v)
            case .double(let v): try jni.set(obj, configCls, name, double: v)
            case .int(let v): try jni.set(obj, configCls, name, int: v)
            case .long(let v): try jni.set(obj, configCls, name, long: v)
            case .bool(let v): try jni.set(obj, configCls, name, bool: v)
            }
        }

        let ptr = UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())
        var a = [jvalue](repeating: jvalue(), count: 5)
        a[0].j = jlong(bitPattern: ptr)
        a[1].i = jint(width)
        a[2].i = jint(height)
        a[3].d = jdouble(dpi)
        a[4].l = obj
        try jni.callStaticVoid(cls, midStart, a)
    }

    /// A value for one field of mactak.engine.MapConfig.
    enum FieldValue {
        case string(String?), strings([String]), double(Double), int(Int), long(Int64), bool(Bool)
    }

    /// Every MapConfig field, by its Java name. MacTAKCoreTests checks the
    /// names against MapConfig.java, so a field added on one side only fails
    /// the build's tests instead of silently keeping its Java default.
    static func javaFields(of c: MapConfig) -> [(String, FieldValue)] {
        [("libs", .strings(c.libs)), ("egl", .string(c.egl)), ("gles", .string(c.gles)),
         ("layers", .strings(c.layers)), ("basemaps", .strings(c.basemaps)),
         ("elevations", .strings(c.elevations)), ("layerDb", .string(c.layerDb)),
         ("res", .double(c.res)), ("atLat", .double(c.atLat)), ("atLon", .double(c.atLon)),
         ("frames", .int(c.frames)), ("settleMs", .long(c.settleMs)), ("out", .string(c.out)),
         ("contentGate", .bool(c.contentGate)), ("liveMs", .long(c.liveMs)),
         ("expectResizes", .int(c.expectResizes)), ("frameLog", .string(c.frameLog)),
         ("scriptedPan", .bool(c.scriptedPan)), ("gestureKinds", .int(Int(c.gestureKinds)))]
    }

    public func pollStatus() -> Phase {
        Phase(rawValue: call { try jni.callStaticInt(cls, midPoll) }) ?? .exited
    }

    /// The final exit code (0 PASS, 1 FAIL, 2 usage, 3 EGL), once exited.
    public func exitCode() -> Int32 { call { try jni.callStaticInt(cls, midExit) } }

    public func stop() { call { try jni.callStaticVoid(cls, midStop) } }

    public func resize(width: Int, height: Int, dpi: Double) {
        var a = [jvalue](repeating: jvalue(), count: 3)
        a[0].i = jint(width); a[1].i = jint(height); a[2].d = jdouble(dpi)
        call { try jni.callStaticVoid(cls, midResize, a) }
    }

    public func setVisible(_ visible: Bool) {
        var a = [jvalue](repeating: jvalue(), count: 1)
        a[0].z = jboolean(visible ? JNI_TRUE : JNI_FALSE)
        call { try jni.callStaticVoid(cls, midVisible, a) }
    }

    public func input(_ g: Gesture, x: Float, y: Float, dx: Float, dy: Float, amount: Double) {
        var a = [jvalue](repeating: jvalue(), count: 6)
        a[0].i = jint(g.rawValue); a[1].f = jfloat(x); a[2].f = jfloat(y)
        a[3].f = jfloat(dx); a[4].f = jfloat(dy); a[5].d = jdouble(amount)
        call { try jni.callStaticVoid(cls, midInput, a) }
    }

    private func call<T>(_ body: () throws -> T) -> T {
        do { return try body() } catch { onFailure("\(error)") }
    }
}
