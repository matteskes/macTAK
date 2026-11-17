// MeshConfig.swift — where a mesh (serverless) TAK client listens and
// sends (G3.3).
//
// ATAK 5.5's defaults (CotService._addDefaultInputs, ChatManagerMapComponent,
// network_connections_preferences.xml): SA in and out on multicast
// 239.2.3.1:6969, chat on 224.10.10.1:17012, unicast UDP and direct TCP on
// port 4242, multicast TTL 64, multicast loopback off.

import Foundation

public struct MeshConfig: Codable, Equatable, Sendable {
    /// A multicast group and the UDP port it is sent to.
    public struct Group: Codable, Equatable, Sendable {
        public var address: String
        public var port: Int
        public init(address: String, port: Int) {
            self.address = address; self.port = port
        }
    }

    public var sa: Group
    public var chat: Group
    /// Unicast UDP in: a peer's broadcast sent straight to this host.
    public var udpPort: Int
    /// Direct TCP in: how a peer sends to this client alone. Peers can only
    /// reach 4242: commo writes every outgoing SA's contact endpoint itself,
    /// "<source address>:4242:tcp" on the mesh with the port fixed
    /// (cotmessage.cpp, endpointForType), whatever the event said. Another
    /// port is for a second client on one host, which then gets no direct
    /// messages.
    public var tcpPort: Int
    public var ttl: Int
    /// This host's own multicast comes back to it. Off in ATAK; two clients
    /// on one Mac need it on.
    public var loopback: Bool

    public init(sa: Group, chat: Group, udpPort: Int, tcpPort: Int, ttl: Int, loopback: Bool) {
        self.sa = sa; self.chat = chat
        self.udpPort = udpPort; self.tcpPort = tcpPort
        self.ttl = ttl; self.loopback = loopback
    }

    public static let atak = MeshConfig(
        sa: Group(address: "239.2.3.1", port: 6969),
        chat: Group(address: "224.10.10.1", port: 17012),
        udpPort: 4242, tcpPort: 4242, ttl: 64, loopback: false)
}
