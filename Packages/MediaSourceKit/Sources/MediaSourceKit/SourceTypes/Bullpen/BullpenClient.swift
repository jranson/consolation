import Foundation

/// The REST calls a Bullpen player makes: the API catalog, the server document, channels and the OPDS library.
/// Read-only. Decoding runs off the caller's actor.
public nonisolated struct BullpenClient: Sendable {
    public let baseURL: URL
    let fetcher: any RemoteDocumentFetching

    public init(baseURL: URL, fetcher: any RemoteDocumentFetching = RemoteDocumentFetcher()) {
        self.baseURL = baseURL
        self.fetcher = fetcher
    }

    /// A server address as typed: `host`, `host:port`, or a URL. A bare host gets `http://` and Bullpen's default
    /// port; the result always ends in `/`, so relative paths stay under it. Nil for anything that isn't an
    /// http(s) address.
    public static func baseURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        if !trimmed.contains("://"), components.port == nil { components.port = BullpenVocabulary.defaultPort }
        components.query = nil
        components.fragment = nil
        if !components.path.hasSuffix("/") { components.path += "/" }
        return components.url
    }

    @concurrent
    public func catalog() async throws -> APICatalog {
        let url = try resolve(String(APICatalog.wellKnownPath.dropFirst()))
        let data = try await fetcher.document(at: url, accept: APICatalog.mediaType + ", application/json")
        return try APICatalog(data: data, fetchedFrom: url)
    }

    @concurrent
    public func server(_ catalog: APICatalog) async throws -> BullpenServerInfo {
        let url = try catalog.url(BullpenVocabulary.serviceMeta) ?? resolve("api/v1/server")
        return try await decode(BullpenServerInfo.self, at: url, accept: "application/json")
    }

    @concurrent
    public func channels(at url: URL) async throws -> [BullpenChannel] {
        try await decode(BullpenChannelList.self, at: url, accept: "application/json").channels
    }

    @concurrent
    public func feed(at url: URL) async throws -> OPDSFeed {
        try await decode(OPDSFeed.self, at: url, accept: OPDSFeed.mediaType + ", application/json")
    }

    /// `path` under the base URL.
    func resolve(_ path: String) throws(RemoteDocumentError) -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw .malformed(path) }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL, accept: String) async throws -> T {
        let data = try await fetcher.document(at: url, accept: accept)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RemoteDocumentError.malformed("\(T.self)")
        }
    }
}
