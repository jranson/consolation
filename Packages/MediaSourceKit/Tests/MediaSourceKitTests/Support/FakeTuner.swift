import Foundation
import HTTPMPEG2Kit
import Synchronization

/// Stands in for every tuner device behind a `TunerBroker`: each GET becomes a `FakeUpstream` the test can feed.
/// Nothing leaves the process.
nonisolated final class FakeTuner: Sendable {
    private struct State {
        var upstreams: [FakeUpstream] = []
        var failure: HDHomeRunClientError?
    }

    private let state = Mutex(State())

    /// - Parameter failure: every GET fails with this device error (805, for example).
    init(failure: HDHomeRunClientError? = nil) {
        state.withLock { $0.failure = failure }
    }

    var factory: TunerBroker.StreamFactory {
        { [self] url in
            let upstream = FakeUpstream(url: url, failure: state.withLock { $0.failure })
            state.withLock { $0.upstreams.append(upstream) }
            return upstream
        }
    }

    var upstreams: [FakeUpstream] { state.withLock { $0.upstreams } }

    func makeBroker() -> TunerBroker {
        TunerBroker(configuration: TunerBrokerConfiguration(busyRetryDelay: .milliseconds(10)), makeStream: factory)
    }

    /// A broker that reads a `status.json` with `free` idle tuners (the rest held by another client), so it can
    /// name a tuner for a full multiplex. The reserve is 0.
    func makeSharingBroker(free: Set<Int>) -> TunerBroker {
        let statuses = (0..<4).map { index in
            free.contains(index) ? TunerStatus(resource: "tuner\(index)")
                : TunerStatus(resource: "tuner\(index)", vctNumber: "7.1", targetIP: "192.0.2.44")
        }
        return TunerBroker(configuration: TunerBrokerConfiguration(busyRetryDelay: .milliseconds(10), reserve: 0),
                           makeStream: factory, fetchStatus: { _ in statuses })
    }
}

nonisolated final class FakeUpstream: TunerStream {
    let url: URL
    let chunks: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let failure: HDHomeRunClientError?
    private let cancelled = Mutex(false)

    init(url: URL, failure: HDHomeRunClientError?) {
        self.url = url
        self.failure = failure
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func open() async throws(HDHomeRunClientError) -> StreamOpenInfo {
        if isCancelled { throw .cancelled }
        if let failure { throw failure }
        return StreamOpenInfo(resource: "tuner0", contentType: "video/mpeg")
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        continuation.finish()
    }

    /// Device side: delivers bytes.
    func send(_ data: Data) {
        continuation.yield(data)
    }
}
