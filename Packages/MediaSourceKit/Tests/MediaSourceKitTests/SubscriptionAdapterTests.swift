import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Testing
@testable import MediaSourceKit

/// The `ChannelSubscription` to `ByteSource` bridge: one GET per open, bytes straight from the subscription, the
/// tuner given back on cancel, and tuner errors as playback errors.
@Suite("ChannelSubscriptionByteSource", .timeLimit(.minutes(1)))
struct SubscriptionAdapterTests {
    static let request = TuneRequest(
        channel: ChannelKey(source: "Antenna", guideNumber: "7.1"),
        routes: [DeviceChannelRef(deviceID: LineupFixture.deviceA, url: URL(string: "http://192.0.2.10:5004/auto/v7.1")!)])

    @Test func opensThroughTheBrokerAndReleasesOnCancel() async throws {
        let tuner = FakeTuner()
        let source = ChannelSubscriptionByteSource(broker: tuner.makeBroker(), request: Self.request)
        #expect(tuner.upstreams.isEmpty)
        var bytes = try await source.open().makeAsyncIterator()
        let upstream = try #require(tuner.upstreams.first)
        upstream.send(Data([0x47, 0x40]))
        let chunk = try await bytes.next()
        #expect(chunk == Data([0x47, 0x40]))
        source.cancel()
        #expect(upstream.isCancelled)
        #expect(tuner.upstreams.count == 1)
    }

    @Test func cancelledBeforeOpenNeverTunes() async throws {
        let tuner = FakeTuner()
        let source = ChannelSubscriptionByteSource(broker: tuner.makeBroker(), request: Self.request)
        source.cancel()
        await #expect(throws: CancellationError.self) { _ = try await source.open() }
        #expect(tuner.upstreams.isEmpty)
    }

    @Test func anAdoptedSubscriptionIsReadAsIs() async throws {
        let tuner = FakeTuner()
        let subscription = try await tuner.makeBroker().subscribe(Self.request)
        let source = ChannelSubscriptionByteSource(subscription: subscription)
        var bytes = try await source.open().makeAsyncIterator()
        tuner.upstreams.first?.send(Data([0x47]))
        let chunk = try await bytes.next()
        #expect(chunk == Data([0x47]))
        source.cancel()
        #expect(subscription.isEnded)

        let cancelled = ChannelSubscriptionByteSource(subscription: subscription)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.open() }
    }

    @Test func eachSlotHoldsItsOwnSubscription() async throws {
        let tuner = FakeTuner()
        let broker = tuner.makeBroker()
        let other = TuneRequest(
            channel: ChannelKey(source: "Antenna", guideNumber: "9.1"),
            routes: [DeviceChannelRef(deviceID: LineupFixture.deviceA, url: URL(string: "http://192.0.2.10:5004/auto/v9.1")!)])
        let player = ChannelSubscriptionByteSource(broker: broker, request: Self.request)
        let tile = ChannelSubscriptionByteSource(broker: broker, request: other, slot: .tile(UUID()))
        // Keep both byte streams: dropping one gives its tuner back.
        let playerBytes = try await player.open()
        let tileBytes = try await tile.open()
        // The tile's subscribe didn't replace the player's: two upstreams, both open.
        #expect(tuner.upstreams.count == 2)
        #expect(tuner.upstreams.allSatisfy { !$0.isCancelled })
        #expect(player.programNumber == nil)
        tile.cancel()
        #expect(tuner.upstreams.last?.isCancelled == true)
        #expect(tuner.upstreams.first?.isCancelled == false)
        player.cancel()
        withExtendedLifetime((playerBytes, tileBytes)) {}
    }

    @Test func tunerErrorsBecomePlaybackErrors() async throws {
        let source = ChannelSubscriptionByteSource(broker: FakeTuner(failure: .allTunersInUse).makeBroker(),
                                                   request: Self.request)
        await #expect(throws: PlaybackError(kind: .source, title: "All tuners are busy.", domain: "HDHomeRun",
                                            code: 805)) {
            _ = try await source.open()
        }
        #expect(ChannelSubscriptionByteSource.playbackError(.connectionLost).kind == .network)
        #expect(ChannelSubscriptionByteSource.playbackError(.cancelled).kind == .cancelled)
        #expect(ChannelSubscriptionByteSource.playbackError(.noVideoData).kind == .source)
    }
}
