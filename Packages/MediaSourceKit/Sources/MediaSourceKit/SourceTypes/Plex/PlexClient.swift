import Foundation

/// A Plex Media Server on the local network, through its JSON API: identity, library sections, metadata, and the
/// DVR's subscriptions and grab operations. Read-only. The token goes only in the `X-Plex-Token` header, never in
/// a URL, and only to this server (redirects elsewhere are refused). No plex.tv, no relay, no transcoder.
public nonisolated struct PlexClient: Sendable {
    /// Who is asking. The product is the app's name; the identifier is one per install.
    public nonisolated struct Client: Hashable, Sendable {
        public var product: String
        public var version: String
        public var identifier: String

        public init(product: String, version: String, identifier: String) {
            self.product = product
            self.version = version
            self.identifier = identifier
        }
    }

    public static let tokenHeader = "X-Plex-Token"
    public static let defaultPort = 32400
    public static let bonjourType = "_plexmediasvr._tcp"

    public let baseURL: URL
    /// Headers for media requests: the token, when there is one.
    public let mediaHeaders: [String: String]
    let fetcher: any RemoteDocumentFetching

    /// - Parameter token: nil for a server that allows this device's network without one.
    public init(baseURL: URL, token: String?, client: Client, fetcher: (any RemoteDocumentFetching)? = nil) {
        self.baseURL = baseURL
        var media: [String: String] = [:]
        if let token, !token.isEmpty { media[Self.tokenHeader] = token }
        mediaHeaders = media
        let headers = media.merging([
            "X-Plex-Product": client.product,
            "X-Plex-Version": client.version,
            "X-Plex-Client-Identifier": client.identifier
        ]) { current, _ in current }
        let userAgent = "\(client.product)/\(client.version)"
        self.fetcher = fetcher ?? RemoteDocumentFetcher(headers: headers, userAgent: userAgent)
    }

    /// A server address as typed: `host`, `host:port` or a URL. A bare host gets `http://` and port 32400.
    public static func baseURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        if components.port == nil, !trimmed.contains("://") { components.port = defaultPort }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Requests

    /// `GET /identity`, which needs no token: the server's `machineIdentifier` and version.
    @concurrent
    public func identity() async throws -> Container {
        try await container("identity")
    }

    /// `GET /`: the server's friendly name, and whether the token (or this network) is accepted.
    @concurrent
    public func root() async throws -> Container {
        try await container("")
    }

    @concurrent
    public func sections() async throws -> [Section] {
        try await container("library/sections/all").sections
    }

    /// A section's top-level items (shows or movies), `size` at a time from `start`.
    @concurrent
    public func items(inSection key: String, start: Int, size: Int) async throws -> Container {
        try await container("library/sections/\(escaped(key))/all", window: (start, size))
    }

    @concurrent
    public func recentlyAdded(inSection key: String, size: Int) async throws -> [Metadata] {
        try await container("library/sections/\(escaped(key))/recentlyAdded", window: (0, size)).metadata
    }

    /// A show's seasons or a season's episodes.
    @concurrent
    public func children(of ratingKey: String) async throws -> [Metadata] {
        try await container("library/metadata/\(escaped(ratingKey))/children").metadata
    }

    @concurrent
    public func metadata(_ ratingKey: String) async throws -> Metadata? {
        try await container("library/metadata/\(escaped(ratingKey))").metadata.first
    }

    /// The DVR's recording rules.
    @concurrent
    public func subscriptions() async throws -> [Subscription] {
        try await container("media/subscriptions").subscriptions
    }

    /// Scheduled, in-progress and finished grab operations.
    @concurrent
    public func scheduled() async throws -> [GrabOperation] {
        try await container("media/subscriptions/scheduled").grabOperations
    }

    /// A server path (`/library/parts/…`, a thumb) as a URL on this server.
    public func url(path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return URL(string: String(path.dropFirst()), relativeTo: baseURL)?.absoluteURL
    }

    private func container(_ path: String, window: (start: Int, size: Int)? = nil) async throws -> Container {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: true)
        else { throw RemoteDocumentError.malformed(path) }
        if let window {
            components.queryItems = [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(max(window.start, 0))),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(max(window.size, 0)))
            ]
        }
        guard let url = components.url else { throw RemoteDocumentError.malformed(path) }
        let data = try await fetcher.document(at: url, accept: "application/json")
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).container
        } catch {
            throw RemoteDocumentError.malformed("MediaContainer")
        }
    }

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? component
    }
}
