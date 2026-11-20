// GeocoderSettings.swift — the Settings window's Address Lookup pane: ATAK
// 5.5's geocoder picker (GeocoderPreferenceFragment) and its Nominatim
// servers, imported from ATAK's <NominatimProperties> files. ADDR entry
// (My Details) uses the one selected.

import MacTAKComms
import SwiftUI
import UniformTypeIdentifiers

struct GeocoderSettings: View {
    @EnvironmentObject private var geocoders: GeocoderRegistry
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            Picker("Look up addresses with", selection: Binding(get: { geocoders.selectedID },
                                                                set: { geocoders.select($0) })) {
                ForEach(geocoders.geocoders, id: \.id) { Text($0.title).tag($0.id) }
            }
            Text("The address you type, or the position you look up an address for, is sent to this service.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Nominatim servers") {
                if geocoders.nominatimServers.isEmpty {
                    Text("None. Import an ATAK geocoder file (<NominatimProperties>) to add one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(geocoders.nominatimServers, id: \.url) { server in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text(server.url).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { geocoders.remove(server.url) }
                            .controlSize(.small)
                    }
                }
                Button("Import Geocoder File…") { importing = true }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let count = try geocoders.importProperties(try Data(contentsOf: url))
                message = "Imported \(count) server\(count == 1 ? "" : "s") from \(url.lastPathComponent)."
            } catch {
                message = "Couldn't import: \(error)"
            }
        }
    }
}
