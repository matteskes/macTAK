// ChatEvent.swift — the GeoChat events this client sends (G3.5a).
//
// Ported from ATAK 5.5's GeoChatService (atak/.../android/chat at the pin):
//   - a message, `b-t-f` (bundleToCot)
//   - a receipt, `b-t-f-d` delivered or `b-t-f-r` read (sendStatusMessage).
// Both carry the same send details (addSendDetails): __chat or
// __chatreceipt with its chatgrp and optional hierarchy, a p-p link to the
// sender, and __serverdestination. A message adds remarks with the text.
//
// What 5.5 takes from the map, the contacts and the preferences comes in
// as values here: the service (G3.5b) works out the room's members, its
// parent group and the hierarchy, as ChatManagerMapComponent does.

import Foundation

/// The fixed names GeoChat rooms are known by.
public enum ChatRoom {
    /// The broadcast room (GeoChatService.DEFAULT_CHATROOM_NAME).
    public static let allChatRooms = "All Chat Rooms"
    /// Its name before 3.x, still read (DEFAULT_CHATROOM_NAME_LEGACY).
    public static let allChatRoomsLegacy = "All Streaming"
    /// Contacts' root group: the parent of one-to-one, All Chat Rooms and
    /// role rooms, and of every receipt.
    public static let rootGroup = "RootContactGroup"
    /// The parent of the team rooms (Contacts.TEAM_GROUPS).
    public static let teamGroups = "TeamGroups"
    /// The parent of user-made groups (Contacts.USER_GROUPS).
    public static let userGroups = "UserGroups"
    /// The name ATAK shows for userGroups (R.string.groups).
    public static let userGroupsName = "Groups"
    /// The mesh chat address (chatAddress, ChatManagerMapComponent).
    public static let meshAddress = "224.10.10.1"
    public static let meshPort = 17012
    /// How long a chat event or receipt is valid: a day.
    public static let staleInterval: TimeInterval = 24 * 60 * 60
}

/// A message's delivery status (ChatLine.Status). The order is 5.5's
/// ordinal order, and a status only replaces a lower one, so `pending`
/// after `read` is taken — an upstream quirk, kept (5.5 never sends
/// pending itself).
public enum ChatStatus: Int, Sendable, Comparable, CaseIterable {
    case none, delivered, read, pending

    public var cotType: String? {
        switch self {
        case .none: return nil
        case .delivered: return "b-t-f-d"
        case .read: return "b-t-f-r"
        case .pending: return "b-t-f-p"
        }
    }

    /// The status a receipt's event type carries; `.none` for anything else.
    public init(cotType: String) {
        self = Self.allCases.first { $0.cotType == cotType } ?? .none
    }

    /// Whether a message at `self` takes `next` (GeoChatService.onCotEvent).
    public func takes(_ next: ChatStatus) -> Bool { next > self }

    public static func < (a: ChatStatus, b: ChatStatus) -> Bool { a.rawValue < b.rawValue }
}

/// A user group's members as GeoChat sends them (`<hierarchy>`): a tree of
/// groups and contacts under the Groups node.
public struct ChatHierarchy: Sendable, Equatable {
    public enum Kind: String, Sendable { case group, contact }

    public var kind: Kind
    public var uid: String
    public var name: String
    public var children: [ChatHierarchy]

    public init(_ kind: Kind, uid: String, name: String, children: [ChatHierarchy] = []) {
        self.kind = kind; self.uid = uid; self.name = name; self.children = children
    }

    /// A user group as Contacts.buildPaths sends it: Groups → the group →
    /// its members (the sender among them).
    public static func userGroup(uid: String, name: String, members: [(uid: String, name: String)]) -> ChatHierarchy {
        let group = ChatHierarchy(.group, uid: uid, name: name,
                                  children: members.map { ChatHierarchy(.contact, uid: $0.uid, name: $0.name) })
        return ChatHierarchy(.group, uid: ChatRoom.userGroups, name: ChatRoom.userGroupsName, children: [group])
    }

    /// ChatMessageParser.getPaths: a node needs a uid and a name; a child
    /// without a uid is skipped.
    public init?(_ detail: CotDetail) {
        guard let uid = detail["uid"], let name = detail["name"] else { return nil }
        self.init(Kind(rawValue: detail.name) ?? .contact, uid: uid, name: name,
                  children: detail.children.filter { $0["uid"] != nil }.compactMap(ChatHierarchy.init))
    }

    public var detail: CotDetail {
        var d = CotDetail(kind.rawValue)
        d["uid"] = uid
        d["name"] = name
        for c in children { d.add(c.detail) }
        return d
    }

    /// Every contact uid in the tree.
    public var contactUIDs: [String] {
        (kind == .contact ? [uid] : []) + children.flatMap(\.contactUIDs)
    }
}

/// This client, as its chat events name it.
public struct ChatSender: Sendable, Equatable {
    public var uid: String
    public var callsign: String
    /// The self marker's type (the map's deviceType).
    public var deviceType: String
    /// Where the event says it is: the self position, or `.zero` when it
    /// has none or hides it (dispatchLocationHidden).
    public var point: CotPoint
    /// This Mac's address for __serverdestination (NetworkUtils.getIP).
    public var address: String

    public init(uid: String, callsign: String, deviceType: String = SelfEvent.defaultType,
                point: CotPoint = .zero, address: String) {
        self.uid = uid; self.callsign = callsign; self.deviceType = deviceType
        self.point = point; self.address = address
    }
}

/// A message to send (the chat bundle bundleToCot reads).
public struct OutgoingChat: Sendable, Equatable {
    public var messageId: String
    /// The room: a contact's uid, a team or role name, a group's uid, or
    /// All Chat Rooms.
    public var conversationId: String
    public var conversationName: String
    public var text: String
    /// Who it goes to, by uid (chatgrp's uid1… after the sender's uid0).
    public var destinations: [String]
    /// The room's parent group (ChatRoom.rootGroup, teamGroups or userGroups).
    public var parent: String
    /// Whether the sender made the group (GroupContact.isUserCreated).
    public var groupOwner = false
    /// The member a group owner removes (deleteChild).
    public var deleteChild: String?
    /// A user group's members (Contacts.buildPaths); nil for other rooms.
    public var hierarchy: ChatHierarchy?

    public init(messageId: String = UUID().uuidString.lowercased(), conversationId: String, conversationName: String,
                text: String, destinations: [String], parent: String = ChatRoom.rootGroup) {
        self.messageId = messageId; self.conversationId = conversationId
        self.conversationName = conversationName; self.text = text
        self.destinations = destinations; self.parent = parent
    }

    /// The `b-t-f` event (bundleToCot).
    public func event(from sender: ChatSender, at now: Date = Date()) -> CotEvent {
        var detail = ChatEvent.sendDetails("__chat", sender: sender, messageId: messageId,
                                           conversationId: conversationId, conversationName: conversationName,
                                           destinations: destinations, parent: parent, groupOwner: groupOwner,
                                           deleteChild: deleteChild, hierarchy: hierarchy)
        var remarks = CotDetail("remarks")
        remarks["source"] = ChatEvent.sourcePrefix + sender.uid
        // "to" only when every other destination is the conversation itself:
        // a one-to-one message.
        for dest in destinations where dest != sender.uid {
            guard dest == conversationId else { remarks["to"] = nil; break }
            remarks["to"] = dest
        }
        remarks["time"] = Cot.time(now)
        remarks.innerText = text
        detail.add(remarks)
        return ChatEvent.event(uid: "GeoChat.\(sender.uid).\(conversationId).\(messageId)", type: "b-t-f",
                               how: "h-g-i-g-o", sender: sender, at: now, detail: detail)
    }
}

/// A delivered or read receipt for a message received one to one
/// (sendStatusMessage): sender and receiver swapped, the message's own id
/// as the event uid, no text.
public struct ChatReceipt: Sendable, Equatable {
    public var status: ChatStatus
    public var messageId: String
    /// The received message's conversation, which in a one-to-one chat is
    /// its sender's uid.
    public var conversationId: String
    public var conversationName: String
    /// Who sent the message: the receipt's only destination.
    public var to: String

    public init(_ status: ChatStatus, messageId: String, conversationId: String, conversationName: String, to: String) {
        self.status = status; self.messageId = messageId
        self.conversationId = conversationId; self.conversationName = conversationName; self.to = to
    }

    /// nil for `.none`, as 5.5 sends nothing then.
    public func event(from sender: ChatSender, at now: Date = Date()) -> CotEvent? {
        guard let type = status.cotType else { return nil }
        let detail = ChatEvent.sendDetails("__chatreceipt", sender: sender, messageId: messageId,
                                           conversationId: conversationId, conversationName: conversationName,
                                           destinations: [to], parent: ChatRoom.rootGroup, groupOwner: false,
                                           deleteChild: nil, hierarchy: nil)
        return ChatEvent.event(uid: messageId, type: type, how: "m-g", sender: sender, at: now, detail: detail)
    }
}

enum ChatEvent {
    /// remarks' source: "BAO.F.ATAK.<uid>" (ATAK's, which peers parse).
    static let sourcePrefix = "BAO.F.ATAK."

    static func event(uid: String, type: String, how: String, sender: ChatSender, at now: Date,
                      detail: CotDetail) -> CotEvent {
        var e = CotEvent(uid: uid, type: type, time: now, stale: now.addingTimeInterval(ChatRoom.staleInterval),
                         how: how, point: CotPoint(mapPoint: sender.point), detail: detail)
        e.access = Cot.undefinedAccess
        return e
    }

    /// addSendDetails.
    static func sendDetails(_ element: String, sender: ChatSender, messageId: String, conversationId: String,
                            conversationName: String, destinations: [String], parent: String, groupOwner: Bool,
                            deleteChild: String?, hierarchy: ChatHierarchy?) -> CotDetail {
        var chat = CotDetail(element)
        chat["id"] = conversationId
        chat["messageId"] = messageId
        var chatgrp = CotDetail("chatgrp")
        chatgrp["id"] = conversationId
        for (i, uid) in ([sender.uid] + destinations).enumerated() {
            chatgrp["uid\(i)"] = uid
        }
        chat["senderCallsign"] = sender.callsign
        chat["chatroom"] = conversationName
        chat["parent"] = parent
        chat["groupOwner"] = groupOwner ? "true" : "false"
        chat["deleteChild"] = deleteChild
        chat.add(chatgrp)
        if let hierarchy {
            var h = CotDetail("hierarchy")
            h.add(hierarchy.detail)
            chat.add(h)
        }

        var detail = CotDetail("detail")
        detail.add(chat)
        var link = CotDetail("link")
        link["uid"] = sender.uid
        link["type"] = sender.deviceType
        link["relation"] = "p-p"
        detail.add(link)
        var server = CotDetail("__serverdestination")
        server["destinations"] = "\(sender.address):4242:tcp:\(sender.uid)"
        detail.add(server)
        return detail
    }
}
