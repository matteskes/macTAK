// AppleGeocoder.swift — the Mac's own geocoder (MapKit), as 5.5's default
// is Android's ("Native Android Geocoder"). It needs no key; the lookups go
// to Apple. The address is MapKit's full address on one line, without the
// country, as 5.5's Nominatim reading drops it.

import CoreLocation
import Foundation
import MapKit

@MainActor
public final class AppleGeocoder: Geocoder {
    public static let identifier = "apple-geocoder"
    public let id = AppleGeocoder.identifier
    public let title = "Apple Maps"

    public nonisolated init() {}

    public func address(lat: Double, lon: Double) async throws -> GeocodeResult? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: lat, longitude: lon)) else {
            throw GeocodeError("Apple Maps can't look up \(lat), \(lon)")
        }
        return Self.result(try await Self.items(request.mapItems))
    }

    public func locate(_ address: String, near: GeoBox?) async throws -> GeocodeResult? {
        guard let request = MKGeocodingRequest(addressString: address) else {
            throw GeocodeError("Apple Maps can't look up “\(address)”")
        }
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (near.south + near.north) / 2,
                                               longitude: (near.west + near.east) / 2),
                span: MKCoordinateSpan(latitudeDelta: near.north - near.south,
                                       longitudeDelta: near.east - near.west))
        }
        return Self.result(try await Self.items(request.mapItems))
    }

    /// MapKit's "not found" is an error; here it is no result.
    private static func items(_ lookup: @autoclosure () async throws -> [MKMapItem]) async throws -> [MKMapItem] {
        do {
            return try await lookup()
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            throw GeocodeError("Apple Maps: \(error.localizedDescription)")
        }
    }

    private static func result(_ items: [MKMapItem]) -> GeocodeResult? {
        guard let item = items.first else { return nil }
        let text = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? item.address?.fullAddress ?? item.name
        guard let text, !text.isEmpty else { return nil }
        let at = item.location.coordinate
        return GeocodeResult(address: text, lat: at.latitude, lon: at.longitude)
    }
}
