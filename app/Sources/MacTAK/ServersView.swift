// ServersView.swift — the sidebar's Servers section (G3.2d).
//
// A row per server with its status and an on/off switch; a menu to quick
// connect (G3.2e), add a server by hand or import an ATAK data package; a
// sheet to enroll for a client certificate, or to give a hand-added server
// its certificates. The
// work happens in ServerConnections (MacTAKComms), which the tests drive.

import MacTAKComms
import SwiftUI
import UniformTypeIdentifiers

struct ServersSection: View {
    @EnvironmentObject private var connections: ServerConnections
    @State private var adding = false
    @State private var quickConnecting = false
    @State private var importing = false
    @State private var enrolling: ServerConfig?
    @State private var certifying: ServerConfig?
    @State private var problem: String?

    var body: some View {
        Section {
            if connections.servers.isEmpty {
                Text("No servers").foregroundStyle(.secondary)
            }
            ForEach(connections.servers) { server in
                ServerRow(server: server, status: connections.status[server.id] ?? .off,
                          enroll: { enrolling = server }, certify: { certifying = server })
            }
        } header: {
            HStack {
                Text("Servers")
                Spacer()
                Menu {
                    Button("Quick Connect…") { quickConnecting = true }
                    Button("Add Server…") { adding = true }
                    Button("Import Data Package…") { importing = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a TAK server")
            }
        }
        .sheet(isPresented: $adding) { AddServerSheet() }
        .sheet(isPresented: $quickConnecting) { QuickConnectSheet() }
        .sheet(item: $enrolling) { EnrollSheet(server: $0) }
        .sheet(item: $certifying) { CertificatesSheet(server: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try connections.importPackage(at: url)
            } catch {
                problem = "\(error)"
            }
        }
        .alert("Couldn't import the data package", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }
}

private struct ServerRow: View {
    @EnvironmentObject private var connections: ServerConnections
    let server: ServerConfig
    let status: ServerStatus
    let enroll: () -> Void
    let certify: () -> Void

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(server.description)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if needsCertificate {
                Button(server.enrollForCertificate ? "Enroll…" : "Certificates…",
                       action: server.enrollForCertificate ? enroll : certify)
                    .controlSize(.small)
            }
            Toggle("", isOn: Binding(get: { server.enabled },
                                     set: { connections.setEnabled(server.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .contextMenu {
            Button("Enroll for a Certificate…", action: enroll).disabled(!server.canEnroll)
            Button("Certificates…", action: certify)
            Divider()
            Button("Remove", role: .destructive) { connections.remove(server.id) }
        }
    }

    private var needsCertificate: Bool { server.address.proto != .tcp && server.identity == nil }

    private var detail: String {
        switch status {
        case .off: "\(server.address) · off"
        case .connecting: "\(server.address) · connecting"
        case .connected: "\(server.address) · connected"
        case .failed(let why): why
        }
    }

    private var color: Color {
        switch status {
        case .off: .gray
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        }
    }
}

/// A server by hand: its name, address and transport. SSL and QUIC servers
/// then need certificates, imported or enrolled for.
private struct AddServerSheet: View {
    @EnvironmentObject private var connections: ServerConnections
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = 8089
    @State private var proto = ConnectString.Proto.ssl
    @State private var enroll = true
    @State private var useTrust = true

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Address", text: $host)
            TextField("Port", value: $port, format: .number.grouping(.never))
            Picker("Transport", selection: $proto) {
                Text("TLS").tag(ConnectString.Proto.ssl)
                Text("QUIC").tag(ConnectString.Proto.quic)
                Text("TCP (no encryption)").tag(ConnectString.Proto.tcp)
            }
            if proto != .tcp {
                Toggle("Enroll for a client certificate with a username and password", isOn: $enroll)
                if enroll {
                    Toggle(isOn: $useTrust) {
                        Text("Enroll with preconfigured trust")
                        Text("Enrollment requires the server to match the truststore you import. "
                             + "Turn off to trust widely trusted public CAs.")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    let address = ConnectString(host: host, port: port, proto: proto)
                    connections.add(ServerConfig(description: name.isEmpty ? address.description : name,
                                                 address: address, enrollForCertificate: proto != .tcp && enroll,
                                                 enrollUseTrust: useTrust))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || !(1...65535).contains(port))
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// Enrollment: the server's username and password (G3.2c).
private struct EnrollSheet: View {
    @EnvironmentObject private var connections: ServerConnections
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    @State private var user = ""
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Form {
            Text("Enroll with \(server.description) (\(server.address.host)) for a client certificate.")
            if !server.enrollUseTrust {
                Text("The server must have a certificate from a public CA for its address.")
                    .foregroundStyle(.secondary)
            } else if server.truststore == nil {
                Text("Import the server's truststore first (Certificates…): enrollment trusts only the server's own CA.")
                    .foregroundStyle(.secondary)
            }
            TextField("Username", text: $user)
            SecureField("Password", text: $password)
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Enroll") {
                    working = true
                    problem = nil
                    Task {
                        do {
                            try await connections.enroll(server.id, user: user, password: password)
                            dismiss()
                        } catch {
                            problem = "\(error)"
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(user.isEmpty || password.isEmpty || working || !server.canEnroll)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

/// ATAK's TAK Server Quick Connect (G3.2e): an address, a username and a
/// password. The server is added and enrolled against the public CAs; one
/// that fails to enroll isn't kept.
private struct QuickConnectSheet: View {
    @EnvironmentObject private var connections: ServerConnections
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Form {
            Text("TAK Server Quick Connect").font(.headline)
            Text("For a server with a certificate from a public CA. The port defaults to \(ConnectString.quickConnectPort).")
                .foregroundStyle(.secondary)
            TextField("Address", text: $address, prompt: Text("tak.example.org"))
            TextField("Username", text: $user)
            SecureField("Password", text: $password)
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(working)
                Button("Connect") {
                    working = true
                    problem = nil
                    Task {
                        do {
                            try await connections.quickConnect(address: address, user: user, password: password)
                            dismiss()
                        } catch {
                            problem = "\(error)"
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty
                          || password.isEmpty || working)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

/// A truststore and, unless the server enrolls, a client certificate, as
/// .p12 files with their passwords.
private struct CertificatesSheet: View {
    @EnvironmentObject private var connections: ServerConnections
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    @State private var truststore: URL?
    @State private var truststorePassword = ""
    @State private var identity: URL?
    @State private var identityPassword = ""
    @State private var picking: Pick?
    @State private var problem: String?

    private enum Pick: Identifiable { case truststore, identity; var id: Self { self } }

    var body: some View {
        Form {
            LabeledContent("Truststore") {
                Button(truststore?.lastPathComponent ?? "Choose .p12…") { picking = .truststore }
            }
            SecureField("Truststore password", text: $truststorePassword)
            LabeledContent("Client certificate") {
                Button(identity?.lastPathComponent ?? "Choose .p12…") { picking = .identity }
            }
            SecureField("Client certificate password", text: $identityPassword)
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") {
                    do {
                        try connections.importCertificates(
                            for: server.id,
                            identity: try identity.map { (try Self.read($0), identityPassword) },
                            truststore: try truststore.map { (try Self.read($0), truststorePassword) })
                        dismiss()
                    } catch {
                        problem = "\(error)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(truststore == nil && identity == nil)
            }
        }
        .padding()
        .frame(width: 420)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { result in
            guard let url = try? result.get() else { return }
            if picking == .truststore { truststore = url } else { identity = url }
        }
    }

    private static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}
