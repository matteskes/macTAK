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
// Shared lines (G3.8d), as 5.5's RangeAndBearingImporter and
// CotDeleteImporter take them: a u-rb-a event adds a line or updates the
// one with its uid, whoever made it. An end is the marker the event names
// when this client has it; otherwise a new line's end is a fixed place, and
// an existing line keeps an end tied to a marker (5.5 moves that marker to
// the event's place; this doesn't move others' markers) and moves a fixed
// end to the event's place. A live import naming a marker this client
// hasn't heard isn't retried (5.5 retries only when loading saved state).
// A delete task with <__forcedelete> removes the line it names, made here
// or not; one without only greys markers, so it leaves lines alone.
//
// Kept across launches (G3.9a): a line the tool makes is archived, as 5.5
// makes it persistent; a received one is when it came with <archive/>.
// The MapItemArchive stores them and gives them back at launch through
// `restore`, which, as 5.5's StateSaverPublisher does, reports a line
// whose named marker isn't loaded yet as deferred, to try again once
// everything else is.
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
    /// The stroke width, 5.5's strokeWeight (3 for a line made here).
    public var weight = RangeBearingEvent.strokeWeight
    /// Who made it and when: this client at the tool's second click
    /// (setAuthorInformation), or a received line's <creator>.
    public var creator: Author?
    /// Kept across launches (5.5's archive meta value).
    public var archived: Bool

    public init(id: String, title: String, start: RangeBearingEnd, end: RangeBearingEnd,
                color: Int32 = RangeBearingEvent.red, received: Bool = false,
                weight: Double = RangeBearingEvent.strokeWeight, creator: Author? = nil,
                archived: Bool = true) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.color = color; self.received = received; self.weight = weight; self.creator = creator
        self.archived = archived
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

    /// This client as a line's author, at the moment asked
    /// (setAuthorInformation); nil leaves lines made here without one.
    public var author: (() -> Author)?

    public init(newID: @escaping () -> String = { UUID().uuidString }) {
        self.newID = newID
    }

    // ---- the tool -----------------------------------------------------------

    public func beginTool() { tool = .pickingStart }

    /// Starts the tool from a marker (5.5's pairing line from a point's
    /// menu): the next click is the end.
    public func beginTool(from uid: String) { tool = .pickingEnd(.item(uid)) }

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
    public func add(start: RangeBearingEnd, end: RangeBearingEnd) -> RangeBearingLine {
        let line = RangeBearingLine(id: newID(), title: nextTitle(), start: start, end: end, creator: author?())
        lines.append(line)
        return line
    }

    public subscript(id: String) -> RangeBearingLine? { lines.first { $0.id == id } }

    /// Takes in a CoT event commo received: a u-rb-a line is added or
    /// updated, a force-delete task naming a line removes it; anything else
    /// is ignored. `isMarker` says whether a uid is a marker this client
    /// has. Returns whether the lines changed.
    @discardableResult
    public func receive(_ xml: String, isMarker: (String) -> Bool) -> Bool {
        guard let event = try? CotEvent.parse(xml) else { return false }
        if event.type == CotMarkerStore.deleteType { return delete(event) }
        guard let r = RangeBearingEvent.parse(event) else { return false }
        return take(r, isMarker: isMarker, received: true)
    }

    /// What `restore` made of a kept event (5.5's ImportResult).
    public enum RestoreResult: Equatable, Sendable {
        case restored
        /// A marker it names isn't here yet: try again later.
        case deferred
        /// Not a line.
        case ignored
    }

    /// Takes back a line kept across launches. It is this client's own
    /// (not shown as received) when its creator is `selfUID`.
    public func restore(_ xml: String, isMarker: (String) -> Bool, selfUID: String) -> RestoreResult {
        guard let event = try? CotEvent.parse(xml), let r = RangeBearingEvent.parse(event) else { return .ignored }
        take(r, isMarker: isMarker, received: r.creator?.uid != selfUID)
        let missing = [r.anchorUID, r.rangeUID].contains { $0.map { !isMarker($0) } ?? false }
        return missing ? .deferred : .restored
    }

    /// Adds the line `r` says, or updates the one with its uid.
    @discardableResult
    private func take(_ r: RangeBearingEvent.Received, isMarker: (String) -> Bool, received: Bool) -> Bool {
        let existing = lines.firstIndex { $0.id == r.uid }
        let old = existing.map { lines[$0] }
        func end(_ uid: String?, _ was: RangeBearingEnd?, _ place: @autoclosure () -> CotPoint) -> RangeBearingEnd {
            if let uid, isMarker(uid) { return .item(uid) }
            if case .item = was { return was! }
            return .point(place())
        }
        let line = RangeBearingLine(id: r.uid, title: r.title ?? nextTitle(),
                                    start: end(r.anchorUID, old?.start, r.anchor),
                                    end: end(r.rangeUID, old?.end, r.farEnd),
                                    color: r.color, received: old?.received ?? received,
                                    weight: r.weight ?? old?.weight ?? RangeBearingEvent.strokeWeight,
                                    creator: r.creator ?? old?.creator,
                                    archived: r.archive || old?.archived == true)
        if let existing {
            if lines[existing] == line { return false }
            lines[existing] = line
        } else {
            lines.append(line)
        }
        return true
    }

    /// CotDeleteImporter: a link with a uid, relation and type, and
    /// <__forcedelete>, removes that line.
    private func delete(_ event: CotEvent) -> Bool {
        guard let link = event.detail("link"), let uid = link["uid"], !uid.isEmpty,
              link["relation"]?.isEmpty == false, link["type"]?.isEmpty == false,
              event.detail("__forcedelete") != nil, self[uid] != nil else { return false }
        remove(id: uid)
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
