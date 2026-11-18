// MarkerIconsTests.swift — a marker's icon and colour as ATAK 5.5 picks
// them (G3.7b, G3.7c; IconsMapAdapter, Icon2525cIconAdapter, teamToColor,
// CotMarkerRefresher), 5.5's icon_filters.xml, and every icon those can
// name shipping in the engine's assets.

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

    // MARK: - CoT markers (G3.7c)

    private let noSymbol: (String) -> String? = { _ in nil }
    private let symbol: (String) -> String? = { "base64://" + $0 }

    func testTypeGoesFiltersThenSymbolThenUnknown() {
        XCTAssertEqual(MarkerIcons.icon(MarkerTraits(type: "a-f-G-E-S-t-x", how: "m-g"), stale: false, symbol: symbol),
                       MarkerIcon(uri: "asset://icons/ttl-icon-f.png"), "the filter beats the symbol")
        XCTAssertEqual(MarkerIcons.icon(MarkerTraits(type: "a-h-G", how: "m-g"), stale: false, symbol: symbol),
                       MarkerIcon(uri: "base64://a-h-G"))
        XCTAssertEqual(MarkerIcons.icon(MarkerTraits(type: "a-n-X", how: "m-g", color: 0xFF12_3456), stale: false,
                                        symbol: noSymbol),
                       MarkerIcon(uri: "asset://icons/unknown-type-n.png"), "unknown-type drops the tint")
    }

    func testColourTintsAndStaleIsDarkGrey() {
        let red = MarkerTraits(type: "a-h-G", how: "h-g-i-g-o", color: 0xFFFF_0000)
        XCTAssertEqual(MarkerIcons.icon(red, stale: false, symbol: symbol).color, 0xFFFF_0000)
        XCTAssertEqual(MarkerIcons.icon(red, stale: true, symbol: symbol).color, MarkerIcons.staleMarker)
        var none = red
        none.color = 0
        XCTAssertEqual(MarkerIcons.icon(none, stale: false, symbol: symbol).color, MarkerIcons.white)
    }

    func testNotReadyDrawsDamagedUnlessATeamMember() {
        func icon(_ type: String, group: GroupDetail? = nil) -> String {
            MarkerIcons.icon(MarkerTraits(type: type, how: "m-g", group: group, ready: false), stale: false,
                             symbol: symbol).uri
        }
        XCTAssertEqual(icon("a-f-G"), "asset://icons/damaged.png")
        XCTAssertEqual(icon("a-h-G"), "asset://icons/damaged_hostile.png")
        XCTAssertEqual(icon("a-n-G"), "asset://icons/damaged_neutral.png")
        XCTAssertEqual(icon("a-u-G"), "asset://icons/damaged_unknown.png")
        XCTAssertEqual(icon("a-f-G", group: GroupDetail(team: "Red")), "asset://icons/roles/team.png")
    }

    func testIconsetPathSpotMapAndBase64() {
        let spot = { (type: String) in
            MarkerIcons.icon(MarkerTraits(type: type, how: "h-e", iconsetPath: "COT_MAPPING_SPOTMAP/b-m-p-s-m/-1"),
                             stale: false, symbol: self.symbol)
        }
        XCTAssertEqual(spot("a-f-G"), MarkerIcon(uri: "asset://icons/reference_point.png", color: 0xFF00_00FF))
        XCTAssertEqual(spot("a-h-G").color, 0xFFFF_0000)
        XCTAssertEqual(spot("a-n-G").color, 0xFF00_FF00)
        XCTAssertEqual(spot("a-u-G").color, 0xFFFF_FF00)
        let own = MarkerTraits(type: "a-h-G", how: "h-e", color: 0xFFFF_0000, iconsetPath: "base64://AAAA")
        XCTAssertEqual(MarkerIcons.icon(own, stale: false, symbol: symbol), MarkerIcon(uri: "base64://AAAA"))
        let set = MarkerTraits(type: "a-h-G", how: "h-e", iconsetPath: "6d781afb-89a6-4c07-b2b9-a89748b6a38f/Misc/x.png")
        XCTAssertEqual(MarkerIcons.icon(set, stale: false, symbol: symbol).uri, "base64://a-h-G",
                       "a user icon set falls back to 2525C")
    }

    func testFiltersAre55sTableAndTheLastMatchWins() throws {
        let xml = try String(contentsOf: Self.repo.appendingPathComponent("dev/g3/test/icon-filters/icon_filters.xml"),
                             encoding: .utf8)
        let uncommented = xml.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let pattern = try NSRegularExpression(pattern: "<filter type='([^']*)'\\s*>([^<]*)</filter>")
        let range = NSRange(uncommented.startIndex..., in: uncommented)
        let expected = pattern.matches(in: uncommented, range: range).map { m in
            (String(uncommented[Range(m.range(at: 1), in: uncommented)!]),
             String(uncommented[Range(m.range(at: 2), in: uncommented)!]).trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(expected.count, 63)
        XCTAssertEqual(IconFilters.entries.map { "\($0.type)=\($0.icon)" }, expected.map { "\($0.0)=\($0.1)" })
        XCTAssertEqual(IconFilters.icon(forType: "b-m-p-s-p-i"), "asset://icons/b-m-p-s-p-i.png")
        XCTAssertEqual(IconFilters.icon(forType: "b-x"), "asset://icons/b.png")
        XCTAssertNil(IconFilters.icon(forType: "a-f-G-U-C"))
    }

    /// Every asset an atom's icon can name ships in dev/g2/render/resources.
    func testEveryAtomIconShips() {
        var uris = IconFilters.entries.filter { $0.type.hasPrefix("a-") }.map { "asset://" + $0.icon }
        uris += ["a-f", "a-h", "a-n", "a-u", "b"].flatMap { [MarkerIcons.damagedIcon($0), MarkerIcons.unknownTypeIcon($0)] }
        uris += ["asset://icons/reference_point.png"]
        uris += ["Team Member", "HQ", "Team Lead", "Sniper", "K9", "RTO", "Medic", "Forward Observer"].flatMap { role in
            ["m-g", "h-e", "m-g-l"].map { MarkerIcons.roleIcon(role: role, customRole: nil, how: $0) }
        }
        let assets = Self.repo.appendingPathComponent("dev/g2/render/resources/assets")
        for uri in uris {
            let path = assets.appendingPathComponent(String(uri.dropFirst("asset://".count))).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), uri)
        }
    }

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}
