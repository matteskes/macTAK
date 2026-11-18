// CoordinateTests.swift — G3.6's gate, the Swift leg: the coordinate port
// writes and reads what 5.5 does (G3.6a).
//
// The expected files in dev/g3/test/coord-golden come from 5.5's own
// CoordinateFormatUtilities and the kernel's MGRSPoint, UTMPoint and
// SpanUtilities, and from the engine's geoid code (make test-coord-golden
// checks them against those every CI run). Strings must match exactly;
// positions and geoid heights to 1e-9 (relative beyond 1).

import Foundation
import XCTest
@testable import MacTAKCot

final class CoordinateTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let golden = root.appendingPathComponent("dev/g3/test/coord-golden")
    static let grid = root.appendingPathComponent("app/Resources/egm96-15.grid")
    static let formats: [CoordinateFormat] = [.mgrs, .utm, .dd, .dm, .dms]

    /// Tab-separated rows of an expected file, '#' lines skipped.
    private func rows(_ name: String) throws -> [[String]] {
        try String(contentsOf: Self.golden.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    private func escape(_ s: String) -> String { s.replacingOccurrences(of: "\u{200E}", with: "\\u200E") }
    private func unescape(_ s: String) -> String { s.replacingOccurrences(of: "\\u200E", with: "\u{200E}") }

    private func close(_ a: Double, _ b: Double) -> Bool {
        a == b || abs(a - b) <= 1e-9 * max(1, abs(a), abs(b))
    }

    /// convert's result as the expected files write it, or nil for a position.
    private func outcome(_ text: String, _ format: CoordinateFormat) -> (String?, (Double, Double)?) {
        do {
            guard let p = try Coordinates.parse(text, as: format) else { return ("!null", nil) }
            return (nil, (p.lat, p.lng))
        } catch let e as CoordinateError {
            return (e.malformed ? "!exception" : "!error \(e.description)", nil)
        } catch {
            return ("!unexpected \(error)", nil)
        }
    }

    private func checkOutcome(_ got: (String?, (Double, Double)?), _ want: String, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        if want.hasPrefix("!") {
            XCTAssertEqual(got.0, want, what, file: file, line: line)
            return
        }
        let parts = want.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let p = got.1 else {
            XCTFail("\(what): got \(got.0 ?? "?"), want \(want)", file: file, line: line)
            return
        }
        XCTAssertTrue(close(p.0, parts[0]) && close(p.1, parts[1]),
                      "\(what): got \(p.0),\(p.1), want \(want)", file: file, line: line)
    }

    func testEveryFormatWritesWhat55Writes() throws {
        let expected = try rows("expected/format.tsv")
        XCTAssertGreaterThan(expected.count, 40)
        for row in expected {
            let lat = try XCTUnwrap(Double(row[0])), lng = try XCTUnwrap(Double(row[1]))
            var got = [row[0], row[1]]
            for f in Self.formats {
                got.append(escape(Coordinates.format(lat: lat, lng: lng, as: f)))
                got.append(escape(Coordinates.format(lat: lat, lng: lng, as: f, short: true)))
            }
            got.append(MGRSPoint(lat: lat, lng: lng).formattedString)
            for (i, (g, w)) in zip(got, row).enumerated() where g != w {
                XCTFail("\(row[0]) \(row[1]) column \(i + 1): got \(g), want \(w)")
            }
        }
    }

    func testWhatItWritesReadsBackAs55Reads() throws {
        let expected = try rows("expected/roundtrip.tsv")
        for row in expected {
            let lat = try XCTUnwrap(Double(row[0])), lng = try XCTUnwrap(Double(row[1]))
            let f = try XCTUnwrap(CoordinateFormat(rawValue: row[2]))
            let text = Coordinates.format(lat: lat, lng: lng, as: f)
            checkOutcome(outcome(text, f), row[3], "\(row[0]) \(row[1]) \(row[2]) \(escape(text))")
        }
    }

    func testTypedCoordinatesReadAs55ReadsThem() throws {
        let expected = try rows("expected/parse.tsv")
        XCTAssertGreaterThan(expected.count, 50)
        for row in expected {
            let f = CoordinateFormat(displayName: row[0])
            checkOutcome(outcome(unescape(row[1]), f), row[2], "\(row[0]) \(row[1])")
        }
    }

    func testAltitudesInFeetAndMetres() throws {
        for row in try rows("expected/altitudes.tsv") {
            let metres = try XCTUnwrap(Double(row[0]))
            XCTAssertEqual(Altitude.spanFormat(metres, .feet), row[1], row[0])
            XCTAssertEqual(Altitude.spanFormat(metres, .meters), row[2], row[0])
        }
    }

    func testGeoidHeightsAreTheEngines() throws {
        let geoid = try Geoid(contentsOf: Self.grid)
        let expected = try rows("expected/geoid.tsv")
        XCTAssertGreaterThan(expected.count, 40)
        for row in expected {
            let lat = Double(row[0]) ?? .nan, lng = Double(row[1]) ?? .nan
            let got = geoid.offset(lat: lat, lng: lng)
            if row[2] == "!invalid" {
                XCTAssertNil(got, "\(row[0]) \(row[1])")
            } else {
                let want = try XCTUnwrap(Double(row[2]))
                XCTAssertTrue(got.map { abs($0 - want) < 1e-9 } ?? false, "\(row[0]) \(row[1]): got \(String(describing: got)), want \(want)")
            }
        }
    }

    func testMSLIsHAEMinusTheGeoid() throws {
        let geoid = try Geoid(contentsOf: Self.grid)
        // at 0,0 the geoid is 17.162 m above the ellipsoid
        XCTAssertEqual(Altitude.format(hae: 117.162, lat: 0, lng: 0, reference: .msl, units: .meters, geoid: geoid), "100 m MSL")
        XCTAssertEqual(Altitude.format(hae: 117.162, lat: 0, lng: 0, reference: .msl, units: .feet, geoid: geoid), "328 ft MSL")
        XCTAssertEqual(Altitude.format(hae: 117.162, lat: 0, lng: 0, reference: .hae, units: .meters, geoid: geoid), "117 m HAE")
        // unknown, out of GeoPoint's range, or off the earth: 5.5 says feet whatever the units
        XCTAssertEqual(Altitude.format(hae: 9999999, lat: 0, lng: 0, reference: .msl, units: .meters, geoid: geoid), "-- ft MSL")
        XCTAssertEqual(Altitude.format(hae: .nan, lat: 0, lng: 0, reference: .hae, units: .meters, geoid: geoid), "-- ft HAE")
        XCTAssertEqual(Altitude.format(hae: 100, lat: 91, lng: 0, reference: .hae, units: .meters, geoid: geoid), "-- ft MSL")
    }

    func testAShortGridIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).grid")
        try Data(count: 16).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Geoid(contentsOf: url))
    }

    func testTheReadoutCyclesAs55Does() {
        var f = CoordinateFormat.dd
        var seen: [CoordinateFormat] = []
        for _ in 0..<5 { seen.append(f); f = f.next }
        XCTAssertEqual(seen, [.dd, .dm, .dms, .utm, .mgrs])
        XCTAssertEqual(f, .dd)
        XCTAssertEqual(CoordinateFormat(displayName: "nonsense"), .mgrs)
        XCTAssertEqual(CoordinateFormat(displayName: nil), .default)
    }

    func testJavaRoundingEdges() {
        // DecimalFormat HALF_UP on the double's exact value: 1.005 is 1.00499…
        XCTAssertEqual(JavaNumber.format(1.005, fraction: 2), "1.00")
        XCTAssertEqual(JavaNumber.format(0.125, fraction: 2), "0.13")
        XCTAssertEqual(JavaNumber.format(-0.001, fraction: 2), "-0.00")
        XCTAssertEqual(JavaNumber.format(9.99999, minInt: 2, fraction: 4), "10.0000")
        XCTAssertEqual(JavaNumber.format(1234567, grouping: true), "1,234,567")
        // Math.round: halves up, not away from zero
        XCTAssertEqual(JavaNumber.round(-2.5), -2)
        XCTAssertEqual(JavaNumber.round(2.5), 3)
        XCTAssertEqual(JavaNumber.round(0.49999999999999994), 0)
        XCTAssertEqual(JavaNumber.parseDouble(" 2d "), 2)
        XCTAssertNil(JavaNumber.parseDouble("inf"))
        XCTAssertEqual(JavaNumber.parseDouble("-Infinity"), -.infinity)
    }
}
