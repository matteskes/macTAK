// ConnectString.swift — a TAK server address, "host:port:proto" (G3.2b).
//
// The form ATAK 5.5 stores in cot_streams' connectStringN (takkernel's
// NetConnectString): proto is ssl, tcp or quic. Stricter than ATAK's parser,
// as G1's importer was (#32, DataPackage.java): the port must be 1–65535,
// the proto must be one of the three exactly (any case), and an IPv6
// literal must be bracketed ("[::1]:8089:ssl"), kept without its brackets.

import Foundation

public struct ConnectString: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Proto: String, Sendable, Codable, CaseIterable {
        case tcp, ssl, quic
    }

    public var host: String
    public var port: Int
    public var proto: Proto

    public init(host: String, port: Int, proto: Proto) {
        self.host = host
        self.port = port
        self.proto = proto
    }

    /// Parses `host:port[:proto]`; a missing proto means tcp, as in ATAK.
    public init(parsing text: String) throws {
        let host: String, tail: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else {
                throw ImportError("connect string \(text): no closing ]")
            }
            host = String(text[text.index(after: text.startIndex)..<close])
            tail = text[text.index(after: close)...]
        } else {
            guard text.filter({ $0 == ":" }).count <= 2 else {
                throw ImportError("connect string \(text): an IPv6 address needs brackets, as in [::1]:8089:ssl")
            }
            let colon = text.firstIndex(of: ":") ?? text.endIndex
            host = String(text[..<colon])
            tail = text[colon...]
        }
        guard !host.isEmpty else { throw ImportError("connect string \(text): no host") }
        guard tail.first == ":" else { throw ImportError("connect string \(text): no port") }
        let parts = tail.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let port = Int(parts[0]), (1...65535).contains(port) else {
            throw ImportError("connect string \(text): the port must be 1–65535")
        }
        let protoText = parts.count > 1 ? parts[1].lowercased() : ""
        guard let proto = protoText.isEmpty ? .tcp : Proto(rawValue: protoText) else {
            throw ImportError("connect string \(text): unsupported proto '\(parts[1])' (tcp, ssl or quic)")
        }
        self.init(host: host, port: port, proto: proto)
    }

    /// The streaming port a quick connect assumes, as ATAK's does.
    public static let quickConnectPort = 8089

    /// Parses a quick connect's address as ATAK's dialog takes it: a host,
    /// optionally with a port and a proto, any `scheme://` dropped. The port
    /// defaults to 8089 and the proto is TLS unless it says quic: a quick
    /// connect always enrolls for a certificate, so never plain TCP.
    public init(quickConnect text: String) throws {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = address.range(of: "://") { address = String(address[scheme.upperBound...]) }
        if let path = address.firstIndex(of: "/") { address = String(address[..<path]) }
        let hasPort = address.hasPrefix("[") ? address.contains("]:") : address.contains(":")
        var parsed = try ConnectString(parsing: hasPort ? address : address + ":\(Self.quickConnectPort)")
        if parsed.proto != .quic { parsed.proto = .ssl }
        self = parsed
    }

    /// The form ATAK writes back, brackets restored around an IPv6 host.
    public var description: String {
        (host.contains(":") ? "[\(host)]" : host) + ":\(port):\(proto.rawValue)"
    }
}
