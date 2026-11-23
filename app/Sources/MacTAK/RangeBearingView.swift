// RangeBearingView.swift — the range and bearing tool's controls (G3.8c):
//
// - a toolbar button over the map starts the tool (5.5's R&B Line button)
// - while it runs, 5.5's prompt shows at the top of the map with Cancel
//   (Esc)
// - the sidebar's Range & Bearing section lists the lines with their labels;
//   a line's context menu sends it (G3.8d: to chosen contacts or everyone,
//   as 5.5's Send) or deletes it, the header deletes them all. A line heard
//   from another client says so.
//
// The tool and the lines are RangeBearingLines (MacTAKComms), which the
// tests drive; MapMarkerSync draws them.

import MacTAKComms
import SwiftUI

struct RangeBearingToolButton: View {
    @ObservedObject var lines: RangeBearingLines
    let mapRunning: Bool

    var body: some View {
        Button {
            if lines.tool == .off { lines.beginTool() } else { lines.endTool() }
        } label: {
            Label("R&B Line", systemImage: "ruler")
        }
        .disabled(!mapRunning)
        .help("Range & Bearing line: click where to measure from, then where to measure to")
    }
}

struct RangeBearingPrompt: View {
    @ObservedObject var lines: RangeBearingLines

    var body: some View {
        if let prompt = lines.prompt {
            HStack(spacing: 12) {
                Text(prompt)
                Button("Cancel") { lines.endTool() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        }
    }
}

struct RangeBearingSection: View {
    @ObservedObject var lines: RangeBearingLines
    @EnvironmentObject private var connections: ServerConnections
    @EnvironmentObject private var units: UnitPreferences
    @State private var sendFailure: String?
    @State private var sending: RangeBearingLine?

    var body: some View {
        Section {
            if lines.lines.isEmpty {
                Text("No lines").foregroundStyle(.secondary)
            }
            ForEach(lines.lines) { line in
                VStack(alignment: .leading) {
                    Text(line.received ? "\(line.title) (received)" : line.title)
                    if let label = lines.labels[line.id] {
                        Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Send…") { sending = line }
                    Button("Delete", role: .destructive) { lines.remove(id: line.id) }
                }
            }
        } header: {
            HStack {
                Text("Range & Bearing")
                Spacer()
                if !lines.lines.isEmpty {
                    Button { lines.removeAll() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete all range & bearing lines")
                }
            }
        }
        .sheet(item: $sending) { line in
            SendItemSheet(title: line.title, contacts: connections.contacts) { choice in
                sending = nil
                switch choice {
                case .everyone: send(line, to: nil)
                case .contacts(let uids): send(line, to: uids)
                case .cancel: break
                }
            }
        }
        .alert("Can't send the line", isPresented: Binding(get: { sendFailure != nil },
                                                           set: { if !$0 { sendFailure = nil } })) {
            Button("OK") { sendFailure = nil }
        } message: {
            Text(sendFailure ?? "")
        }
    }

    /// `to` nil is everyone.
    private func send(_ line: RangeBearingLine, to: [String]?) {
        do {
            try connections.share(line: line.id, to: to, style: units.rangeBearingStyle)
        } catch ServerConnections.ShareError.notRunning {
            sendFailure = "Nothing is connected: start the mesh or a server."
        } catch ServerConnections.ShareError.noPlace {
            sendFailure = "One of its markers has no position here."
        } catch {
            sendFailure = "\(error)"
        }
    }
}

/// 5.5's Send for a map item: pick contacts, or broadcast to everyone.
struct SendItemSheet: View {
    enum Choice { case everyone, contacts([String]), cancel }

    let title: String
    @ObservedObject var contacts: ContactStore
    let done: (Choice) -> Void
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send \(title)").font(.headline)
            if contacts.contacts.isEmpty {
                Text("No contacts heard yet: Broadcast sends it to everyone connected.")
                    .foregroundStyle(.secondary)
            } else {
                List(contacts.contacts, selection: $chosen) { c in
                    Text(c.callsign).tag(c.uid)
                }
                .frame(minHeight: 160)
            }
            HStack {
                Button("Cancel", role: .cancel) { done(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Broadcast") { done(.everyone) }
                Button("Send") { done(.contacts(Array(chosen))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
