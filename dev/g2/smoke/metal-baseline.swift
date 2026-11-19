// metal-baseline.swift — trap #77, step 1: does a bare Metal window drop
// frames the way the exit run does, with no ANGLE, JVM or engine?
//
// One titled NSWindow at the shell's default size (640x480 pt), a
// CAMetalLayer set up as ANGLE sets up ours (BGRA8, framebufferOnly off,
// display sync on, default drawable count of 3), and a render thread that
// blocks on nextDrawable, clears to a new colour, presents and commits,
// for --seconds. Timed like WindowApp's live loop: the interval is
// present to present on the render thread, and a drop is an interval
// past 1.5 x the run's median. It also records when each drawable
// actually reached the screen (addPresentedHandler), which the exit run
// cannot see: an on-screen interval past 1.5 x the median is a refresh
// the viewer missed, whatever our cadence said.
//
// --settle S (default 0.5) shows the window S seconds before the render
// thread starts, to separate a cause tied to the app's launch from one
// tied to the first frames. Drop times are also given from launch.
//
// Writes a per-frame CSV to --csv and prints one summary line.
// Build: swiftc -O metal-baseline.swift -o metal-baseline

import AppKit
import Metal
import QuartzCore

struct Options {
    var seconds = 11.0
    var csv = "metal-baseline.csv"
    var width: CGFloat = 640
    var height: CGFloat = 480
    var settle = 0.5
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--seconds": o.seconds = Double(args.next()!)!
        case "--csv": o.csv = args.next()!
        case "--settle": o.settle = Double(args.next()!)!
        case "--size":
            let p = args.next()!.split(separator: "x").map { CGFloat(Double($0)!) }
            o.width = p[0]; o.height = p[1]
        default:
            FileHandle.standardError.write("metal-baseline: unknown option \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

final class FrameLog {
    let lock = NSLock()
    var submitted: [UInt64] = []        // mach-continuous ns after present+commit
    var waitNs: [UInt64] = []           // time blocked in nextDrawable
    var onScreen: [Int: CFTimeInterval] = [:]   // frame → presentedTime (s)

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

func median(_ v: [Double]) -> Double {
    let s = v.sorted()
    return s.isEmpty ? 0 : s[s.count / 2]
}

func percentile(_ v: [Double], _ p: Double) -> Double {
    let s = v.sorted()
    return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
}

let launchNs = FrameLog.now()
let o = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("metal-baseline: no Metal device"); exit(1)
}

let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: o.width, height: o.height),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "metal-baseline"
let view = NSView(frame: NSRect(x: 0, y: 0, width: o.width, height: o.height))
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.framebufferOnly = false
layer.displaySyncEnabled = true
view.layer = layer
view.wantsLayer = true
window.contentView = view
let scale = window.backingScaleFactor
layer.contentsScale = scale
layer.drawableSize = CGSize(width: o.width * scale, height: o.height * scale)

app.activate()
window.makeKeyAndOrderFront(nil)

let log = FrameLog()

let renderThread = Thread {
    let deadline = FrameLog.now() + UInt64(o.seconds * 1e9)
    var frame = 0
    while FrameLog.now() < deadline {
        autoreleasepool {
            let w0 = FrameLog.now()
            guard let drawable = layer.nextDrawable() else { return }
            let waited = FrameLog.now() - w0
            let hue = Double(frame % 120) / 120.0
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1)
            let cb = queue.makeCommandBuffer()!
            cb.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
            let f = frame
            drawable.addPresentedHandler { d in
                log.lock.lock(); log.onScreen[f] = d.presentedTime; log.lock.unlock()
            }
            cb.present(drawable)
            cb.commit()
            log.lock.lock()
            log.submitted.append(FrameLog.now())
            log.waitNs.append(waited)
            log.lock.unlock()
            frame += 1
        }
    }
    // let the last presented handlers arrive
    Thread.sleep(forTimeInterval: 0.2)
    DispatchQueue.main.async { finish() }
}

func finish() {
    log.lock.lock(); defer { log.lock.unlock() }
    let n = log.submitted.count
    var iv: [Double] = []
    for i in 1..<n { iv.append(Double(log.submitted[i] - log.submitted[i - 1]) / 1e6) }
    var screenIv: [Int: Double] = [:]
    for i in 1..<n {
        if let a = log.onScreen[i - 1], let b = log.onScreen[i], a > 0, b > 0 { screenIv[i] = (b - a) * 1e3 }
    }
    let med = median(iv)
    let limit = med * 1.5
    let screenMed = median(Array(screenIv.values))
    let screenLimit = screenMed * 1.5
    let dropped = iv.enumerated().filter { $0.element > limit }
    let screenDropped = screenIv.filter { $0.value > screenLimit }.sorted { $0.key < $1.key }
    let notShown = (0..<n).filter { (log.onScreen[$0] ?? 0) <= 0 }.count
    let origin = log.submitted.first ?? 0
    let sinceLaunch = { (f: Int) in Double(log.submitted[f] - launchNs) / 1e9 }

    var csv = "frame,t_s,interval_ms,drawable_wait_ms,on_screen_interval_ms\n"
    for i in 0..<n {
        let t = Double(log.submitted[i] - origin) / 1e9
        let ivs = i == 0 ? "" : String(format: "%.3f", iv[i - 1])
        let sc = screenIv[i].map { String(format: "%.3f", $0) } ?? ""
        csv += String(format: "%d,%.4f,%@,%.3f,%@\n", i, t, ivs, Double(log.waitNs[i]) / 1e6, sc)
    }
    try? csv.write(toFile: o.csv, atomically: true, encoding: .utf8)

    print(String(format: "metal-baseline: %d frames; interval ms p50 %.2f p95 %.2f max %.2f (%.1f fps); dropped (>%.1f ms) %d; on-screen p50 %.2f max %.2f, missed (>%.1f ms) %d; not shown %d; drawable %dx%d @%.0fx",
                 n, med, percentile(iv, 0.95), iv.max() ?? 0, 1000 / max(med, 0.001), limit, dropped.count,
                 screenMed, screenIv.values.max() ?? 0, screenLimit, screenDropped.count, notShown,
                 Int(layer.drawableSize.width), Int(layer.drawableSize.height), scale))
    for (i, v) in dropped {
        let f = i + 1
        print(String(format: "metal-baseline: dropped frame %d at %.3f s (%.3f s after launch): interval %.2f ms, drawable wait %.2f ms",
                     f, Double(log.submitted[f] - origin) / 1e9, sinceLaunch(f), v, Double(log.waitNs[f]) / 1e6))
    }
    for (f, v) in screenDropped {
        print(String(format: "metal-baseline: on-screen miss before frame %d at %.3f s (%.3f s after launch): %.2f ms",
                     f, Double(log.submitted[f] - origin) / 1e9, sinceLaunch(f), v))
    }
    exit(0)
}

// Start once the window is on screen, as the shell does after its first
// layout; --settle delays it further, with the window already showing.
DispatchQueue.main.asyncAfter(deadline: .now() + o.settle) { renderThread.start() }
app.run()
