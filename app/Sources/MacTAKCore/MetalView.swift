// MetalView.swift — the map's view: a CAMetalLayer the engine renders into
// on its own thread (ANGLE/Metal), and the AppKit input it forwards.
// Moved from the G2 shell (M3.0–M3.4) unchanged in behaviour.

import AppKit
import Metal
import QuartzCore

public final class MetalView: NSView {
    public let metalLayer: CAMetalLayer
    /// Called with the new drawableSize (pixels) and dpi after every backing
    /// change, once the render thread exists (set after EngineBridge.start).
    public var onBackingChange: ((Int, Int, Double) -> Void)?
    /// Called with each input event once the render thread exists.
    public var onGesture: ((Gesture, Float, Float, Float, Float, Double) -> Void)?
    /// Called once, when the view is first in a window with a non-empty size:
    /// the moment a host can start the engine on it. SwiftUI adds the view to
    /// its window before laying it out, so joining the window alone is too
    /// early (a 1x1 surface the first resize cannot rebuild).
    public var onReady: ((MetalView) -> Void)?
    private var readyAnnounced = false
    private let log: (String) -> Void
    /// The backing last reported: compared against, not the layer's
    /// drawableSize, which Core Animation may already have moved along with
    /// the layer's bounds by the time setFrameSize runs (G2 trap #58).
    private var reported: (w: Int, h: Int, scale: CGFloat)?
    private var lastDrag: (x: CGFloat, y: CGFloat)?

    /// `log` gets one line per backing change.
    public init(frame frameRect: NSRect, log: @escaping (String) -> Void = { print($0) }) {
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        self.log = log
        super.init(frame: frameRect)
        self.layer = metalLayer          // set explicitly, Chromium-style: on
        self.wantsLayer = true           // current macOS a +layerClass override
        syncBacking()                    // is ignored for backing layers (M3.0)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    public var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Pixels the surface needs: the view's points times the backing scale.
    public var pixelSize: (Int, Int) {
        let s = backingScale
        return (max(1, Int((bounds.width * s).rounded())), max(1, Int((bounds.height * s).rounded())))
    }

    /// The engine's dpi for this backing: 72 x the scale.
    public var dpi: Double { 72.0 * Double(backingScale) }

    /// M3.3 Retina: drawableSize = points x backing scale, contentsScale =
    /// that scale, dpi = 72 x scale. The layer's drawableSize is the host's
    /// truth; the render thread adopts it (WindowApp.resize → EGL recreate).
    public func syncBacking() {
        let (w, h) = pixelSize
        let scale = backingScale
        if let r = reported, r.w == w, r.h == h, r.scale == scale { return }
        reported = (w, h, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation of the backing
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: w, height: h)
        CATransaction.commit()
        log("backing \(w)x\(h) px @\(scale)x\(onBackingChange == nil ? " (before start)" : "")")
        onBackingChange?(w, h, 72.0 * Double(scale))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncBacking()
        announceReadyIfSized()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncBacking()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncBacking()
        announceReadyIfSized()
    }

    private func announceReadyIfSized() {
        guard !readyAnnounced, window != nil, bounds.width >= 1, bounds.height >= 1 else { return }
        readyAnnounced = true
        onReady?(self)
    }

    // ---- M3.4: input → EngineBridge.input (InputBridge on the render thread) --
    //
    // Every event goes over as surface pixels from the upper left; the
    // gesture meaning (Apple Maps style) is InputBridge's, JVM-side.

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

    public override func mouseDown(with e: NSEvent) {
        let p = pixels(e)
        lastDrag = p
        if e.clickCount == 2 { send(.doubleClick, p) }
    }

    public override func mouseDragged(with e: NSEvent) {
        let p = pixels(e)
        defer { lastDrag = p }
        guard let last = lastDrag else { return }
        send(e.modifierFlags.contains(.option) ? .optionDrag : .drag, p, dx: p.x - last.x, dy: p.y - last.y)
    }

    public override func mouseUp(with e: NSEvent) { lastDrag = nil }

    /// Trackpad (precise deltas): pan, the content following the fingers.
    /// Mouse wheel (line deltas): zoom about the pointer, positive = in.
    public override func scrollWheel(with e: NSEvent) {
        let p = pixels(e)
        if e.hasPreciseScrollingDeltas {
            let s = backingScale
            send(.scroll, p, dx: e.scrollingDeltaX * s, dy: e.scrollingDeltaY * s)
        } else if e.scrollingDeltaY != 0 {
            send(.wheel, p, amount: Double(e.scrollingDeltaY))
        }
    }

    public override func magnify(with e: NSEvent) { send(.magnify, pixels(e), amount: Double(e.magnification)) }

    public override func rotate(with e: NSEvent) { send(.rotate, pixels(e), amount: Double(e.rotation)) }
}

extension MetalView {
    /// Wire this view to a started engine: backing changes and input.
    public func connect(to engine: EngineBridge) {
        onBackingChange = { w, h, dpi in engine.resize(width: w, height: h, dpi: dpi) }
        onGesture = { kind, x, y, dx, dy, amount in
            engine.input(kind, x: x, y: y, dx: dx, dy: dy, amount: amount)
        }
    }
}
