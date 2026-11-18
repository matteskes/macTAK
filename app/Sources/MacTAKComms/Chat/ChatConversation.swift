// ChatConversation.swift — a GeoChat room, as the Chat window lists it (G3.5b).
//
// ATAK 5.5 builds its rooms from contacts (ChatManagerMapComponent):
//   - All Chat Rooms: a broadcast
//   - a team room per team (TeamGroup): the contacts in that team; parent
//     TeamGroups; only your own team's room takes messages
//   - a role room per role but Team Member (RoleGroup): the contacts with
//     that role; hidden while empty; only your own role's takes messages
//   - user-made groups under Groups (UserGroups)
//   - one-to-one with each contact.

import Foundation

public struct ChatConversation: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, Comparable {
        case allChatRooms, team, role, group, direct
    }

    /// The conversation id the chat events carry: All Chat Rooms, a team or
    /// role name, a group's uid, or a contact's uid.
    public var id: String
    public var name: String
    public var kind: Kind
    /// Who a message goes to, by uid, this client left out.
    public var members: [String]
    /// Whether this client may write here (5.5's setUnmodifiable).
    public var writable: Bool
    public var unread: Int
    public var lastMessage: Date?

    public init(id: String, name: String, kind: Kind, members: [String], writable: Bool,
                unread: Int = 0, lastMessage: Date? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.members = members
        self.writable = writable; self.unread = unread; self.lastMessage = lastMessage
    }

    /// The group a room hangs under, which its events name as `parent`.
    public var parent: String {
        switch kind {
        case .team: ChatRoom.teamGroups
        case .group: ChatRoom.userGroups
        case .allChatRooms, .role, .direct: ChatRoom.rootGroup
        }
    }

    /// Only a one-to-one chat has receipts (GeoChatService: the
    /// conversation is the sender).
    public var hasReceipts: Bool { kind == .direct }
}

/// Who this client is in chat: what its events say, and the team and role
/// that decide which rooms it may write in.
public struct ChatIdentity: Sendable, Equatable {
    public var sender: ChatSender
    public var team: String
    public var role: String

    public init(sender: ChatSender, team: String, role: String) {
        self.sender = sender; self.team = team; self.role = role
    }
}

/// How chat events leave: commo, or a recorder in tests.
public protocol ChatTransport: Sendable {
    func broadcast(_ xml: String, via route: SendRoute) async throws
    func send(_ xml: String, to uids: [String]) async throws
}

extension CommoClient: ChatTransport {}
