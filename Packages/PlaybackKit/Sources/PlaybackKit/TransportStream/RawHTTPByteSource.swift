//
//  RawHTTPByteSource.swift
//  PlaybackKit
//
//  Streams a raw MPEG-TS URL over plain http:// with Network.framework, which App Transport Security doesn't cover.
//  Used where ATS would block URLSession: raw transport streams over http to non-local hosts, and streams from a
//  Bonjour service endpoint (another device on the local network) that has no URL.
//

import Foundation
import Network

nonisolated public final class RawHTTPByteSource: ByteSource, @unchecked Sendable {
    // @unchecked: `connection`, `parser`, `continuation` and `opened` are only touched on `queue`.
    private enum Target {
        case url(URL)
        case endpoint(NWEndpoint, path: String, host: String)
    }

    private let target: Target
    private let minimumChunk: Int
    private let queue = DispatchQueue(label: "PlaybackKit.RawHTTP")
    private var connection: NWConnection?
    private var parser = HTTPResponseParser()
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var opened: CheckedContinuation<Void, any Error>?
    /// Reading is held back for a backlogged reader; a receive is due when it lets go.
    private var backlogged = false
    private var receiveDue = false
    private let lengthLock = NSLock()
    private var lengthKnown = false
    private var length: Int64?
    /// Asked for with a range request; a server that ignores it sends the whole body, and `skipRemaining` is dropped.
    private let startOffset: Int64
    private var skipRemaining: Int64 = 0

    /// `offset` > 0 asks for the stream from that byte on (an HTTP range request).
    public init(url: URL, startingAt offset: Int64 = 0) {
        target = .url(url)
        minimumChunk = 1
        startOffset = max(0, offset)
    }

    /// Streams `path` from `endpoint`, for example a Bonjour service, which Network.framework resolves when it
    /// connects. `hostHeader` is sent as the `Host` header. Body pieces are gathered to at least `minimumChunk`
    /// bytes (except the last), so a fast local stream wakes its reader less often.
    public init(endpoint: NWEndpoint, path: String, hostHeader: String, minimumChunk: Int = 1) {
        target = .endpoint(endpoint, path: path, host: hostHeader)
        self.minimumChunk = max(minimumChunk, 1)
        startOffset = 0
    }

    /// Whether this URL needs the raw client: plain http to a host that isn't on the local network.
    public static func isNeeded(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased() else { return false }
        return !isLocalHost(host)
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    public func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let endpoint: NWEndpoint
        switch target {
        case .url(let url):
            guard let host = url.host() else {
                throw PlaybackError(kind: .source, title: "The URL has no host.")
            }
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 80)) ?? .http
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        case .endpoint(let target, _, _):
            endpoint = target
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        let connection = NWConnection(to: endpoint, using: .tcp)
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                self.continuation = continuation
                self.connection = connection
                opened = waiter
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
            }
        }
        return stream
    }

    /// A response with a Content-Length (and no chunked encoding).
    public var isFinite: Bool { lengthLock.withLock { lengthKnown } }

    /// The whole stream's length (the start offset plus the response's length).
    public var contentLength: Int64? { lengthLock.withLock { length } }

    /// URL streams seek with a range request; endpoint streams (relays of live channels) can't.
    public func reopened(at offset: Int64) -> (any ByteSource)? {
        guard case .url(let url) = target else { return nil }
        return RawHTTPByteSource(url: url, startingAt: offset)
    }

    /// Stops reading from the connection while the reader catches up (TCP flow control then holds the server).
    public func setBacklogged(_ backlogged: Bool) {
        queue.async { [self] in
            self.backlogged = backlogged
            if !backlogged, receiveDue {
                receiveDue = false
                receive()
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
            continuation?.finish()
            continuation = nil
            opened?.resume(throwing: CancellationError())
            opened = nil
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendRequest()
        case .failed(let error), .waiting(let error):
            fail(PlaybackError(kind: .network, title: "Couldn't connect to the server.", underlying: error))
        default:
            break
        }
    }

    /// The request target and `Host` header.
    private var requestLine: (path: String, host: String) {
        switch target {
        case .url(let url):
            var path = url.path(percentEncoded: true)
            if path.isEmpty { path = "/" }
            if let query = url.query(percentEncoded: true) { path += "?\(query)" }
            return (path, url.port.map { "\(url.host() ?? ""):\($0)" } ?? (url.host() ?? ""))
        case .endpoint(_, let path, let host):
            return (path, host)
        }
    }

    private func sendRequest() {
        let (path, hostHeader) = requestLine
        let range = startOffset > 0 ? "Range: bytes=\(startOffset)-\r\n" : ""
        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: PlaybackKit\r\n" +
            "Accept: */*\r\n\(range)Connection: close\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(PlaybackError(kind: .network, title: "Couldn't send the request.",
                                                    underlying: error)) }
        })
        receive()
    }

    private func receive() {
        let most = 256 * 1_024
        // Small reads until the response head arrived, so `open()` never waits for a full chunk of body.
        let minimum = opened == nil ? min(minimumChunk, most) : 1
        connection?.receive(minimumIncompleteLength: minimum, maximumLength: most) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { deliver(data) }
            if let error {
                fail(PlaybackError(kind: .network, title: "The stream stopped.", underlying: error))
            } else if done {
                continuation?.finish()
                continuation = nil
            } else if backlogged {
                receiveDue = true
            } else {
                receive()
            }
        }
    }

    private func deliver(_ data: Data) {
        do {
            for output in try parser.feed(data) {
                switch output {
                case .head(let status, let headers):
                    let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
                    let declared = chunked ? nil : headers["content-length"].flatMap { Int64($0) }
                    // A 206 carries the rest of the body from the offset; a 200 the whole of it.
                    let partial = status == 206
                    skipRemaining = partial ? 0 : startOffset
                    lengthLock.withLock {
                        lengthKnown = declared != nil
                        length = declared.map { $0 + (partial ? startOffset : 0) }
                    }
                    if (200..<300).contains(status) {
                        opened?.resume()
                        opened = nil
                    } else {
                        fail(PlaybackError(kind: .source, title: "The server returned HTTP \(status).",
                                           domain: "HTTP", code: status))
                    }
                case .body(let body):
                    let skip = Int(min(skipRemaining, Int64(body.count)))
                    skipRemaining -= Int64(skip)
                    if skip < body.count {
                        let kept = skip == 0 ? body : body.subdata(in: (body.startIndex + skip)..<body.endIndex)
                        continuation?.yield(kept)
                    }
                case .end:
                    continuation?.finish()
                    continuation = nil
                }
            }
        } catch {
            fail(PlaybackError(kind: .source, title: "The server's response was malformed."))
        }
    }

    private func fail(_ error: PlaybackError) {
        opened?.resume(throwing: error)
        opened = nil
        continuation?.finish(throwing: error)
        continuation = nil
        connection?.cancel()
        connection = nil
    }
}
