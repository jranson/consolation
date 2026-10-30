import Foundation
import Security

/// The Keychain behind `CredentialStore`: generic passwords, keyed by the injected service and the account.
///
/// It deliberately omits `kSecUseDataProtectionKeychain`. On macOS that keychain needs entitlements a provisioning
/// profile authorizes, which an app built ad hoc or signed with Developer ID but no profile doesn't have, so the
/// store uses the sandboxed file-based login keychain there. Items are readable after the first unlock, so background
/// refresh works after a reboot, and stay on this device unless sync was asked for.
public nonisolated struct KeychainCredentialBacking: CredentialBacking {
    public init() {}

    public func setSecret(_ secret: Data, service: String, account: String, synchronizable: Bool) throws {
        // Remove both the synchronizable and the local variant first, so one account never holds two items.
        let deleted = SecItemDelete(Self.matchQuery(service: service, account: account) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
        let query = Self.addQuery(service: service, account: account, secret: secret, synchronizable: synchronizable)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func secret(service: String, account: String) throws -> Data? {
        var query = Self.matchQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    public func removeSecret(service: String, account: String) throws {
        let status = SecItemDelete(Self.matchQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func accounts(service: String) throws -> [String] {
        var query = Self.serviceQuery(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - Queries (tested without touching the Keychain)

    /// Every item of the service, synchronizable or not.
    static func serviceQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }

    /// One account's item, synchronizable or not.
    static func matchQuery(service: String, account: String) -> [String: Any] {
        var query = serviceQuery(service: service)
        query[kSecAttrAccount as String] = account
        return query
    }

    static func addQuery(service: String, account: String, secret: Data, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

/// A Keychain call failed with this `OSStatus` (for example -34018, `errSecMissingEntitlement`). Its
/// `localizedDescription` names the status, so a message built from it says what failed.
public nonisolated struct KeychainError: LocalizedError, Hashable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
    }

    public var errorDescription: String? { description }
}
