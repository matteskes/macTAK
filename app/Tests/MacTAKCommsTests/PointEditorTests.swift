// G3.9c: editing points. The inspector's edits (name, remarks, colour,
// affiliation) change the marker's CoT and what is kept across launches; a
// move by click or drag; a machine-generated marker doesn't move; a delete
// removes it, kept copy included; received markers edit too, until a newer
// event replaces the edit; R&B from a point; a sent point is timed now.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class PointEditorTests: XCTestCase {
    /// 2026-11-03 14:32:05 UTC.
    private let t = Date(timeIntervalSince1970: 1_793_716_325)
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)

    private func setUp(_ markers: CotMarkerStore) -> (PointDropper, PointEditor) {
        let place: (String) -> CotPoint? = { markers[$0]?.point }
        let dropper = PointDropper(markers: markers, place: place, deviceCallsign: { "VIPER" },
                                   newID: { "pt-\(markers.markers.count + 1)" },
                                   timeZone: TimeZone(identifier: "UTC")!)
        return (dropper, PointEditor(markers: markers, place: place))
    }

    private func received(_ uid: String, how: String = "h-g-i-g-o", callsign: String, at p: CotPoint,
                          stale: TimeInterval = 60) -> String {
        var detail = CotDetail("detail")
        var contact = CotDetail("contact")
        contact["callsign"] = callsign
        detail.add(contact)
        return CotEvent(uid: uid, type: "a-h-G", time: t, stale: t.addingTimeInterval(stale), how: how,
                        point: p, detail: detail).xml()
    }

    private func placed(_ markers: CotMarkerStore, _ kind: PointKind = .affiliation(.hostile)) throws
        -> (PointEditor, String) {
        let (dropper, editor) = setUp(markers)
        dropper.begin(kind)
        let uid = try XCTUnwrap(dropper.click(.ground(here), at: t)).uid
        dropper.end()
        return (editor, uid)
    }

    func testTheInspectorsEditsChangeTheKeptCoT() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (editor, uid) = try placed(markers)
        editor.inspect(uid)
        XCTAssertEqual(editor.inspected, uid)
        editor.rename(uid, to: "  Bridge  ")
        editor.setRemarks(uid, "two trucks\n")
        editor.setColor(uid, 0xFFFF_0000)
        editor.setAffiliation(uid, .friendly)
        let m = try XCTUnwrap(markers[uid])
        XCTAssertEqual(m.label, "Bridge")
        XCTAssertEqual(m.remarks, "two trucks")
        XCTAssertEqual(m.traits.color, 0xFFFF_0000)
        XCTAssertEqual(m.type, "a-f-G")
        XCTAssertEqual(m.traits.iconsetPath, "COT_MAPPING_2525C/a-h/a-h-G", "5.5 leaves the iconset path")
        let kept = try CotEvent.parse(try XCTUnwrap(m.archivedEvent))
        XCTAssertEqual(kept.type, "a-f-G")
        XCTAssertEqual(kept.detail("contact")?["callsign"], "Bridge")
        XCTAssertEqual(kept.detail("remarks")?.innerText, "two trucks")
        XCTAssertEqual(kept.detail("color")?["argb"], "-65536")
        XCTAssertNotNil(kept.detail("archive"))
        editor.setRemarks(uid, "  ")
        XCTAssertNil(markers[uid]?.remarks, "empty remarks go")
    }

    func testANameThatIsEmptyOrTheUIDIsIgnored() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (editor, uid) = try placed(markers)
        let before = markers[uid]?.label
        editor.rename(uid, to: "   ")
        editor.rename(uid, to: uid)
        XCTAssertEqual(markers[uid]?.label, before)
    }

    func testMoveTakesTheNextClick() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        markers.receive(received("theirs", callsign: "Other", at: there), at: t)
        let (editor, uid) = try placed(markers)
        editor.beginMove(uid)
        XCTAssertEqual(editor.prompt, "Click where to move \(markers[uid]!.label!).")
        XCTAssertFalse(editor.click(.item(uid)), "not onto itself")
        XCTAssertEqual(editor.moving, uid)
        XCTAssertTrue(editor.click(.ground(there)))
        XCTAssertEqual(markers[uid]?.point, there)
        XCTAssertNil(editor.moving, "one move per Move")
        XCTAssertFalse(editor.click(.ground(here)))
        editor.beginMove(uid)
        editor.click(.item("theirs"))
        XCTAssertEqual(markers[uid]?.point, there, "onto another item's point")
        let kept = try CotEvent.parse(try XCTUnwrap(markers[uid]?.archivedEvent))
        XCTAssertEqual(kept.point, there)
    }

    func testADragMovesIt() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (editor, uid) = try placed(markers, .spotMap(.red))
        XCTAssertTrue(editor.canMove(uid))
        XCTAssertTrue(editor.move(uid, to: there))
        XCTAssertEqual(markers[uid]?.point, there)
    }

    func testAMachineGeneratedMarkerDoesntMoveOrChangeAffiliation() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (_, editor) = setUp(markers)
        markers.receive(received("sensor", how: "m-g", callsign: "Sensor", at: here), at: t)
        XCTAssertTrue(editor.canEdit("sensor"))
        XCTAssertFalse(editor.canMove("sensor"))
        editor.beginMove("sensor")
        XCTAssertNil(editor.moving)
        XCTAssertFalse(editor.move("sensor", to: there))
        editor.setAffiliation("sensor", .friendly)
        XCTAssertEqual(markers["sensor"]?.type, "a-h-G")
        editor.rename("sensor", to: "Gate")
        XCTAssertEqual(markers["sensor"]?.label, "Gate", "its name still edits")
    }

    func testAReceivedMarkerEditsUntilANewerEventReplacesIt() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (_, editor) = setUp(markers)
        markers.receive(received("theirs", callsign: "Other", at: here, stale: 60), at: t)
        let staleAt = try XCTUnwrap(markers["theirs"]).staleAt
        editor.rename("theirs", to: "Mine now")
        let m = try XCTUnwrap(markers["theirs"])
        XCTAssertEqual(m.label, "Mine now")
        XCTAssertEqual(m.staleAt, staleAt, "an edit keeps its timing")
        XCTAssertFalse(m.archived, "and doesn't keep it")
        markers.receive(received("theirs", callsign: "Other", at: there), at: t.addingTimeInterval(5))
        XCTAssertEqual(markers["theirs"]?.label, "Other")
    }

    func testDeleteRemovesItAndClosesTheInspector() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (editor, uid) = try placed(markers)
        editor.inspect(uid)
        editor.beginMove(uid)
        editor.delete(uid)
        XCTAssertNil(markers[uid])
        XCTAssertNil(editor.inspected)
        XCTAssertNil(editor.moving)
    }

    func testOnlyCotMarkersAreInspected() {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (_, editor) = setUp(markers)
        editor.inspect("contact-1")
        XCTAssertNil(editor.inspected)
    }

    func testRangeAndBearingFromAPoint() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (_, uid) = try placed(markers)
        let lines = RangeBearingLines(newID: { "rb-1" })
        lines.beginTool(from: uid)
        XCTAssertEqual(lines.prompt, "Click the point to measure range and bearing to.")
        let line = try XCTUnwrap(lines.click(.ground(there)))
        XCTAssertEqual(line.start, .item(uid))
        XCTAssertEqual(line.end, .point(there))
    }

    func testASentPointIsTimedNowWithItsEdits() throws {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let (editor, uid) = try placed(markers)
        editor.rename(uid, to: "Bridge")
        let event = try XCTUnwrap(markers[uid]).event
        let now = t.addingTimeInterval(3600)
        let sent = ServerConnections.outgoing(event, at: now)
        XCTAssertEqual(sent.time, now)
        XCTAssertEqual(sent.start, now)
        XCTAssertEqual(sent.stale, now.addingTimeInterval(PlacedPoint.staleSeconds))
        XCTAssertEqual(sent.detail("contact")?["callsign"], "Bridge")
        XCTAssertNotNil(sent.detail("archive"))
    }

    func testEditsAndDeletesSurviveARelaunch() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statesaver-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        func launch() throws -> ServerConnections {
            let settings = MemorySettings()
            return ServerConnections(settings: settings, identities: keychain.store, me: .testing(settings),
                                     mapItemStore: try MapItemStore(url: url))
        }
        let (kept, gone): (String, String)
        do {
            let c = try launch()
            c.pointDropper.begin(.spotMap(.white))
            kept = try XCTUnwrap(c.pointDropper.click(.ground(here))).uid
            gone = try XCTUnwrap(c.pointDropper.click(.ground(there))).uid
            c.pointEditor.rename(kept, to: "Rally")
            c.pointEditor.setRemarks(kept, "north gate")
            c.pointEditor.move(kept, to: there)
            c.pointEditor.delete(gone)
            c.syncArchive()
        }
        let c = try launch()
        let m = try XCTUnwrap(c.markers[kept])
        XCTAssertEqual(m.label, "Rally")
        XCTAssertEqual(m.remarks, "north gate")
        XCTAssertEqual(m.point, there)
        XCTAssertNil(c.markers[gone])
    }
}
