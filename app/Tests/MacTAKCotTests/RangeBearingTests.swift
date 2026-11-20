// RangeBearingTests.swift — G3.8a's gate, the Swift leg: range, bearing,
// slant range, grid convergence, magnetic north and their text are what
// 5.5 computes and writes.
//
// The expected files in dev/g3/test/rab-golden come from 5.5's own
// GeoCalculations, AngleUtilities and SpanUtilities on the engine's natives
// with 5.5's wmm_cof (make test-rab-golden checks them against those every
// CI run). Strings must match exactly; numbers to 1e-9 (relative beyond 1).

import Foundation
import XCTest
@testable import MacTAKCot

final class RangeBearingTests: XCTestCase {
    static let golden = CoordinateTests.root.appendingPathComponent("dev/g3/test/rab-golden")
    static let wmmCof = CoordinateTests.root.appendingPathComponent("app/Resources/wmm_cof")

    private func rows(_ name: String) throws -> [[String]] {
        try String(contentsOf: Self.golden.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    private func number(_ s: String) -> Double { s == "NaN" ? .nan : Double(s)! }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        a == b || (a.isNaN && b.isNaN) || abs(a - b) <= tolerance * max(1, abs(a), abs(b))
    }

    func testGeodesyIsTheEngines() throws {
        let pairs = try rows("pairs.tsv"), expected = try rows("expected/geodesy.tsv")
        XCTAssertEqual(pairs.count, expected.count)
        var mismatches: [String] = []
        for (p, e) in zip(pairs, expected) {
            let v = p.map(number)
            let got = [
                Geodesy.distance(lat1: v[0], lon1: v[1], lat2: v[3], lon2: v[4]),
                Geodesy.bearing(lat1: v[0], lon1: v[1], lat2: v[3], lon2: v[4]),
                Geodesy.slantDistance(lat1: v[0], lon1: v[1], hae1: v[2], lat2: v[3], lon2: v[4], hae2: v[5]),
                Geodesy.gridConvergence(lat1: v[0], lon1: v[1], lat2: v[3], lon2: v[4]),
            ]
            // Grid convergence over a line shorter than a millimetre is the
            // bearing of a rounding error (the same point twice: 4e-11 m), in
            // the engine as here; 5.5 asks for it only on a drawn line.
            let names = number(e[0]) < 1e-3 ? ["distance", "bearing", "slant"] : ["distance", "bearing", "slant", "grid"]
            for (i, name) in names.enumerated()
            where !close(got[i], number(e[i])) {
                mismatches.append("\(p.joined(separator: " ")) \(name): \(got[i]) want \(e[i])")
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// G3.8d: a received line's far end, as RangeAndBearingImporter finds it.
    func testPointAtDistanceIsTheEngines() throws {
        let starts = try rows("destinations.tsv"), expected = try rows("expected/destinations.tsv")
        XCTAssertEqual(starts.count, expected.count)
        var mismatches: [String] = []
        for (r, e) in zip(starts, expected) {
            let v = r.map(number), want = e.map(number)
            let got = Geodesy.pointAtDistance(lat: v[0], lon: v[1], hae: v[2], azimuth: v[3], distance: v[4],
                                              inclination: v[5])
            for (name, g, w) in [("lat", got.lat, want[0]), ("lon", got.lon, want[1]), ("hae", got.hae, want[2])]
            where !close(g, w) {
                mismatches.append("\(r.joined(separator: " ")) \(name): \(g) want \(w)")
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testMagneticNorthIsTheEngines() throws {
        let model = try MagneticModel(contentsOf: Self.wmmCof)
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var mismatches: [String] = []
        for (r, e) in zip(try rows("magnetic.tsv"), try rows("expected/magnetic.tsv")) {
            let noon = calendar.date(from: DateComponents(year: Int(r[2]), month: Int(r[3])! + 1, day: Int(r[4]),
                                                          hour: 12))!
            let dec = model.declination(lat: number(r[0]), lon: number(r[1]), at: noon, timeZone: utc)
            let mag = model.magnetic(fromTrue: number(r[5]), lat: number(r[0]), lon: number(r[1]), at: noon,
                                     timeZone: utc)
            if dec.map({ close($0, number(e[0])) }) != true || mag.map({ close($0, number(e[1])) }) != true {
                mismatches.append("\(r.joined(separator: " ")): \(String(describing: dec)), \(String(describing: mag)) want \(e[0]), \(e[1])")
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testAnglesAreWrittenAs5_5WritesThem() throws {
        var mismatches: [String] = []
        for (r, e) in zip(try rows("angles.tsv"), try rows("expected/angles.tsv")) {
            let v = number(r[0])
            let got = [RangeBearingText.angle(v, .degrees), RangeBearingText.angle(v, .mils),
                       RangeBearingText.angle(v, .degrees, isBearing: false),
                       RangeBearingText.angle(v, .mils, isBearing: false)]
            if got != e { mismatches.append("\(r[0]): \(got) want \(e)") }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testRangesAreWrittenAs5_5WritesThem() throws {
        let low = RangeBearingText.Thresholds(feetToMiles: 100, metersToKilometers: 500)
        var mismatches: [String] = []
        for (r, e) in zip(try rows("ranges.tsv"), try rows("expected/ranges.tsv")) {
            let m = number(r[0])
            let got = [RangeBearingText.range(m, .feetMiles), RangeBearingText.range(m, .metersKilometers),
                       RangeBearingText.range(m, .nauticalMiles),
                       RangeBearingText.range(m, .feetMiles, thresholds: low),
                       RangeBearingText.range(m, .metersKilometers, thresholds: low)]
            if got != e { mismatches.append("\(r[0]): \(got) want \(e)") }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testTheCompassPointsAreDirectionTypes() {
        XCTAssertEqual([0, 22.4, 22.5, 67.5, 112.5, 157.5, 202.5, 247.5, 292.5, 337.4, 337.5, -10, 359.9]
            .map(RangeBearingText.cardinal), ["N", "N", "NE", "E", "SE", "S", "SW", "W", "NW", "NW", "N", "N", "N"])
    }
}
