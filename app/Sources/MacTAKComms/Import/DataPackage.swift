// DataPackage.swift — the server connections an ATAK data package carries (G3.2b).
//
// A data package is a zip. For a server connection it holds one or more
// .pref files and the PKCS#12 files they name. This is a port of what ATAK
// 5.5 does with them, read at the pin (git -C src show 9f6893d:<path>):
//
//   PreferenceControl.loadSettings   cot_streams: count, then per index j
//                                    connectStringj, descriptionj, enabledj,
//                                    useAuthj, cacheCredsj, caLocationj,
//                                    caPasswordj, certificateLocationj,
//                                    clientPasswordj,
//                                    enrollForCertificateWithTrustj,
//                                    enrollUseTrustj
//   ImportCertResolver               certificates in app_preferences
//                                    (caLocation, …) are the default for a
//                                    connection that names none of its own;
//                                    enrollUseTrust defaults to true
//
// A location names a file in the package by its basename, as ATAK copies
// every .p12 into one certificate directory. Nothing is written to disk: the
// PKCS#12 bytes go to the IdentityStore.
//
// The hardening of G1's importer (dev/g1/headless/src/mactak/headless/
// DataPackage.java) carries over: suspicious entry names are refused, every
// entry is size-capped (#31), two PKCS#12 files with one basename are
// refused as ambiguous (#32), the connect string is parsed strictly (#32),
// and no description prints a password.

import Foundation

public struct ImportError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

public struct DataPackage: Sendable {
    /// A PKCS#12 file from the package and the password the package gives it.
    public struct Certificate: Sendable, CustomStringConvertible {
        public let fileName: String
        public let pkcs12: Data
        public let password: String?

        public var description: String {
            "\(fileName) (\(pkcs12.count) bytes, password \(password == nil ? "none" : "set"))"
        }
    }

    /// One cot_streams connection.
    public struct Server: Sendable {
        public var description: String
        public var address: ConnectString
        /// As ATAK reads it: absent means false.
        public var enabled: Bool
        public var useAuth: Bool
        public var cacheCredentials: String?
        /// enrollForCertificateWithTrust: get a client certificate by
        /// enrollment (G3.2c) instead of from the package.
        public var enrollForCertificate: Bool
        /// enrollUseTrust: enroll trusting the package's CA (default true).
        public var enrollUseTrust: Bool
        public var truststore: Certificate?
        public var clientCertificate: Certificate?
    }

    public let servers: [Server]
    /// app_preferences' locationCallsign, when the package sets one.
    public let callsign: String?

    static let maxPackageBytes = 128 << 20
    static let maxPreferenceBytes = 16 << 20
    static let maxCertificateBytes = 64 << 20
    static let appPreferences = ["com.atakmap.app_preferences", "com.atakmap.civ_preferences"]

    public static func open(_ url: URL) throws -> DataPackage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxPackageBytes else {
            throw ImportError("\(url.lastPathComponent) exceeds \(maxPackageBytes) bytes")
        }
        return try DataPackage(data: Data(contentsOf: url), name: url.lastPathComponent)
    }

    /// `requireServer`: a server connection package must configure one; a
    /// device profile (G3.2c) may carry preferences only.
    public init(data: Data, name: String, requireServer: Bool = true) throws {
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch let e as ZipError { throw ImportError("\(name): \(e)") }
        let files = zip.entries.filter { !$0.isDirectory }
        for entry in files { try Self.checkEntryName(entry.name) }

        let prefs = try files.filter { $0.name.lowercased().hasSuffix(".pref") }.map { entry in
            try PreferenceFile(data: Self.read(zip, entry, limit: Self.maxPreferenceBytes), name: entry.name)
        }
        guard !prefs.isEmpty || !requireServer else { throw ImportError("\(name) has no .pref file") }

        let certificates = try CertificateFiles(zip: zip, files: files)
        let defaults = prefs.lazy.compactMap { pref in Self.appPreferences.lazy.compactMap(pref.block(named:)).first }.first
        let defaultTruststore = try certificates.resolve(defaults?.entries, "caLocation", "caPassword")
        let defaultClient = try certificates.resolve(defaults?.entries, "certificateLocation", "clientPassword")

        var servers: [Server] = []
        for streams in prefs.compactMap({ $0.block(named: "cot_streams") }) {
            let e = streams.entries
            guard let count = e["count"].flatMap(Int.init), (0...64).contains(count) else {
                throw ImportError("cot_streams has no usable count")
            }
            for j in 0..<count {
                guard let connect = e["connectString\(j)"], !connect.isEmpty else {
                    throw ImportError("cot_streams has no connectString\(j)")
                }
                servers.append(Server(
                    description: e["description\(j)"] ?? connect,
                    address: try ConnectString(parsing: connect),
                    enabled: e["enabled\(j)"].map(Self.bool) ?? false,
                    useAuth: e["useAuth\(j)"].map(Self.bool) ?? false,
                    cacheCredentials: e["cacheCreds\(j)"].flatMap { $0.isEmpty ? nil : $0 },
                    enrollForCertificate: e["enrollForCertificateWithTrust\(j)"].map(Self.bool) ?? false,
                    enrollUseTrust: e["enrollUseTrust\(j)"].map(Self.bool) ?? true,
                    truststore: try certificates.resolve(e, "caLocation\(j)", "caPassword\(j)") ?? defaultTruststore,
                    clientCertificate: try certificates.resolve(e, "certificateLocation\(j)", "clientPassword\(j)")
                        ?? defaultClient))
            }
        }
        guard !servers.isEmpty || !requireServer else {
            throw ImportError("\(name) configures no server (no cot_streams connection)")
        }
        self.servers = servers
        callsign = defaults?.entries["locationCallsign"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - details

    /// The package's PKCS#12 files by basename, read once each.
    private struct CertificateFiles {
        private let zip: ZipArchive
        private let byBaseName: [String: ZipArchive.Entry]

        init(zip: ZipArchive, files: [ZipArchive.Entry]) throws {
            self.zip = zip
            var byBaseName: [String: ZipArchive.Entry] = [:]
            for entry in files where [".p12", ".pfx"].contains(where: entry.name.lowercased().hasSuffix) {
                let base = DataPackage.baseName(entry.name).lowercased()
                if let other = byBaseName[base] {
                    throw ImportError("two PKCS#12 files share one basename, so a location can't tell them apart: "
                                      + "\(other.name), \(entry.name)")
                }
                byBaseName[base] = entry
            }
            self.byBaseName = byBaseName
        }

        /// The certificate the `location` key names, with the `password`
        /// key's value; nil when the key is absent, empty or "(built-in)"
        /// (ATAK's "none").
        func resolve(_ entries: [String: String]?, _ location: String, _ password: String) throws -> Certificate? {
            guard let path = entries?[location], !path.isEmpty, path != "(built-in)" else { return nil }
            let base = DataPackage.baseName(path)
            guard let entry = byBaseName[base.lowercased()] else {
                throw ImportError("\(location) names \(path), which isn't in the package")
            }
            return Certificate(fileName: base,
                               pkcs12: try DataPackage.read(zip, entry, limit: DataPackage.maxCertificateBytes),
                               password: entries?[password].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private static func read(_ zip: ZipArchive, _ entry: ZipArchive.Entry, limit: Int) throws -> Data {
        do { return try zip.contents(of: entry, limit: limit) } catch let e as ZipError { throw ImportError(e.description) }
    }

    /// Refuses path-traversal names (Zip-Slip), as G1's importer did. Nothing
    /// here writes to disk, but a package that carries one is hostile.
    private static func checkEntryName(_ name: String) throws {
        let suspicious = name.hasPrefix("/") || name.contains("\\") || name.contains("\0")
            || name.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
        if suspicious { throw ImportError("refusing suspicious zip entry: \(name)") }
    }

    static func baseName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    /// Java's Boolean.parseBoolean: "true" in any case, everything else false.
    private static func bool(_ text: String) -> Bool { text.lowercased() == "true" }
}
