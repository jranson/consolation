import Foundation

/// One live stream from an HDHomeRun, read with exactly one HTTP GET.
///
/// Tuner etiquette is built in: no HEAD or Range probes, no redirects followed, no retries. The device
/// allocates a tuner when the GET arrives and frees it within about a second of the socket closing.
///
/// ```swift
/// let stream = HDHomeRunStreamClient(url: channel.url!, configuration: configuration)
/// let info = try await stream.open()          // "tuner2", "video/mpeg", or throws .allTunersInUse
/// for try await chunk in stream.chunks { ... }
/// stream.cancel()                              // frees the tuner
/// ```
///
/// The stream also closes when the device ends it (for example after `?duration=`), when the task
/// iterating `chunks` is cancelled, or when the stream object and every copy of `chunks` are released.
/// Breaking out of a `for try await` loop alone does not close it while `chunks` is still referenced,
/// so call `cancel()` when you stop reading.
public nonisolated final class HDHomeRunStreamClient: Sendable {
    public let url: URL
    /// The MPEG-TS body, in chunks of up to about 128 KB (URLSession's small pieces are gathered for at most
    /// 50 ms, so a live stream wakes its reader about 20 times a second instead of hundreds). Ends normally when the device closes the stream
    /// or after `cancel()`, and throws `HDHomeRunClientError` on failure. Error responses never deliver data.
    public let chunks: AsyncThrowingStream<Data, any Error>

    private let session: URLSession
    private let task: URLSessionDataTask
    private let delegate: StreamClientDelegate

    /// Prepares the request. Nothing is sent until `open()`.
    public convenience init(url: URL, configuration: TunerClientConfiguration = TunerClientConfiguration()) {
        self.init(
            url: url,
            configuration: configuration,
            sessionConfiguration: configuration.makeStreamSessionConfiguration()
        )
    }

    /// Lets tests supply a session configuration (for example with a stub `URLProtocol`).
    init(url: URL, configuration: TunerClientConfiguration, sessionConfiguration: URLSessionConfiguration) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let delegate = StreamClientDelegate(continuation: continuation, host: url.host() ?? url.absoluteString)
        let queue = OperationQueue()
        queue.name = "HDHomeRunStreamClient"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        // One session per stream: it owns the delegate until invalidated, and keeps stream connections
        // out of the per-host connection limit shared with JSON polling.
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: queue)
        self.url = url
        self.chunks = stream
        self.session = session
        self.delegate = delegate
        self.task = session.dataTask(with: configuration.makeRequest(url: url))
        continuation.onTermination = { [delegate, session] termination in
            if case .cancelled = termination {
                delegate.cancelByClient()
            }
            session.invalidateAndCancel()
        }
    }

    /// Sends the GET (only on the first call) and returns once the response headers arrive.
    ///
    /// Throws the mapped `HDHomeRunClientError` for an error response (for example `.allTunersInUse` for
    /// `503` + `805 All Tuners In Use`), `.unreachable` when the device cannot be reached, and `.cancelled`
    /// after `cancel()` or when the calling task is cancelled.
    public func open() async throws(HDHomeRunClientError) -> StreamOpenInfo {
        let result = await withTaskCancellationHandler {
            if delegate.markStarted() {
                task.resume()
            }
            return await delegate.waitForOpen()
        } onCancel: {
            self.cancel()
        }
        return try result.get()
    }

    /// Closes the connection at once, which frees the tuner, and ends `chunks`. Safe to call repeatedly.
    public func cancel() {
        delegate.cancelByClient()
        session.invalidateAndCancel()
    }
}
