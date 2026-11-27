// Bounded waits for the tests that watch a client's state change: a server
// connecting, an event arriving, a sync landing. Each fails with what it
// was waiting for instead of hanging. (Recorder and FakeServer have their
// own: they wait on an actor's events and on the server's output.)

import Foundation
@testable import MacTAKComms

/// Waits until `done` holds, checking every 0.1 s; throws after `timeout`.
@MainActor
func waitFor(_ what: String, timeout: TimeInterval = 15, _ done: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        guard Date() < deadline else { throw timedOut(what, after: timeout) }
        try await Task.sleep(for: .milliseconds(100))
    }
}

/// Calls `send` once a second until `arrived`; throws after `timeout`.
/// commo reports a connection up before it can send on it (CommoClient's
/// notes, G1), so a first share can go nowhere; a resend of a line or a
/// point replaces it at the other end, as 5.5's does.
@MainActor
func resend(_ what: String, timeout: TimeInterval = 15, _ send: () throws -> Void,
            until arrived: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !arrived() {
        guard Date() < deadline else { throw timedOut(what, after: timeout) }
        try send()
        for _ in 0..<10 where !arrived() { try await Task.sleep(for: .milliseconds(100)) }
    }
}

/// Calls `send` once a second until `seen` has an event that matches;
/// throws after `timeout`. For a broadcast the test makes itself: one sent
/// before the peer can hear it is lost, as a datagram is.
func resend(_ what: String, timeout: TimeInterval = 15, _ send: () async throws -> Void,
            until seen: Recorder, _ match: @escaping @Sendable (CommoEvent) -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !seen.contains(match) {
        guard Date() < deadline else { throw timedOut(what, after: timeout) }
        try await send()
        for _ in 0..<10 where await !seen.contains(match) { try await Task.sleep(for: .milliseconds(100)) }
    }
}

private func timedOut(_ what: String, after timeout: TimeInterval) -> CommoError {
    CommoError(description: "timed out after \(Int(timeout)) s waiting for: \(what)")
}
