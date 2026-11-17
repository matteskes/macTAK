// MeshNetwork.swift — the app's mesh: peers on the local network with no
// server (G3.3b).
//
// It runs the mesh on the app's one CommoClient (ServerConnections hands it
// over when commo starts) on every interface that can carry it, and follows
// interfaces as they come and go. Like ATAK (enableNonStreamingConnections),
// it is on unless the user turns it off. Its settings persist in the same
// store as the server list.

import Combine
import Foundation

/// One network interface's part in the mesh, as the app shows it.
public enum MeshInterfaceStatus: Equatable, Sendable {
    case starting
    case up
    case down
    case failed(String)
}

@MainActor
public final class MeshNetwork: ObservableObject {
    @Published public private(set) var enabled: Bool
    @Published public private(set) var config: MeshConfig
    /// The interfaces the mesh runs on, by name.
    @Published public private(set) var interfaces: [String: MeshInterfaceStatus] = [:]
    /// Direct TCP in: `.starting` until commo has its port, which another
    /// TAK app on this Mac may hold (commo keeps retrying).
    @Published public private(set) var directTCP: MeshInterfaceStatus?
    /// Why the mesh couldn't start.
    @Published public private(set) var problem: String?

    private let settings: SettingsStore
    private let available: () -> [String]
    private var client: CommoClient?
    private var running = false
    /// Which interface each commo interface id belongs to.
    private var owners: [String: String] = [:]
    /// Ids commo reported up, by id: an interface can come up before its
    /// add call returns.
    private var upIds: Set<String> = []
    /// Changes queue here, so a refresh never interleaves with a restart.
    private var work: Task<Void, Never>?

    private static let enabledKey = "mactak.mesh.enabled", configKey = "mactak.mesh.config"

    /// `available` lists the interfaces to run on; the app's is
    /// `NetworkInterfaces.meshCapable`.
    public init(settings: SettingsStore,
                available: @escaping () -> [String] = NetworkInterfaces.meshCapable) {
        self.settings = settings
        self.available = available
        enabled = settings.string(forKey: Self.enabledKey).map { $0 == "true" } ?? true
        config = settings.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(MeshConfig.self, from: $0) } ?? .atak
    }

    // MARK: - lifecycle (ServerConnections calls these)

    func attach(_ client: CommoClient) {
        self.client = client
        if enabled { enqueue { await self.startMesh() } }
    }

    func detach() async {
        let pending = work
        client = nil
        await pending?.value
        clear()
    }

    // MARK: - what the user changes

    public func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        settings.set(enabled ? "true" : "false", forKey: Self.enabledKey)
        enqueue { enabled ? await self.startMesh() : await self.stopMesh() }
    }

    /// New ports, groups or TTL: the mesh restarts with them.
    public func setConfig(_ config: MeshConfig) {
        guard config != self.config else { return }
        self.config = config
        settings.set(try? JSONEncoder().encode(config), forKey: Self.configKey)
        guard enabled else { return }
        enqueue {
            await self.stopMesh()
            await self.startMesh()
        }
    }

    /// Bring the mesh's interfaces in line with the ones available now
    /// (the app calls this when the system's interfaces change).
    public func refresh() {
        guard enabled else { return }
        enqueue { await self.syncInterfaces() }
    }

    /// Wait for queued changes (tests).
    func settle() async { await work?.value }

    // MARK: - commo's events (ServerConnections forwards them)

    func handle(_ event: CommoEvent) {
        switch event {
        case let .interfaceUp(id):
            upIds.insert(id)
            if id == tcpId { directTCP = .up }
            if let name = owners[id] { interfaces[name] = .up }
        case let .interfaceDown(id):
            upIds.remove(id)
            if id == tcpId, directTCP != nil { directTCP = .down }
            if let name = owners[id], !owned(by: name).contains(where: upIds.contains) {
                interfaces[name] = .down
            }
        case let .interfaceError(id, code):
            if id == tcpId, directTCP != nil { directTCP = .failed(ServerConnections.describe(code)) }
            if let name = owners[id] { interfaces[name] = .failed(ServerConnections.describe(code)) }
        default:
            break
        }
    }

    // MARK: - the work

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            await job()
        }
    }

    private var tcpId: String { "tcp:\(config.tcpPort)" }

    private func startMesh() async {
        guard let client, enabled, !running else { return }
        do {
            try await client.startMesh(config, interfaces: [])
        } catch {
            problem = "\(error)"
            return
        }
        running = true
        problem = nil
        directTCP = upIds.contains(tcpId) ? .up : .starting
        await syncInterfaces()
    }

    private func stopMesh() async {
        await client?.stopMesh()
        clear()
    }

    private func syncInterfaces() async {
        guard let client, running else { return }
        let wanted = Set(available())
        for name in interfaces.keys where !wanted.contains(name) {
            await client.removeMeshInterface(name)
            for id in owned(by: name) { owners[id] = nil }
            interfaces[name] = nil
        }
        for name in wanted.sorted() where interfaces[name] == nil {
            interfaces[name] = .starting
            do {
                let ids = try await client.addMeshInterface(name)
                for id in ids { owners[id] = name }
                if ids.contains(where: upIds.contains) { interfaces[name] = .up }
            } catch {
                interfaces[name] = .failed("\(error)")
            }
        }
    }

    private func owned(by name: String) -> [String] {
        owners.filter { $0.value == name }.map(\.key)
    }

    private func clear() {
        running = false
        directTCP = nil
        interfaces.removeAll()
        owners.removeAll()
        upIds.removeAll()
        problem = nil
    }
}
