// Author.swift — who made a map item and when, as ATAK 5.5's
// ATAKUtilities.setAuthorInformation records it at creation (parent_uid,
// parent_type, parent_callsign, production_time) and two detail handlers
// write it:
//
// - CreatorDetailHandler: <creator uid type callsign time>, for any item;
// - LinkDetailHandler: <link uid type relation="p-p" production_time
//   parent_callsign>, the "parent" link a marker carries.
//
// The type is the device's (mapData deviceType, "a-f-G" by default), not
// the self marker's; the time is a CoordinatedTime, to the millisecond.

import Foundation

public struct Author: Sendable, Equatable {
    public var uid, type, callsign: String
    public var time: Date

    public init(uid: String, type: String, callsign: String, time: Date) {
        self.uid = uid; self.type = type; self.callsign = callsign; self.time = time
    }

    /// <creator>, as CreatorDetailHandler reads it; nil without a uid.
    /// `time` stands in for a time that is missing or doesn't parse.
    public init?(creator: CotDetail?, orTime time: Date) {
        guard let c = creator, c.name == "creator", let uid = c["uid"], !uid.isEmpty else { return nil }
        self.init(uid: uid, type: c["type"] ?? "", callsign: c["callsign"] ?? "",
                  time: c["time"].flatMap(Cot.parseTime) ?? time)
    }

    /// CreatorDetailHandler.toCotDetail.
    public var creatorDetail: CotDetail {
        var c = CotDetail("creator")
        c["uid"] = uid
        c["type"] = type
        c["callsign"] = callsign
        c["time"] = Cot.time(time)
        return c
    }

    /// LinkDetailHandler.toCotDetail's parent link.
    public var parentLink: CotDetail {
        var link = CotDetail("link")
        link["uid"] = uid
        link["type"] = type
        link["relation"] = "p-p"
        link["production_time"] = Cot.time(time)
        link["parent_callsign"] = callsign
        return link
    }
}
