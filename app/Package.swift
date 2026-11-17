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
//   CCommoShim    C++: commo's listener classes forwarded to C callbacks,
//                 behind a plain C API (commo_shim.h)
//   MacTAKComms   the CommoClient actor and the self-SA presence
//
// Every build links commo (G3.2): a built commo in dev/g1/native-dist
// (dev/g1/build-commo.sh; CI's shell job downloads the comms job's), or the
// directory MACTAK_COMMO_LIB names, the atak-civ headers in src/, and the
// headers of the curl commo carries (dev/g1/build-curl/prefix/include).
//
// jni.h comes from the repo's pinned copy (dev/g1/jdk-include): the JNI
// surface used here is JNI 1.8's, which JDK 21 serves unchanged, so the
// build needs no JDK on the machine.
import PackageDescription
import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let jniInclude = repo.appendingPathComponent("dev/g1/jdk-include").path
let commoLib = ProcessInfo.processInfo.environment["MACTAK_COMMO_LIB"].flatMap { $0.isEmpty ? nil : $0 }
    ?? repo.appendingPathComponent("dev/g1/native-dist").path
let commoInclude = repo.appendingPathComponent("src/commoncommo/core/include").path
// The curl commo carries (dev/g1/fetch-curl.sh): the shim calls it for the
// device profile's https GET (G3.2c), resolved against commo's exports.
let curlInclude = repo.appendingPathComponent("dev/g1/build-curl/prefix/include").path

// Fail here, with the fix, rather than at link time with "library not found".
for (path, fix) in [
    ("\(commoLib)/libcommoncommo.dylib", "run dev/g1/build-commo.sh, or set MACTAK_COMMO_LIB to commo's directory"),
    ("\(commoInclude)/commo.h", "check out atak-civ at the pin into src/ (CONTRIBUTING.md, Setup)"),
    ("\(curlInclude)/curl/curl.h", "run dev/g1/build-commo.sh, which builds commo's curl"),
] where !FileManager.default.fileExists(atPath: path) {
    fatalError("app/Package.swift: \(path) is missing — \(fix)")
}

let package = Package(
    name: "MacTAK",
    platforms: [.macOS("27.0")],   // the supported floor (dev/g3/NOTES.md, trap 3)
    products: [
        .executable(name: "MacTAK", targets: ["MacTAK"]),
        .executable(name: "mactak-shell", targets: ["mactak-shell"]),
        .library(name: "MacTAKCore", targets: ["MacTAKCore"]),
        .library(name: "MacTAKComms", targets: ["MacTAKComms"]),
    ],
    targets: [
        .target(
            name: "CJavaBoot",
            cSettings: [.unsafeFlags(["-I\(jniInclude)", "-Wall", "-Wextra"])]
        ),
        .target(
            name: "MacTAKCore",
            dependencies: ["CJavaBoot"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(jniInclude)"])]
        ),
        .executableTarget(
            name: "mactak-shell",
            dependencies: ["MacTAKCore", "CJavaBoot"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(jniInclude)"])]
        ),
        .executableTarget(
            name: "MacTAK",
            dependencies: ["MacTAKCore", "CJavaBoot"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(jniInclude)"])],
            // the bundle's natives live in Contents/Frameworks (app/bundle.sh, #152)
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "MacTAKCoreTests",
            dependencies: ["MacTAKCore"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(jniInclude)"])]
        ),
        .target(
            name: "CCommoShim",
            cxxSettings: [.unsafeFlags(["-isystem\(commoInclude)", "-isystem\(curlInclude)",
                                        "-DCURL_STATICLIB", "-Wall", "-Wextra"])],
            linkerSettings: [.unsafeFlags(["-L\(commoLib)", "-lcommoncommo",
                                           "-Xlinker", "-rpath", "-Xlinker", commoLib])]
        ),
        .target(name: "MacTAKComms", dependencies: ["CCommoShim"]),
        .testTarget(name: "MacTAKCommsTests", dependencies: ["MacTAKComms"]),
    ],
    cxxLanguageStandard: .cxx17
)

