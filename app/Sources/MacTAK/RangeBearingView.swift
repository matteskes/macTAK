// RangeBearingView.swift — the range and bearing tool's controls (G3.8c):
//
// - a toolbar button over the map starts the tool (5.5's R&B Line button)
// - while it runs, 5.5's prompt shows at the top of the map with Cancel
//   (Esc)
// - the lines are listed in the Overlay Manager (G3.11b: Shapes › Range &
//   Bearing, as 5.5 lists them), whose row menu sends a line (G3.8d: to
//   chosen contacts or everyone, as 5.5's Send) or deletes it.
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
