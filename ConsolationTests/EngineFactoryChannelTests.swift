import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import PlaybackKit
import Synchronization
import Testing
@testable import Consolation

/// A channel's tuner path as `EngineFactory` builds it, through MediaSourceKit's subscription adapter: it
/// subscribes through the broker and never holds two tuners, even when the engine builds the next source (a
/// reconnect) before the previous one is cancelled. No request leaves the process.
@Suite(.timeLimit(.minutes(1)))
struct EngineFactoryChannelTests {
    private static let channel = LiveChannel(
        key: "tvch:Antenna:7.1", guideNumber: "7.1", name: "Test",
        streamURL: URL(string: "http://192.0.2.10:5004/auto/v7.1")!, isHD: true, favorite: .none)

    private static func source(_ broker: TunerBroker) -> ChannelSubscriptionByteSource {
        ChannelSubscriptionByteSource(broker: broker, request: EngineFactory.tuneRequest(for: channel))
    }

    @Test func requestUsesTheChannelKeyAndNoOtherIdentity() {
        let request = EngineFactory.tuneRequest(for: Self.channel)
        #expect(request.channel == ChannelKey(source: "Antenna", guideNumber: "7.1"))
        #expect(request.routes.map(\.url) == [Self.channel.streamURL])
        #expect(request.purpose == .watch)
    }

    @Test func deliversTheSubscriptionBytes() async throws {
        let streams = StreamLog()
        let broker = TunerBroker(makeStream: streams.factory)
        let bytes = try await Self.source(broker).open()
        let upstream = try #require(streams.all.first)
        upstream.send(Data([0x47, 0x01]))
        upstream.end()
        var received = Data()
        for try await chunk in bytes { received.append(chunk) }
        #expect(received == Data([0x47, 0x01]))
    }

    @Test func aReconnectNeverHoldsTwoTuners() async throws {
        let streams = StreamLog()
        let broker = TunerBroker(makeStream: streams.factory)
        let first = Self.source(broker)
        let firstBytes = try await first.open()
        // The engine's next attempt opens before the old source's cancel() has run.
        let second = Self.source(broker)
        let secondBytes = try await second.open()
        first.cancel()
        #expect(streams.all.count == 2)
        #expect(streams.all[0].isCancelled)
        #expect(!streams.all[1].isCancelled)
        second.cancel()
        #expect(streams.all.allSatisfy { $0.isCancelled })
        // Holding the byte streams matters: dropping one also releases its tuner.
        withExtendedLifetime((firstBytes, secondBytes)) {}
    }

    @Test func cancelBeforeTheResponseGivesTheTunerBack() async throws {
        let streams = StreamLog()
        let broker = TunerBroker(makeStream: streams.factory)
        let source = Self.source(broker)
        source.cancel()
        await #expect(throws: CancellationError.self) { _ = try await source.open() }
        #expect(streams.all.allSatisfy { $0.isCancelled })
    }

    @Test func errorsKeepTheWatchdogFromStealingTheTunerBack() {
        #expect(ChannelSubscriptionByteSource.playbackError(.allTunersInUse).kind == .source)
        #expect(ChannelSubscriptionByteSource.playbackError(.allTunersInUse).code == 805)
        #expect(ChannelSubscriptionByteSource.playbackError(.connectionLost).kind == .network)
        #expect(ChannelSubscriptionByteSource.playbackError(.cancelled).kind == .cancelled)
    }
}

/// Every upstream the broker built, each accepting at once.
private nonisolated final class StreamLog: Sendable {
    private let streams = Mutex<[AcceptingStream]>([])

    var all: [AcceptingStream] { streams.withLock { $0 } }

    var factory: TunerBroker.StreamFactory {
        { [self] _ in
            let stream = AcceptingStream()
            streams.withLock { $0.append(stream) }
            return stream
        }
    }
}

private nonisolated final class AcceptingStream: TunerStream {
    let chunks: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let cancelled = Mutex(false)

    init() {
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func open() async throws(HDHomeRunClientError) -> StreamOpenInfo {
        if isCancelled { throw .cancelled }
        return StreamOpenInfo(resource: "tuner1", contentType: "video/mpeg")
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        continuation.finish()
    }

    func send(_ data: Data) { continuation.yield(data) }
    func end() { continuation.finish() }
}
