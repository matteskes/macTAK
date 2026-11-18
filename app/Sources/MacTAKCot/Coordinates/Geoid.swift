// Geoid.swift — EGM96's height above the WGS84 ellipsoid, for altitude in
// MSL (G3.6a).
//
// 5.5's EGM96.getOffset always ends in the WMM grid compiled into the
// engine (it configures no egm96-file): 721 rows × 1441 columns of
// float heights at 15′, row 0 at 90°N, column 0 at 0°E, interpolated
// bilinearly by MAG_GetGeoidHeight. The grid is app/Resources/
// egm96-15.grid, written from the engine's own EGM9615.h by
// dev/g3/test/geoid-oracle.cpp (make geoid-grid), which also checks the
// heights here against the engine's code (make test-coord-golden).

import Foundation

public struct Geoid: Sendable {
    static let rows = 721
    static let columns = 1441
    /// Grid cells per degree.
    static let scale = 4.0

    private let heights: [Float]

    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The grid file, little-endian float32s.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = Self.rows * Self.columns
        guard data.count == count * 4 else {
            throw LoadError(description: "\(url.lastPathComponent) has \(data.count) bytes, not \(count * 4)")
        }
        heights = data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    /// The geoid's height above the ellipsoid in metres (HAE − MSL), or
    /// nil off the earth (a NaN, |lat| > 90), as ElevationManager_getGeoidHeight.
    public func offset(lat: Double, lng: Double) -> Double? {
        if lat.isNaN || lng.isNaN || lat < -90 || lat > 90 { return nil }
        var longitude = lng
        if longitude < -180 { longitude += 360 } else if longitude > 180 { longitude -= 360 }
        return height(latitude: lat, longitude: longitude)
    }

    /// MAG_GetGeoidHeight, line for line.
    private func height(latitude: Double, longitude: Double) -> Double? {
        if latitude < -90 || latitude > 90 || longitude < -180 || longitude > 360 { return nil }
        let offsetX = (longitude < 0 ? longitude + 360 : longitude) * Self.scale
        let offsetY = (90 - latitude) * Self.scale
        var postX = offsetX.rounded(.down)
        if postX + 1 == Double(Self.columns) { postX -= 1 }
        var postY = offsetY.rounded(.down)
        if postY + 1 == Double(Self.rows) { postY -= 1 }

        var index = Int(postY * Double(Self.columns) + postX)
        let nw = Double(heights[index]), ne = Double(heights[index + 1])
        index = Int((postY + 1) * Double(Self.columns) + postX)
        let sw = Double(heights[index]), se = Double(heights[index + 1])

        let deltaX = offsetX - postX, deltaY = offsetY - postY
        let upperY = nw + deltaX * (ne - nw)
        let lowerY = sw + deltaX * (se - sw)
        return upperY + deltaY * (lowerY - upperY)
    }
}
