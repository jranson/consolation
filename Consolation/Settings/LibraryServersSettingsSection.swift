//
//  LibraryServersSettingsSection.swift
//  Consolation
//
//  Add and remove library servers (Bullpen) by address, or from the ones that answer on this network when the user
//  asks to find them.
//

import MediaSourceKit
import SwiftUI

struct LibraryServersSettingsSection: View {
    @Environment(SourceStore.self) private var sources
    @Environment(SourceRegistry.self) private var registry
    @Environment(LocalNetworkGate.self) private var localNetwork

    @State private var address = ""
    @State private var adding = false
    @State private var searching = false
    @State private var found: [BonjourService] = []
    @State private var message: String?

    var body: some View {
        Section {
            ForEach(sources.bullpens) { config in
                HStack {
                    Label {
                        VStack(alignment: .leading) {
                            Text(config.name)
                            Text(registry.status(of: config.sourceID).libraryText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { sources.remove(config) }
                }
            }
            HStack {
                TextField("Add Bullpen server (name, IP address or URL)", text: $address)
                    .autocorrectionDisabled()
                    .onSubmit { add(address) }
                Button(adding ? "Adding…" : "Add") { add(address) }
                    .disabled(adding || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                // Browsing runs only when the user asks (privacy promise).
                Button(searching ? "Searching…" : "Find Servers on This Network") { search() }
                    .disabled(searching)
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            ForEach(found, id: \.self) { service in
                HStack {
                    Text(service.name)
                    Spacer()
                    Button("Add") { add("\(service.host):\(service.port)") }
                        .disabled(adding)
                }
            }
            PlexServerSettingsRows()
        } header: {
            Text("Library Servers")
        } footer: {
            Text("""
                Bullpen and Plex servers share their recordings, library and live channels. \(AppIdentifier.name) \
                connects only to the servers you add here, on this network. A Plex token is kept in the Keychain; \
                find yours in Plex Web: open an item, then ⋯ › Get Info › View XML.
                """)
        }
        .task { await registry.updateStatuses() }
    }

    private func search() {
        localNetwork.perform {
            searching = true
            message = nil
            Task {
                let services = await BonjourDiscovery.browse(type: BullpenVocabulary.bonjourType)
                let known = Set(sources.bullpens.map(\.sourceID))
                found = services.filter { service in
                    !known.contains(.bullpen(serverID: service.txt["id"] ?? service.name))
                }
                if services.isEmpty {
                    message = String(localized: "No servers found.")
                } else if found.isEmpty {
                    message = String(localized: "All found servers are added.")
                }
                searching = false
            }
        }
    }

    /// Reads the server's catalog and identity before saving it, so only a server that answers is added.
    private func add(_ text: String) {
        guard let base = BullpenClient.baseURL(from: text) else {
            message = String(localized: "That isn't a server address.")
            return
        }
        localNetwork.perform(for: base) {
            adding = true
            message = nil
            Task {
                defer { adding = false }
                do {
                    let config = try await Self.identify(base)
                    sources.addBullpen(config)
                    address = ""
                    found.removeAll { .bullpen(serverID: $0.txt["id"] ?? $0.name) == config.sourceID }
                    await registry.updateStatuses()
                } catch {
                    message = Self.message(for: error)
                }
            }
        }
    }

    @concurrent
    private static func identify(_ base: URL) async throws -> BullpenSourceConfig {
        let client = BullpenClient(baseURL: base, fetcher: RemoteDocumentFetcher())
        let catalog = try await client.catalog()
        guard !catalog.has(BullpenVocabulary.oidcIssuer) else { throw AddError.needsSignIn }
        let server = try await client.server(catalog)
        return BullpenSourceConfig(id: server.sourceID.raw, address: base.absoluteString, name: server.name)
    }

    private nonisolated enum AddError: Error {
        case needsSignIn
    }

    private static func message(for error: any Error) -> String {
        if case AddError.needsSignIn = error {
            return String(localized: "This server requires sign-in, which \(AppIdentifier.name) doesn't support yet.")
        }
        switch error as? RemoteDocumentError {
        case .status(404, _)?, .malformed?:
            return String(localized: "That address isn't a Bullpen server.")
        case .status(let code, let problem)?:
            return problem?.message ?? String(localized: "The server answered HTTP \(code).")
        case .unreachable(let reason)?:
            return reason
        default:
            return error.localizedDescription
        }
    }
}

extension SourceStatus {
    /// How Settings › Library Servers describes a server's status.
    var libraryText: String {
        switch self {
        case .unconfigured: String(localized: "Not set up")
        case .connecting: String(localized: "Connecting…")
        case .ready: String(localized: "Ready")
        case .authRequired: String(localized: "Needs sign-in")
        case .localNetworkDenied: String(localized: "Local Network access is off")
        case .unreachable(let reason): reason.isEmpty ? String(localized: "Can't reach the server") : reason
        case .degraded(let reason): reason
        }
    }
}
