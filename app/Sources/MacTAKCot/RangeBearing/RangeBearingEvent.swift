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
//     stroke colour (toCot sets it for ColorDetailHandler); <creator uid
//     type callsign time>, who made it and when (CreatorDetailHandler, from
//     setAuthorInformation in the tool).
//   The numbers are written as Java's Double.toString writes them.
//
// Read: the anchor is the event's point unless <anchorUID> names a marker
// this client has; the far end is <rangeUID>'s marker, else the point
// <range> along <bearing> from the anchor (pointAtDistance), with the
// inclination's height when there is one. A missing title is the caller's
// "R&B n"; a missing colour is red.

import Foundation

public enum RangeBearingEvent {
    public static let type = "u-rb-a"
    public static let how = "h-e"
    /// 5.5's default line colour, Color.RED, as an int.
    public static let red: Int32 = -65536
    /// toCot's stroke weight.
    public static let strokeWeight = 3.0

    /// Who made a line: setAuthorInformation's parent_* and production_time.
    public struct Creator: Sendable, Equatable {
        public var uid, type, callsign: String
        public var time: Date
        public init(uid: String, type: String, callsign: String, time: Date) {
            self.uid = uid; self.type = type; self.callsign = callsign; self.time = time
        }
    }

    /// The line `uid` from `start` to `end` as 5.5's toCot writes it.
    /// `startUID` and `endUID` name an end's marker when 5.5 would.
    public static func make(uid: String, title: String, start: CotPoint, end: CotPoint,
                            startUID: String?, endUID: String?, style: RangeBearing.Style,
                            color: Int32 = red, creator: Creator?, now: Date) -> CotEvent {
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
        value("strokeWeight", Cot.number(strokeWeight))
        value("strokeStyle", "solid")
        value("color", String(color))
        if let creator {
            var c = CotDetail("creator")
            c["uid"] = creator.uid
            c["type"] = creator.type
            c["callsign"] = creator.callsign
            c["time"] = Cot.time(creator.time)
            detail.add(c)
        }
        return CotEvent(uid: uid, type: type, time: now, stale: now.addingTimeInterval(24 * 3600), how: how,
                        point: start, detail: detail)
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
        public var color: Int32

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
        return Received(uid: event.uid,
                        title: callsign?.isEmpty == false ? callsign : nil,
                        anchor: event.point,
                        anchorUID: value("anchorUID"),
                        rangeUID: value("rangeUID"),
                        range: number("range", -1),
                        bearing: number("bearing", -1),
                        inclination: number("inclination", .nan),
                        color: value("color").flatMap { Int32($0) } ?? red)
    }
}
