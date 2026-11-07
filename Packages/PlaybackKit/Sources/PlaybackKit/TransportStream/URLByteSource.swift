//
//  URLByteSource.swift
//  PlaybackKit
//
//  Streams an http(s) URL with the client App Transport Security allows for it, and follows redirects between them:
//  URLSession (`HTTPByteSource`) for https and local-network http, Network.framework (`RawHTTPByteSource`) for plain
//  http elsewhere. IPTV servers and CDNs often answer an https URL with a redirect to plain http on a bare address,
//  which URLSession must not follow.
//

import Foundation

/// A redirect a client leaves to `URLByteSource`: one to plain http off the local network (URLSession), or any
/// redirect (the raw client, which follows none itself).
nonisolated public struct ByteSourceRedirect: Error, Sendable, Equatable {
    public let location: URL

    public init(location: URL) {
        self.location = location
    }
}

nonisolated public final class URLByteSource: ByteSource, @unchecked Sendable {
    // @unchecked: `current` and `cancelled` are only touched under `lock`.
    static let maximumRedirects = 8

    private let url: URL
    private let startOffset: Int64
    private let headers: [String: String]
    private let needsRawClient: @Sendable (URL) -> Bool
    private let lock = NSLock()
    /// The client of the hop being opened, or of the one that answered.
    private var current: (any ByteSource)?
    private var cancelled = false

    /// `offset` > 0 asks for the stream from that byte on (an HTTP range request). `headers` (a token) go only to
    /// the origin of `url`.
    public convenience init(url: URL, startingAt offset: Int64 = 0, headers: [String: String] = [:]) {
        self.init(url: url, startingAt: offset, headers: headers, needsRawClient: RawHTTPByteSource.isNeeded(for:))
    }

    /// `needsRawClient` picks the client for each hop (tests send loopback hops through the raw client).
    init(url: URL, startingAt offset: Int64, headers: [String: String],
         needsRawClient: @escaping @Sendable (URL) -> Bool) {
        self.url = url
        startOffset = max(0, offset)
        self.headers = headers
        self.needsRawClient = needsRawClient
    }

    public func open() async throws -> AsyncThrowingStream<Data, any Error> {
        var target = url
        for _ in 0...Self.maximumRedirects {
            let client = client(for: target)
            let installed = lock.withLock {
                if !cancelled { current = client }
                return !cancelled
            }
            guard installed else { throw CancellationError() }
            do {
                return try await client.open()
            } catch let redirect as ByteSourceRedirect {
                target = redirect.location
            }
        }
        throw PlaybackError(kind: .source, title: "The server redirected too many times.")
    }

    /// The client for one hop. Every hop asks for the same range.
    func client(for target: URL) -> any ByteSource {
        if needsRawClient(target) { return RawHTTPByteSource(url: target, startingAt: startOffset) }
        let sameOrigin = HTTPByteSource.isSameOrigin(target, url)
        return HTTPByteSource(url: target, startingAt: startOffset, headers: sameOrigin ? headers : [:],
                              refusesRedirect: needsRawClient)
    }

    /// The client the first request goes through, for tests.
    var firstClient: any ByteSource { client(for: url) }

    private var client: (any ByteSource)? { lock.withLock { current } }

    public var isFinite: Bool { client?.isFinite ?? false }

    public var contentLength: Int64? { client?.contentLength }

    public func setBacklogged(_ backlogged: Bool) {
        client?.setBacklogged(backlogged)
    }

    /// Seeks with a range request from the original URL, so a redirect to a short-lived address is asked for anew.
    public func reopened(at offset: Int64) -> (any ByteSource)? {
        URLByteSource(url: url, startingAt: offset, headers: headers, needsRawClient: needsRawClient)
    }

    public func cancel() {
        let client = lock.withLock {
            cancelled = true
            return current
        }
        client?.cancel()
    }
}
