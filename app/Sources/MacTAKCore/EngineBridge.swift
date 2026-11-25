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
    private let midStart, midPoll, midExit, midStop, midResize, midVisible, midInput, midPanTo: jmethodID
    private let midSymbolPng, midCanRenderSymbol: jmethodID
    private let midPutMarker, midRemoveMarker, midMarkersReady, midSelfIconUri: jmethodID
    private let midPutLine, midGroundAt, midMarkerAt, midAltitudeSource: jmethodID
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
        midPanTo = try jni.staticMethod(cls, "panTo", "(DD)V")
        midSymbolPng = try jni.staticMethod(cls, "symbolPng", "(Ljava/lang/String;)[B")
        midCanRenderSymbol = try jni.staticMethod(cls, "canRenderSymbol", "(Ljava/lang/String;)Z")
        midPutMarker = try jni.staticMethod(cls, "putMarker",
                                            "(Ljava/lang/String;DDDLjava/lang/String;IIIDLjava/lang/String;)V")
        midRemoveMarker = try jni.staticMethod(cls, "removeMarker", "(Ljava/lang/String;)V")
        midMarkersReady = try jni.staticMethod(cls, "markersReady", "()Z")
        midSelfIconUri = try jni.staticMethod(cls, "selfIconUri", "(II)Ljava/lang/String;")
        midPutLine = try jni.staticMethod(cls, "putLine", "(Ljava/lang/String;[DIFIZLjava/lang/String;)V")
        midGroundAt = try jni.staticMethod(cls, "groundAt", "(FF)[D")
        midMarkerAt = try jni.staticMethod(cls, "markerAt", "(FFF)Ljava/lang/String;")
        midAltitudeSource = try jni.staticMethod(cls, "altitudeSource", "(DD)Ljava/lang/String;")
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

    /// Centre the map on (lat, lon), animated, keeping zoom and tilt.
    public func panTo(lat: Double, lon: Double) {
        var a = [jvalue](repeating: jvalue(), count: 2)
        a[0].d = jdouble(lat); a[1].d = jdouble(lon)
        call { try jni.callStaticVoid(cls, midPanTo, a) }
    }

    /// Add or move a marker (G3.7b): `hae` nil draws it at 0, `rotation`
    /// nil leaves the icon upright (degrees clockwise from north), `label`
    /// nil draws none. Dropped until `markersReady`.
    public func putMarker(uid: String, lat: Double, lon: Double, hae: Double?, iconURI: String,
                          color: UInt32, width: Int, height: Int, rotation: Double?, label: String?) {
        call {
            let jUid = try jni.newString(uid), jIcon = try jni.newString(iconURI)
            let jLabel = try label.map { try jni.newString($0) }
            defer { jni.deleteLocalRef(jUid); jni.deleteLocalRef(jIcon); jni.deleteLocalRef(jLabel) }
            var a = [jvalue](repeating: jvalue(), count: 10)
            a[0].l = jUid; a[1].d = lat; a[2].d = lon; a[3].d = hae ?? .nan
            a[4].l = jIcon; a[5].i = jint(bitPattern: color); a[6].i = jint(width); a[7].i = jint(height)
            a[8].d = rotation ?? .nan; a[9].l = jLabel
            try jni.callStaticVoid(cls, midPutMarker, a)
        }
    }

    public func removeMarker(uid: String) {
        call {
            let jUid = try jni.newString(uid)
            defer { jni.deleteLocalRef(jUid) }
            var a = [jvalue](repeating: jvalue(), count: 1)
            a[0].l = jUid
            try jni.callStaticVoid(cls, midRemoveMarker, a)
        }
    }

    /// 5.5's basic line styles (Shape.BASIC_LINE_STYLE_*), as the engine
    /// draws them (G3.10b): dashed and dotted stipple, outlined a black
    /// edge.
    public enum LineStyle: Int32, Sendable {
        case solid, dashed, dotted, outlined
    }

    /// Add or move a line (G3.8b) through `points` (two or more), clamped
    /// to the ground: `color` ARGB, `width` pixels, `style` 5.5's line
    /// style, `arrow` an arrow head at the last point (a solid line), `label`
    /// drawn along it (hidden where it doesn't fit) or nil.
    /// `removeMarker(uid:)` removes it. Dropped until `markersReady`.
    public func putLine(uid: String, points: [(lat: Double, lon: Double)], color: UInt32, width: Float,
                        style: LineStyle = .solid, arrow: Bool, label: String?) {
        call {
            let jUid = try jni.newString(uid)
            let jPoints = try jni.newDoubleArray(points.flatMap { [$0.lat, $0.lon] })
            let jLabel = try label.map { try jni.newString($0) }
            defer { jni.deleteLocalRef(jUid); jni.deleteLocalRef(jPoints); jni.deleteLocalRef(jLabel) }
            var a = [jvalue](repeating: jvalue(), count: 7)
            a[0].l = jUid; a[1].l = jPoints; a[2].i = jint(bitPattern: color); a[3].f = jfloat(width)
            a[4].i = jint(style.rawValue); a[5].z = jboolean(arrow ? JNI_TRUE : JNI_FALSE); a[6].l = jLabel
            try jni.callStaticVoid(cls, midPutLine, a)
        }
    }

    /// The ground under a surface pixel (upper-left origin) as the last
    /// frame drew it, with its height above the ellipsoid where elevation
    /// data covers it; nil off the world or before the first frame (G3.8b).
    public func groundAt(x: Float, y: Float) -> (lat: Double, lon: Double, hae: Double?)? {
        call {
            var a = [jvalue](repeating: jvalue(), count: 2)
            a[0].f = jfloat(x); a[1].f = jfloat(y)
            guard let v = try jni.callStaticDoubles(cls, midGroundAt, a), v.count == 3 else { return nil }
            return (v[0], v[1], v[2].isNaN ? nil : v[2])
        }
    }

    /// Where the altitude at (lat, lon) comes from: the elevation data's
    /// type ("DTED1", say), "???" where none covers it (G3.9d).
    public func altitudeSource(lat: Double, lon: Double) -> String? {
        call {
            var a = [jvalue](repeating: jvalue(), count: 2)
            a[0].d = lat; a[1].d = lon
            return try jni.callStaticString(cls, midAltitudeSource, a)
        }
    }

    /// The uid of the marker nearest a surface pixel (upper-left origin)
    /// within `radius` pixels, or nil (G3.8b). Lines are not picked.
    public func markerAt(x: Float, y: Float, radius: Float) -> String? {
        call {
            var a = [jvalue](repeating: jvalue(), count: 3)
            a[0].f = jfloat(x); a[1].f = jfloat(y); a[2].f = jfloat(radius)
            return try jni.callStaticString(cls, midMarkerAt, a)
        }
    }

    /// Whether the map takes markers yet; resend them all once it does.
    public var markersReady: Bool { call { try jni.callStaticBool(cls, midMarkersReady) } }

    /// The self marker's icon in these colours, as 5.5 builds it (a base64:// URI).
    public func selfIconURI(fill: UInt32, stroke: UInt32) -> String {
        call {
            var a = [jvalue](repeating: jvalue(), count: 2)
            a[0].i = jint(bitPattern: fill); a[1].i = jint(bitPattern: stroke)
            guard let uri = try jni.callStaticString(cls, midSelfIconUri, a) else { throw JNIError("no self icon") }
            return uri
        }
    }

    /// A MIL-STD-2525 point symbol as PNG (a 15-character code is 2525C,
    /// anything else 2525D/E), or nil when it isn't one the renderers draw.
    public func symbolPNG(_ code: String) -> [UInt8]? {
        call {
            let js = try jni.newString(code)
            defer { jni.deleteLocalRef(js) }
            var a = [jvalue](repeating: jvalue(), count: 1)
            a[0].l = js
            return try jni.callStaticBytes(cls, midSymbolPng, a)
        }
    }

    /// Whether `symbolPNG` draws `code`: what 5.5 asks when it maps a CoT type.
    public func canRenderSymbol(_ code: String) -> Bool {
        call {
            let js = try jni.newString(code)
            defer { jni.deleteLocalRef(js) }
            var a = [jvalue](repeating: jvalue(), count: 1)
            a[0].l = js
            return try jni.callStaticBool(cls, midCanRenderSymbol, a)
        }
    }

    private func call<T>(_ body: () throws -> T) -> T {
        do { return try body() } catch { onFailure("\(error)") }
    }
}
