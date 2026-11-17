// CommoClient+Mesh.swift — peers on the local network with no server
// (G3.3), over the shim's mesh calls (commo_shim.h §Mesh networking).
//
// Per interface the mesh listens on the SA group, the chat group and unicast
// UDP, and sends SA and chat broadcasts to their groups; it also accepts
// direct TCP once, on every interface. commo tells peers how to reach this
// client: it sets the contact endpoint of every SA it sends on the mesh to
// "<source address>:4242:tcp".

import CCommoShim
import Foundation

/// The mesh a CommoClient is running.
struct MeshState {
    let config: MeshConfig
    let tcpEndpoint: String
    /// The ids of each interface's commo interfaces, by interface name.
    var interfaces: [String: [String]] = [:]
}

extension CommoClient {
    /// Start the mesh on these interfaces (`NetworkInterfaces.meshCapable()`
    /// in the app). Throws if it already runs, or if TCP or any interface
    /// cannot be opened; what was opened is closed again.
    public func startMesh(_ config: MeshConfig, interfaces names: [String]) throws {
        guard mesh == nil else { throw CommoError(description: "the mesh is already running") }
        let commo = try live()
        try CommoClient.check { err, len in
            mactak_commo_set_mesh_options(commo, Int32(config.ttl), config.loopback ? 1 : 0, 1, err, len)
        }
        let tcp = try CommoClient.endpoint { out, count, err, len in
            mactak_commo_add_tcp_inbound(commo, Int32(config.tcpPort), out, count, err, len)
        }
        mesh = MeshState(config: config, tcpEndpoint: tcp)
        do {
            for name in names { try addMeshInterface(name) }
        } catch {
            stopMesh()
            throw error
        }
    }

    /// Stop the mesh: every mesh interface closes.
    public func stopMesh() {
        guard let running = mesh, let commo = try? live() else { mesh = nil; return }
        for name in running.interfaces.keys { removeMeshInterface(name) }
        remove(running.tcpEndpoint, commo)
        mesh = nil
    }

    /// Open the running mesh on one more interface (one that came up).
    /// Returns its commo interfaces' ids.
    @discardableResult
    public func addMeshInterface(_ name: String) throws -> [String] {
        guard var running = mesh else { throw CommoError(description: "the mesh is not running") }
        guard running.interfaces[name] == nil else { return running.interfaces[name]! }
        let commo = try live()
        let config = running.config
        var opened: [String] = []
        do {
            opened.append(try inbound(commo, name, config.sa.port, [config.sa.address]))
            opened.append(try inbound(commo, name, config.chat.port, [config.chat.address]))
            opened.append(try inbound(commo, name, config.udpPort, []))
            opened.append(try broadcast(commo, name, MACTAK_COMMO_SA, config.sa))
            opened.append(try broadcast(commo, name, MACTAK_COMMO_CHAT, config.chat))
        } catch {
            opened.forEach { remove($0, commo) }
            throw error
        }
        running.interfaces[name] = opened
        mesh = running
        return opened
    }

    /// Close the running mesh on one interface (one that went away).
    public func removeMeshInterface(_ name: String) {
        guard var running = mesh, let ids = running.interfaces.removeValue(forKey: name),
              let commo = try? live() else { return }
        ids.forEach { remove($0, commo) }
        mesh = running
    }

    /// The interfaces the mesh runs on.
    public var meshInterfaces: [String] { mesh.map { $0.interfaces.keys.sorted() } ?? [] }

    private func inbound(_ commo: OpaquePointer, _ name: String, _ port: Int,
                         _ groups: [String]) throws -> String {
        var cStrings = groups.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        return try cStrings.withUnsafeMutableBufferPointer { buf in
            try buf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { list in
                try CommoClient.endpoint { out, count, err, len in
                    mactak_commo_add_inbound(commo, name, Int32(port), list.baseAddress, list.count,
                                             out, count, err, len)
                }
            }
        }
    }

    private func broadcast(_ commo: OpaquePointer, _ name: String, _ kind: Int,
                           _ group: MeshConfig.Group) throws -> String {
        try CommoClient.endpoint { out, count, err, len in
            mactak_commo_add_broadcast(commo, name, Int32(kind), group.address, Int32(group.port),
                                       out, count, err, len)
        }
    }

    private func remove(_ id: String, _ commo: OpaquePointer) {
        do {
            try CommoClient.check { err, len in mactak_commo_remove_mesh(commo, id, err, len) }
        } catch {
            sink.yield(.log(level: .warning, message: "mesh interface \(id) not removed: \(error)"))
        }
    }

    /// Run a shim call that writes an interface id; returns the id.
    static func endpoint(
        _ body: (UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws -> String {
        var endpoint = [CChar](repeating: 0, count: 512)
        let count = endpoint.count
        try endpoint.withUnsafeMutableBufferPointer { out in
            try check { err, len in body(out.baseAddress!, count, err, len) }
        }
        return String(cString: endpoint)
    }
}
