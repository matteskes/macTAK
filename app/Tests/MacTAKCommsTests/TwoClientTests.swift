// Two CommoClients through dev/g1/headless/fake-cot-server.py over plain
// TCP (G3.1): the round trip in Support/TwoClients.swift, plus the
// client's own refusals.

import Foundation
import XCTest
@testable import MacTAKComms

final class TwoClientTests: XCTestCase {
    func testTwoClientsSeeEachOther() async throws {
        let port = try freePort()
        let server = try FakeServer.cot(port: port)
        defer { server.stop() }
        try await TwoClients.roundTrip(port: port) { _ in .tcp }
    }

    func testShutDownClientRefusesToSend() async throws {
        let client = try CommoClient(uid: "g3-comms-closed", callsign: "G3-COMMS-CLOSED")
        await client.shutdown()
        do {
            try await client.broadcast(SelfEvent(uid: "x", callsign: "x").event(stale: 30).xml())
            XCTFail("a shut-down client sent")
        } catch let error as CommoError {
            XCTAssertEqual(error.description, "commo is shut down")
        }
    }
}
