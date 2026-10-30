import Foundation

/// An RFC 9457 error body (`application/problem+json`). Every member is optional, and members a server adds
/// (`conflicts`, `alternatives`) are left to the source that knows them.
public nonisolated struct ProblemDetails: Hashable, Codable, Sendable {
    /// A URI naming the problem; `about:blank` when the status says it all.
    public var type: String?
    public var title: String?
    public var status: Int?
    public var detail: String?
    public var instance: String?

    public init(type: String? = nil, title: String? = nil, status: Int? = nil, detail: String? = nil,
                instance: String? = nil) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
    }

    /// The text for an error message: the detail, else the title.
    public var message: String? {
        [detail, title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
