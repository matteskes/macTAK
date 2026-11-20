// RangeBearingView.swift — the range and bearing tool's controls (G3.8c):
//
// - a toolbar button over the map starts the tool (5.5's R&B Line button)
// - while it runs, 5.5's prompt shows at the top of the map with Cancel
//   (Esc)
// - the sidebar's Range & Bearing section lists the lines with their labels;
//   a line's context menu deletes it, the header deletes them all.
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

    var body: some View {
        Section {
            if lines.lines.isEmpty {
                Text("No lines").foregroundStyle(.secondary)
            }
            ForEach(lines.lines) { line in
                VStack(alignment: .leading) {
                    Text(line.title)
                    if let label = lines.labels[line.id] {
                        Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
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
    }
}
