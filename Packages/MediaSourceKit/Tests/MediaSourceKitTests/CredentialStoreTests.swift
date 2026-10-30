import Foundation
import Security
import Testing
@testable import MediaSourceKit

/// `CredentialStore` with the in-memory backing (tests never touch the Keychain), and the Keychain queries checked
/// as dictionaries without calling `SecItem`.
@Suite("CredentialStore")
struct CredentialStoreTests {
    static let service = "org.example.tests.source"
    static let plex = SourceID(raw: "plex:0f0e0d0c")
    static let jellyfin = SourceID(raw: "jf:a1b2")

    @Test func secretsAreKeyedBySourceAndLabel() async throws {
        let backing = InMemoryCredentialBacking()
        let store = CredentialStore(service: Self.service, backing: backing)
        #expect(CredentialStore.account(for: Self.plex, label: "token") == "plex:0f0e0d0c:token")

        try await store.set(Data("one".utf8), source: Self.plex, label: "token")
        #expect(try await store.secret(source: Self.plex, label: "token") == Data("one".utf8))
        #expect(backing.accounts(service: Self.service) == ["plex:0f0e0d0c:token"])
        #expect(backing.isSynchronizable(service: Self.service, account: "plex:0f0e0d0c:token") == false)

        try await store.set(Data("two".utf8), source: Self.plex, label: "token", synchronizable: true)
        #expect(try await store.secret(source: Self.plex, label: "token") == Data("two".utf8))
        #expect(backing.isSynchronizable(service: Self.service, account: "plex:0f0e0d0c:token") == true)
        #expect(try await store.secret(source: Self.plex, label: "password") == nil)

        try await store.remove(source: Self.plex, label: "token")
        #expect(try await store.secret(source: Self.plex, label: "token") == nil)
        try await store.remove(source: Self.plex, label: "token")
    }

    @Test func removingASourceRemovesOnlyItsSecrets() async throws {
        let backing = InMemoryCredentialBacking()
        let store = CredentialStore(service: Self.service, backing: backing)
        let other = CredentialStore(service: "org.example.other", backing: backing)
        try await store.set(Data("t".utf8), source: Self.plex, label: "token")
        try await store.set(Data("k".utf8), source: Self.plex, label: "jwt-key")
        try await store.set(Data("j".utf8), source: Self.jellyfin, label: "token")
        // A source whose ID merely starts with the same text keeps its secrets.
        try await store.set(Data("x".utf8), source: SourceID(raw: "plex:0f0e0d0c9"), label: "token")
        try await other.set(Data("o".utf8), source: Self.plex, label: "token")

        try await store.removeAll(for: Self.plex)
        #expect(backing.accounts(service: Self.service) == ["jf:a1b2:token", "plex:0f0e0d0c9:token"])
        #expect(try await other.secret(source: Self.plex, label: "token") == Data("o".utf8))
    }

    @Test func keychainItemsAreGenericPasswordsOutsideTheDataProtectionKeychain() throws {
        let local = KeychainCredentialBacking.addQuery(service: Self.service, account: "plex:1:token",
                                                       secret: Data("s".utf8), synchronizable: false)
        #expect(local[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(local[kSecAttrService as String] as? String == Self.service)
        #expect(local[kSecAttrAccount as String] as? String == "plex:1:token")
        #expect(local[kSecUseDataProtectionKeychain as String] == nil)
        #expect(local[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(local[kSecAttrSynchronizable as String] as? Bool == false)

        let synced = KeychainCredentialBacking.addQuery(service: Self.service, account: "plex:1:token",
                                                        secret: Data("s".utf8), synchronizable: true)
        #expect(synced[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == true)

        // Reads and deletes match both the synchronizable and the local variant.
        let match = KeychainCredentialBacking.matchQuery(service: Self.service, account: "plex:1:token")
        #expect(match[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String)
        #expect(match[kSecUseDataProtectionKeychain as String] == nil)
        #expect(match[kSecValueData as String] == nil)
    }

    @Test func keychainErrorsNameTheirStatus() {
        #expect(KeychainError(status: errSecMissingEntitlement).description.hasPrefix("Keychain error -34018"))
        // A message built from it says what failed, not "error 1".
        let error: any Error = KeychainError(status: errSecMissingEntitlement)
        #expect(error.localizedDescription.hasPrefix("Keychain error -34018"))
    }
}
