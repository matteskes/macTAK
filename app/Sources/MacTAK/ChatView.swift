// ChatView.swift — GeoChat in the app (G3.5c): the sidebar's Chat section
// and the Chat window (owner decision 2: laid out like Messages, rooms on
// the left, the conversation on the right, so the map stays whole).
//
// The rooms are ChatService's (MacTAKComms): All Chat Rooms, the teams, the
// roles, user groups and one-to-one. A room this client may not write in
// (another team's or role's) shows its history with the composer off. Lines
// a peer sent are marked seen while the window is key and the room is open,
// which sends the read receipt in a one-to-one. This client's own lines in
// a one-to-one show the receipt they got back.

import MacTAKComms
import SwiftUI

/// Which room the Chat window shows; the sidebar sets it to open one.
@MainActor
final class ChatSelection: ObservableObject {
    @Published var room: String? = ChatRoom.allChatRooms
}

// MARK: - the sidebar

struct ChatSection: View {
    @EnvironmentObject private var connections: ServerConnections

    var body: some View {
        Section("Chat") {
            if let chat = connections.chat {
                ChatSummary(chat: chat)
            } else {
                Text("Chat history couldn't be opened").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChatSummary: View {
    @ObservedObject var chat: ChatService
    @EnvironmentObject private var selection: ChatSelection
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // All Chat Rooms, then every room with something in it, newest first.
        let active = chat.conversations
            .filter { $0.kind == .allChatRooms || $0.lastMessage != nil }
            .sorted { ($0.kind == .allChatRooms ? .distantFuture : $0.lastMessage ?? .distantPast)
                > ($1.kind == .allChatRooms ? .distantFuture : $1.lastMessage ?? .distantPast) }
        ForEach(active.prefix(6)) { room in
            Button { open(room.id) } label: { RoomRow(room: room) }
                .buttonStyle(.plain)
        }
        Button("Open Chat…") { open(selection.room ?? ChatRoom.allChatRooms) }
            .buttonStyle(.link)
    }

    private func open(_ id: String) {
        selection.room = id
        openWindow(id: "chat")
    }
}

private struct RoomRow: View {
    let room: ChatConversation

    var body: some View {
        HStack {
            RoomIcon(room: room)
            Text(room.name).lineLimit(1)
                .foregroundStyle(room.writable ? .primary : .secondary)
            Spacer()
            if room.unread > 0 {
                Text("\(room.unread)").font(.caption.bold()).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.tint, in: Capsule()).foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct RoomIcon: View {
    let room: ChatConversation

    var body: some View {
        switch room.kind {
        case .allChatRooms: Image(systemName: "antenna.radiowaves.left.and.right")
        case .team: TeamDot(team: room.id, stale: false).frame(width: 16)
        case .role: Image(systemName: "person.badge.shield.checkmark")
        case .group: Image(systemName: "person.3")
        case .direct: Image(systemName: "person")
        }
    }
}

// MARK: - the window

struct ChatWindow: View {
    @EnvironmentObject private var connections: ServerConnections

    var body: some View {
        if let chat = connections.chat {
            ChatBrowser(chat: chat, contacts: connections.contacts)
        } else {
            Text("Chat history couldn't be opened").foregroundStyle(.secondary).padding()
        }
    }
}

private struct ChatBrowser: View {
    @ObservedObject var chat: ChatService
    let contacts: ContactStore
    @EnvironmentObject private var selection: ChatSelection
    @State private var newGroup = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.room) {
                rooms(nil, [.allChatRooms])
                rooms("Teams", [.team])
                rooms("Roles", [.role])
                Section {
                    ForEach(chat.conversations.filter { $0.kind == .group }) { room in
                        RoomRow(room: room).tag(room.id)
                            .contextMenu {
                                Button("Delete Group", role: .destructive) { chat.deleteGroup(room.id) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Groups")
                        Spacer()
                        Button { newGroup = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless).help("New Group")
                    }
                }
                rooms("Direct", [.direct])
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let id = selection.room, let room = chat.conversation(id) {
                ConversationView(chat: chat, room: room).id(id)
            } else {
                Text("Pick a room").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $newGroup) { NewGroupSheet(chat: chat, contacts: contacts) }
    }

    @ViewBuilder
    private func rooms(_ title: String?, _ kinds: [ChatConversation.Kind]) -> some View {
        let list = chat.conversations.filter { kinds.contains($0.kind) }
        if let title {
            if !list.isEmpty {
                Section(title) { ForEach(list) { RoomRow(room: $0).tag($0.id) } }
            }
        } else {
            ForEach(list) { RoomRow(room: $0).tag($0.id) }
        }
    }
}

private struct ConversationView: View {
    @ObservedObject var chat: ChatService
    let room: ChatConversation
    @State private var draft = ""
    @Environment(\.controlActiveState) private var active

    var body: some View {
        let lines = chat.history(room.id)
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            LineView(line: line, receipts: room.hasReceipts, showSender: room.kind != .direct)
                                .id(line.messageId)
                        }
                    }
                    .padding()
                }
                .onAppear { scroller.scrollTo(lines.last?.messageId, anchor: .bottom) }
                .onChange(of: lines.last?.messageId) { _, last in
                    withAnimation { scroller.scrollTo(last, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .navigationTitle(room.name)
        .navigationSubtitle(subtitle)
        .onAppear(perform: markSeen)
        .onChange(of: chat.revision) { markSeen() }
        .onChange(of: active) { markSeen() }
    }

    private var subtitle: String {
        switch room.kind {
        case .allChatRooms: "everyone"
        case .direct: "one-to-one"
        default: room.members.count == 1 ? "1 member" : "\(room.members.count) members"
        }
    }

    @ViewBuilder private var composer: some View {
        if room.writable {
            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            if let error = chat.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding([.horizontal, .bottom], 10)
            }
        } else {
            Text(room.kind == .team ? "Only the \(room.name) team can write here" : "Only a \(room.name) can write here")
                .font(.callout).foregroundStyle(.secondary).padding(10)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try chat.send(text, to: room.id)
            draft = ""
        } catch {
            NSLog("macTAK: chat not sent: \(error)")
        }
    }

    /// Read only while someone can see it: the window is key.
    private func markSeen() {
        guard active == .key else { return }
        chat.markSeen(room.id)
    }
}

private struct LineView: View {
    let line: ChatLine
    let receipts: Bool
    let showSender: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if line.outgoing { Spacer(minLength: 60) }
            VStack(alignment: line.outgoing ? .trailing : .leading, spacing: 2) {
                if showSender && !line.outgoing {
                    Text(line.senderCallsign).font(.caption).foregroundStyle(.secondary)
                }
                Text(line.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(line.outgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(line.outgoing ? .white : .primary)
                HStack(spacing: 4) {
                    Text(line.sentTime, format: .dateTime.hour().minute())
                    if line.outgoing && receipts { Text(status) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !line.outgoing { Spacer(minLength: 60) }
        }
    }

    /// ATAK's receipt marks, in words.
    private var status: String {
        switch line.status {
        case .none: "sent"
        case .delivered: "delivered"
        case .read: "read"
        case .pending: "pending"
        }
    }
}

private struct NewGroupSheet: View {
    @ObservedObject var chat: ChatService
    @ObservedObject var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var selection: ChatSelection
    @State private var name = ""
    @State private var members: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Text("Members").font(.subheadline)
            List(contacts.contacts, selection: $members) { contact in
                HStack {
                    TeamDot(team: contact.group?.team, stale: false)
                    Text(contact.callsign)
                    if let role = contact.roleLabel { Text(role).foregroundStyle(.secondary) }
                }
                .tag(contact.uid)
            }
            .frame(minHeight: 180)
            .overlay {
                if contacts.contacts.isEmpty { Text("No one heard yet").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    let group = chat.createGroup(name: name.trimmingCharacters(in: .whitespaces),
                                                 members: Array(members))
                    selection.room = group.uid
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
