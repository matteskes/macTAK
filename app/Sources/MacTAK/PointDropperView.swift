// PointDropperView.swift — the Point Dropper's controls (G3.9b):
//
// - a toolbar button over the map opens the palettes, 5.5's 2525C quick
//   drops (Unknown, Neutral, Hostile, Friendly) and Spot Map's colours;
//   choosing one starts the tool, choosing it again stops it
// - while it runs, the prompt shows at the top of the map with Done (Esc);
//   every click places a point.
//
// The tool is PointDropper (MacTAKComms), which the tests drive; the points
// are CoT markers, which MapMarkerSync draws.

import MacTAKComms
import MacTAKCot
import SwiftUI

struct PointDropperToolButton: View {
    @ObservedObject var dropper: PointDropper
    let mapRunning: Bool
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Label("Point Dropper", systemImage: dropper.selected == nil ? "mappin" : "mappin.circle.fill")
        }
        .disabled(!mapRunning)
        .help("Point Dropper: choose a point, then click the map to place it")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PointPalettes(dropper: dropper) { showing = false }
        }
    }
}

private struct PointPalettes: View {
    @ObservedObject var dropper: PointDropper
    let chosen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2525C").font(.headline)
            HStack(spacing: 8) {
                ForEach(PointKind.Affiliation.paletteOrder, id: \.self) { a in
                    entry(.affiliation(a)) { AffiliationGlyph(affiliation: a) }
                }
            }
            Text("Spot Map").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 6), spacing: 6) {
                ForEach(PointKind.SpotMapColor.allCases, id: \.self) { c in
                    entry(.spotMap(c)) {
                        Circle().fill(Color(argb: c.argb))
                            .overlay(Circle().stroke(.secondary, lineWidth: 1))
                            .frame(width: 18, height: 18)
                            .overlay(alignment: .bottom) { Text(c.abbreviation).font(.caption2).offset(y: 14) }
                            .padding(.bottom, 10)
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }

    /// One palette button: on starts the tool with it, on again stops it.
    private func entry(_ kind: PointKind, @ViewBuilder glyph: () -> some View) -> some View {
        let on = dropper.selected == kind
        return Button {
            if on { dropper.end() } else { dropper.begin(kind) }
            chosen()
        } label: {
            glyph()
                .frame(width: 40, height: 40)
                .background(on ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(kind.name)
        .accessibilityLabel(kind.name)
    }
}

/// The 2525C frame shapes in their affiliation colours.
private struct AffiliationGlyph: View {
    let affiliation: PointKind.Affiliation

    var body: some View {
        switch affiliation {
        case .hostile: Image(systemName: "diamond.fill").foregroundStyle(Color(argb: 0xFFFF_8080))
        case .friendly: Image(systemName: "rectangle.fill").foregroundStyle(Color(argb: 0xFF80_E0FF))
        case .neutral: Image(systemName: "square.fill").foregroundStyle(Color(argb: 0xFFAA_FFAA))
        case .unknown: Image(systemName: "seal.fill").foregroundStyle(Color(argb: 0xFFFF_FF80))
        }
    }
}

struct PointDropperPrompt: View {
    @ObservedObject var dropper: PointDropper

    var body: some View {
        if let prompt = dropper.prompt {
            HStack(spacing: 12) {
                Text(prompt)
                Button("Done") { dropper.end() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        }
    }
}

extension Color {
    init(argb: UInt32) {
        self.init(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255, opacity: Double(argb >> 24) / 255)
    }
}
