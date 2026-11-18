// MarkerIconsTests.swift — a marker's icon and colour as ATAK 5.5 picks
// them (G3.7b; Icon2525cIconAdapter, teamToColor, CotMarkerRefresher).

import Foundation
import XCTest
import MacTAKCot
@testable import MacTAKComms

final class MarkerIconsTests: XCTestCase {
    private func contact(type: String = "a-f-G-U-C", how: String = "m-g", group: GroupDetail?) -> Contact {
        let now = Date()
        return Contact(uid: "u", callsign: "C", type: type, group: group, point: CotPoint(lat: 37.8, lon: -122.4),
                       how: how, precision: nil, takv: nil, track: nil, battery: nil, endpoint: "*:-1:stcp",
                       paths: [.mesh], lastHeard: now, staleAt: now, removeAt: now)
    }

    func testTeamColoursAre55s() {
        XCTAssertEqual(MarkerIcons.teamColor("Cyan"), 0xFF00_FFFF)
        XCTAssertEqual(MarkerIcons.teamColor("Dark Blue"), 0xFF00_007F)
        XCTAssertEqual(MarkerIcons.teamColor("Brown"), 0xFFA0_714F)
        XCTAssertEqual(MarkerIcons.teamColor("Rad Sensor"), 0xFFFF_FF00)
        XCTAssertEqual(MarkerIcons.teamColor("White"), 0xFFFF_FFFF)
        XCTAssertEqual(MarkerIcons.teamColor("no such team"), 0xFFFF_FFFF)
        XCTAssertEqual(MarkerIcons.teamColor(nil), 0xFFFF_FFFF)
    }

    func testRoleIconsAndTheirHowVariants() {
        XCTAssertEqual(MarkerIcons.roleIcon(role: "Team Member", customRole: nil, how: "m-g"),
                       "asset://icons/roles/team.png")
        XCTAssertEqual(MarkerIcons.roleIcon(role: "Forward Observer", customRole: nil, how: "h-e"),
                       "asset://icons/roles/forwardobserver_human.png")
        XCTAssertEqual(MarkerIcons.roleIcon(role: "HQ", customRole: nil, how: "m-g-l"),
                       "asset://icons/roles/hq_nogps.png")
        XCTAssertEqual(MarkerIcons.roleIcon(role: "Medic", customRole: "Pilot", how: "m-g"),
                       "asset://icons/roles/team.png")
    }

    func testTeamMemberDrawsItsRoleInItsTeamColour() {
        let c = contact(group: GroupDetail(team: "Red", role: "Sniper"))
        let icon = MarkerIcons.contact(c, stale: false) { _ in XCTFail("no symbol for a team member"); return nil }
        XCTAssertEqual(icon, MarkerIcon(uri: "asset://icons/roles/sniper.png", color: 0xFFFF_0000))
        XCTAssertEqual(MarkerIcons.contact(c, stale: true) { _ in nil }.color, MarkerIcons.staleContact)
    }

    func testShownAsASymbolOrWithoutATeamDrawsItsType() {
        let symbol: (String) -> String? = { $0 == "a-f-G-U-C" ? "base64://SYMBOL" : nil }
        let asSymbol = contact(group: GroupDetail(team: "Red", displayAsSymbologyGraphic: true))
        XCTAssertEqual(MarkerIcons.contact(asSymbol, stale: false, symbol: symbol),
                       MarkerIcon(uri: "base64://SYMBOL"))
        XCTAssertEqual(MarkerIcons.contact(asSymbol, stale: true, symbol: symbol).color, MarkerIcons.staleContact)
        let noTeam = contact(type: "a-h-G-X", group: nil)
        XCTAssertEqual(MarkerIcons.contact(noTeam, stale: true, symbol: symbol),
                       MarkerIcon(uri: "asset://icons/unknown-type-h.png", color: MarkerIcons.staleMarker))
    }

    func testUnknownTypeIconsByAffiliation() {
        XCTAssertEqual(MarkerIcons.unknownTypeIcon("a-a-G"), "asset://icons/unknown-type-f.png")
        XCTAssertEqual(MarkerIcons.unknownTypeIcon("a-n-G"), "asset://icons/unknown-type-n.png")
        XCTAssertEqual(MarkerIcons.unknownTypeIcon("a-j-G"), "asset://icons/unknown-type-h.png")
        XCTAssertEqual(MarkerIcons.unknownTypeIcon("a-p-G"), "asset://icons/unknown-type-u.png")
        XCTAssertEqual(MarkerIcons.unknownTypeIcon("b-m-p-s-p-i"), "asset://icons/unknown-type.png")
    }
}
