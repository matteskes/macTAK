// PointDropper.swift — the Point Dropper tool (G3.9b), as ATAK 5.5's
// EnterLocationTool and EnterLocationDropDownReceiver place points:
//
// - choosing a palette entry (PointKind) starts the tool; it stays on, and
//   every click places one point, until it is ended or another tool starts.
// - a click on the map places the point there; a click on a marker, a
//   contact or the self marker places it at that item's point (Tool.findPoint).
//   A click on a point placed here since launch places nothing: 5.5 opens
//   that point's radial menu instead, the app its inspector (G3.9c).
// - the point is MarkerCreator's (PlacedPoint), named as PointNaming says:
//   2525C's by genCallsign, made unique among the same-type points placed
//   here since launch (5.5's User Objects groups; points it takes back at
//   launch go to the CoT groups, so they don't count); Spot Map's "<abbr> n"
//   by getCount over every Spot Map point, then made unique among them (all
//   of them are in 5.5's Spot Map group).
// - the point goes into the CotMarkerStore as its own CoT, archived, so the
//   map draws it as 5.5 adapts its icon and the MapItemArchive keeps it.
//
// Not yet: long-press coordinate entry, double-click R&B entry, the
// recently-added list, the custom naming field.

import Foundation
import MacTAKCot

@MainActor
public final class PointDropper: ObservableObject {
    /// What a click places; nil while the tool is off.
    @Published public private(set) var selected: PointKind?

    private let markers: CotMarkerStore
    private let place: (String) -> CotPoint?
    private let deviceCallsign: () -> String
    private let legacyNaming: () -> Bool
    private let newID: () -> String
    private let timeZone: TimeZone
    /// The uids of the points placed here since launch, in order.
    private var placedHere: [String] = []

    /// `place` says where a clicked item (marker, contact, self) is;
    /// `legacyNaming` is 5.5's legacyPointDropNaming preference.
    public init(markers: CotMarkerStore, place: @escaping (String) -> CotPoint?,
                deviceCallsign: @escaping () -> String, legacyNaming: @escaping () -> Bool = { false },
                newID: @escaping () -> String = { UUID().uuidString }, timeZone: TimeZone = .current) {
        self.markers = markers
        self.place = place
        self.deviceCallsign = deviceCallsign
        self.legacyNaming = legacyNaming
        self.newID = newID
        self.timeZone = timeZone
    }

    public func begin(_ kind: PointKind) { selected = kind }

    public func end() { selected = nil }

    /// Whether `uid` is a point placed here since launch (a click on one
    /// shows it instead: G3.9c).
    public func isPlacedHere(_ uid: String) -> Bool { placedHere.contains(uid) && markers[uid] != nil }

    /// The tool's prompt (5.5's location_prompt, for a mouse); nil while off.
    public var prompt: String? {
        selected.map { "Click the map to place \($0.name) points." }
    }

    /// A click while the tool is on; returns the point it placed, if any.
    @discardableResult
    public func click(_ pick: MapPick, at now: Date = Date()) -> CotMarker? {
        guard let kind = selected else { return nil }
        let point: CotPoint
        switch pick {
        case .ground(let p):
            point = p
        case .item(let uid):
            if isPlacedHere(uid) { return nil }
            guard let p = place(uid) else { return nil }
            point = p
        }
        guard point.isValid else { return nil }
        let uid = newID()
        let event = PlacedPoint.event(uid: uid, kind: kind, callsign: callsign(for: kind, at: now), point: point,
                                      at: now)
        guard markers.receive(event.xml(), at: now) else { return nil }
        placedHere.append(uid)
        return markers[uid]
    }

    /// The point's name, as the palette and placePoint make it.
    func callsign(for kind: PointKind, at now: Date) -> String {
        switch kind {
        case .affiliation:
            let name = PointNaming.callsign(type: kind.type, deviceCallsign: deviceCallsign(),
                                            legacy: legacyNaming(), at: now, timeZone: timeZone)
            let group = placedHere.compactMap { markers[$0] }.filter { $0.type == kind.type }
            return PointNaming.deduplicated(name, among: group.map(title))
        case .spotMap(let color):
            let spots = markers.markers.filter { $0.type == PointKind.spotMapType }.map(title)
            let n = PointNaming.count(prefix: color.abbreviation, titles: spots)
            return PointNaming.deduplicated("\(color.abbreviation) \(n)", among: spots)
        }
    }

    private func title(_ m: CotMarker) -> String { m.label ?? "" }
}
