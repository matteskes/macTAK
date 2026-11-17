// A stand-in TAK server run as a child process (fake-cot-server.py,
// fake-quic-server.py), with its output kept so a test can wait on a line.

import Foundation
@testable import MacTAKComms

/// The repository's root, from this file's path.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

final class FakeServer: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var output = ""

    /// Starts `executable arguments…` and returns once its output contains
    /// "listening" (both fake servers print it once bound), or throws.
    init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData   // drained always, so a full pipe never blocks the server
            guard let self, !chunk.isEmpty else { return }
            self.lock.withLock { self.output += String(decoding: chunk, as: UTF8.self) }
        }
        try process.run()
        do {
            try waitFor("listening", timeout: 15)
        } catch {
            stop()
            throw error
        }
    }

    /// fake-cot-server.py on `port`, with any of its TLS options.
    static func cot(port: Int, _ options: [String] = []) throws -> FakeServer {
        let script = repoRoot.appendingPathComponent("dev/g1/headless/fake-cot-server.py").path
        return try FakeServer("/usr/bin/env", ["python3", script, String(port)] + options)
    }

    /// fake-quic-server.py on `port`, run by the aioquic venv's python.
    static func quic(python: String, port: Int, cert: String, key: String) throws -> FakeServer {
        let script = repoRoot.appendingPathComponent("dev/g1/headless/test/fake-quic-server.py").path
        return try FakeServer(python, [script, String(port), cert, key])
    }

    var log: String { lock.withLock { output } }

    /// Waits, bounded, for `text` to appear in the server's output.
    func waitFor(_ text: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if log.contains(text) { return }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard log.contains(text) else {
            throw CommoError(description: "server never printed \"\(text)\"; its output:\n\(log)")
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    deinit { stop() }
}

/// A free loopback port for `type` (SOCK_STREAM for TCP, SOCK_DGRAM for QUIC).
func freePort(_ type: Int32 = SOCK_STREAM) throws -> Int {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw CommoError(description: "socket failed") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
        }
    }
    guard bound else { throw CommoError(description: "bind failed") }
    return Int(UInt16(bigEndian: addr.sin_port))
}
