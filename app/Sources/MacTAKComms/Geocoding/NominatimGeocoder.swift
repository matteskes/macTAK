// NominatimGeocoder.swift — a Nominatim server, as ATAK 5.5's
// GeocodeManager.NominatimGeocoder and GeocoderNominatim use one.
//
// The requests are 5.5's: <url>reverse?format=json[&key=…]&accept-language=…
// &addressdetails=1&lat=…&lon=…, and <url>search?format=json[&key=…]
// &accept-language=…&addressdetails=1&limit=1&q=…&viewbox=W,N,E,S&bounded=1,
// then again with bounded=0 when that finds nothing
// (getFromLocationNameFallback). The address is display_name less its last
// part (the country), as 5.5 trims it.
//
// The servers come from ATAK's <NominatimProperties> files: <entry name url
// serviceKey/>, the url being the uid. 5.5 reads them from tools/address.
//
// URLSession, not commo's curl: a geocoder isn't a TAK server, needs no
// client certificate, and 5.5 allows plain http for one.

import Foundation

@MainActor
public final class NominatimGeocoder: Geocoder {
    public struct Server: Sendable, Equatable, Codable {
        public var name: String
        public var url: String
        public var serviceKey: String

        public init(name: String, url: String, serviceKey: String = "") {
            self.name = name
            self.url = url
            self.serviceKey = serviceKey
        }
    }

    public let server: Server
    public var id: String { server.url }
    public var title: String { server.name }
    private let session: URLSession
    private let language: String

    /// 5.5 sends "ATAK"; Nominatim's usage policy asks for an identifying agent.
    static let userAgent = "macTAK"

    public nonisolated init(_ server: Server, session: URLSession = .shared,
                language: String = Locale.current.language.languageCode?.identifier ?? "en") {
        self.server = server
        self.session = session
        self.language = language
    }

    public func address(lat: Double, lon: Double) async throws -> GeocodeResult? {
        let data = try await get(try Self.reverseURL(server, lat: lat, lon: lon, language: language))
        return try Self.parseReverse(data)
    }

    public func locate(_ address: String, near: GeoBox?) async throws -> GeocodeResult? {
        if let near, let found = try Self.parseSearch(try await get(
            try Self.searchURL(server, query: address, near: near, bounded: true, language: language))) {
            return found
        }
        return try Self.parseSearch(try await get(
            try Self.searchURL(server, query: address, near: near, bounded: false, language: language)))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GeocodeError("\(server.name) answered HTTP \(status)") }
        return data
    }

    // MARK: - 5.5's requests and replies

    static func reverseURL(_ server: Server, lat: Double, lon: Double, language: String) throws -> URL {
        try url(server, "reverse", [("accept-language", language), ("addressdetails", "1"),
                                    ("lat", "\(lat)"), ("lon", "\(lon)")])
    }

    static func searchURL(_ server: Server, query: String, near: GeoBox?, bounded: Bool,
                          language: String) throws -> URL {
        var items = [("accept-language", language), ("addressdetails", "1"), ("limit", "1"), ("q", query)]
        if let near {
            // viewbox = left, top, right, bottom
            items.append(("viewbox", "\(near.west),\(near.north),\(near.east),\(near.south)"))
            items.append(("bounded", bounded ? "1" : "0"))
        }
        return try url(server, "search", items)
    }

    private static func url(_ server: Server, _ endpoint: String, _ items: [(String, String)]) throws -> URL {
        var base = server.url
        if !base.hasSuffix("/") { base += "/" }
        guard var parts = URLComponents(string: base + endpoint),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw GeocodeError("\(server.name): “\(server.url)” is not an http or https URL")
        }
        var query = [URLQueryItem(name: "format", value: "json")]
        if !server.serviceKey.isEmpty { query.append(URLQueryItem(name: "key", value: server.serviceKey)) }
        query += items.map { URLQueryItem(name: $0.0, value: $0.1) }
        parts.queryItems = query
        // URLComponents leaves "+" alone, which a server reads as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw GeocodeError("\(server.name): no URL for \(endpoint)") }
        return url
    }

    private struct Place: Decodable {
        let lat: String
        let lon: String
        let display_name: String?
    }

    /// /reverse answers one place, or {"error": …} where there is none.
    static func parseReverse(_ data: Data) throws -> GeocodeResult? {
        let object = try JSONSerialization.jsonObject(with: data)
        if let reply = object as? [String: Any], reply["error"] != nil { return nil }
        return result(try JSONDecoder().decode(Place.self, from: data))
    }

    /// /search answers a list, maybe empty.
    static func parseSearch(_ data: Data) throws -> GeocodeResult? {
        try JSONDecoder().decode([Place].self, from: data).lazy.compactMap(result).first
    }

    private static func result(_ place: Place) -> GeocodeResult? {
        guard let lat = Double(place.lat), let lon = Double(place.lon), var name = place.display_name else {
            return nil
        }
        if let lastComma = name.lastIndex(of: ",") { name = String(name[..<lastComma]) }
        return GeocodeResult(address: name, lat: lat, lon: lon)
    }

    /// The servers in an ATAK <NominatimProperties> file.
    public static func servers(fromProperties data: Data) throws -> [Server] {
        let reader = PropertiesReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.sawRoot else {
            throw GeocodeError("not an ATAK geocoder file (<NominatimProperties>)")
        }
        guard !reader.servers.isEmpty else { throw GeocodeError("the file lists no geocoder (<entry url=…>)") }
        return reader.servers
    }

    private final class PropertiesReader: NSObject, XMLParserDelegate {
        var servers: [Server] = []
        var sawRoot = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if element == "NominatimProperties" { sawRoot = true }
            guard element == "entry", let url = attributes["url"], !url.isEmpty else { return }
            servers.append(Server(name: attributes["name"].flatMap { $0.isEmpty ? nil : $0 } ?? url, url: url,
                                  serviceKey: attributes["serviceKey"] ?? ""))
        }
    }
}
