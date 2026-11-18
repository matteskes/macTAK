// SelfReporter+Chat.swift — who this client is in GeoChat (G3.5b): its uid,
// callsign and unit type from the self details, the position the self-SA
// reports (5.5's dispatchLocationHidden is off by default), this Mac's
// address, and the team and role that open its own rooms.

import Foundation

extension SelfReporter {
    public var chatIdentity: ChatIdentity {
        ChatIdentity(sender: ChatSender(uid: details.uid, callsign: details.callsign, deviceType: details.unitType,
                                        point: location?.point ?? .zero, address: NetworkInterfaces.primaryIPv4()),
                     team: details.team, role: details.role)
    }
}
