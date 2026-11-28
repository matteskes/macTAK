// ChatService.swift — GeoChat: rooms, sending, receiving, receipts (G3.5b).
//
// Ported from ATAK 5.5's GeoChatService and ChatManagerMapComponent, with
// the contact lookups ChatMessageParser makes (G3.5a left them here):
//
// Receiving a message:
//   - an old GeoChat event names its room and sender by callsign, found in
//     the contacts (this client's own callsign: a one-to-one); else the
//     room comes from the event uid
//   - a room equal to this client's uid is a one-to-one, filed under the
//     sender
//   - a hierarchy updates the user groups (ChatDatabase.HierarchyParser):
//     a group made here is never changed by a peer; the group's owner
//     replaces its members, anyone else adds to them
//   - a group with no parent, hierarchy or deleteChild that isn't a known
//     room is a legacy user group, made from the chatgrp's uids
//   - deleteChild removes that user group and its history
//   - a one-to-one from a known contact is answered with a delivered
//     receipt.
// Receiving a receipt moves the message's status up only (ChatStatus).
// Showing a one-to-one's lines sends read receipts (sendReadStatus).
//
// Unlike 5.5:
//   - a sender with no SA is not made a contact from the packet's source
//     address (commo doesn't pass it on), so it gets no receipt
//   - a message arriving twice (a server and the mesh) is kept once
//   - TADIL-J messages are dropped, and a group-delete notice isn't kept as
//     a line.

import Combine
import Foundation

public struct ChatError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

@MainActor
public final class ChatService: ObservableObject {
    /// The rooms, in the Chat window's order: All Chat Rooms, teams, roles,
    /// groups, then one-to-one by name.
    @Published public private(set) var conversations: [ChatConversation] = []
    /// Bumped whenever a line is added or changes, so views reload.
    @Published public private(set) var revision = 0
    /// The last send or receipt that failed, for the window to show.
    @Published public private(set) var lastError: String?

    public let store: ChatStore
    private let contacts: ContactStore
    private let identity: @MainActor () -> ChatIdentity
    private var transport: ChatTransport?
    private var watching: AnyCancellable?
    /// Sends in order, each after the one before.
    private var lastSend: Task<Void, Never>?

    public init(store: ChatStore, contacts: ContactStore, identity: @escaping @MainActor () -> ChatIdentity) {
        self.store = store
        self.contacts = contacts
        self.identity = identity
        watching = contacts.$contacts.sink { [weak self] _ in
            // $contacts fires before the value is set.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }

    public func attach(_ transport: ChatTransport) { self.transport = transport }
    public func detach() { transport = nil }

    private var selfUID: String { identity().sender.uid }

    // MARK: - rooms

    public func conversation(_ id: String) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    public func history(_ id: String) -> [ChatLine] {
        stored("read room \(id)") { try store.history(id) } ?? []
    }

    /// Rebuilds the rooms from the contacts, the user groups and the history.
    /// The team and role a room checks are this client's when it runs; the
    /// app calls it again when they change.
    public func refresh() {
        let me = identity()
        let kept = stored("read the conversations") { try store.conversations() } ?? []
        let activity = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let heard = contacts.contacts
        var rooms: [ChatConversation] = []

        func add(_ id: String, _ name: String, _ kind: ChatConversation.Kind, _ members: [String], writable: Bool) {
            rooms.append(ChatConversation(id: id, name: name, kind: kind, members: members, writable: writable,
                                          unread: activity[id]?.unread ?? 0, lastMessage: activity[id]?.last))
        }

        add(ChatRoom.allChatRooms, ChatRoom.allChatRooms, .allChatRooms, [], writable: true)
        for team in GroupDetail.teams {
            add(team, team, .team, heard.filter { $0.group?.team == team }.map(\.uid), writable: team == me.team)
        }
        for role in SelfDetails.roles.dropFirst() {
            let members = heard.filter { $0.group?.role == role }.map(\.uid)
            guard !members.isEmpty || activity[role] != nil else { continue }   // setHideIfEmpty
            add(role, role, .role, members, writable: role == me.role)
        }
        for group in stored("read the groups", { try store.groups() }) ?? [] {
            add(group.uid, group.name, .group, others(group.members, me: me), writable: true)
        }
        var direct: [ChatConversation] = []
        let known = Set(rooms.map(\.id))
        for contact in heard where !known.contains(contact.uid) {
            direct.append(ChatConversation(id: contact.uid, name: contact.callsign, kind: .direct,
                                           members: [contact.uid], writable: true,
                                           unread: activity[contact.uid]?.unread ?? 0,
                                           lastMessage: activity[contact.uid]?.last))
        }
        // A peer that has gone keeps its conversation.
        for past in kept where !known.contains(past.id) && !direct.contains(where: { $0.id == past.id }) {
            direct.append(ChatConversation(id: past.id, name: past.name, kind: .direct, members: [past.id],
                                           writable: true, unread: past.unread, lastMessage: past.last))
        }
        direct.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let next = rooms + direct
        if next != conversations { conversations = next }
    }

    // MARK: - sending

    /// Sends text to a room: All Chat Rooms to everyone, any other room to
    /// each member. The line is kept even when nobody is there to get it.
    @discardableResult
    public func send(_ text: String, to id: String, at now: Date = Date()) throws -> ChatLine {
        guard let room = conversation(id) else { throw ChatError(description: "no room \(id)") }
        guard room.writable else { throw ChatError(description: "\(room.name) is another team's or role's room") }
        let me = identity()
        var message = OutgoingChat(conversationId: room.id, conversationName: room.name, text: text,
                                   destinations: room.kind == .allChatRooms ? [ChatRoom.allChatRooms] : room.members,
                                   parent: room.parent)
        if room.kind == .group, let group = try store.groups().first(where: { $0.uid == id }) {
            message.groupOwner = group.createdLocally
            message.destinations = group.members
            message.hierarchy = .userGroup(uid: group.uid, name: group.name,
                                           members: group.members.map { ($0, name(of: $0, me: me)) })
        }
        let line = ChatLine(messageId: message.messageId, conversationId: room.id, conversationName: room.name,
                            senderUid: me.sender.uid, senderCallsign: me.sender.callsign, text: text,
                            sentTime: now, outgoing: true, seen: true)
        try store.save(line)
        changed()
        let xml = message.event(from: me.sender, at: now).xml()
        if room.kind == .allChatRooms {
            dispatch { try await $0.broadcast(xml, via: .any) }
        } else {
            send(xml, toMembers: room.members, me: me)
        }
        return line
    }

    /// Marks a room's lines shown, and sends a read receipt for each new one
    /// in a one-to-one with a known contact.
    public func markSeen(_ id: String, at now: Date = Date()) {
        guard let unseen = stored("read room \(id)", { try store.history(id) })?
            .filter({ !$0.outgoing && !$0.seen }), !unseen.isEmpty else { return }
        let me = identity()
        for var line in unseen {
            line.seen = true
            stored("mark a line seen") { try store.save(line) }
            guard line.senderUid == line.conversationId, contacts[line.senderUid] != nil else { continue }
            sendReceipt(.read, for: line, me: me, at: now)
        }
        changed()
    }

    // MARK: - user groups

    /// A group made here: its members and this client.
    @discardableResult
    public func createGroup(name: String, members: [String]) throws -> ChatGroup {
        let me = selfUID
        let group = ChatGroup(uid: UUID().uuidString.lowercased(), name: name,
                              members: members.filter { $0 != me } + [me], createdLocally: true)
        try store.save(group)
        refresh()
        return group
    }

    /// Removes a group; one made here tells its members, as 5.5 does
    /// ("Deleted group: …" with deleteChild).
    public func deleteGroup(_ uid: String, at now: Date = Date()) throws {
        guard let group = try store.groups().first(where: { $0.uid == uid }) else { return }
        try store.removeGroup(uid)
        refresh()
        guard group.createdLocally else { return }
        let me = identity()
        var notice = OutgoingChat(conversationId: ChatRoom.userGroups, conversationName: ChatRoom.userGroupsName,
                                  text: "Deleted group: \(group.name)", destinations: group.members,
                                  parent: ChatRoom.rootGroup)
        notice.deleteChild = uid
        send(notice.event(from: me.sender, at: now).xml(), toMembers: group.members, me: me)
    }

    // MARK: - receiving

    /// Takes in any CoT event commo received; anything but chat is ignored.
    public func receive(_ xml: String, at now: Date = Date()) {
        guard let event = try? CotEvent.parse(xml, now: now), let chat = ReceivedChat(event) else { return }
        switch chat.kind {
        case let .receipt(status): receipt(status, for: chat.messageId, at: event.time)
        case .message: message(chat, at: now)
        }
    }

    private func receipt(_ status: ChatStatus, for messageId: String, at time: Date) {
        guard var line = stored("read message \(messageId)", { try store.line(messageId) }) ?? nil,
              line.status.takes(status) else { return }
        line.status = status
        if status == .delivered { line.receiveTime = time } else if status == .read { line.readTime = time }
        stored("save a receipt") { try store.save(line) }
        changed()
    }

    private func message(_ chat: ReceivedChat, at now: Date) {
        let me = identity()
        guard !chat.tadilJ else { return }
        func byCallsign(_ callsign: String) -> String? {
            contacts.contacts.first { $0.callsign == callsign }?.uid
        }
        var senderUid = chat.senderUid ?? byCallsign(chat.uidSenderSection) ?? chat.linkUid ?? ""
        if senderUid.isEmpty { senderUid = chat.senderCallsign }
        // commo hands a client its own mesh traffic back (G3.3a).
        guard senderUid != me.sender.uid, !senderUid.isEmpty else { return }

        if let deleted = chat.deleteChild {
            stored("remove group \(deleted)") { try store.removeGroup(deleted) }
            refresh()
            return
        }

        var conversationId = chat.conversationId ?? byCallsign(chat.chatroom) ?? chat.fallbackConversationId
        var conversationName = chat.chatroom
        // An old GeoChat one-to-one names its room by the receiver's callsign.
        let toMe = conversationId == me.sender.uid || (chat.version == .geoChat && chat.chatroom == me.sender.callsign)
        if toMe {
            conversationId = senderUid
            conversationName = contacts[senderUid]?.callsign ?? chat.senderCallsign
        }
        let senderCallsign = chat.version == .chat3
            ? contacts[chat.uidSenderSection]?.callsign ?? chat.senderCallsign : chat.senderCallsign

        updateGroups(chat, conversationId: conversationId, senderUid: senderUid, senderCallsign: senderCallsign)

        let heardBefore = stored("look up message \(chat.messageId)") { try store.line(chat.messageId) } ?? nil
        guard heardBefore == nil else { return }   // heard on another path
        var line = ChatLine(messageId: chat.messageId, conversationId: conversationId,
                            conversationName: conversationName, senderUid: senderUid,
                            senderCallsign: senderCallsign, text: chat.text, sentTime: chat.time,
                            receiveTime: now, outgoing: false, seen: false)
        if conversationId == senderUid, contacts[senderUid] != nil {
            line.status = .delivered
            sendReceipt(.delivered, for: line, me: me, at: now)
        }
        if stored("save a received message", { try store.save(line) }) == nil {
            lastError = Self.notSaved
        }
        changed()
    }

    /// 5.5's toast when a received message isn't saved (chat_text14).
    /// Not as 5.5: its advice to clear the chat under Chat Preferences
    /// (clear_db_file) is left out, as macTAK has no such setting yet.
    static let notSaved = "Chat issue - data not saved."

    /// HierarchyParser, for groups one level under Groups, and 5.5's legacy
    /// groups.
    private func updateGroups(_ chat: ReceivedChat, conversationId: String, senderUid: String,
                              senderCallsign: String) {
        let groups = stored("read the groups") { try store.groups() } ?? []
        if let hierarchy = chat.hierarchy {
            let tops = hierarchy.uid == ChatRoom.userGroups ? hierarchy.children : [hierarchy]
            for node in tops where node.kind == .group {
                let existing = groups.first { $0.uid == node.uid }
                if existing?.createdLocally == true { continue }
                var members = chat.groupOwner ? [] : existing?.members ?? []
                for uid in node.contactUIDs + (chat.groupOwner ? [senderUid] : []) where !members.contains(uid) {
                    members.append(uid)
                }
                let group = ChatGroup(uid: node.uid, name: node.name, members: members, createdLocally: false)
                stored("save group \(group.uid)") { try store.save(group) }
            }
            refresh()
            return
        }
        let isRoom = conversationId == ChatRoom.allChatRooms || GroupDetail.teams.contains(conversationId)
            || SelfDetails.roles.contains(conversationId) || contacts[conversationId] != nil
        guard chat.version != nil, chat.parent == nil, senderUid != conversationId, !isRoom,
              !groups.contains(where: { $0.uid == conversationId }) else { return }
        var members = chat.destinations
        if !members.contains(senderUid) { members.append(senderUid) }
        let group = ChatGroup(uid: conversationId, name: chat.chatroom, members: members, createdLocally: false)
        stored("save group \(group.uid)") { try store.save(group) }
        refresh()
    }

    // MARK: -

    private func name(of uid: String, me: ChatIdentity) -> String {
        uid == me.sender.uid ? me.sender.callsign : contacts[uid]?.callsign ?? uid
    }

    private func changed() {
        revision += 1
        refresh()
    }

    /// `members` without this client.
    private func others(_ members: [String], me: ChatIdentity) -> [String] {
        members.filter { $0 != me.sender.uid }
    }

    /// Sends to each of `members` but this client, when any are left.
    private func send(_ xml: String, toMembers members: [String], me: ChatIdentity) {
        let to = others(members, me: me)
        if !to.isEmpty { dispatch { try await $0.send(xml, to: to) } }
    }

    /// Tells the sender of `line` it was delivered or read (5.5's
    /// sendReadStatus / the delivered receipt).
    private func sendReceipt(_ status: ChatStatus, for line: ChatLine, me: ChatIdentity, at now: Date) {
        let receipt = ChatReceipt(status, messageId: line.messageId, conversationId: line.conversationId,
                                  conversationName: line.conversationName, to: line.senderUid)
        guard let xml = receipt.event(from: me.sender, at: now)?.xml() else { return }
        send(xml, toMembers: [line.senderUid], me: me)
    }

    /// A ChatStore call whose failure the chat goes on without: logged, as
    /// 5.5's ChatDatabase logs an SQLiteException, and nil.
    @discardableResult
    private func stored<T>(_ what: String, _ call: () throws -> T) -> T? {
        do {
            return try call()
        } catch {
            NSLog("ChatService: couldn't \(what): \(error). Clear your DB file if this continues.")
            return nil
        }
    }

    private func dispatch(_ body: @escaping @Sendable (ChatTransport) async throws -> Void) {
        guard let transport else { return }
        let previous = lastSend
        lastSend = Task { [weak self] in
            await previous?.value
            do {
                try await body(transport)
            } catch {
                self?.lastError = "\(error)"
            }
        }
    }

    /// Waits for every queued send (tests).
    func flush() async {
        await lastSend?.value
    }
}
