//
//  ByteSource.swift
//  PlaybackKit
//
//  Where a transport stream's bytes come from. The TS engine never opens HDHomeRun URLs itself: the host hands it
//  a source that owns exactly one connection (and so exactly one tuner).
//

import Foundation

/// A one-shot stream of bytes. `open()` is called once; `cancel()` must release the connection promptly.
nonisolated public protocol ByteSource: Sendable {
    func open() async throws -> AsyncThrowingStream<Data, any Error>
    func cancel()
    /// The program to select from the PAT, known once `open()` returned (a full multiplex carries several), or nil
    /// for the first program. Defaults to nil.
    var programNumber: Int? { get }
    /// The stream has a known end (a file, or an HTTP response with a length), known once `open()` returned. A
    /// finite stream is played to its end and then stops; a live one that ends is reconnected. Its delivery may be
    /// held back (`setBacklogged`) so unread data is never overwritten. Defaults to false.
    var isFinite: Bool { get }
    /// The reader is so far behind that the time-shift buffer is full of unread data: a finite source should stop
    /// delivering until called with false. Live sources never get it. Defaults to doing nothing.
    func setBacklogged(_ backlogged: Bool)
    /// The stream's total length in bytes (a finite source's), once `open()` returned. Defaults to nil.
    var contentLength: Int64? { get }
    /// A new, unopened source for the same stream starting at byte `offset` (a range request, or a file read from
    /// there), so a finite stream can seek beyond what the time-shift buffer holds; nil when this source can't.
    /// Making one costs nothing until it is opened. Defaults to nil.
    func reopened(at offset: Int64) -> (any ByteSource)?
}

nonisolated public extension ByteSource {
    var isFinite: Bool { false }
    func setBacklogged(_ backlogged: Bool) {}
    var contentLength: Int64? { nil }
    func reopened(at offset: Int64) -> (any ByteSource)? { nil }
}

/// Streams a URL with one GET through URLSession, delivering data chunks as they arrive.
/// Used for raw MPEG-TS URLs that App Transport Security allows (https, and local-network http), and files.
/// Request headers (a server's token) go with every request, including the range requests of a seek.
nonisolated public final class HTTPByteSource: NSObject, ByteSource, URLSessionDataDelegate, @unchecked Sendable {
    // @unchecked: mutable state is only touched under `lock`, and URLSession calls the delegate on its serial queue.
    private let url: URL
    private let startOffset: Int64
    private let headers: [String: String]
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var opened: CheckedContinuation<Void, any Error>?
    private var hasLength = false
    private var length: Int64?
    /// Bytes still to drop before delivering: a server that ignored the range request sent the whole body.
    private var skipRemaining: Int64 = 0

    /// `offset` > 0 asks for the stream from that byte on (an HTTP range request).
    public init(url: URL, startingAt offset: Int64 = 0, headers: [String: String] = [:]) {
        self.url = url
        startOffset = max(0, offset)
        self.headers = headers
    }

    public func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        lock.withLock {
            self.continuation = continuation
            self.session = session
        }
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            lock.withLock { opened = waiter }
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if startOffset > 0 { request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: request)
            lock.withLock { self.task = task }
            task.resume()
        }
        return stream
    }

    /// A file URL, or a response with a Content-Length.
    public var isFinite: Bool { lock.withLock { hasLength } }

    /// The whole stream's length (the start offset plus the response's length).
    public var contentLength: Int64? { lock.withLock { length } }

    /// Seeks with a range request; a file is read from the offset directly.
    public func reopened(at offset: Int64) -> (any ByteSource)? {
        if url.isFileURL { return FileByteSource(url: url, startingAt: offset) }
        return HTTPByteSource(url: url, startingAt: offset, headers: headers)
    }

    /// Suspends the transfer while the reader catches up (URLSession then stops reading the file or the socket).
    public func setBacklogged(_ backlogged: Bool) {
        let task = lock.withLock { self.task }
        if backlogged { task?.suspend() } else { task?.resume() }
    }

    public func cancel() {
        let (session, continuation, waiter) = lock.withLock {
            let result = (self.session, self.continuation, opened)
            self.session = nil
            task = nil
            self.continuation = nil
            opened = nil
            return result
        }
        session?.invalidateAndCancel()
        continuation?.finish()
        waiter?.resume(throwing: CancellationError())
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let waiter = lock.withLock {
            let waiter = opened
            opened = nil
            hasLength = response.expectedContentLength >= 0
            // A 206 carries the rest of the body from the offset; a 200 the whole of it.
            let partial = status == 206
            skipRemaining = partial ? 0 : startOffset
            length = hasLength ? response.expectedContentLength + (partial ? startOffset : 0) : nil
            return waiter
        }
        if (200..<300).contains(status) {
            completionHandler(.allow)
            waiter?.resume()
        } else {
            completionHandler(.cancel)
            waiter?.resume(throwing: PlaybackError(kind: .source, title: "The server returned HTTP \(status).",
                                                   domain: "HTTP", code: status))
        }
    }

    /// A redirect to another origin (object storage, a CDN) goes without the request headers, so a token is only
    /// ever sent where it was meant to go.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard !headers.isEmpty, !Self.isSameOrigin(request.url, url) else { return completionHandler(request) }
        var stripped = request
        for name in headers.keys { stripped.setValue(nil, forHTTPHeaderField: name) }
        completionHandler(stripped)
    }

    static func isSameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host()?.lowercased() == rhs.host()?.lowercased() && lhs.port == rhs.port
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (continuation, skip) = lock.withLock {
            let skip = Int(min(skipRemaining, Int64(data.count)))
            skipRemaining -= Int64(skip)
            return (self.continuation, skip)
        }
        guard skip < data.count else { return }
        _ = continuation?.yield(skip == 0 ? data : data.subdata(in: (data.startIndex + skip)..<data.endIndex))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, waiter) = lock.withLock {
            let result = (self.continuation, opened)
            self.continuation = nil
            opened = nil
            return result
        }
        if let error {
            waiter?.resume(throwing: error)
            continuation?.finish(throwing: error)
        } else {
            waiter?.resume()
            continuation?.finish()
        }
    }
}
