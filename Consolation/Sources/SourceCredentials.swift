//
//  SourceCredentials.swift
//  Consolation
//
//  Secrets for added sources (a Plex token), in the Keychain under the app's service name, one item per source and
//  label. Never in a configuration document, a URL or a log. Removing a source removes its secrets.
//

import Foundation
import MediaSourceKit

nonisolated struct SourceCredentials: Sendable {
    static let tokenLabel = "token"

    let store: CredentialStore
    private let backing: any CredentialBacking

    init(backing: any CredentialBacking = KeychainCredentialBacking()) {
        self.backing = backing
        store = CredentialStore(service: AppIdentifier.scoped("source"), backing: backing)
    }

    /// The source's token, read at once (sources are built synchronously; a Keychain read is small).
    func token(for source: SourceID) -> String? {
        let account = CredentialStore.account(for: source, label: Self.tokenLabel)
        guard let data = try? backing.secret(service: store.service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String, for source: SourceID) async throws {
        try await store.set(Data(token.utf8), source: source, label: Self.tokenLabel)
    }

    func removeAll(for source: SourceID) async {
        try? await store.removeAll(for: source)
    }

    /// The identifier Plex servers know this install by, made once.
    static var plexClientIdentifier: String {
        let key = AppIdentifier.scoped("plex.clientIdentifier")
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    static var plexClient: PlexClient.Client {
        PlexClient.Client(product: AppIdentifier.name, version: BuildInfo.version, identifier: plexClientIdentifier)
    }
}
