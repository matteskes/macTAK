// ExitScript.swift — what one instance does in the G3 exit run, and what it
// reports (dev/g3/NOTES.md §The G3 exit, PR b).
//
// The app reads a script with `--exit-script FILE`; without the flag none of
// this runs. The script names the server, the instance's callsign and place,
// the peer it waits for, the point it drops and the chats it sends. The
// password is never in the file: it names the environment variable that
// holds it. ExitRun carries the script out on a ServerConnections and
// writes an ExitReport, which dev/g3/test/exit-run.sh checks.

import Foundation
import MacTAKCot

public struct ExitScript: Codable, Sendable, Equatable {
    public struct Server: Codable, Sendable, Equatable {
        /// What the server list calls it; a run first removes every server
        /// of this name from the instance's list.
        public var description: String
        public var host: String
        /// The SSL CoT port.
        public var port: Int
        public var enrollmentPort: Int
        /// The server's CA as PKCS#12, as ATAK imports a truststore.
        public var truststore: String
        public var truststorePassword: String
        public var user: String
        /// The environment variable that holds the user's password.
        public var passwordVariable: String
    }

    public struct Place: Codable, Sendable, Equatable {
        public var lat: Double
        public var lon: Double
        public var point: CotPoint { CotPoint(lat: lat, lon: lon) }
    }

    public var server: Server
    public var callsign: String
    /// Where this instance says it is (a placed position).
    public var place: Place
    /// ATAK's Constant reporting strategy, both streams every this many
    /// seconds. ATAK's default, Dynamic, reports a still client to the
    /// server every 180 s, so a self-SA sent before the peer was registered
    /// would leave the peer waiting that long (OpenTAKServer forwards only
    /// to the clients registered when it arrives).
    public var reportEvery: Int
    /// The callsign of the other instance.
    public var peer: String
    /// Where this instance drops its Spot Map point, which it then sends,
    /// and its colour by 5.5's abbreviation ("R" is red).
    public var point: Place
    public var pointColor: String
    /// What it sends to All Chat Rooms, and to the peer one-to-one.
    public var allChatRooms: String
    public var direct: String
    /// How long each wait may take, in seconds.
    public var timeout: Double
    /// Where the report goes.
    public var report: String
    /// Only remove the exit servers and their certificates, then report.
    public var cleanupOnly: Bool

    public init(server: Server, callsign: String, place: Place, reportEvery: Int = 3, peer: String, point: Place,
                pointColor: String, allChatRooms: String, direct: String,
                timeout: Double, report: String, cleanupOnly: Bool = false) {
        self.server = server
        self.callsign = callsign
        self.place = place
        self.reportEvery = reportEvery
        self.peer = peer
        self.point = point
        self.pointColor = pointColor
        self.allChatRooms = allChatRooms
        self.direct = direct
        self.timeout = timeout
        self.report = report
        self.cleanupOnly = cleanupOnly
    }

    public static func load(_ url: URL) throws -> ExitScript {
        try JSONDecoder().decode(ExitScript.self, from: Data(contentsOf: url))
    }
}

/// What one instance did and saw. `passed` is its own verdict; the exit
/// run checks the parts itself too.
public struct ExitReport: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable {
        public var name: String
        /// Seconds since the run started.
        public var at: Double
    }

    public struct Peer: Codable, Sendable, Equatable {
        public var uid: String
        public var callsign: String
        /// Whether it was heard through the server, and through the mesh.
        public var viaServer: Bool
        public var viaMesh: Bool
    }

    public struct Marker: Codable, Sendable, Equatable {
        public var uid: String
        public var label: String
        public var type: String
        public var lat: Double
        public var lon: Double
        /// The uid of whoever placed it (its creator, else its link).
        public var author: String?
    }

    public struct Chat: Codable, Sendable, Equatable {
        public var room: String
        public var sender: String
        public var text: String
    }

    public struct Receipts: Codable, Sendable, Equatable {
        public var delivered: Bool
        public var read: Bool
    }

    public var callsign: String = ""
    public var uid: String = ""
    public var passed = false
    public var failure: String?
    public var steps: [Step] = []
    /// The Keychain items the enrollment made (SHA-256 fingerprints).
    public var identity: String?
    public var truststore: String?
    public var peer: Peer?
    /// The point this instance dropped, and the peer's point as it arrived.
    public var dropped: Marker?
    public var peerMarker: Marker?
    /// The peer's chats that arrived, and the receipts for this one's direct message.
    public var chats: [Chat] = []
    public var receipts: Receipts?
    /// What cleanup removed.
    public var removed: [String] = []

    public init() {}

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
