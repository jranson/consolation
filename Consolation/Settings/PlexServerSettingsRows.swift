//
//  PlexServerSettingsRows.swift
//  Consolation
//
//  The Plex rows of Settings › Library Servers: the servers added, and adding one by address with a token (kept in
//  the Keychain) or none, when the server allows this device's network. LAN only: nothing goes to plex.tv.
//

import MediaSourceKit
import SwiftUI

struct PlexServerSettingsRows: View {
    @Environment(SourceStore.self) private var sources
    @Environment(SourceRegistry.self) private var registry
    @Environment(LocalNetworkGate.self) private var localNetwork

    @State private var address = ""
    @State private var token = ""
    @State private var adding = false
    @State private var searching = false
    @State private var found: [BonjourService] = []
    @State private var message: String?

    var body: some View {
        ForEach(sources.plexServers) { config in
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(config.name)
                        Text(registry.status(of: config.sourceID).libraryText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "play.square.stack")
                }
                Spacer()
                Button("Remove", role: .destructive) { remove(config) }
            }
        }
        TextField("Add Plex server (IP address or name)", text: $address)
            .autocorrectionDisabled()
            .accessibilityIdentifier("settings.plex.address")
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        HStack {
            SecureField("Plex token (empty if this network is allowed without one)", text: $token)
                .onSubmit(add)
                .accessibilityIdentifier("settings.plex.token")
            Button(adding ? "Adding…" : "Add") { add() }
                .disabled(adding || address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack {
            // Browsing runs only when the user asks (privacy promise).
            Button(searching ? "Searching…" : "Find Plex Servers on This Network") { search() }
                .disabled(searching)
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        // Bonjour resolves one of the server's addresses, which may be its Wi-Fi rather than its Ethernet: the row
        // shows it, and "Use" only fills the address field, which stays editable.
        ForEach(found, id: \.self) { service in
            HStack {
                Text("\(service.name) · \(service.host)")
                Spacer()
                Button("Use") { address = "\(service.host):\(service.port)" }
            }
        }
    }

    private func search() {
        localNetwork.perform {
            searching = true
            message = nil
            Task {
                found = await BonjourDiscovery.browse(type: PlexClient.bonjourType)
                if found.isEmpty { message = String(localized: "No Plex servers found.") }
                searching = false
            }
        }
    }

    private func add() {
        guard let base = PlexClient.baseURL(from: address) else {
            message = String(localized: "That isn't a server address.")
            return
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        localNetwork.perform(for: base) {
            adding = true
            message = nil
            Task {
                defer { adding = false }
                do {
                    let config = try await Self.identify(base, token: token.isEmpty ? nil : token)
                    if config.usesToken { try await registry.credentials.setToken(token, for: config.sourceID) }
                    sources.addPlex(config)
                    registry.rebuildLibrary(config.sourceID)
                    address = ""
                    self.token = ""
                    found = []
                    await registry.updateStatuses()
                } catch {
                    message = Self.message(for: error, hadToken: !token.isEmpty)
                }
            }
        }
    }

    private func remove(_ config: PlexSourceConfig) {
        sources.remove(config)
        let credentials = registry.credentials
        Task { await credentials.removeAll(for: config.sourceID) }
    }

    /// The server's identity (no token needed), then its name, which needs the token (or an allowed network).
    @concurrent
    private static func identify(_ base: URL, token: String?) async throws -> PlexSourceConfig {
        let client = PlexClient(baseURL: base, token: token, client: SourceCredentials.plexClient)
        guard let machine = try await client.identity().machineIdentifier else {
            throw RemoteDocumentError.malformed("identity")
        }
        let root = try await client.root()
        return PlexSourceConfig(id: SourceID.plex(machineIdentifier: machine).raw, address: base.absoluteString,
                                name: root.friendlyName ?? "Plex", usesToken: token != nil)
    }

    private static func message(for error: any Error, hadToken: Bool) -> String {
        if let keychain = error as? KeychainError {
            return String(localized: "The token couldn't be saved in the Keychain (error \(keychain.status)).")
        }
        switch error as? RemoteDocumentError {
        case .status(401, _)?, .status(403, _)?:
            return hadToken ? String(localized: "The server didn't accept that token.")
                : String(localized: "This server needs a token.")
        case .status(404, _)?, .malformed?:
            return String(localized: "That address isn't a Plex server.")
        case .status(let code, _)?:
            return String(localized: "The server answered HTTP \(code).")
        case .unreachable(let reason)?:
            return reason
        default:
            return error.localizedDescription
        }
    }
}
