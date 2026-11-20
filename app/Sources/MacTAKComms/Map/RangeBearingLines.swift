// RangeBearingLines.swift — the range and bearing lines on the map and the
// tool that makes them (G3.8c), as ATAK 5.5 has them
// (RangeAndBearingTool, RangeAndBearingMapItem):
//
// - the tool takes two clicks: the start, then the end. A click on a marker
//   ties that end to it (the line follows it as it moves); a click on the
//   map fixes the end there, and the first such click shows a red start
//   point until the line is made. The same marker twice is ignored. The
//   line is made on the second click and the tool ends.
// - a line is titled "R&B n", the lowest n no other line has.
// - when a marker an end is tied to goes away, the line stays and that end
//   stays where the marker last was (removePoint).
//
// Shared lines (G3.8d): a line can be sent as CoT (u-rb-a,
// RangeBearingEvent) and others' lines arrive the same way: an end is the
// marker the event names when this client has it, else a fixed place (5.5
// defers and retries such an import; here the place stands). A delete task
// naming a line removes it. A line this client made is never replaced by
// one heard under its uid (the mesh can echo it back).
//
// The map side (drawing, the label from the Units preferences) is the app's
// MapMarkerSync; this file holds what the lines are.

import Foundation
import MacTAKCot

/// One end of a range and bearing line.
public enum RangeBearingEnd: Equatable, Sendable {
    /// Tied to the marker with this uid (a contact, a CoT marker, the self).
    case item(String)
    /// A fixed place.
    case point(CotPoint)
}

public struct RangeBearingLine: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var start: RangeBearingEnd
    public var end: RangeBearingEnd
    /// ARGB as an int, as CoT carries it (5.5's default red).
    public var color: Int32 = RangeBearingEvent.red
    /// Heard from another client, not made here.
    public var received = false
    /// When it was made here (CoT's <creator time>).
    public var created = Date()

    public init(id: String, title: String, start: RangeBearingEnd, end: RangeBearingEnd,
                color: Int32 = RangeBearingEvent.red, received: Bool = false, created: Date = Date()) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.color = color; self.received = received; self.created = created
    }
}

/// What a click on the map hit, for the tool.
public enum MapPick: Equatable, Sendable {
    case item(String)
    case ground(CotPoint)
}

@MainActor
public final class RangeBearingLines: ObservableObject {
    public enum ToolState: Equatable, Sendable {
        case off
        /// Waiting for the start (5.5's rb_prompt).
        case pickingStart
        /// Waiting for the end (rb_prompt3 after a marker, rb_measure_prompt after a place).
        case pickingEnd(RangeBearingEnd)
    }

    @Published public private(set) var lines: [RangeBearingLine] = []
    @Published public private(set) var tool: ToolState = .off
    /// Each line's label as the map last drew it, by line id (for the list).
    @Published public private(set) var labels: [String: String] = [:]
    private let newID: () -> String

    public init(newID: @escaping () -> String = { UUID().uuidString }) {
        self.newID = newID
    }

    // ---- the tool -----------------------------------------------------------

    public func beginTool() { tool = .pickingStart }

    /// Cancel: nothing is made.
    public func endTool() { tool = .off }

    /// The tool's prompt, 5.5's wording; nil while it is off.
    public var prompt: String? {
        switch tool {
        case .off: nil
        case .pickingStart: "Click the point to measure from."
        case .pickingEnd(.item): "Click the point to measure range and bearing to."
        case .pickingEnd(.point): "Click the point to measure to."
        }
    }

    /// The red start point shown while the end is picked after a click on the map.
    public var startPoint: CotPoint? {
        if case .pickingEnd(.point(let p)) = tool { return p }
        return nil
    }

    /// A click while the tool is on; returns the line it made, if any.
    @discardableResult
    public func click(_ pick: MapPick) -> RangeBearingLine? {
        let end: RangeBearingEnd = switch pick {
        case .item(let uid): .item(uid)
        case .ground(let p): .point(p)
        }
        switch tool {
        case .off:
            return nil
        case .pickingStart:
            tool = .pickingEnd(end)
            return nil
        case .pickingEnd(let start):
            if case .item = end, end == start { return nil }   // the same marker twice
            let line = add(start: start, end: end)
            tool = .off
            return line
        }
    }

    // ---- the lines ----------------------------------------------------------

    @discardableResult
    public func add(start: RangeBearingEnd, end: RangeBearingEnd, at now: Date = Date()) -> RangeBearingLine {
        let line = RangeBearingLine(id: newID(), title: nextTitle(), start: start, end: end, created: now)
        lines.append(line)
        return line
    }

    public subscript(id: String) -> RangeBearingLine? { lines.first { $0.id == id } }

    /// Takes in a CoT event commo received: a u-rb-a line is added or
    /// replaced, a delete task naming a line removes it; anything else is
    /// ignored. `isMarker` says whether a uid is a marker this client has.
    /// Returns whether the lines changed.
    @discardableResult
    public func receive(_ xml: String, isMarker: (String) -> Bool) -> Bool {
        guard let event = try? CotEvent.parse(xml) else { return false }
        if event.type == CotMarkerStore.deleteType {
            guard let uid = event.detail("link")?["uid"], self[uid] != nil else { return false }
            remove(id: uid)
            return true
        }
        guard let r = RangeBearingEvent.parse(event) else { return false }
        if let mine = self[r.uid], !mine.received { return false }
        let start: RangeBearingEnd = r.anchorUID.map { isMarker($0) } == true ? .item(r.anchorUID!) : .point(r.anchor)
        let end: RangeBearingEnd = r.rangeUID.map { isMarker($0) } == true ? .item(r.rangeUID!) : .point(r.farEnd)
        if let i = lines.firstIndex(where: { $0.id == r.uid }) {
            lines[i].title = r.title ?? lines[i].title
            lines[i].start = start
            lines[i].end = end
            lines[i].color = r.color
        } else {
            lines.append(RangeBearingLine(id: r.uid, title: r.title ?? nextTitle(), start: start, end: end,
                                          color: r.color, received: true))
        }
        return true
    }

    public func remove(id: String) {
        lines.removeAll { $0.id == id }
        labels[id] = nil
    }

    public func removeAll() {
        lines.removeAll()
        labels.removeAll()
    }

    /// The labels the map drew; published only when they change.
    public func setLabels(_ new: [String: String]) {
        if new != labels { labels = new }
    }

    /// "R&B n", the lowest n not taken (RangeAndBearingImporter.getInstanceNum).
    func nextTitle() -> String {
        let taken = Set(lines.map(\.title))
        var n = 1
        while taken.contains("R&B \(n)") { n += 1 }
        return "R&B \(n)"
    }

    /// Where the lines' ends are now: each tied end at its marker's place
    /// in `markers` (uid → place). An end whose marker has gone becomes a
    /// fixed place where the marker was last seen (5.5's removePoint); a
    /// line whose marker hasn't been seen yet is left out until it is.
    public func ends(markers: [String: CotPoint]) -> [(line: RangeBearingLine, start: CotPoint, end: CotPoint)] {
        let tied = tiedUIDs
        for (uid, p) in markers where tied.contains(uid) { lastSeen[uid] = p }
        var resolved: [(RangeBearingLine, CotPoint, CotPoint)] = []
        for i in lines.indices {
            if let pinned = pin(lines[i].start, markers) { lines[i].start = pinned }
            if let pinned = pin(lines[i].end, markers) { lines[i].end = pinned }
            guard let s = place(lines[i].start, markers), let e = place(lines[i].end, markers) else { continue }
            resolved.append((lines[i], s, e))
        }
        let stillTied = tiedUIDs
        lastSeen = lastSeen.filter { stillTied.contains($0.key) }
        return resolved
    }

    /// Where each tied marker was last seen.
    private var lastSeen: [String: CotPoint] = [:]

    private var tiedUIDs: Set<String> {
        var uids = Set<String>()
        for line in lines {
            if case .item(let uid) = line.start { uids.insert(uid) }
            if case .item(let uid) = line.end { uids.insert(uid) }
        }
        if case .pickingEnd(.item(let uid)) = tool { uids.insert(uid) }
        return uids
    }

    /// The fixed end a tied end becomes once its marker has gone, else nil.
    private func pin(_ end: RangeBearingEnd, _ markers: [String: CotPoint]) -> RangeBearingEnd? {
        guard case .item(let uid) = end, markers[uid] == nil, let last = lastSeen[uid] else { return nil }
        return .point(last)
    }

    private func place(_ end: RangeBearingEnd, _ markers: [String: CotPoint]) -> CotPoint? {
        switch end {
        case .point(let p): p
        case .item(let uid): markers[uid]
        }
    }
}
