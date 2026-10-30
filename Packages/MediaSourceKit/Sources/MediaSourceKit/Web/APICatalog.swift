import Foundation

/// An RFC 9727 API catalog (`/.well-known/api-catalog`): an RFC 9264 linkset whose relations say what a server
/// offers. A missing relation means the feature is off.
public nonisolated struct APICatalog: Hashable, Sendable {
    /// One target of a relation.
    public nonisolated struct Target: Hashable, Codable, Sendable {
        public var href: String
        public var type: String?
        public var title: String?
    }

    /// The URL relative targets resolve against: the catalog's own URL, the address the user reached. The
    /// linkset's `anchor` is the server's own idea of its address, which may not be reachable from here.
    public let base: URL
    /// The linkset's `anchor`, when it has one.
    public let anchor: URL?
    /// Relation → targets, from the first linkset context (a server describes itself in one).
    public let relations: [String: [Target]]

    public static let wellKnownPath = "/.well-known/api-catalog"
    public static let mediaType = "application/linkset+json"

    /// Parses a catalog fetched from `url`. Members that aren't arrays of link targets are ignored.
    public init(data: Data, fetchedFrom url: URL) throws(RemoteDocumentError) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let linkset = root["linkset"] as? [[String: Any]], let context = linkset.first else {
            throw .malformed("not an API catalog")
        }
        var relations: [String: [Target]] = [:]
        for (name, value) in context where name != "anchor" {
            guard let entries = value as? [[String: Any]] else { continue }
            let targets = entries.compactMap { entry -> Target? in
                guard let href = entry["href"] as? String, !href.isEmpty else { return nil }
                return Target(href: href, type: entry["type"] as? String, title: entry["title"] as? String)
            }
            if !targets.isEmpty { relations[name] = targets }
        }
        anchor = (context["anchor"] as? String).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        base = url
        self.relations = relations
    }

    public func has(_ relation: String) -> Bool {
        relations[relation] != nil
    }

    /// The first target of `relation`, resolved against `base`.
    public func url(_ relation: String) -> URL? {
        guard let href = relations[relation]?.first?.href else { return nil }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }
}
