import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Testing
@testable import MediaSourceKit

/// The tuner lease follows the engine's reconnects: releasing it frees whichever tuner the engine reads now, refuses
/// later reconnects, and never shows a device URL.
@Suite("TunerLease", .timeLimit(.minutes(1)))
struct TunerLeaseTests {
    static let channel = ChannelKey(source: "Antenna", guideNumber: "4.1")

    static func liveDescriptor(_ tuner: FakeTuner) async throws -> PlaybackDescriptor {
        let source = HDHomeRunSource(lineupSource: "Antenna",
                                     devices: [FixtureLineupProvider(try LineupFixture.antennaA())],
                                     broker: tuner.makeBroker())
        return try await source.playback(for: MediaItemID(channel: channel), request: PlaybackRequest())
    }

    static func feed(_ descriptor: PlaybackDescriptor) throws -> TransportStreamFeed? {
        guard case .transportStream(let feed) = try PlaybackInputMapper.input(for: descriptor) else { return nil }
        return feed
    }

    static func expectCancelled(_ source: any ByteSource) async {
        do {
            _ = try await source.open()
            Issue.record("Expected the attempt to fail as cancelled")
        } catch let error as PlaybackError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func releasingAfterAReconnectFreesTheReconnectedTuner() async throws {
        let tuner = FakeTuner()
        let descriptor = try await Self.liveDescriptor(tuner)
        let feed = try #require(try Self.feed(descriptor))
        let first = feed.makeSource()
        _ = try await first.open()
        // The engine drops the connection and reconnects: a new GET, and the old one closes.
        first.cancel()
        let second = feed.makeSource()
        var bytes = try await second.open().makeAsyncIterator()
        #expect(tuner.upstreams.count == 2)
        let reconnected = try #require(tuner.upstreams.last)
        reconnected.send(Data([0x47]))
        let chunk = try await bytes.next()
        #expect(chunk == Data([0x47]))
        #expect(!reconnected.isCancelled)

        await descriptor.lease?.release()
        #expect(reconnected.isCancelled)
        #expect(tuner.upstreams.allSatisfy { $0.isCancelled })
        // No reconnect after the release: the next attempt fails as cancelled (never retried) and never tunes.
        await Self.expectCancelled(feed.makeSource())
        #expect(tuner.upstreams.count == 2)
    }

    @Test func releasingBeforeTheFirstConnectionGivesTheOpenTunerBack() async throws {
        let tuner = FakeTuner()
        let broker = tuner.makeBroker()
        let request = TuneRequest(channel: Self.channel,
                                  routes: [DeviceChannelRef(url: URL(string: "http://192.0.2.10:5004/auto/v4.1")!)])
        let lease = TunerLease(subscription: try await broker.subscribe(request), broker: broker, request: request)
        #expect(!lease.isReleased)
        await lease.release()
        await lease.release()
        #expect(lease.isReleased)
        #expect(tuner.upstreams.first?.isCancelled == true)
        await Self.expectCancelled(lease.makeSource(expectsRelease: false))
        #expect(tuner.upstreams.count == 1)
    }

    @Test func aReconnectThatHasNotOpenedYetNeverTunesAfterARelease() async throws {
        let tuner = FakeTuner()
        let descriptor = try await Self.liveDescriptor(tuner)
        let feed = try #require(try Self.feed(descriptor))
        _ = feed.makeSource()
        let reconnect = feed.makeSource()
        await descriptor.lease?.release()
        await #expect(throws: CancellationError.self) { _ = try await reconnect.open() }
        #expect(tuner.upstreams.count == 1)
        #expect(tuner.upstreams.first?.isCancelled == true)
    }

    @Test func noTextualFormShowsADeviceURL() async throws {
        let tuner = FakeTuner()
        let descriptor = try await Self.liveDescriptor(tuner)
        guard case .liveTuner(let lease) = descriptor.transport else {
            Issue.record("Expected a live tuner transport")
            return
        }
        var dumped = ""
        dump(descriptor, to: &dumped)
        var dumpedLease = ""
        dump(lease, to: &dumpedLease)
        for text in [dumped, dumpedLease, descriptor.description, String(reflecting: lease)] {
            #expect(text.contains("tvch:Antenna:4.1"))
            for forbidden in ["192.0.2", "5004", "/auto/", "http"] {
                #expect(!text.contains(forbidden), "\(forbidden) leaked")
            }
        }
        await lease.release()
    }
}
