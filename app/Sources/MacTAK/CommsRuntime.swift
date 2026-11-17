// CommsRuntime.swift — what commo needs from the bundle before it starts (G3.2d).
//
// commo loads OpenSSL's legacy provider in every Commo constructor
// (CryptoUtil::staticInit): PKCS#12 files from TAK servers, and the
// Keychain's own exports, use RC2 and 3DES. OpenSSL looks for the provider
// in OPENSSL_MODULES, or else in the directory it was built with, which is
// Homebrew's cellar on the build Mac. app/bundle.sh stages legacy.dylib in
// Contents/Frameworks, so the app points OPENSSL_MODULES there before any
// CommoClient exists (dev/g3/NOTES.md, trap 7).

import Foundation
import MacTAKComms

enum CommsRuntime {
    /// Points OpenSSL at the bundle's provider modules, when the bundle has them.
    static func configure() {
        guard let frameworks = Bundle.main.privateFrameworksURL,
              FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("legacy.dylib").path)
        else { return }
        setenv("OPENSSL_MODULES", frameworks.path, 1)
    }

    /// `MacTAK --check-comms-runtime`: start commo the way the app does and
    /// report whether it loaded OpenSSL's legacy provider (app/test/
    /// bundle-runtime.sh runs it). Exits 0 when it did, 1 when it didn't.
    static func checkAndExit() -> Never {
        configure()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loaded: Bool?
        Task.detached {
            do {
                let client = try CommoClient(uid: "mactak-runtime-check", callsign: "CHECK", logLevel: .info)
                for await event in client.events {
                    guard case let .log(_, message) = event, message.contains("ossl legacy provider") else { continue }
                    print("check-comms-runtime: \(message)")
                    loaded = message.contains("loaded successfully")
                    break
                }
                await client.shutdown()
            } catch {
                print("check-comms-runtime: \(error)")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut { print("check-comms-runtime: no answer from commo") }
        print("check-comms-runtime: OPENSSL_MODULES=\(ProcessInfo.processInfo.environment["OPENSSL_MODULES"] ?? "unset")")
        exit(loaded == true ? 0 : 1)
    }
}
