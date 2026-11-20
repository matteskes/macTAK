// Geocoder.swift — address lookup, as ATAK 5.5's GeocodeManager has it.
//
// 5.5 has the platform's own geocoder (Android's, which is Google's) and
// any Nominatim servers in tools/address/*.xml, with one selected under
// selected_geocoder_uid. Here the platform's is Apple's (MapKit), and the
// Nominatim servers are imported from the same <NominatimProperties> files
// (NominatimGeocoder). What is looked up leaves the Mac: the address typed,
// or the position whose address is wanted.
//
// 5.5 looks an address up within the map's view first, then anywhere. The
// app's map doesn't report its bounds, so the search is biased to an area
// around the caller's position instead (GeoBox.around).

import Foundation

/// A looked-up address and where it is.
public struct GeocodeResult: Sendable, Equatable {
    public var address: String
    public var lat: Double
    public var lon: Double

    public init(address: String, lat: Double, lon: Double) {
        self.address = address
        self.lat = lat
        self.lon = lon
    }
}

/// An area to prefer results in.
public struct GeoBox: Sendable, Equatable {
    public var south, west, north, east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south; self.west = west; self.north = north; self.east = east
    }

    /// About a city's worth around a point: what a map view shows zoomed
    /// to a town.
    public static func around(lat: Double, lon: Double, degrees: Double = 0.25) -> GeoBox {
        GeoBox(south: max(-90, lat - degrees), west: max(-180, lon - degrees),
               north: min(90, lat + degrees), east: min(180, lon + degrees))
    }
}

public struct GeocodeError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

@MainActor
public protocol Geocoder: AnyObject {
    /// ATAK's unique identifier (selected_geocoder_uid's value).
    var id: String { get }
    /// What the picker and the <__address geocoder> attribute call it.
    var title: String { get }
    /// The address at a position; nil when there is none.
    func address(lat: Double, lon: Double) async throws -> GeocodeResult?
    /// Where an address is, preferring `near`; nil when it isn't found.
    func locate(_ address: String, near: GeoBox?) async throws -> GeocodeResult?
}
