import Foundation

/// A configured source as stored: kind, display name, endpoints, options, path mappings and folder bookmarks.
///
/// It **never holds secrets**. Tokens and passwords go in `CredentialStore`, keyed by `SourceID`.
/// `validateNoSecrets()` rejects the obvious mistakes (credentials or token parameters in an endpoint URL, option
/// keys that name a secret), and the stores in this package call it before saving.
public nonisolated struct SourceConfiguration: Identifiable, Hashable, Codable, Sendable {
    public var id: SourceID
    public var kind: SourceKind
    public var displayName: String
    /// Hosts or URLs as the user entered them (`hdhomerun.local`, `192.0.2.10`), or as discovery found them.
    public var endpoints: [String]
    /// Non-secret settings, such as `"lineupSource": "Antenna"`.
    public var options: [String: String]
    public var pathMappings: [PathMapping]
    /// Security-scoped (macOS) or minimal (iOS) bookmark data for a Folder source.
    public var bookmark: Data?
    public var isEnabled: Bool

    public init(id: SourceID, kind: SourceKind, displayName: String, endpoints: [String] = [],
                options: [String: String] = [:], pathMappings: [PathMapping] = [], bookmark: Data? = nil,
                isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.endpoints = endpoints
        self.options = options
        self.pathMappings = pathMappings
        self.bookmark = bookmark
        self.isEnabled = isEnabled
    }

    /// Throws when an endpoint carries a user name, password or token parameter, or an option key names a secret.
    /// The error names the field, never the value.
    public func validateNoSecrets() throws(SourceConfigurationError) {
        for (index, endpoint) in endpoints.enumerated() where Self.endpointCarriesSecret(endpoint) {
            throw .containsSecret(field: "endpoints[\(index)]")
        }
        for key in options.keys.sorted() where Self.isSecretName(key) {
            throw .containsSecret(field: "options.\(key)")
        }
    }

    private static let secretNames: Set<String> = [
        "auth", "authorization", "apikey", "api_key", "api-key", "jwt", "pwd", "passwd", "credential", "credentials"
    ]
    private static let secretFragments = ["token", "password", "secret"]

    /// `X-Plex-Token`, `access_token`, `password`, `api_key` and the like.
    static func isSecretName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return secretNames.contains(lowered) || secretFragments.contains { lowered.contains($0) }
    }

    private static func endpointCarriesSecret(_ endpoint: String) -> Bool {
        guard endpoint.contains("://") || endpoint.contains("@") || endpoint.contains("?") else { return false }
        let candidate = endpoint.contains("://") ? endpoint : "http://" + endpoint
        guard let components = URLComponents(string: candidate) else { return endpoint.contains("@") }
        if components.user != nil || components.password != nil { return true }
        return (components.queryItems ?? []).contains { isSecretName($0.name) }
    }
}

public nonisolated enum SourceConfigurationError: Error, Hashable, Sendable {
    /// The configuration would store a secret; it belongs in `CredentialStore`.
    case containsSecret(field: String)
}

/// Where to read a server-side path on this device, for example Plex's `/Volumes/Media` through a Folder source.
public nonisolated struct PathMapping: Hashable, Codable, Sendable {
    public nonisolated enum Target: Hashable, Codable, Sendable {
        case folder(SourceID, relativePath: String)
        case smb(SourceID, share: String, path: String)
    }

    public var serverPrefix: String
    public var target: Target

    public init(serverPrefix: String, target: Target) {
        self.serverPrefix = serverPrefix
        self.target = target
    }

    /// The mapping with the longest prefix that matches whole path components of `serverPath`, and the rest of
    /// the path after it (without a leading slash). Nil when none matches.
    public static func bestMatch(for serverPath: String, in mappings: [PathMapping])
        -> (mapping: PathMapping, remainder: String)? {
        let pathParts = components(serverPath)
        var best: PathMapping?
        var bestLength = -1
        for mapping in mappings {
            let prefixParts = components(mapping.serverPrefix)
            guard prefixParts.count <= pathParts.count, prefixParts.count > bestLength,
                  Array(pathParts.prefix(prefixParts.count)) == prefixParts else { continue }
            best = mapping
            bestLength = prefixParts.count
        }
        guard let best else { return nil }
        return (best, pathParts.dropFirst(bestLength).joined(separator: "/"))
    }

    private static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}
