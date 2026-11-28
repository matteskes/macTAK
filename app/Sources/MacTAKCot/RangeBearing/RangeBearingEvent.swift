// RangeBearingEvent.swift — a range and bearing line as CoT, "u-rb-a"
// (G3.8d), as ATAK 5.5 writes it (RangeAndBearingMapItem.toCot, with the
// detail handlers CotDetailManager adds for a line) and reads it
// (RangeAndBearingImporter).
//
// Written, field by field:
//   - the event: uid the line's, type u-rb-a, how h-e, stale a day on, the
//     point the start's
//   - <range value>: metres along the ground; <bearing value>: degrees from
//     true north; <inclination value>: the up (+) or down (−) angle in
//     degrees, 0.0 when either height is unknown (5.5's _depAngle starts
//     at 0 and is only set with a slant range)
//   - <rangeUID value>, <anchorUID value>: the end and start markers'
//     uids, only when an end is a marker 5.5 would name (a CoT marker; not
//     a fixed place, the self marker or a contact)
//   - <rangeUnits value>, <bearingUnits value>, <northRef value>: the
//     preferences' numbers (Span, Angle and NorthReference values)
//   - the handlers': <contact callsign> the title (ContactDetailHandler);
//     <strokeColor value>, <strokeWeight value>, <strokeStyle value>
//     (StrokeFillDetailHandler, a line is a Shape); <color value>, the
//     stroke colour (toCot sets it for ColorDetailHandler); <archive/> on a
//     line kept across launches (ArchiveDetailHandler: the tool's lines
//     are, and a received one that came with it); <creator uid type
//     callsign time>, who made it and when (CreatorDetailHandler, from
//     setAuthorInformation in the tool).
//   The numbers are written as Java's Double.toString writes them.
//
// Read: the anchor is the event's point unless <anchorUID> names a marker
// this client has; the far end is <rangeUID>'s marker, else the point
// <range> along <bearing> from the anchor (pointAtDistance), with the
// inclination's height when there is one. A missing title is the caller's
// "R&B n". The colour and weight are what the detail handlers leave (see
// Received); <archive/> and <creator> are kept to send on.

import Foundation

public enum RangeBearingEvent {
    public static let type = "u-rb-a"
    public static let how = "h-e"
    /// 5.5's default line colour, Color.RED, as an int.
    public static let red: Int32 = -65536
    /// toCot's stroke weight.
    public static let strokeWeight = 3.0

    /// The line `uid` from `start` to `end` as 5.5's toCot writes it.
    /// `startUID` and `endUID` name an end's marker when 5.5 would;
    /// `archive` marks a line kept across launches.
    public static func make(uid: String, title: String, start: CotPoint, end: CotPoint,
                            startUID: String?, endUID: String?, style: RangeBearing.Style,
                            color: Int32 = red, weight: Double = strokeWeight, archive: Bool = false,
                            creator: Author?, now: Date) -> CotEvent {
        let rab = RangeBearing(from: start, to: end)
        var detail = CotDetail("detail")
        func value(_ name: String, _ v: String) {
            var d = CotDetail(name)
            d["value"] = v
            detail.add(d)
        }
        value("range", Cot.number(rab.range))
        value("bearing", Cot.number(rab.bearing))
        let inclination = rab.depressionAngle
        value("inclination", Cot.number(inclination.isNaN ? 0 : inclination))
        if let endUID { value("rangeUID", endUID) }
        if let startUID { value("anchorUID", startUID) }
        value("rangeUnits", String(style.rangeUnits.rawValue))
        value("bearingUnits", String(style.bearingUnits.rawValue))
        value("northRef", String(style.north.rawValue))
        var contact = CotDetail("contact")
        contact["callsign"] = title
        detail.add(contact)
        value("strokeColor", String(color))
        value("strokeWeight", Cot.number(weight))
        value("strokeStyle", "solid")
        value("color", String(color))
        if archive { detail.add(CotDetail("archive")) }
        if let creator { detail.add(creator.creatorDetail) }
        return CotEvent(uid: uid, type: type, time: now, stale: now.addingTimeInterval(24 * 3600), how: how,
                        point: CotPoint(mapPoint: start), detail: detail)
    }

    /// What a received line says.
    public struct Received: Sendable, Equatable {
        public var uid: String
        /// <contact callsign>, nil when missing or empty.
        public var title: String?
        public var anchor: CotPoint
        public var anchorUID: String?
        public var rangeUID: String?
        public var range: Double
        public var bearing: Double
        /// NaN when the event has none.
        public var inclination: Double
        /// What the line's colour ends up as in 5.5: <strokeColor value>
        /// (StrokeFillDetailHandler, applied last; white when it doesn't
        /// parse), else <color value> (the importer; red when missing or
        /// unparseable).
        public var color: Int32
        /// <strokeWeight value>, 6.0 when it doesn't parse; nil when absent.
        public var weight: Double?
        /// <creator>, as CreatorDetailHandler keeps it; nil when absent.
        public var creator: Author?
        /// <archive/>: kept across launches (ArchiveDetailHandler).
        public var archive = false

        /// The far end when `rangeUID` isn't a marker here: `range` along
        /// `bearing` from the anchor, as the importer computes it.
        public var farEnd: CotPoint {
            let unknown = !Altitude.isValid(anchor.hae)
            let p = Geodesy.pointAtDistance(lat: anchor.lat, lon: anchor.lon, hae: unknown ? .nan : anchor.hae,
                                            azimuth: bearing, distance: range, inclination: inclination)
            return CotPoint(lat: p.lat, lon: p.lon, hae: p.hae)
        }
    }

    /// A u-rb-a event's line; nil for any other type or one with no detail.
    /// Values that don't parse take the importer's defaults (range and
    /// bearing −1, no inclination, red).
    public static func parse(_ event: CotEvent) -> Received? {
        guard event.type == type, event.detail != nil else { return nil }
        func value(_ name: String) -> String? { event.detail(name)?["value"] }
        func number(_ name: String, _ fallback: Double) -> Double {
            value(name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
        }
        let callsign = event.detail("contact")?["callsign"]
        let white: Int32 = -1
        var color = value("color").flatMap { Int32($0) } ?? red
        if let stroke = event.detail("strokeColor") { color = stroke["value"].flatMap { Int32($0) } ?? white }
        let weight = event.detail("strokeWeight").map { $0["value"].flatMap { Double($0) } ?? 6.0 }
        let creator = Author(creator: event.detail("creator"), orTime: event.time)
        return Received(uid: event.uid,
                        title: callsign?.isEmpty == false ? callsign : nil,
                        anchor: event.point,
                        anchorUID: value("anchorUID"),
                        rangeUID: value("rangeUID"),
                        range: number("range", -1),
                        bearing: number("bearing", -1),
                        inclination: number("inclination", .nan),
                        color: color, weight: weight, creator: creator,
                        archive: event.detail("archive") != nil)
    }
}
