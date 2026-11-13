// swift-tools-version:5.9
//
// macTAK's Swift app (G3; the plan in dev/g3/NOTES.md). Targets:
//
//   CJavaBoot     C: finds libjli and creates the in-process JVM (moved from
//                 dev/g2/shell, M3.2)
//   MacTAKCore    the shared library: JNI helpers, the JVM boot, the map's
//                 Metal view and its input, the EngineBridge client
//   mactak-shell  the G2 test harness (make test-shell, make exit-run),
//                 rebuilt on MacTAKCore with the same flags and log lines
//   MacTAK        the SwiftUI app (app/bundle.sh makes build/MacTAK.app)
//
// jni.h comes from the repo's pinned copy (dev/g1/jdk-include): the JNI
// surface used here is JNI 1.8's, which JDK 21 serves unchanged, so the
// build needs no JDK on the machine.
import PackageDescription
import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let jniInclude = repo.appendingPathComponent("dev/g1/jdk-include").path

let package = Package(
    name: "MacTAK",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacTAK", targets: ["MacTAK"]),
        .executable(name: "mactak-shell", targets: ["mactak-shell"]),
        .library(name: "MacTAKCore", targets: ["MacTAKCore"]),
    ],
    targets: [
        .target(
            name: "CJavaBoot",
            cSettings: [.unsafeFlags(["-I", jniInclude, "-Wall", "-Wextra"])]
        ),
        .target(
            name: "MacTAKCore",
            dependencies: ["CJavaBoot"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I", "-Xcc", jniInclude])]
        ),
        .executableTarget(
            name: "mactak-shell",
            dependencies: ["MacTAKCore", "CJavaBoot"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I", "-Xcc", jniInclude])]
        ),
        .executableTarget(
            name: "MacTAK",
            dependencies: ["MacTAKCore", "CJavaBoot"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I", "-Xcc", jniInclude])]
        ),
        .testTarget(
            name: "MacTAKCoreTests",
            dependencies: ["MacTAKCore"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I", "-Xcc", jniInclude])]
        ),
    ]
)
