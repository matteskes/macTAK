// ADDR: <__address>, as 5.5's AddressDetailHandler writes and reads it.

import XCTest
@testable import MacTAKCot

final class AddressDetailTests: XCTestCase {
    func testItReadsAndWrites5_5sAttributes() throws {
        let xml = """
        <event version="2.0" uid="m1" type="a-h-G" how="h-g-i-g-o" time="2026-11-20T12:00:00Z" \
        start="2026-11-20T12:00:00Z" stale="2026-11-20T12:05:00Z"><point lat="38.8977" lon="-77.0365" \
        hae="0" ce="9999999" le="9999999"/><detail><__address text="1600 Pennsylvania Ave NW, Washington" \
        geocoder="Apple Maps" time="2026-11-20T11:59:00.000Z"/></detail></event>
        """
        let event = try CotEvent.parse(xml)
        let address = try XCTUnwrap(AddressDetail(event.detail(AddressDetail.elementName)))
        XCTAssertEqual(address, AddressDetail(text: "1600 Pennsylvania Ave NW, Washington", geocoder: "Apple Maps",
                                              time: "2026-11-20T11:59:00.000Z"))
        XCTAssertEqual(AddressDetail(address.detail), address, "what it writes reads back")
        XCTAssertEqual(address.detail.name, "__address")
    }

    func testNoTextIsNoAddressAndNoGeocoderIsUnknown() {
        var d = CotDetail("__address")
        d["geocoder"] = "Apple Maps"
        XCTAssertNil(AddressDetail(d), "5.5 takes nothing without text")
        d["text"] = "Somewhere"
        d["geocoder"] = nil
        XCTAssertEqual(AddressDetail(d)?.geocoder, "unknown")
        XCTAssertNil(AddressDetail(CotDetail("contact")))
    }

    func testTheLocationHashIsTheFifthDecimalPlace() {
        XCTAssertEqual(AddressDetail.locationHash(lat: 38.897704, lon: -77.036504), "38.8977,-77.0365")
        XCTAssertEqual(AddressDetail.locationHash(lat: 38.897704, lon: -77.036504),
                       AddressDetail.locationHash(lat: 38.897696, lon: -77.036496), "under a metre apart")
        XCTAssertNotEqual(AddressDetail.locationHash(lat: 38.8977, lon: -77.0365),
                          AddressDetail.locationHash(lat: 38.89772, lon: -77.0365), "two metres apart")
        XCTAssertEqual(AddressDetail.locationHash(lat: 38, lon: 0), "38.0,0.0", "Java's Double.toString")
    }
}
