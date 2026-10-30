import Foundation
import Synchronization

/// Where `CredentialStore` keeps secrets: the Keychain in the app (`KeychainCredentialBacking`), memory in tests
/// (`InMemoryCredentialBacking`). Calls may block (the macOS file-based keychain can prompt), so `CredentialStore`
/// makes them off the caller's actor.
public nonisolated protocol CredentialBacking: Sendable {
    /// Replaces any existing secret for the account, synchronizable or not.
    func setSecret(_ secret: Data, service: String, account: String, synchronizable: Bool) throws
    func secret(service: String, account: String) throws -> Data?
    /// Removes the secret; succeeds when there is none.
    func removeSecret(service: String, account: String) throws
    /// Every account stored under the service.
    func accounts(service: String) throws -> [String]
}

/// Secrets for configured sources: Plex tokens, Jellyfin and Emby tokens, SMB, WebDAV and HTTP passwords, the user's
/// TMDB key.
///
/// One generic-password item per secret, under an injected service name (each app passes its own) and the account
/// `"<SourceID.raw>:<label>"`, for example `plex:abc123:token`. Secrets are this-device-only unless the caller
/// asks for iCloud Keychain sync, which is opt-in and off by default. Never log a secret or put one in a URL.
public nonisolated struct CredentialStore: Sendable {
    public let service: String
    private let backing: any CredentialBacking

    /// - Parameters:
    ///   - service: the Keychain service, injected by the app.
    ///   - backing: `KeychainCredentialBacking()` in the app; `InMemoryCredentialBacking()` in every test.
    public init(service: String, backing: any CredentialBacking) {
        self.service = service
        self.backing = backing
    }

    /// The Keychain account for a source's secret: `"<SourceID.raw>:<label>"`.
    public static func account(for source: SourceID, label: String) -> String {
        "\(source.raw):\(label)"
    }

    /// Stores a secret, replacing any previous one for the same source and label.
    /// - Parameter synchronizable: iCloud Keychain sync; only when the user turned it on.
    @concurrent
    public func set(_ secret: Data, source: SourceID, label: String, synchronizable: Bool = false) async throws {
        try backing.setSecret(secret, service: service, account: Self.account(for: source, label: label),
                              synchronizable: synchronizable)
    }

    @concurrent
    public func secret(source: SourceID, label: String) async throws -> Data? {
        try backing.secret(service: service, account: Self.account(for: source, label: label))
    }

    @concurrent
    public func remove(source: SourceID, label: String) async throws {
        try backing.removeSecret(service: service, account: Self.account(for: source, label: label))
    }

    /// Removes every secret of a source, as removing the source must.
    @concurrent
    public func removeAll(for source: SourceID) async throws {
        let prefix = source.raw + ":"
        for account in try backing.accounts(service: service) where account.hasPrefix(prefix) {
            try backing.removeSecret(service: service, account: account)
        }
    }
}

/// Keeps secrets in memory, for tests and previews. Tests never touch the Keychain.
public nonisolated final class InMemoryCredentialBacking: CredentialBacking {
    private struct Entry {
        var secret: Data
        var synchronizable: Bool
    }

    private let entries = Mutex<[String: [String: Entry]]>([:])

    public init() {}

    public func setSecret(_ secret: Data, service: String, account: String, synchronizable: Bool) {
        entries.withLock { $0[service, default: [:]][account] = Entry(secret: secret, synchronizable: synchronizable) }
    }

    public func secret(service: String, account: String) -> Data? {
        entries.withLock { $0[service]?[account]?.secret }
    }

    public func removeSecret(service: String, account: String) {
        entries.withLock { _ = $0[service]?.removeValue(forKey: account) }
    }

    public func accounts(service: String) -> [String] {
        entries.withLock { ($0[service] ?? [:]).keys.sorted() }
    }

    /// Whether the stored secret asked for iCloud Keychain sync; nil when there is none.
    public func isSynchronizable(service: String, account: String) -> Bool? {
        entries.withLock { $0[service]?[account]?.synchronizable }
    }
}
