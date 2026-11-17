// MeshView.swift — the sidebar's Mesh section (G3.3b).
//
// Peers on the local network with no server, as ATAK has them by default:
// an on/off switch, a row per network interface with its status, direct
// messages' TCP port, and a sheet for the ports, groups and TTL. The work
// happens in MeshNetwork (MacTAKComms), which the tests drive.

import MacTAKComms
import SwiftUI

struct MeshSection: View {
    @EnvironmentObject private var mesh: MeshNetwork
    @State private var editing = false

    var body: some View {
        Section {
            if !mesh.enabled {
                Text("Off").foregroundStyle(.secondary)
            } else if let problem = mesh.problem {
                Text(problem).foregroundStyle(.red).lineLimit(3)
            } else {
                if mesh.interfaces.isEmpty {
                    Text("No network").foregroundStyle(.secondary)
                }
                ForEach(mesh.interfaces.keys.sorted(), id: \.self) { name in
                    StatusRow(title: name, detail: groups, status: mesh.interfaces[name] ?? .starting)
                }
                if let tcp = mesh.directTCP {
                    StatusRow(title: "Direct messages", detail: tcpDetail(tcp), status: tcp)
                }
            }
        } header: {
            HStack {
                Text("Mesh")
                Spacer()
                Button {
                    editing = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Mesh ports and groups")
                Toggle("", isOn: Binding(get: { mesh.enabled }, set: { mesh.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Peers on the local network, with no server")
            }
        }
        .sheet(isPresented: $editing) { MeshSettingsSheet(config: mesh.config) }
    }

    private var groups: String {
        "SA \(mesh.config.sa.address):\(mesh.config.sa.port) · chat \(mesh.config.chat.address):\(mesh.config.chat.port)"
    }

    private func tcpDetail(_ status: MeshInterfaceStatus) -> String {
        switch status {
        case .starting: "TCP \(mesh.config.tcpPort) · waiting for the port (another TAK app may hold it)"
        default: "TCP \(mesh.config.tcpPort)"
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let status: MeshInterfaceStatus

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(title)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var text: String {
        switch status {
        case .starting, .up: detail
        case .down: "down"
        case .failed(let why): why
        }
    }

    private var color: Color {
        switch status {
        case .starting: .yellow
        case .up: .green
        case .down: .gray
        case .failed: .red
        }
    }
}

/// ATAK's mesh settings: where SA and chat go, direct messages' port, the
/// multicast TTL, and loopback (on only to run two copies on one Mac).
private struct MeshSettingsSheet: View {
    @EnvironmentObject private var mesh: MeshNetwork
    @Environment(\.dismiss) private var dismiss
    @State var config: MeshConfig

    var body: some View {
        Form {
            Section("Situational awareness") {
                TextField("Group", text: $config.sa.address)
                TextField("Port", value: $config.sa.port, format: .number.grouping(.never))
            }
            Section("Chat") {
                TextField("Group", text: $config.chat.address)
                TextField("Port", value: $config.chat.port, format: .number.grouping(.never))
            }
            Section("This Mac") {
                TextField("Direct messages (TCP)", value: $config.tcpPort, format: .number.grouping(.never))
                TextField("Unicast UDP", value: $config.udpPort, format: .number.grouping(.never))
                TextField("Multicast TTL", value: $config.ttl, format: .number)
                Toggle("Hear this Mac's own multicast (to run two copies on one Mac)", isOn: $config.loopback)
            }
            HStack {
                Button("ATAK Defaults") { config = .atak }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    mesh.setConfig(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var valid: Bool {
        let ports = [config.sa.port, config.chat.port, config.tcpPort, config.udpPort]
        return ports.allSatisfy { (1...65535).contains($0) } && (1...255).contains(config.ttl)
    }
}
