// PlacedPoint.swift — a point placed here as the CoT ATAK 5.5 sends for it
// (G3.9d), field by field. PlacePointTool.MarkerCreator makes the marker
// (archive on, readiness true, how h-g-i-g-o, the palette's colour and
// iconsetpath, setAuthorInformation) and CotEventFactory.createDefaultEvent
// writes it:
//
// - the event: version 2.0, the uid, type and how, the point (no ce or le
//   for a click), time and start now, stale a year on, access Undefined
//   (AccessUtils' default);
// - createDefaultEvent's own details: <status readiness="true">, <archive/>;
// - then CotDetailManager's handlers, each for what the marker holds:
//   <contact callsign> (ContactDetailHandler), <precisionlocation>
//   (PrecisionLocationHandler, from the clicked point: altsrc is the
//   elevation data's, else "???"), the parent <link> to its author
//   (LinkDetailHandler), <archive/> again (ArchiveDetailHandler), <creator>
//   (CreatorDetailHandler), <usericon iconsetpath> (UserIconHandler),
//   <color argb> (ColorDetailHandler, a Marker's as argb). Later edits add
//   <remarks> and <__address> (PointEdits).
//
// 5.5 keeps its handlers in a HashSet, so their details come in no set
// order; this is the order they are registered in. <archive/> twice is
// 5.5's: createDefaultEvent and ArchiveDetailHandler both write it.
// dev/g3/test/cot-golden/point holds this to the kernel's CotEvent.

import Foundation

/// A place and where its position and altitude came from: the part of 5.5's
/// GeoPointMetaData that PrecisionLocationHandler sends.
public struct SourcedPoint: Sendable, Equatable {
    public var point: CotPoint
    public var precision: PrecisionLocation?

    public init(_ point: CotPoint, precision: PrecisionLocation?) {
        self.point = point
        self.precision = precision
    }

    /// A clicked place, as ElevationManager leaves it: the altitude's
    /// source when elevation data covers it, else "???".
    public static func clicked(_ point: CotPoint, altitudeSource: String?) -> SourcedPoint {
        SourcedPoint(point, precision: PrecisionLocation(geopointSource: nil,
                                                         altitudeSource: altitudeSource ?? PrecisionLocation.unknown))
    }
}

/// A point placed here, as its CoT.
public enum PlacedPoint {
    /// MarkerCreator's how.
    public static let how = "h-g-i-g-o"
    /// CotEventFactory's stale for a marker: a year.
    public static let staleSeconds: TimeInterval = 31_536_000

    public static func event(uid: String, kind: PointKind, callsign: String, at place: SourcedPoint,
                             author: Author?, now: Date) -> CotEvent {
        var detail = CotDetail("detail")
        var status = CotDetail("status")
        status["readiness"] = "true"
        detail.add(status)
        detail.add(CotDetail("archive"))
        var contact = CotDetail("contact")
        contact["callsign"] = callsign
        detail.add(contact)
        if let precision = place.precision?.detail { detail.add(precision) }
        if let author { detail.add(author.parentLink) }
        detail.add(CotDetail("archive"))
        if let author { detail.add(author.creatorDetail) }
        var usericon = CotDetail("usericon")
        usericon["iconsetpath"] = kind.iconsetPath
        detail.add(usericon)
        var color = CotDetail("color")
        color["argb"] = String(Int32(bitPattern: kind.argb))
        detail.add(color)
        return CotEvent(uid: uid, type: kind.type, time: now, stale: now.addingTimeInterval(staleSeconds),
                        how: how, point: place.point, detail: detail)
    }
}
