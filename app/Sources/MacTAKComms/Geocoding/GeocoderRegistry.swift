// GeocoderRegistry.swift — the geocoders and which one is used, as ATAK
// 5.5's GeocodeManager keeps them: the platform's own first (it can't be
// removed), then the Nominatim servers, the selection under 5.5's key
// selected_geocoder_uid; an unknown selection falls back to the first.
// The imported servers persist as JSON in the settings store.

import Combine
import Foundation

@MainActor
public final class GeocoderRegistry: ObservableObject {
    @Published public private(set) var geocoders: [any Geocoder]
    @Published public private(set) var selectedID: String

    private let settings: SettingsStore
    private let makeNominatim: (NominatimGeocoder.Server) -> NominatimGeocoder

    static let selectedKey = "selected_geocoder_uid"
    static let serversKey = "mactak.nominatimServers"

    public init(settings: SettingsStore, native: any Geocoder = AppleGeocoder(),
                makeNominatim: @escaping (NominatimGeocoder.Server) -> NominatimGeocoder = { NominatimGeocoder($0) }) {
        self.settings = settings
        self.makeNominatim = makeNominatim
        let servers = settings.data(forKey: Self.serversKey)
            .flatMap { try? JSONDecoder().decode([NominatimGeocoder.Server].self, from: $0) } ?? []
        geocoders = [native] + servers.map(makeNominatim)
        selectedID = settings.string(forKey: Self.selectedKey) ?? native.id
    }

    /// getSelectedGeocoder: the selected one, else the first.
    public var selected: any Geocoder {
        geocoders.first { $0.id == selectedID } ?? geocoders[0]
    }

    public func select(_ id: String) {
        guard geocoders.contains(where: { $0.id == id }) else { return }
        selectedID = id
        settings.set(id, forKey: Self.selectedKey)
    }

    /// Adds the servers in an ATAK <NominatimProperties> file; one already
    /// listed (by url) is replaced. Returns how many it listed.
    @discardableResult
    public func importProperties(_ data: Data) throws -> Int {
        let added = try NominatimGeocoder.servers(fromProperties: data)
        var servers = nominatimServers
        for server in added {
            servers.removeAll { $0.url == server.url }
            servers.append(server)
        }
        setServers(servers)
        return added.count
    }

    /// Removes an imported server; the native geocoder stays.
    public func remove(_ id: String) {
        setServers(nominatimServers.filter { $0.url != id })
    }

    public var nominatimServers: [NominatimGeocoder.Server] {
        geocoders.compactMap { ($0 as? NominatimGeocoder)?.server }
    }

    private func setServers(_ servers: [NominatimGeocoder.Server]) {
        geocoders = [geocoders[0]] + servers.map(makeNominatim)
        settings.set(try? JSONEncoder().encode(servers), forKey: Self.serversKey)
    }
}
