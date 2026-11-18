// ReceivedChat.swift — a GeoChat event as it arrives (G3.5a).
//
// Ported from ATAK 5.5's ChatMessageParser and GeoChatService.isGeoChat:
// every `b-t-f…` event is chat; one carrying a ChatStatus type is a
// receipt for the message whose id is the event's uid.
//
// This reads only the event. What 5.5 then looks up in the contacts is left
// to the service (G3.5b), with what it needs kept here:
//   - an old GeoChat event (no chatgrp) names the room and the sender by
//     callsign: `chatroom` and `uidSenderSection`
//   - a conversation id equal to this client's uid is a one-to-one chat,
//     filed under the sender
//   - a group with no parent, deleteChild or hierarchy that isn't a known
//     contact is a legacy user group (isLegacyGroupCandidate).
// TADIL-J and APASS are read as 5.5 reads them but not acted on.

import Foundation

public struct ReceivedChat: Sendable, Equatable {
    /// CHAT3 has a chatgrp; GEO_CHAT is what came before it.
    public enum Version: Sendable, Equatable { case chat3, geoChat }

    /// What the event carries: a message, or a receipt for one.
    public enum Kind: Sendable, Equatable {
        case message
        case receipt(ChatStatus)
    }

    public var kind: Kind
    public var messageId: String
    /// nil for an event with only remarks (no __chat).
    public var version: Version?
    /// The room's id; nil when an old GeoChat event names it only by
    /// callsign (`chatroom`), which the contacts must resolve.
    public var conversationId: String?
    /// The room from the event uid (getFallbackConversationId), for an old
    /// GeoChat event whose `chatroom` names no known contact.
    public var fallbackConversationId: String
    /// The room's name (`chatroom`), All Streaming read as All Chat Rooms.
    public var chatroom: String
    /// The sender's uid; nil when an old GeoChat event names it only by
    /// callsign (`uidSenderSection`).
    public var senderUid: String?
    /// senderCallsign, else the uid's sender section.
    public var senderCallsign: String
    /// The second dot-separated part of the event uid
    /// ("GeoChat.<this>.<room>.<id>"): a uid in CHAT3, a callsign before.
    public var uidSenderSection: String
    /// The link p-p uid: who sent it, when nothing else says.
    public var linkUid: String?
    /// chatgrp's uids in order, else __serverdestination's, else All Chat
    /// Rooms.
    public var destinations: [String]
    public var parent: String?
    public var deleteChild: String?
    public var groupOwner: Bool
    public var hierarchy: ChatHierarchy?
    public var tadilJ: Bool
    public var text: String
    public var time: Date

    /// 5.5's legacy-group test, before the contacts are asked whether the
    /// room is a known non-group contact.
    public var isLegacyGroupCandidate: Bool {
        version != nil && !tadilJ && parent == nil && deleteChild == nil && hierarchy == nil
            && senderUid != conversationId
    }

    /// Whether this is a chat event at all (GeoChatService.isGeoChat).
    public static func isChat(_ event: CotEvent) -> Bool {
        event.isValid && event.detail != nil && event.type.hasPrefix("b-t-f")
    }

    /// nil when the event isn't chat.
    public init?(_ event: CotEvent) {
        guard Self.isChat(event) else { return nil }
        let status = ChatStatus(cotType: event.type)
        kind = status == .none ? .message : .receipt(status)
        time = event.time
        let parts = event.uid.components(separatedBy: ".")
        uidSenderSection = parts.count > 1 ? parts[1] : ""
        // A receipt's event uid is the message id itself.
        let chat = event.detail("__chat") ?? event.detail("__chatreceipt")
        messageId = status == .none ? (chat?["messageId"] ?? parts.last ?? "") : event.uid
        text = event.detail("remarks")?.innerText ?? ""
        linkUid = event.detail?.children.first { $0.name == "link" && $0["relation"] == "p-p" }?["uid"]

        guard let chat else {
            // No __chat: the remarks' source is the room and the sender.
            let source = event.detail("remarks")?["source"]
            version = nil
            fallbackConversationId = ChatRoom.allChatRooms
            conversationId = source; chatroom = source ?? ""
            senderUid = source; senderCallsign = source ?? ""
            destinations = []
            parent = nil; deleteChild = nil; groupOwner = false; hierarchy = nil; tadilJ = false
            return
        }

        let chatgrp = chat.child("chatgrp")
        let version: Version = chatgrp != nil ? .chat3 : .geoChat
        self.version = version
        chatroom = Self.currentName(chat["chatroom"] ?? "")
        fallbackConversationId = Self.currentName(Self.fallbackConversationId(event, parts))

        switch version {
        case .chat3:
            var id = chat["id"] ?? ""
            if id == "Streaming" { id = ChatRoom.allChatRoomsLegacy }
            if id.isEmpty { id = fallbackConversationId }
            conversationId = Self.currentName(id)
            senderUid = Self.senderUid(event.detail("remarks"), section: uidSenderSection)
        case .geoChat:
            conversationId = nil
            senderUid = nil
        }
        let callsign = chat["senderCallsign"] ?? ""
        senderCallsign = callsign.isEmpty ? uidSenderSection : callsign

        var dests: [String] = []
        for a in chatgrp?.attributes ?? [] where a.name.hasPrefix("uid") && !dests.contains(a.value) {
            dests.append(a.value)
        }
        destinations = dests.isEmpty ? Self.serverDestinations(event.detail("__serverdestination")) : dests

        tadilJ = chat["tadilj"] == "true"
        parent = chat["parent"]
        deleteChild = chat["deleteChild"]
        groupOwner = chat["groupOwner"] == "true"
        hierarchy = chat.child("hierarchy")?.children.first.flatMap(ChatHierarchy.init)
    }

    private static func currentName(_ room: String) -> String {
        room == ChatRoom.allChatRoomsLegacy ? ChatRoom.allChatRooms : room
    }

    /// getFallbackConversationId: the room from the event uid.
    private static func fallbackConversationId(_ event: CotEvent, _ parts: [String]) -> String {
        var id = ""
        if parts.count > 1 {
            let apass = event.detail?.children.contains { $0.name == "origin" && $0["uid"] != nil } ?? false
            if apass { id = parts[1] } else if parts.count > 3 { id = parts[2] }
        }
        return id.isEmpty ? ChatRoom.allChatRooms : id
    }

    /// getSenderUid for CHAT3: remarks' sourceID (WinTAK), else its source
    /// without ATAK's or WinTAK's prefix, else the uid's sender section.
    private static func senderUid(_ remarks: CotDetail?, section: String) -> String {
        if let id = remarks?["sourceID"], !id.isEmpty { return id }
        if let source = remarks?["source"], !source.isEmpty {
            for prefix in [ChatEvent.sourcePrefix, "BAO.F.WinTAK."] where source.hasPrefix(prefix) {
                return String(source.dropFirst(prefix.count))
            }
            return source
        }
        return section
    }

    /// getDestinationsFromServerDestination, for a chat with no chatgrp:
    /// "<ip>:<port>:<proto>:<uid>" names a uid; none at all means the
    /// broadcast room. 5.5 also turns UDP entries into addresses, which no
    /// room is made of here, so they are skipped.
    private static func serverDestinations(_ detail: CotDetail?) -> [String] {
        guard let list = detail?["destinations"] else { return [ChatRoom.allChatRooms] }
        return list.split(separator: ",").compactMap { entry in
            let s = String(entry)
            if s.hasPrefix("udp") { return nil }
            let c = s.components(separatedBy: ":")
            return c.count == 4 ? c[3] : s
        }
    }
}
