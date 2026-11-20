// AddressDetail.swift — <__address>, a point's looked-up street address, as
// ATAK 5.5's AddressDetailHandler writes and reads it: the address text, the
// geocoder's title, and when it was looked up. 5.5 sends it with a point
// whose address was looked up for where the point still is, and keeps a
// received one against the event's point.

import Foundation

public struct AddressDetail: Sendable, Equatable, Codable {
    public static let elementName = "__address"

    public var text: String
    /// The geocoder's title; 5.5 writes "unknown" when it has none.
    public var geocoder: String
    /// When it was looked up, as 5.5 writes CoordinatedTime (ISO 8601).
    public var time: String?

    public init(text: String, geocoder: String, time: String?) {
        self.text = text
        self.geocoder = geocoder
        self.time = time
    }

    /// Reads <__address>; nil without one or without its text, as 5.5
    /// takes nothing then.
    public init?(_ detail: CotDetail?) {
        guard let detail, detail.name == Self.elementName, let text = detail["text"] else { return nil }
        self.init(text: text, geocoder: detail["geocoder"] ?? "unknown", time: detail["time"])
    }

    public var detail: CotDetail {
        var d = CotDetail(Self.elementName)
        d["text"] = text
        d["geocoder"] = geocoder
        if let time { d["time"] = time }
        return d
    }

    /// AddressDetailHandler.locationHash: the position to the fifth decimal
    /// place (up to 1.1 m), which an address must still match to be kept.
    /// Java's Math.round is floor(x + 0.5).
    public static func locationHash(lat: Double, lon: Double) -> String {
        func round5(_ v: Double) -> Double { (v * 100_000 + 0.5).rounded(.down) / 100_000 }
        return "\(round5(lat)),\(round5(lon))"
    }
}
