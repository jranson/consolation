import Foundation
import Synchronization

/// The URLSession delegate behind one `HDHomeRunStreamClient`.
///
/// Callbacks arrive on the stream's private serial queue; `open()`, `cancel()` and stream termination can
/// arrive from any thread. All mutable state lives in a `Mutex`, so the class is checked `Sendable`.
nonisolated final class StreamClientDelegate: NSObject, URLSessionDataDelegate, Sendable {
    typealias OpenResult = Result<StreamOpenInfo, HDHomeRunClientError>

    private struct State {
        /// The single GET has been resumed.
        var didStart = false
        /// The first outcome of the request: accepted headers or an error. Never changes once set.
        var openResult: OpenResult?
        /// Callers of `open()` waiting for `openResult`.
        var waiters: [CheckedContinuation<OpenResult, Never>] = []
        /// The chunk stream has finished; nothing more is delivered.
        var isClosed = false
        /// The consumer cancelled; `open()` throws `.cancelled` from now on.
        var isCancelled = false
        /// Body bytes not handed to the consumer yet (see `coalescingBytes`).
        var pending = Data()
        /// When bytes were last handed over (CLOCK_UPTIME_RAW nanoseconds; 0 before the first).
        var lastYield: UInt64 = 0

        /// Body bytes are delivered only after a 200 was accepted and before the stream closed, so an
        /// error body can never reach the consumer.
        var isDelivering: Bool {
            guard !isClosed, case .success = openResult else { return false }
            return true
        }
    }

    /// URLSession delivers a live stream in many small pieces. Every piece handed over wakes
    /// the consumer's tasks, so pieces are gathered until this many bytes are waiting or `coalescingInterval` has
    /// passed since the last hand-over, checked whenever a piece arrives: no timer, and at most about 20 hand-overs a
    /// second, at the cost of up to ~50 ms of extra latency on a 19.4 Mbps stream.
    static let coalescingBytes = 128 * 1_024
    static let coalescingInterval: UInt64 = 50_000_000

    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let host: String

    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation, host: String) {
        self.continuation = continuation
        self.host = host
    }

    /// True exactly once, when the request should be resumed; false after cancellation.
    func markStarted() -> Bool {
        state.withLock { state in
            guard !state.didStart, !state.isClosed else { return false }
            state.didStart = true
            return true
        }
    }

    /// Waits until the response headers arrive, the request fails or the stream is cancelled.
    func waitForOpen() async -> OpenResult {
        await withCheckedContinuation { (waiter: CheckedContinuation<OpenResult, Never>) in
            let settled: OpenResult? = state.withLock { state in
                if state.isCancelled { return .failure(.cancelled) }
                if let result = state.openResult { return result }
                state.waiters.append(waiter)
                return nil
            }
            if let settled { waiter.resume(returning: settled) }
        }
    }

    /// Records the open outcome if none was recorded yet and wakes `open()` callers.
    /// Returns false when an earlier outcome (for example a cancellation) already won.
    @discardableResult
    func settleOpen(_ result: OpenResult) -> Bool {
        let waiters: [CheckedContinuation<OpenResult, Never>]? = state.withLock { state in
            guard state.openResult == nil else { return nil }
            state.openResult = result
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: result) }
        return true
    }

    /// Finishes the chunk stream once; `error` nil is a normal end. With `flushing`, bytes still gathered are
    /// delivered first (the device ended the stream); otherwise they are dropped (the consumer cancelled).
    func close(throwing error: HDHomeRunClientError?, flushing: Bool = false) {
        let (isFirst, remainder) = state.withLock { state -> (Bool, Data) in
            guard !state.isClosed else { return (false, Data()) }
            let remainder = flushing && state.isDelivering ? state.pending : Data()
            state.pending = Data()
            state.isClosed = true
            return (true, remainder)
        }
        guard isFirst else { return }
        if !remainder.isEmpty { continuation.yield(remainder) }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    /// The consumer cancelled: a pending `open()` throws `.cancelled` and the chunk stream ends normally.
    func cancelByClient() {
        state.withLock { $0.isCancelled = true }
        settleOpen(.failure(.cancelled))
        close(throwing: nil)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let result = StreamOpenInfo.evaluate(response)
        switch result {
        case .success:
            completionHandler(settleOpen(result) ? .allow : .cancel)
        case .failure(let error):
            // Refuse the body: an error page must never be delivered as stream data.
            settleOpen(result)
            close(throwing: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let ready: Data? = state.withLock { state in
            guard state.isDelivering else { return nil }
            if state.pending.isEmpty {
                state.pending = data
            } else {
                state.pending.append(data)
            }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard state.pending.count >= Self.coalescingBytes || now &- state.lastYield >= Self.coalescingInterval
            else { return nil }
            state.lastYield = now
            let ready = state.pending
            state.pending = Data()
            return ready
        }
        if let ready, case .terminated = continuation.yield(ready) {
            session.invalidateAndCancel()
        }
    }

    /// One GET per stream: a redirect is never followed; the 3xx response becomes an error instead.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let wasDelivering = state.withLock { $0.isDelivering }
        if let error {
            let mapped = HDHomeRunClientError(transportError: error, host: host)
            if wasDelivering {
                close(throwing: mapped == .cancelled ? nil : .connectionLost, flushing: mapped != .cancelled)
            } else {
                settleOpen(.failure(mapped))
                close(throwing: mapped)
            }
        } else {
            // A completion without accepted headers cannot normally happen; never leave `open()` waiting.
            settleOpen(.failure(.invalidResponse))
            close(throwing: wasDelivering ? nil : .invalidResponse, flushing: true)
        }
        session.finishTasksAndInvalidate()
    }
}
