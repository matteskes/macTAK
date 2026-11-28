// SelfEvent.swift — this client's self-SA (G3.4).
//
// Ported from ATAK 5.5's CotMapComponent.getSelfEvent, the event every TAK
// client reports itself with. The details go in getSelfEvent's order:
// takv, contact, remarks, uid, precisionlocation, __group, status, track.
// What 5.5 sends only on Android (phone numbers, SIP, VMF, TADIL-J, a mock
// location's parent link) is left out.

import Foundation

public struct SelfEvent: Sendable, Equatable {
    /// Where the position came from, which sets the event's `how`.
    public enum Source: Sendable, Equatable {
        /// A location provider (CoreLocation): "m-g".
        case provider
        /// Placed by hand ("set my location"): "h-e".
        case manual
    }

    public struct Location: Sendable, Equatable {
        public var point: CotPoint
        public var source: Source
        public init(point: CotPoint, source: Source) {
            self.point = point; self.source = source
        }
    }

    /// ATAK's default unit type (locationUnitType).
    public static let defaultType = "a-f-G-U-C"
    /// What commo replaces with each connection's own endpoint.
    public static let serverEndpoint = "*:-1:stcp"

    public var uid: String
    public var type = defaultType
    public var callsign: String
    public var endpoint: String? = serverEndpoint
    public var group: GroupDetail
    public var remarks: String?
    /// nil until the client knows where it is: no provider and nothing
    /// placed, sent at 0,0 with unknown errors, "h-g-i-g-o".
    public var location: Location?
    public var track = Track(speed: 0, course: 0)
    public var battery = 100
    public var takv = TakVersion(device: "Mac", platform: "macTAK", os: "macOS", version: Cot.clientVersion)

    public init(uid: String, callsign: String, group: GroupDetail = GroupDetail(team: "Cyan")) {
        self.uid = uid; self.callsign = callsign; self.group = group
    }

    /// Whether what ATAK reports at once when it changes is the same:
    /// callsign, unit type, team, role, custom role and remarks
    /// (ReportingRate's monitored preferences).
    public func sameIdentity(as other: SelfEvent) -> Bool {
        callsign == other.callsign && type == other.type && group == other.group && remarks == other.remarks
    }

    public var how: String {
        switch location?.source {
        case .provider: return "m-g"
        case .manual: return "h-e"
        case nil: return "h-g-i-g-o"
        }
    }

    /// The self point's precisionlocation (Location.precision).
    public var precision: PrecisionLocation? { location?.precision }

    /// The event, valid from now until now + stale.
    public func event(at now: Date = Date(), stale: TimeInterval) -> CotEvent {
        var detail = CotDetail("detail")
        detail.add(takv.detail)
        var contact = CotDetail("contact")
        contact["callsign"] = callsign
        contact["endpoint"] = endpoint
        detail.add(contact)
        if let remarks = remarks?.trimmingCharacters(in: .whitespacesAndNewlines), !remarks.isEmpty {
            var r = CotDetail("remarks")
            r.innerText = remarks
            detail.add(r)
        }
        var droid = CotDetail("uid")
        droid["Droid"] = callsign
        detail.add(droid)
        if let precision = precision?.detail { detail.add(precision) }
        detail.add(group.detail)
        var status = CotDetail("status")
        status["battery"] = String(battery)
        detail.add(status)
        detail.add(track.detail)
        return CotEvent(uid: uid, type: type, time: now, stale: now.addingTimeInterval(stale),
                        how: how, point: location.map { CotPoint(mapPoint: $0.point) } ?? .zero, detail: detail)
    }
}

extension SelfEvent.Location {
    /// Its precisionlocation: GPS from a provider, USER when placed (its
    /// altitude USER only when one was given).
    public var precision: PrecisionLocation {
        switch source {
        case .provider:
            return PrecisionLocation(geopointSource: PrecisionLocation.gps, altitudeSource: PrecisionLocation.gps)
        case .manual:
            let altitudeKnown = point.validAltitude != nil
            return PrecisionLocation(geopointSource: PrecisionLocation.user,
                                     altitudeSource: altitudeKnown ? PrecisionLocation.user : PrecisionLocation.unknown)
        }
    }
}
