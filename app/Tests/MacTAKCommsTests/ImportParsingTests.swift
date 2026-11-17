// The data-package importer's parts (G3.2b): the zip reader, the connect
// string, and a package's servers and certificates. Each refusal mirrors
// one in G1's DataPackageSelfTest.

import Foundation
import XCTest
@testable import MacTAKComms

final class ImportParsingTests: XCTestCase {
    // MARK: - connect strings

    func testConnectStringsATAKWrites() throws {
        XCTAssertEqual(try ConnectString(parsing: "tak.example.org:8089:ssl"),
                       ConnectString(host: "tak.example.org", port: 8089, proto: .ssl))
        XCTAssertEqual(try ConnectString(parsing: "10.0.0.1:8090:QUIC").proto, .quic)
        XCTAssertEqual(try ConnectString(parsing: "10.0.0.1:8087").proto, .tcp)
        let v6 = try ConnectString(parsing: "[fd00::1]:8089:ssl")
        XCTAssertEqual(v6.host, "fd00::1")
        XCTAssertEqual(v6.description, "[fd00::1]:8089:ssl")
    }

    func testConnectStringsRefused() {
        for text in ["host:0:ssl", "host:65536:ssl", "host:8089:dtls", "fd00::1:8089:ssl", "host",
                     ":8089:ssl", "[fd00::1:8089:ssl", "host:port:ssl"] {
            XCTAssertThrowsError(try ConnectString(parsing: text), text)
        }
    }

    // MARK: - the zip reader

    func testReadsStoredAndDeflatedEntries() throws {
        var zip = ZipWriter()
        let text = String(repeating: "takserver ", count: 500)
        zip.add("a.txt", text)
        zip.add("b.bin", Data([1, 2, 3]), deflate: false)
        let archive = try ZipArchive(data: zip.archive())
        XCTAssertEqual(archive.entries.map(\.name), ["a.txt", "b.bin"])
        XCTAssertEqual(try archive.contents(of: archive.entries[0], limit: 1 << 20), Data(text.utf8))
        XCTAssertEqual(try archive.contents(of: archive.entries[1], limit: 1 << 20), Data([1, 2, 3]))
    }

    /// The system's zip writes what ATAK's do; this reads one of those too.
    func testReadsAnArchiveFromTheSystemZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactak-zip-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("certs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = String(repeating: "<entry key='x'>y</entry>\n", count: 200)
        try text.write(to: dir.appendingPathComponent("certs/server.pref"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-r", "out.zip", "certs"]
        try p.run()
        p.waitUntilExit()
        let archive = try ZipArchive(data: Data(contentsOf: dir.appendingPathComponent("out.zip")))
        let entry = try XCTUnwrap(archive.entries.first { $0.name == "certs/server.pref" })
        XCTAssertEqual(entry.method, 8)
        XCTAssertEqual(try archive.contents(of: entry, limit: 1 << 20), Data(text.utf8))
    }

    func testRefusesAnEntryOverTheCap() throws {
        var zip = ZipWriter()
        zip.add("big.p12", Data(count: 4096))
        let archive = try ZipArchive(data: zip.archive())
        XCTAssertThrowsError(try archive.contents(of: archive.entries[0], limit: 4095)) {
            XCTAssertEqual(($0 as? ZipError)?.description, "big.p12 exceeds 4095 bytes")
        }
    }

    /// A header that claims a small size can't sneak a large entry past the cap.
    func testRefusesAnEntryLargerThanItsHeaderSays() throws {
        var zip = ZipWriter()
        zip.entries.append(.init(name: "liar.p12", data: Data(count: 1 << 16), declaredSize: 16))
        let archive = try ZipArchive(data: zip.archive())
        XCTAssertThrowsError(try archive.contents(of: archive.entries[0], limit: 1024)) {
            XCTAssertTrue("\($0)".contains("more than 16 declared bytes"), "\($0)")
        }
    }

    func testRefusesABadCRCAndEncryptedEntries() throws {
        var bad = ZipWriter()
        bad.entries.append(.init(name: "x.pref", data: Data("abc".utf8), crc: 1))
        let archive = try ZipArchive(data: bad.archive())
        XCTAssertThrowsError(try archive.contents(of: archive.entries[0], limit: 1024)) {
            XCTAssertEqual(($0 as? ZipError)?.description, "x.pref: CRC mismatch")
        }
        var encrypted = ZipWriter()
        encrypted.entries.append(.init(name: "x.pref", data: Data("abc".utf8), flags: 0x0801))
        XCTAssertThrowsError(try ZipArchive(data: encrypted.archive()))
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip".utf8)))
    }

    // MARK: - data packages

    func testResolvesServersAndTheirCertificates() throws {
        var zip = ZipWriter()
        zip.add("MANIFEST/manifest.xml", "<MissionPackageManifest version='2'/>")
        zip.add("certs/server.pref", Self.pref(streams: [
            ["connectString": "tak.example.org:8089:ssl", "description": "Ops", "enabled": "true",
             "caLocation": "cert/truststore-ops.p12", "caPassword": "trustpw",
             "certificateLocation": "/sdcard/atak/cert/user.p12", "clientPassword": "userpw"],
            ["connectString": "tak.example.org:8090:quic", "enabled": "TRUE",
             "enrollForCertificateWithTrust": "true", "useAuth": "true", "cacheCreds": "Cache credentials"],
        ], app: ["locationCallsign": "VIPER-1", "caLocation": "cert/default-ca.p12", "caPassword": "defpw"]))
        zip.add("certs/truststore-ops.p12", Data([1]))
        zip.add("certs/user.p12", Data([2]))
        zip.add("certs/default-ca.p12", Data([3]))

        let package = try DataPackage(data: zip.archive(), name: "fixture.zip")
        XCTAssertEqual(package.callsign, "VIPER-1")
        XCTAssertEqual(package.servers.count, 2)
        let ops = package.servers[0], quic = package.servers[1]
        XCTAssertEqual(ops.description, "Ops")
        XCTAssertEqual(ops.address, ConnectString(host: "tak.example.org", port: 8089, proto: .ssl))
        XCTAssertTrue(ops.enabled)
        XCTAssertEqual(ops.truststore?.pkcs12, Data([1]))
        XCTAssertEqual(ops.truststore?.password, "trustpw")
        XCTAssertEqual(ops.clientCertificate?.pkcs12, Data([2]))
        XCTAssertEqual(ops.clientCertificate?.password, "userpw")
        XCTAssertFalse(ops.enrollForCertificate)
        // The second names no certificates of its own: the default CA applies.
        XCTAssertEqual(quic.description, "tak.example.org:8090:quic")
        XCTAssertEqual(quic.address.proto, .quic)
        XCTAssertTrue(quic.enabled)
        XCTAssertEqual(quic.truststore?.pkcs12, Data([3]))
        XCTAssertNil(quic.clientCertificate)
        XCTAssertTrue(quic.enrollForCertificate)
        XCTAssertTrue(quic.enrollUseTrust)
        XCTAssertTrue(quic.useAuth)
        XCTAssertEqual(quic.cacheCredentials, "Cache credentials")
        XCTAssertFalse("\(ops.clientCertificate!)".contains("userpw"))
    }

    /// As ATAK reads it (Boolean.parseBoolean): an absent enabled is false.
    func testAbsentEnabledIsFalse() throws {
        var zip = ZipWriter()
        zip.add("a.pref", Self.pref(streams: [["connectString": "h:8087:tcp"]]))
        XCTAssertFalse(try DataPackage(data: zip.archive(), name: "p").servers[0].enabled)
    }

    func testRefusesHostilePackages() throws {
        let streams = [["connectString": "h:8089:ssl", "caLocation": "cert/ca.p12", "caPassword": "x"]]
        let cases: [(String, (inout ZipWriter) -> Void, String)] = [
            ("traversal", { $0.add("../evil.p12", Data([1])) }, "refusing suspicious zip entry: ../evil.p12"),
            ("absolute", { $0.add("/etc/evil.pref", "x") }, "refusing suspicious zip entry: /etc/evil.pref"),
            ("same basename", { $0.add("other/ca.p12", Data([2])) },
             "two PKCS#12 files share one basename, so a location can't tell them apart: certs/ca.p12, other/ca.p12"),
            ("doctype", { $0.add("x.pref", "<!DOCTYPE p [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><preferences/>") },
             "x.pref: a DOCTYPE or entity declaration is not allowed"),
        ]
        for (label, mutate, message) in cases {
            var zip = ZipWriter()
            zip.add("a.pref", Self.pref(streams: streams))
            zip.add("certs/ca.p12", Data([1]))
            mutate(&zip)
            XCTAssertThrowsError(try DataPackage(data: zip.archive(), name: "p"), label) {
                XCTAssertEqual("\($0)", message, label)
            }
        }
    }

    func testRefusesIncompletePackages() throws {
        var noPref = ZipWriter()
        noPref.add("certs/ca.p12", Data([1]))
        XCTAssertThrowsError(try DataPackage(data: noPref.archive(), name: "p")) {
            XCTAssertEqual("\($0)", "p has no .pref file")
        }
        var missingCert = ZipWriter()
        missingCert.add("a.pref", Self.pref(streams: [["connectString": "h:8089:ssl", "caLocation": "cert/gone.p12"]]))
        XCTAssertThrowsError(try DataPackage(data: missingCert.archive(), name: "p")) {
            XCTAssertEqual("\($0)", "caLocation0 names cert/gone.p12, which isn't in the package")
        }
        var noServer = ZipWriter()
        noServer.add("a.pref", Self.pref(streams: [], app: ["locationCallsign": "X"]))
        XCTAssertThrowsError(try DataPackage(data: noServer.archive(), name: "p")) {
            XCTAssertEqual("\($0)", "p configures no server (no cot_streams connection)")
        }
    }

    // MARK: - helpers

    /// A .pref as ATAK writes one: cot_streams entries indexed from 0, and
    /// app_preferences.
    static func pref(streams: [[String: String]], app: [String: String] = [:]) -> String {
        func entry(_ key: String, _ value: String) -> String {
            "    <entry key=\"\(key)\" class=\"class java.lang.String\">\(value)</entry>\n"
        }
        var xml = "<?xml version='1.0' standalone='yes'?>\n<preferences>\n"
        xml += "  <preference version=\"1\" name=\"cot_streams\">\n" + entry("count", "\(streams.count)")
        for (j, stream) in streams.enumerated() {
            for (key, value) in stream.sorted(by: { $0.key < $1.key }) { xml += entry("\(key)\(j)", value) }
        }
        xml += "  </preference>\n  <preference version=\"1\" name=\"com.atakmap.app_preferences\">\n"
        for (key, value) in app.sorted(by: { $0.key < $1.key }) { xml += entry(key, value) }
        return xml + "  </preference>\n</preferences>\n"
    }
}
