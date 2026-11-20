// ADDR's address lookup: 5.5's Nominatim requests and replies, against
// dev/g3/test/fake-nominatim-server.py; ATAK's <NominatimProperties> files;
// the registry's selection under 5.5's key; the placed position's address;
// and <__address> on received contacts and markers. Apple's geocoder needs
// the network and Apple's service, so only MACTAK_NETWORK_TESTS=1 runs it.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class GeocodingTests: XCTestCase {
    private let server = NominatimGeocoder.Server(name: "Test", url: "https://nominatim.example/v1/", serviceKey: "k1")

    // MARK: - 5.5's requests

    func testTheReverseRequestIs5_5s() throws {
        let url = try NominatimGeocoder.reverseURL(server, lat: 38.8977, lon: -77.0365, language: "en")
        XCTAssertEqual(url.absoluteString, "https://nominatim.example/v1/reverse?format=json&key=k1"
                       + "&accept-language=en&addressdetails=1&lat=38.8977&lon=-77.0365")
    }

    func testTheSearchIsBoundedToTheViewboxThenNot() throws {
        let box = GeoBox(south: 38.6, west: -77.3, north: 39.1, east: -76.8)
        let bounded = try NominatimGeocoder.searchURL(server, query: "1600 Pennsylvania Ave+NW", near: box,
                                                      bounded: true, language: "en")
        XCTAssertEqual(bounded.absoluteString, "https://nominatim.example/v1/search?format=json&key=k1"
                       + "&accept-language=en&addressdetails=1&limit=1&q=1600%20Pennsylvania%20Ave%2BNW"
                       + "&viewbox=-77.3,39.1,-76.8,38.6&bounded=1")
        let keyless = NominatimGeocoder.Server(name: "T", url: "http://localhost:8080/nominatim")
        let anywhere = try NominatimGeocoder.searchURL(keyless, query: "x", near: nil, bounded: false, language: "de")
        XCTAssertEqual(anywhere.absoluteString, "http://localhost:8080/nominatim/search?format=json"
                       + "&accept-language=de&addressdetails=1&limit=1&q=x")
        XCTAssertThrowsError(try NominatimGeocoder.searchURL(NominatimGeocoder.Server(name: "F", url: "ftp://x/"),
                                                             query: "x", near: nil, bounded: false, language: "en"))
    }

    func testRepliesDropTheCountryAndNothingIsNil() throws {
        let place = Data(#"{"lat":"38.8977","lon":"-77.0365","display_name":"1600, Pennsylvania Avenue, Washington, United States"}"#.utf8)
        XCTAssertEqual(try NominatimGeocoder.parseReverse(place),
                       GeocodeResult(address: "1600, Pennsylvania Avenue, Washington", lat: 38.8977, lon: -77.0365))
        XCTAssertNil(try NominatimGeocoder.parseReverse(Data(#"{"error":"Unable to geocode"}"#.utf8)))
        XCTAssertNil(try NominatimGeocoder.parseSearch(Data("[]".utf8)))
        XCTAssertEqual(try NominatimGeocoder.parseSearch(Data("[\(String(decoding: place, as: UTF8.self))]".utf8))?.lat,
                       38.8977)
        XCTAssertThrowsError(try NominatimGeocoder.parseSearch(Data("<html>".utf8)))
    }

    // MARK: - against a server

    func testLookupsAgainstAServer() async throws {
        let port = try freePort()
        let fake = try FakeServer.nominatim(port: port)
        defer { fake.stop() }
        let geocoder = NominatimGeocoder(NominatimGeocoder.Server(name: "Fake", url: "http://127.0.0.1:\(port)/nominatim/"),
                                         language: "en")

        let here = try await geocoder.address(lat: 38.8977, lon: -77.0365)
        XCTAssertEqual(here, GeocodeResult(address: "Test Street 1, Testville", lat: 38.8977, lon: -77.0365))
        let nothing = try await geocoder.address(lat: 0, lon: 0)
        XCTAssertNil(nothing)

        let near = GeoBox.around(lat: 38.9, lon: -77.0)
        let found = try await geocoder.locate("Test Street 1", near: near)
        XCTAssertEqual(found?.lat, 38.8977)
        XCTAssertEqual(fake.log.components(separatedBy: "q=Test%20Street%201").count - 1, 1, "found in the viewbox: one request")
        let far = try await geocoder.locate("far", near: near)
        XCTAssertNotNil(far, "not in the viewbox, found anywhere")
        XCTAssertTrue(fake.log.contains("q=far&viewbox=-77.25,39.15,-76.75,38.65&bounded=1"), fake.log)
        XCTAssertTrue(fake.log.contains("q=far&viewbox=-77.25,39.15,-76.75,38.65&bounded=0"), fake.log)
        let missing = try await geocoder.locate("nowhere", near: nil)
        XCTAssertNil(missing)
        XCTAssertTrue(fake.log.contains("ua=macTAK"), fake.log)

        let broken = NominatimGeocoder(NominatimGeocoder.Server(name: "Fake", url: "http://127.0.0.1:\(port)/missing/"))
        do {
            _ = try await broken.address(lat: 1, lon: 1)
            XCTFail("a 404 read as an answer")
        } catch let error as GeocodeError {
            XCTAssertEqual(error.description, "Fake answered HTTP 404")
        }
    }

    // MARK: - ATAK's files and the registry

    func testATAKsGeocoderFileImports() throws {
        let file = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <NominatimProperties>
        <entry name="Public TAK Server" url="https://127.0.0.1:456/" serviceKey=""/>
        <entry name="" url="https://nominatim.example/v1/" serviceKey="k1"/>
        </NominatimProperties>
        """.utf8)
        XCTAssertEqual(try NominatimGeocoder.servers(fromProperties: file), [
            NominatimGeocoder.Server(name: "Public TAK Server", url: "https://127.0.0.1:456/"),
            NominatimGeocoder.Server(name: "https://nominatim.example/v1/", url: "https://nominatim.example/v1/",
                                     serviceKey: "k1"),
        ])
        XCTAssertThrowsError(try NominatimGeocoder.servers(fromProperties: Data("<preferences/>".utf8)))
        XCTAssertThrowsError(try NominatimGeocoder.servers(fromProperties: Data("<NominatimProperties/>".utf8)))
    }

    func testTheRegistryKeepsServersAndTheSelectionUnder5_5sKey() throws {
        let settings = MemorySettings()
        let registry = GeocoderRegistry(settings: settings)
        XCTAssertEqual(registry.selected.id, AppleGeocoder.identifier, "the native geocoder first")
        let file = Data(#"<NominatimProperties><entry name="A" url="https://a.example/"/><entry name="B" url="https://b.example/"/></NominatimProperties>"#.utf8)
        XCTAssertEqual(try registry.importProperties(file), 2)
        registry.select("https://b.example/")
        XCTAssertEqual(settings.string(forKey: "selected_geocoder_uid"), "https://b.example/")
        registry.select("https://unknown.example/")
        XCTAssertEqual(registry.selected.title, "B", "an unknown id isn't selected")

        let reopened = GeocoderRegistry(settings: settings)
        XCTAssertEqual(reopened.geocoders.map(\.title), ["Apple Maps", "A", "B"])
        XCTAssertEqual(reopened.selected.title, "B")
        try reopened.importProperties(Data(#"<NominatimProperties><entry name="B2" url="https://b.example/"/></NominatimProperties>"#.utf8))
        XCTAssertEqual(reopened.geocoders.map(\.title), ["Apple Maps", "A", "B2"], "same url: replaced")
        reopened.remove("https://b.example/")
        reopened.remove(AppleGeocoder.identifier)
        XCTAssertEqual(reopened.geocoders.map(\.title), ["Apple Maps", "A"], "the native one stays")
        XCTAssertEqual(reopened.selected.title, "Apple Maps", "its selection gone, the first")
    }

    // MARK: - the placed position's address

    func testThePlacedAddressIsKeptWhileThePositionStays() {
        let settings = MemorySettings()
        let me = SelfReporter.testing(settings)
        let address = AddressDetail(text: "Test Street 1, Testville", geocoder: "Fake", time: "2026-11-20T12:00:00.000Z")
        me.place(CotPoint(lat: 38.8977, lon: -77.0365), address: address)
        XCTAssertEqual(me.addressOfPlaced, address)
        XCTAssertEqual(SelfReporter.testing(settings).addressOfPlaced, address, "persisted")

        me.placed = CotPoint(lat: 38.897704, lon: -77.036504)
        XCTAssertEqual(me.addressOfPlaced, address, "under a metre: kept")
        me.placed = CotPoint(lat: 38.9, lon: -77.0365)
        XCTAssertNil(me.addressOfPlaced, "moved: not its address")
        me.placed = CotPoint(lat: 38.8977, lon: -77.0365)
        XCTAssertEqual(me.addressOfPlaced, address, "back where it was looked up")
        me.place(CotPoint(lat: 1, lon: 1), address: nil)
        XCTAssertNil(me.addressOfPlaced)
    }

    // MARK: - received

    func testReceivedContactsAndMarkersKeepTheirAddress() throws {
        let address = AddressDetail(text: "Test Street 1, Testville", geocoder: "Apple Maps", time: "2026-11-20T12:00:00.000Z")
        func event(_ uid: String, endpoint: Bool) -> String {
            var e = SelfEvent(uid: uid, callsign: uid.uppercased()).event(at: Date(), stale: 60)
            var detail = e.detail ?? CotDetail("detail")
            if !endpoint {
                detail.children.removeAll { $0.name == "contact" }
                var c = CotDetail("contact")
                c["callsign"] = uid.uppercased()
                detail.add(c)
            }
            detail.add(address.detail)
            e.detail = detail
            return e.xml()
        }
        let contacts = ContactStore(selfUID: "me")
        XCTAssertTrue(contacts.receive(event("peer", endpoint: true), via: .mesh))
        XCTAssertEqual(contacts["peer"]?.address, address)
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        XCTAssertTrue(markers.receive(event("m1", endpoint: false)))
        XCTAssertEqual(markers.markers.first?.address, address)
    }

    // MARK: - Apple's, by hand

    func testApplesGeocoderFindsAnAddress() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACTAK_NETWORK_TESTS"] == "1",
                          "needs Apple's service: MACTAK_NETWORK_TESTS=1")
        let apple = AppleGeocoder()
        let house = try await apple.locate("1600 Pennsylvania Ave NW, Washington, DC", near: nil)
        let found = try XCTUnwrap(house)
        XCTAssertEqual(found.lat, 38.8977, accuracy: 0.01)
        XCTAssertEqual(found.lon, -77.0365, accuracy: 0.01)
        let back = try await apple.address(lat: found.lat, lon: found.lon)
        XCTAssertTrue(try XCTUnwrap(back).address.contains("Pennsylvania"), back?.address ?? "")
        print("apple-geocoder: \(found.address) | \(back?.address ?? "")")
    }
}
