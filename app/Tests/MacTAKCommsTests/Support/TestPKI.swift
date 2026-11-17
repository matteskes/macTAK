// A throwaway PKI for the TLS and QUIC legs, made with Homebrew's openssl@3
// the way dev/g1/headless/test/quic.sh makes its own: one CA signs a
// serverAuth leaf for the server and clientAuth leaves for the clients, and
// a second CA signs an impostor client that the server must refuse.

import Foundation
@testable import MacTAKComms

struct TestPKI {
    static let password = "atakatak"

    /// The directory holding every file below; deleted by `remove()`.
    let dir: URL

    var caPEM: String { path("ca.crt") }
    var caKey: String { path("ca.key") }
    var serverCert: String { path("server.crt") }
    var serverKey: String { path("server.key") }

    /// A client identity signed by the server's CA, with the CA as its trust.
    func credentials(_ client: String) throws -> TLSCredentials {
        TLSCredentials(identity: try Data(contentsOf: URL(fileURLWithPath: path("\(client).p12"))),
                       identityPassword: Self.password,
                       ca: try Data(contentsOf: URL(fileURLWithPath: path("truststore.p12"))),
                       caPassword: Self.password)
    }

    /// The server's CA, or the other CA, as a truststore (PKCS#12).
    func truststore(other: Bool = false) throws -> TLSTruststore {
        TLSTruststore(pkcs12: try Data(contentsOf: URL(fileURLWithPath: path(other ? "other-truststore.p12" : "truststore.p12"))),
                      password: Self.password)
    }

    /// Makes the CA, the server leaf, a client leaf per name in `clients`,
    /// and an `impostor` client signed by another CA.
    static func make(clients: [String]) throws -> TestPKI {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactak-pki-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pki = TestPKI(dir: dir)
        try pki.makeCA("ca")
        try pki.makeCA("other-ca")
        try pki.makeLeaf("server", ca: "ca", usage: "serverAuth")
        for client in clients {
            try pki.makeLeaf(client, ca: "ca", usage: "clientAuth")
        }
        try pki.makeLeaf("impostor", ca: "other-ca", usage: "clientAuth")
        try pki.openssl(["pkcs12", "-export", "-nokeys", "-in", pki.path("ca.crt"),
                         "-out", pki.path("truststore.p12"), "-passout", "pass:\(password)", "-name", "ca"])
        try pki.openssl(["pkcs12", "-export", "-nokeys", "-in", pki.path("other-ca.crt"),
                         "-out", pki.path("other-truststore.p12"), "-passout", "pass:\(password)", "-name", "other-ca"])
        return pki
    }

    func remove() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - openssl

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func makeCA(_ name: String) throws {
        try write("\(name).ext", "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n")
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", path("\(name).key"),
                     "-out", path("\(name).csr"), "-subj", "/CN=mactak-test-\(name)"])
        try openssl(["x509", "-req", "-in", path("\(name).csr"), "-signkey", path("\(name).key"),
                     "-out", path("\(name).crt"), "-days", "2", "-extfile", path("\(name).ext")])
    }

    private func makeLeaf(_ name: String, ca: String, usage: String) throws {
        try write("\(name).ext", "extendedKeyUsage=\(usage)\n")
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", path("\(name).key"),
                     "-out", path("\(name).csr"), "-subj", "/CN=\(name)"])
        try openssl(["x509", "-req", "-in", path("\(name).csr"), "-CA", path("\(ca).crt"),
                     "-CAkey", path("\(ca).key"), "-CAcreateserial", "-out", path("\(name).crt"),
                     "-days", "2", "-extfile", path("\(name).ext")])
        try openssl(["pkcs12", "-export", "-in", path("\(name).crt"), "-inkey", path("\(name).key"),
                     "-certfile", path("\(ca).crt"), "-out", path("\(name).p12"),
                     "-passout", "pass:\(Self.password)", "-name", name])
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    /// Homebrew's openssl@3: Apple's /usr/bin/openssl is LibreSSL.
    static let opensslPath = ProcessInfo.processInfo.environment["MACTAK_OPENSSL"]
        ?? "/opt/homebrew/opt/openssl@3/bin/openssl"

    private func openssl(_ arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.opensslPath) else {
            throw CommoError(description: "\(Self.opensslPath) missing — brew install openssl@3, or set MACTAK_OPENSSL")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.opensslPath)
        p.arguments = arguments
        let errors = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        try p.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CommoError(description: "openssl \(arguments.first ?? "") failed: "
                             + String(decoding: message, as: UTF8.self))
        }
    }
}
