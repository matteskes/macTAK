// RangeBearingView.swift — the range and bearing tool's controls (G3.8c):
//
// - a toolbar button over the map starts the tool (5.5's R&B Line button)
// - while it runs, 5.5's prompt shows at the top of the map with Cancel
//   (Esc)
// - the sidebar's Range & Bearing section lists the lines with their labels;
//   a line's context menu sends it to everyone (G3.8d) or deletes it, the
//   header deletes them all. A line heard from another client says so.
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
                    Button("Send to All") { send(line) }
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
        .alert("Can't send the line", isPresented: Binding(get: { sendFailure != nil },
                                                           set: { if !$0 { sendFailure = nil } })) {
            Button("OK") { sendFailure = nil }
        } message: {
            Text(sendFailure ?? "")
        }
    }

    private func send(_ line: RangeBearingLine) {
        do {
            try connections.share(line: line.id, style: units.rangeBearingStyle)
        } catch ServerConnections.ShareError.notRunning {
            sendFailure = "Nothing is connected: start the mesh or a server."
        } catch ServerConnections.ShareError.noPlace {
            sendFailure = "One of its markers has no position here."
        } catch {
            sendFailure = "\(error)"
        }
    }
}
