import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// The stream delegate gathers URLSession's small pieces into fewer, larger chunks without losing or reordering
/// bytes, and hands the first piece over at once.
@Suite("Stream chunk coalescing", .timeLimit(.minutes(1)))
struct StreamCoalescingTests {
    private struct Harness {
        let delegate: StreamClientDelegate
        let chunks: AsyncThrowingStream<Data, any Error>
        let session = URLSession(configuration: .ephemeral)
        let task: URLSessionDataTask

        init() throws {
            let (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
            self.chunks = chunks
            delegate = StreamClientDelegate(continuation: continuation, host: "192.0.2.1")
            task = session.dataTask(with: try #require(URL(string: "http://192.0.2.1:5004/auto/v5.1")))
            delegate.settleOpen(.success(StreamOpenInfo(resource: "tuner0", contentType: "video/mpeg")))
        }

        func receive(_ data: Data) {
            delegate.urlSession(session, dataTask: task, didReceive: data)
        }

        func collect() async throws -> [Data] {
            var received: [Data] = []
            for try await chunk in chunks { received.append(chunk) }
            return received
        }
    }

    /// Distinct bytes, so reordering or loss shows.
    private static func pieces(count: Int, size: Int) -> [Data] {
        (0..<count).map { index in Data((0..<size).map { UInt8(truncatingIfNeeded: index * 7 + $0) }) }
    }

    @Test func smallPiecesArriveInOrderInFewChunks() async throws {
        let harness = try Harness()
        let pieces = Self.pieces(count: 300, size: 1_316)
        for piece in pieces { harness.receive(piece) }
        harness.delegate.close(throwing: nil, flushing: true)
        let chunks = try await harness.collect()
        #expect(chunks.reduce(Data(), +) == pieces.reduce(Data(), +))
        // The first piece goes out at once; the rest (about 390 KB, delivered faster than 50 ms) in 128 KB chunks.
        #expect(chunks.first == pieces.first)
        #expect(chunks.count <= 5)
        #expect(chunks.dropFirst().dropLast().allSatisfy { $0.count >= StreamClientDelegate.coalescingBytes })
    }

    @Test func piecesAfterAPauseAreNotHeldBack() async throws {
        let harness = try Harness()
        harness.receive(Data([1, 2, 3]))
        try await Task.sleep(for: .milliseconds(80))
        harness.receive(Data([4, 5]))
        harness.delegate.close(throwing: nil, flushing: false)
        // Both went out as they came: the second arrived more than 50 ms after the first hand-over.
        #expect(try await harness.collect() == [Data([1, 2, 3]), Data([4, 5])])
    }

    @Test func cancellingDropsGatheredBytes() async throws {
        let harness = try Harness()
        harness.receive(Data([1]))
        harness.receive(Data([2]))
        harness.delegate.cancelByClient()
        #expect(try await harness.collect() == [Data([1])])
    }
}
