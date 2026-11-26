// exit-capture.swift — the G3 exit run's window checks (dev/g3/test/exit-run.sh,
// dev/g3/NOTES.md §The G3 exit, PR c). Compiled by the run with swiftc.
//
//   exit-capture window PID          the id of PID's largest on-screen window
//   exit-capture count PNG RRGGBB T  pixels within T (0-255, per channel) of
//                                    RRGGBB, and how far apart they spread
//
// The capture itself is `screencapture -l ID`, which needs Screen Recording
// for the terminal running the exit. `count` prints
// "pixels=N box=WxH": a Spot Map point is a small, solid dot, so the run
// wants pixels in a small box, not scattered over the map.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("exit-capture: \(why)\n".utf8))
    exit(1)
}

func window(of pid: pid_t) -> Int {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        fail("no window list (Screen Recording?)")
    }
    let mine = list.filter {
        ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    func area(_ w: [String: Any]) -> Double {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    guard let biggest = mine.max(by: { area($0) < area($1) }),
          let id = biggest[kCGWindowNumber as String] as? Int else { fail("process \(pid) has no window") }
    return id
}

func count(_ path: String, _ hex: String, _ tolerance: Int) {
    guard let rgb = UInt32(hex, radix: 16) else { fail("not a colour: \(hex)") }
    let want = [Int(rgb >> 16 & 0xFF), Int(rgb >> 8 & 0xFF), Int(rgb & 0xFF)]
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(path)") }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { fail("can't draw \(path)") }
    var n = 0, minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            guard abs(Int(pixels[i]) - want[0]) <= tolerance, abs(Int(pixels[i + 1]) - want[1]) <= tolerance,
                  abs(Int(pixels[i + 2]) - want[2]) <= tolerance else { continue }
            n += 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let box = n == 0 ? "0x0" : "\(maxX - minX + 1)x\(maxY - minY + 1)"
    print("pixels=\(n) box=\(box)")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "window" where args.count == 3:
    guard let pid = pid_t(args[2]) else { fail("not a pid: \(args[2])") }
    print(window(of: pid))
case "count" where args.count == 5:
    guard let tolerance = Int(args[4]) else { fail("not a tolerance: \(args[4])") }
    count(args[2], args[3], tolerance)
default:
    fail("usage: exit-capture window PID | count PNG RRGGBB TOLERANCE")
}
