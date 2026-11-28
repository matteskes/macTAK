// The delete task (t-x-d-d, N2) as 5.5's CotDeleteImporter reads it: the
// type exactly, a link whose uid, relation and type aren't empty, and
// <__forcedelete> when it is there.

import Foundation
import XCTest
@testable import MacTAKCot

final class CotDeleteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(type: String = CotDelete.type, link: [String: String]? = ["uid": "m1", "relation": "none",
                                                                              "type": "none"],
                      force: Bool = false) -> CotEvent {
        var detail = CotDetail("detail")
        if let link {
            var l = CotDetail("link")
            for (name, value) in link { l[name] = value }
            detail.add(l)
        }
        if force { detail.add(CotDetail("__forcedelete")) }
        return CotEvent(uid: "del-1", type: type, time: now, stale: now, how: "h-g-i-g-o", detail: detail)
    }

    func testATaskNamesItsLinksUIDAndWhetherItForces() {
        XCTAssertEqual(CotDelete.parse(task()), CotDelete(uid: "m1", force: false))
        XCTAssertEqual(CotDelete.parse(task(force: true)), CotDelete(uid: "m1", force: true))
    }

    func testOnlyTheTypeItselfNotOneThatStartsWithIt() {
        XCTAssertNil(CotDelete.parse(task(type: "t-x-d-d-x")), "the marshal routes it, the importer refuses it")
        XCTAssertNil(CotDelete.parse(task(type: "a-h-G")))
    }

    func testTheLinkNeedsAUIDRelationAndType() {
        XCTAssertNil(CotDelete.parse(task(link: nil)))
        XCTAssertNil(CotDelete.parse(task(link: ["uid": "m1", "relation": "none"])))
        XCTAssertNil(CotDelete.parse(task(link: ["uid": "m1", "relation": "", "type": "none"])))
        XCTAssertNil(CotDelete.parse(task(link: ["uid": "", "relation": "none", "type": "none"])))
    }
}
