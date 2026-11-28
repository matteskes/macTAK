// MapLocator.swift — where a click on the map is, and where that place came
// from (G3.9d), for the Point Dropper and Move: 5.5's Tool.findPoint, with
// the GeoPointMetaData PrecisionLocationHandler later sends.
//
// - the ground: the clicked place, its altitude's source the elevation
//   data's where the map has an altitude there, else "???"
//   (inverseWithElevation);
// - an item: a CoT marker with its own <precisionlocation>, a contact with
//   its SA's, or the self marker with how it was placed (GPS or USER).
//
// And for a place the app computes (a route's centre, G3.10a), the
// elevation data's source there (`elevationSource`).

import Foundation
import MacTAKCot

@MainActor
public final class MapLocator {
    /// The source of the altitude at a place (ElevationManager's result
    /// type, "DTED1" say), or nil where no elevation data covers it. The
    /// app sets it from the engine; nil until then.
    public var altitudeSource: ((CotPoint) -> String?)?

    private let markers: CotMarkerStore
    private let contacts: ContactStore
    private let me: SelfReporter

    public init(markers: CotMarkerStore, contacts: ContactStore, me: SelfReporter) {
        self.markers = markers
        self.contacts = contacts
        self.me = me
    }

    /// Where `pick` is, or nil for an item that isn't on the map.
    public func locate(_ pick: MapPick) -> SourcedPoint? {
        switch pick {
        case .ground(let p):
            return .clicked(p, altitudeSource: p.validAltitude == nil ? nil : altitudeSource?(p))
        case .item(let uid):
            if let m = markers[uid] {
                return SourcedPoint(m.point, precision: PrecisionLocation(m.event.detail(PrecisionLocation.elementName)))
            }
            if let c = contacts[uid] { return SourcedPoint(c.point, precision: c.precision) }
            guard uid == me.details.uid, let l = me.location else { return nil }
            return SourcedPoint(l.point, precision: l.precision)
        }
    }

    /// Where the altitude at a computed place, such as a route's centre,
    /// comes from (ATAKUtilities.getElevationMetadata): the elevation
    /// data's source, else "???".
    public func elevationSource(at p: CotPoint) -> PrecisionLocation {
        PrecisionLocation(geopointSource: nil, altitudeSource: altitudeSource?(p) ?? PrecisionLocation.unknown)
    }
}
