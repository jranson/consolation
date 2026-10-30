import Foundation

/// The relay's tiny HTTP/1.1 protocol, version 1:
///
/// - `GET /v1/stream/<percent-encoded ChannelKey>`: `200` and the raw MPEG-TS body until either side closes, `404`
///   when the channel isn't open on the host, `503` when the host already serves its maximum number of clients.
/// - `GET /v1/info`: `200` and JSON `{"channels":["tvch:Antenna:9.1"],"version":1}`.
///
/// Every response carries `Connection: close`; there is no keep-alive, chunked encoding or range support.
public nonisolated enum RelayRequest: Sendable, Equatable {
    case info
    case stream(ChannelKey)

    public static let infoPath = "/v1/info"
    public static let streamPathPrefix = "/v1/stream/"
    /// The largest request head the host reads before answering 431.
    public static let maxHeadBytes = 8_192

    /// The result of reading a request head.
    public enum Parsed: Sendable, Equatable {
        /// The head isn't complete yet; read more.
        case incomplete
        case request(RelayRequest)
        /// Answer with this status and close.
        case rejected(RelayResponseStatus)
    }

    /// The path that streams `channel`.
    public static func streamPath(for channel: ChannelKey) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = channel.stringValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return streamPathPrefix + encoded
    }

    /// Reads a request head (everything up to the blank line). Headers are ignored; only `GET` is allowed.
    public static func parse(_ head: Data) -> Parsed {
        guard let end = head.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return head.count > maxHeadBytes ? .rejected(.headTooLarge) : .incomplete
        }
        guard end.lowerBound <= maxHeadBytes else { return .rejected(.headTooLarge) }
        guard let text = String(data: head[head.startIndex..<end.lowerBound], encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else { return .rejected(.badRequest) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .rejected(.badRequest) }
        guard parts[0] == "GET" else { return .rejected(.methodNotAllowed) }
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return route(String(target))
    }

    private static func route(_ path: String) -> Parsed {
        if path == infoPath { return .request(.info) }
        guard path.hasPrefix(streamPathPrefix) else { return .rejected(.notFound) }
        let encoded = path.dropFirst(streamPathPrefix.count)
        guard !encoded.contains("/"), let decoded = encoded.removingPercentEncoding,
              let channel = ChannelKey(stringValue: decoded) else { return .rejected(.notFound) }
        return .request(.stream(channel))
    }
}

/// The statuses the relay answers with.
public nonisolated enum RelayResponseStatus: Int, Sendable {
    case success = 200
    case badRequest = 400
    case notFound = 404
    case methodNotAllowed = 405
    case headTooLarge = 431
    case unavailable = 503

    var reason: String {
        switch self {
        case .success: "OK"
        case .badRequest: "Bad Request"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .headTooLarge: "Request Header Fields Too Large"
        case .unavailable: "Service Unavailable"
        }
    }

    /// The response head. A stream response has no length: the body ends when the connection closes.
    func head(contentType: String? = nil, contentLength: Int? = nil) -> Data {
        var lines = ["HTTP/1.1 \(rawValue) \(reason)"]
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if let contentLength { lines.append("Content-Length: \(contentLength)") }
        lines.append("Cache-Control: no-store")
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A complete response with an empty body.
    var emptyResponse: Data {
        head(contentLength: 0)
    }
}

/// The body of `GET /v1/info`.
public nonisolated struct RelayInfo: Codable, Sendable, Hashable {
    public var version: Int
    public var channels: [String]

    public init(version: Int = RelayAdvertisement.currentVersion, channels: [ChannelKey]) {
        self.version = version
        self.channels = channels.map(\.stringValue)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
