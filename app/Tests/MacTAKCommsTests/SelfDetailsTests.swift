// G3.4b: the self details persist under ATAK's preference keys with ATAK's
// defaults; the device uid is the hardware's, kept apart from the settings;
// the location mode picks CoreLocation or the placed position.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class SelfDetailsTests: XCTestCase {
    func testDefaultsAreATAKs() {
        let details = SelfDetails(settings: MemorySettings(), uid: "MACTAK-ABCD-1234")
        XCTAssertEqual(details.callsign, "MACTAK-1234")
        XCTAssertEqual(details.team, "Cyan")
        XCTAssertEqual(details.role, "Team Member")
        XCTAssertEqual(details.unitType, "a-f-G-U-C")
        XCTAssertEqual(details.reporting, .atak)
        XCTAssertEqual(details.reporting.strategy, .dynamic)
    }

    func testPersistsUnderATAKsKeysAsStrings() {
        let settings = MemorySettings()
        let details = SelfDetails(settings: settings, uid: "u")
        details.callsign = "VIPER"
        details.team = "Dark Blue"
        details.role = "Team Lead"
        details.customRole = "Joint Terminal Attack Controller"
        details.customRoleAbbreviation = "JTAC"
        details.useTypeIcon = true
        details.reporting.strategy = .constant
        details.reporting.constantUnreliable = 5
        XCTAssertEqual(settings.string(forKey: "locationCallsign"), "VIPER")
        XCTAssertEqual(settings.string(forKey: "locationTeam"), "Dark Blue")
        XCTAssertEqual(settings.string(forKey: "atakRoleType"), "Team Lead")
        XCTAssertEqual(settings.string(forKey: "customRoleAbbreviation"), "JTAC")
        XCTAssertEqual(settings.string(forKey: "customRoleUseTypeIcon"), "true")
        XCTAssertEqual(settings.string(forKey: "locationReportingStrategy"), "Constant")
        XCTAssertEqual(settings.string(forKey: "constantReportingRateUnreliable"), "5")

        let reopened = SelfDetails(settings: settings, uid: "u")
        XCTAssertEqual(reopened.callsign, "VIPER")
        XCTAssertEqual(reopened.customRole, "Joint Terminal Attack Controller")
        XCTAssertTrue(reopened.useTypeIcon)
        XCTAssertEqual(reopened.reporting.strategy, .constant)
        XCTAssertEqual(reopened.reporting.constantUnreliable, 5)
    }

    func testReadsLikeATAK() {
        let settings = MemorySettings()
        settings.set("Puce", forKey: "locationTeam")
        settings.set("-4", forKey: "dynamicReportingRateMaxReliable")
        settings.set("x", forKey: "constantReportingRateReliable")
        settings.set("G32D-CALLSIGN", forKey: "mactak.callsign")
        let details = SelfDetails(settings: settings, uid: "u")
        XCTAssertEqual(details.team, "Pink", "ensureValidGroup on load")
        XCTAssertEqual(details.reporting.dynamicMaxReliable, 2, "a negative rate is the default")
        XCTAssertEqual(details.reporting.constantReliable, 15, "so is one that isn't a number")
        XCTAssertEqual(details.callsign, "G32D-CALLSIGN", "G3.2d's callsign carries over")
        settings.set("PACKAGE-1", forKey: "locationCallsign")
        XCTAssertEqual(SelfDetails(settings: settings, uid: "u").callsign, "PACKAGE-1", "locationCallsign wins")
    }

    func testAppliesToTheSelfEvent() {
        let details = SelfDetails(settings: MemorySettings(), uid: "u")
        details.customRole = "Combat Lifesaver"
        details.remarks = "on the ridge"
        var event = SelfEvent(uid: "u", callsign: "x")
        details.apply(to: &event)
        XCTAssertEqual(event.callsign, details.callsign)
        XCTAssertEqual(event.group, GroupDetail(team: "Cyan", role: "Team Member", customRole: "Combat Lifesaver"))
        XCTAssertEqual(event.remarks, "on the ridge")
        details.remarks = ""
        details.apply(to: &event)
        XCTAssertNil(event.remarks)
    }

    func testOnChangeFollowsEveryChangeButNoRepeat() {
        let details = SelfDetails(settings: MemorySettings(), uid: "u")
        var changes = 0
        details.onChange = { _ in changes += 1 }
        details.team = "Red"
        details.team = "Red"
        details.reporting.constantReliable = 30
        XCTAssertEqual(changes, 2)
    }

    // MARK: - the device uid

    private func uidFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mactak-uid-\(UUID().uuidString)/device-uid")
    }

    func testDeviceUIDIsTheHardwaresAndStaysPut() throws {
        let file = uidFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(DeviceUID.resolve(file: file, hardware: { "HW-1" }), "MACTAK-HW-1")
        XCTAssertEqual(DeviceUID.resolve(file: file, hardware: { "HW-2" }), "MACTAK-HW-1", "kept, not re-read")
        XCTAssertEqual(DeviceUID.resolve(file: file, suite: "two", hardware: { "HW-2" }), "MACTAK-HW-1-two")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "MACTAK-HW-1\n", "the suffix isn't kept")
    }

    func testDeviceUIDFallsBackAndRepairs() throws {
        let file = uidFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let random = DeviceUID.resolve(file: file, hardware: { nil })
        XCTAssertTrue(random.hasPrefix("MACTAK-") && random.count == 7 + 36, random)
        try "garbage".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DeviceUID.resolve(file: file, hardware: { "HW-3" }), "MACTAK-HW-3")
    }

    func testThisMacHasAPlatformUUID() throws {
        let uuid = try XCTUnwrap(DeviceUID.platformUUID())
        XCTAssertNotNil(UUID(uuidString: uuid), uuid)
    }

    func testTheDeviceUIDIsNotASetting() throws {
        let settings = MemorySettings()
        settings.set("MACTAK-OLD-RANDOM", forKey: "mactak.uid")
        let connections = ServerConnections(settings: settings, identities: IdentityStore.login,
                                            me: .testing(settings, uid: "MACTAK-HW"))
        XCTAssertEqual(connections.uid, "MACTAK-HW")
        XCTAssertNil(settings.string(forKey: "mactak.uid"), "G3.2d's random uid is dropped")
    }

    // MARK: - the location

    func testTheModePicksTheSource() {
        let fix = LocationFix(point: CotPoint(lat: 1, lon: 2), speed: 3, course: 90)
        let placed = CotPoint(lat: 5, lon: 6)
        func source(_ mode: LocationMode, _ fix: LocationFix?, _ placed: CotPoint?) -> SelfEvent.Source? {
            SelfLocation.choose(mode: mode, fix: fix, placed: placed).location?.source
        }
        XCTAssertEqual(source(.both, fix, placed), .provider)
        XCTAssertEqual(source(.both, nil, placed), .manual)
        XCTAssertNil(source(.both, nil, nil))
        XCTAssertEqual(source(.device, fix, placed), .provider)
        XCTAssertNil(source(.device, nil, placed))
        XCTAssertEqual(source(.manual, fix, placed), .manual)
        XCTAssertNil(source(.manual, fix, nil))
        XCTAssertEqual(SelfLocation.choose(mode: .both, fix: fix, placed: nil).track, Track(speed: 3, course: 90))
        XCTAssertEqual(SelfLocation.choose(mode: .manual, fix: fix, placed: placed).track, Track(speed: 0, course: 0))
    }

    func testTheModeAndPlacedPositionPersist() {
        let settings = MemorySettings()
        let me = SelfReporter.testing(settings)
        XCTAssertEqual(me.mode, .both)
        XCTAssertNil(me.location)
        me.mode = .manual
        me.placed = CotPoint(lat: 51.5, lon: -0.12, hae: 30)
        XCTAssertEqual(me.location, .init(point: CotPoint(lat: 51.5, lon: -0.12, hae: 30), source: .manual))
        let reopened = SelfReporter.testing(settings)
        XCTAssertEqual(reopened.mode, .manual)
        XCTAssertEqual(reopened.placed, CotPoint(lat: 51.5, lon: -0.12, hae: 30))
        XCTAssertNil(SelfReporter.point("91,0"), "off the globe")
        XCTAssertEqual(SelfReporter.point(" 1.5, 2 "), CotPoint(lat: 1.5, lon: 2))
    }

    func testBatteryIsAPercentage() {
        XCTAssertTrue((0...100).contains(SelfLocation.batteryPercent()))
    }
}
