import Foundation
import Synchronization
@testable import HTTPMPEG2Kit

/// A scripted stand-in for a tuner device: every GET takes the next scripted answer, and the device counts how many
/// of our connections hold a tuner at once. Nothing leaves the process.
nonisolated final class FakeTunerDevice: Sendable {
    enum Answer: Sendable {
        /// 200 with this `X-HDHomeRun-Resource`.
        case accept(String)
        case fail(HDHomeRunClientError)
        /// No response until the stream is cancelled.
        case hang
        /// 200 with this resource after a delay (another subscribe can run meanwhile).
        case delayed(String, Duration)
    }

    private struct State {
        var script: [Answer] = []
        var streams: [FakeTunerStream] = []
        var requests: [URL] = []
        /// Connections sent and not yet cancelled, when each GET was sent.
        var heldAtRequest: [Int] = []
        var maxHeld = 0
    }

    private let state = Mutex(State())

    init(_ script: [Answer] = []) {
        state.withLock { $0.script = script }
    }

    func enqueue(_ answers: Answer...) {
        state.withLock { $0.script += answers }
    }

    /// The broker's stream factory.
    var factory: TunerBroker.StreamFactory {
        { [self] url in makeStream(url) }
    }

    var requests: [URL] { state.withLock { $0.requests } }
    var streams: [FakeTunerStream] { state.withLock { $0.streams } }
    var heldAtRequest: [Int] { state.withLock { $0.heldAtRequest } }
    /// The most connections we ever held at once. Single-upstream means this never exceeds 1.
    var maxHeld: Int { state.withLock { $0.maxHeld } }
    var held: Int { state.withLock { state in state.streams.filter(\.holdsTuner).count } }

    private func makeStream(_ url: URL) -> FakeTunerStream {
        let stream = FakeTunerStream(url: url, device: self)
        state.withLock { $0.streams.append(stream) }
        return stream
    }

    /// Called by a stream when its GET goes out. An accepted or hanging request holds a tuner until cancelled.
    func requestSent(_ stream: FakeTunerStream) -> Answer {
        state.withLock { state in
            let held = state.streams.filter(\.holdsTuner).count
            state.requests.append(stream.url)
            state.heldAtRequest.append(held)
            let answer = state.script.isEmpty ? .accept("tuner0") : state.script.removeFirst()
            if case .fail = answer { return answer }
            stream.markHolding()
            state.maxHeld = max(state.maxHeld, held + 1)
            return answer
        }
    }
}

nonisolated final class FakeTunerStream: TunerStream {
    let url: URL
    let chunks: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let device: FakeTunerDevice

    private struct State {
        var isHolding = false
        var isCancelled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    init(url: URL, device: FakeTunerDevice) {
        self.url = url
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        self.device = device
    }

    var holdsTuner: Bool { state.withLock { $0.isHolding && !$0.isCancelled } }
    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func open() async throws(HDHomeRunClientError) -> StreamOpenInfo {
        if isCancelled { throw .cancelled }
        switch device.requestSent(self) {
        case .accept(let resource):
            if isCancelled { throw .cancelled }
            return StreamOpenInfo(resource: resource, contentType: "video/mpeg")
        case let .delayed(resource, delay):
            try? await Task.sleep(for: delay)
            if isCancelled { throw .cancelled }
            return StreamOpenInfo(resource: resource, contentType: "video/mpeg")
        case .fail(let error):
            throw error
        case .hang:
            // Like the real client: cancelling the calling task cancels the request. The deadline makes a broker
            // bug that never cancels the request fail the test within seconds instead of hanging the run.
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.cancel()
            }
            defer { deadline.cancel() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    let resumeNow = state.withLock { state in
                        if state.isCancelled { return true }
                        state.waiter = waiter
                        return false
                    }
                    if resumeNow { waiter.resume() }
                }
            } onCancel: {
                cancel()
            }
            throw .cancelled
        }
    }

    func markHolding() {
        state.withLock { $0.isHolding = true }
    }

    func cancel() {
        let waiter = state.withLock { state in
            state.isCancelled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
        continuation.finish()
    }

    /// Device side: delivers bytes, ends the stream or breaks it.
    func send(_ data: Data) { continuation.yield(data) }
    func end() { continuation.finish() }
    func fail(_ error: HDHomeRunClientError) { continuation.finish(throwing: error) }
}
