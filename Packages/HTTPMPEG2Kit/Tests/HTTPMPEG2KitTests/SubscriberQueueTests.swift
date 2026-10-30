import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Bounded per-subscriber queues: a slow subscriber loses its oldest chunks and reads one `.discontinuity`, and the
/// others are never stalled. Relay clients keep an unbounded queue (they enforce their own bound).
@Suite("Subscriber queues", .timeLimit(.minutes(1)))
struct SubscriberQueueTests {
    static let route = StreamRoute(channel: MultiView.key("9.1"), deviceID: nil, resource: "tuner0",
                                   contentType: "video/mpeg", programNumber: nil)

    static func chunk(_ marker: UInt8, size: Int = 376) -> Data {
        var data = Data(repeating: 0, count: size)
        data[0] = 0x47
        data[1] = marker
        return data
    }

    @Test func overflowDropsTheOldestAndMarksTheGap() async throws {
        let queue = SubscriberQueue(route: Self.route, byteLimit: 1000)
        for marker in UInt8(0)..<5 { queue.push(Self.chunk(marker)) }
        queue.finish()
        var read: [TSChunk] = []
        while let next = try await queue.next(onAbandon: {}) { read.append(next) }
        // 5 × 376 bytes against a 1000-byte bound: the two newest fit, with one marker in front of them.
        #expect(read == [.discontinuity, .data(Self.chunk(3)), .data(Self.chunk(4))])
        #expect(queue.discontinuities == 1)
        #expect(queue.droppedBytes == 3 * 376)
    }

    @Test func anUnboundedQueueKeepsEverything() async throws {
        let queue = SubscriberQueue(route: Self.route, byteLimit: nil)
        for marker in UInt8(0)..<50 { queue.push(Self.chunk(marker)) }
        #expect(queue.queuedBytes == 50 * 376)
        queue.finish(throwing: HDHomeRunClientError.connectionLost)
        var count = 0
        await #expect(throws: HDHomeRunClientError.connectionLost) {
            while try await queue.next(onAbandon: {}) != nil { count += 1 }
        }
        #expect(count == 50)
    }

    @Test func aSlowSubscriberGetsADiscontinuityWithoutStallingTheOthers() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, queueBytes: 2000)
        let fast = try await broker.subscribe(MultiView.request("9.1", purpose: .watch))
        let slow = try await broker.subscribe(MultiView.request("9.1", purpose: .watch), slot: MultiView.tile())
        let relay = try await broker.attach(to: MultiView.key("9.1"))
        let upstream = try #require(device.streams.first)
        let total = 40
        // The fast subscriber reports every chunk it reads; the device sends the next one only after that, so the
        // fast one never falls behind while the slow one reads nothing.
        let (received, receivedSink) = AsyncStream.makeStream(of: UInt8.self)
        let reader = Task {
            for try await chunk in fast.chunks {
                if case .data(let data) = chunk { receivedSink.yield(data[1]) }
            }
        }
        defer { reader.cancel() }
        var markers: [UInt8] = []
        var progress = received.makeAsyncIterator()
        for marker in 0..<total {
            upstream.send(Self.chunk(UInt8(marker)))
            if let next = await progress.next() { markers.append(next) }
        }
        #expect(markers == (0..<total).map(UInt8.init))
        #expect(try await TunerBrokerTests.eventually { slow.droppedByteCount > 0 })

        var slowBytes = slow.chunks.makeAsyncIterator()
        #expect(try await slowBytes.next() == .discontinuity)
        guard case .data(let first) = try await slowBytes.next() else {
            Issue.record("expected data after the marker")
            return
        }
        #expect(first[1] > 0)
        #expect(slow.discontinuityCount == 1)

        // The relay client's queue is unbounded: StreamRelayServer drops a slow client instead.
        var relayBytes = relay.chunks.makeAsyncIterator()
        #expect(try await relayBytes.next() == .data(Self.chunk(0)))
        #expect(device.requests.count == 1)
    }

    @Test func cancellingTheReaderLeavesTheUpstream() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device)
        let subscription = try await broker.subscribe(MultiView.request("9.1", purpose: .watch))
        let reader = Task {
            for try await _ in subscription.chunks {}
        }
        try await Task.sleep(for: .milliseconds(20))
        reader.cancel()
        _ = try? await reader.value
        #expect(try await TunerBrokerTests.eventually { device.held == 0 })
        #expect(subscription.isEnded)
    }
}
