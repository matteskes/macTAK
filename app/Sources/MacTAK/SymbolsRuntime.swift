// SymbolsRuntime.swift — `MacTAK --check-symbols` (G3.7a): the bundle's JVM
// draws MIL-STD-2525 symbols.
//
// Boots the JVM from the bundle's launch.json, as the map does, and asks
// EngineBridge for a 2525C and a 2525D symbol (missioncommand's two
// renderers, staged as engine jars), and for a code no renderer knows.
// app/test/bundle-runtime.sh runs it, so a missing jar or a renderer that
// needs something the bundle lacks fails the bundle check, not a user's map.

import Foundation
import MacTAKCore

enum SymbolsRuntime {
    /// Friendly infantry (2525C, the code ATAK 5.5 draws for a-f-G-U-C-I),
    /// the same in 2525D, and nonsense.
    static let checks: [(code: String, draws: Bool)] = [
        ("SFGPUCI--------", true),
        ("10031000001211000000", true),
        ("SXXXXXXXXXXXXXX", false),
    ]

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Exits 0 when every check answers as expected, 1 otherwise, 2 when the JVM can't start.
    static func checkAndExit() -> Never {
        let engine: EngineBridge
        do {
            let launch = try LaunchConfig.load()
            launch.applyEnvironment()
            let jvm = try JavaBoot.start(classpath: launch.resolvedClasspath, options: launch.resolvedJvmOptions)
            engine = try EngineBridge(jni: jvm.jni)
        } catch {
            print("check-symbols: \(error)")
            exit(2)
        }
        engine.onFailure = { msg in
            print("check-symbols: \(msg)")
            exit(1)
        }
        var ok = true
        for check in checks {
            let png = engine.symbolPNG(check.code)
            let isPNG = png.map { Array($0.prefix(8)) == pngSignature } ?? false
            let canRender = engine.canRenderSymbol(check.code)
            print("check-symbols: \(check.code) png=\(png.map { "\($0.count) bytes" } ?? "none") canRender=\(canRender)")
            if isPNG != check.draws || canRender != check.draws { ok = false }
        }
        exit(ok ? 0 : 1)
    }
}
