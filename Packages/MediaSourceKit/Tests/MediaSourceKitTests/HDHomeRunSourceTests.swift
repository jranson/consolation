import Foundation
import HTTPMPEG2Kit
import Testing
@testable import MediaSourceKit

/// `HDHomeRunSource` over fixture lineups and a fake tuner: one logical source per lineup Source, the Live TV
/// pane's channel rules, favorites, de-duplication across devices, and no network before a call.
@Suite("HDHomeRunSource", .timeLimit(.minutes(1)))
struct HDHomeRunSourceTests {
    static let antenna = SourceID.hdhomerunLive(lineupSource: "Antenna")

    static func source(_ providers: [FixtureLineupProvider], tuner: FakeTuner = FakeTuner()) -> HDHomeRunSource {
        HDHomeRunSource(lineupSource: "Antenna", devices: providers, broker: tuner.makeBroker())
    }

    static func item(_ guideNumber: String) -> MediaItemID {
        MediaItemID(source: antenna, key: "ch:\(guideNumber)")
    }

    @Test func nothingIsFetchedUntilAMethodNeedsTheLineup() async throws {
        let device = FixtureLineupProvider(try LineupFixture.antennaA())
        let source = Self.source([device])
        #expect(source.id == Self.antenna)
        #expect(source.kind == .hdhomerun)
        #expect(await source.capabilities().contains(.liveTV))
        #expect(await source.status() == .ready)
        #expect(device.fetchCount == 0)

        _ = try await source.children(of: nil, page: .all)
        #expect(device.fetchCount == 1)
        _ = try await source.item(Self.item("2.1"))
        #expect(device.fetchCount == 1)
    }

    @Test func channelsAreInGuideOrderWithTheLiveTVRules() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA())])
        let items = try await source.children(of: nil, page: .all).items
        // 7.1 is DRM, 102.1 is ATSC 3.0 (HEVC/AC-4) and 11.1 is unsubscribed: all hidden, as in the Live TV pane.
        #expect(items.map(\.key) == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:20.1", "ch:20.4", "ch:31.1"])
        let first = try #require(items.first)
        #expect(first.kind == .channel(number: "2.1", callSign: "KAAA-DT", isHD: true, isFavorite: true))
        #expect(first.title == "KAAA-DT")
        #expect(first.subtitle == "2.1")
        #expect(first.artwork.bestLandscape == .stylized(seed: "hdhr-live:Antenna:ch:2.1"))
        #expect(first.technical == CodecHints(container: .mpegTS, video: .mpeg2, audio: .ac3))
        let page = try await source.children(of: nil, page: PageRequest(offset: 2, limit: 2))
        #expect(page.items.map(\.key) == ["ch:9.1", "ch:20.1"])
        #expect(page.total == 6)
    }

    @Test func favoritesComeFromTheFavoriteFlagAndLegacyTags() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA())])
        let favorites = try await source.children(of: nil, page: .all).items.filter(\.isDeviceFavorite)
        #expect(favorites.map(\.key) == ["ch:2.1", "ch:4.1", "ch:20.4"])
    }

    @Test func twoDevicesOnOneLineupSourceListEachChannelOnce() async throws {
        let deviceA = FixtureLineupProvider(try LineupFixture.antennaA())
        let deviceB = FixtureLineupProvider(try LineupFixture.antennaB())
        let source = Self.source([deviceA, deviceB])
        let items = try await source.children(of: nil, page: .all).items
        #expect(items.map(\.key) == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:13.1", "ch:20.1", "ch:20.4", "ch:31.1"])
        #expect(Set(items.map(\.id)).count == items.count)
        // 9.1 is a favorite only on device B; the union counts.
        #expect(items.filter(\.isDeviceFavorite).map(\.key) == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:20.4"])
        #expect(deviceA.fetchCount == 1)
        #expect(deviceB.fetchCount == 1)
    }

    @Test func aDeviceOnAnotherLineupSourceIsSkipped() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA()),
                                  FixtureLineupProvider(try LineupFixture.cable())])
        let keys = try await source.children(of: nil, page: .all).items.map(\.key)
        #expect(!keys.contains("ch:702"))
        #expect(keys.count == 6)
    }

    @Test func idsNeverHoldDeviceIDsHostsOrAddresses() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA()),
                                  FixtureLineupProvider(try LineupFixture.antennaB())])
        for item in try await source.children(of: nil, page: .all).items {
            for forbidden in ["192.0.2", "5004", "1A2B3C4D", "5E6F7A8B", "hdhr-1a2b", "http"] {
                #expect(!item.cardID.localizedCaseInsensitiveContains(forbidden))
            }
        }
    }

    @Test func playbackSubscribesThroughTheBroker() async throws {
        let tuner = FakeTuner()
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA()),
                                  FixtureLineupProvider(try LineupFixture.antennaB())], tuner: tuner)
        let descriptor = try await source.playback(for: Self.item("9.1"), request: PlaybackRequest())
        #expect(descriptor.isLive)
        #expect(!descriptor.isGrowing)
        #expect(descriptor.start == .liveEdge)
        #expect(descriptor.container == .mpegTS)
        guard case .liveTuner(let lease) = descriptor.transport else {
            Issue.record("Expected a live tuner transport")
            return
        }
        #expect(lease.channel == ChannelKey(source: "Antenna", guideNumber: "9.1"))
        #expect(lease.route.deviceID == LineupFixture.deviceA)
        // Both devices carry 9.1, so the broker may fail over to B; A comes first.
        #expect(lease.reconnectRequest?.routes.map(\.deviceID) == [LineupFixture.deviceA, LineupFixture.deviceB])
        #expect(lease.reconnectRequest?.purpose == .watch)
        #expect(tuner.upstreams.map(\.url.absoluteString) == ["http://192.0.2.10:5004/auto/v9.1"])

        // The transport's lease is the descriptor's lease: releasing it frees the tuner.
        #expect(descriptor.lease as? TunerLease === lease)
        await descriptor.lease?.release()
        #expect(lease.isReleased)
        #expect(tuner.upstreams.first?.isCancelled == true)
    }

    @Test func aTileAsksTheBrokerForATile() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA())])
        let descriptor = try await source.playback(for: Self.item("2.1"), request: PlaybackRequest(purpose: .tile))
        guard case .liveTuner(let lease) = descriptor.transport else {
            Issue.record("Expected a live tuner transport")
            return
        }
        #expect(lease.reconnectRequest?.purpose == .tile)
        await descriptor.lease?.release()
    }

    @Test func playbackFailsWithTheDeviceError() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA())],
                                 tuner: FakeTuner(failure: .noVideoData))
        await #expect(throws: HDHomeRunClientError.noVideoData) {
            _ = try await source.playback(for: Self.item("2.1"), request: PlaybackRequest())
        }
    }

    @Test func unknownAndForeignItemsAreRejected() async throws {
        let source = Self.source([FixtureLineupProvider(try LineupFixture.antennaA())])
        await #expect(throws: MediaSourceError.notFound(Self.item("7.1"))) {
            _ = try await source.item(Self.item("7.1"))
        }
        let foreign = MediaItemID(source: .hdhomerunLive(lineupSource: "Cable"), key: "ch:2.1")
        await #expect(throws: MediaSourceError.wrongSource(foreign)) {
            _ = try await source.item(foreign)
        }
        #expect(try await source.children(of: Self.item("2.1"), page: .all).items.isEmpty)
    }

    @Test func statusFollowsTheDevices() async throws {
        let failing = FixtureLineupProvider([.failure(.unreachable(host: "hdhomerun.local", reason: nil))])
        let degraded = Self.source([FixtureLineupProvider(try LineupFixture.antennaA()), failing])
        #expect(try await degraded.children(of: nil, page: .all).items.count == 6)
        #expect(await degraded.status() == .degraded("1 of 2 tuners didn't answer."))

        let down = Self.source([failing])
        await #expect(throws: HDHomeRunClientError.self) { _ = try await down.children(of: nil, page: .all) }
        #expect(await down.status() == .unreachable("Can't reach the HDHomeRun at hdhomerun.local."))

        let denied = Self.source([FixtureLineupProvider([.failure(.localNetworkUnavailable(errno: 1))])])
        _ = try? await denied.children(of: nil, page: .all)
        #expect(await denied.status() == .localNetworkDenied)

        let empty = HDHomeRunSource(lineupSource: "Antenna", devices: [], broker: FakeTuner().makeBroker())
        #expect(await empty.status() == .unconfigured)
    }

    @Test func aFailedFirstLoadStillAnswersHome() async throws {
        let device = FixtureLineupProvider([.failure(.localNetworkUnavailable(errno: 1))])
        let source = Self.source([device])
        var updates = await source.shelfContributions().makeAsyncIterator()
        let failedUpdate = await updates.next()
        let failed = try #require(failedUpdate)
        #expect(failed.map(\.shelf) == [.favorites, .liveChannels])
        #expect(failed.allSatisfy { $0.items.isEmpty })
        #expect(await source.status() == .localNetworkDenied)

        device.script([.success(try LineupFixture.antennaA())])
        try await source.refresh(force: true)
        let loadedUpdate = await updates.next()
        let loaded = try #require(loadedUpdate)
        #expect(loaded[1].items.count == 6)
        #expect(await source.status() == .ready)

        // Once a lineup loaded, a failed reload keeps what was published and publishes nothing new.
        device.script([.failure(.unreachable(host: "tuner.local", reason: nil))])
        await #expect(throws: HDHomeRunClientError.self) { try await source.refresh(force: true) }
        #expect(await source.publishCount == 1)
        #expect(try await source.children(of: nil, page: .all).items.count == 6)
    }

    @Test func concurrentCallersShareOneFetch() async throws {
        let device = FixtureLineupProvider(try LineupFixture.antennaA())
        let source = Self.source([device])
        async let first = source.children(of: nil, page: .all)
        async let second = source.item(Self.item("4.1"))
        _ = try await (first, second)
        #expect(device.fetchCount == 1)
    }

    @Test func shelvesArePublishedOnlyWhenTheLineupChanges() async throws {
        let device = FixtureLineupProvider(try LineupFixture.antennaA())
        let source = Self.source([device])
        var updates = await source.shelfContributions().makeAsyncIterator()
        // Subscribing loads the lineup once.
        let firstUpdate = await updates.next()
        let first = try #require(firstUpdate)
        #expect(first.map(\.shelf) == [.favorites, .liveChannels])
        #expect(first[0].items.map(\.key) == ["ch:2.1", "ch:4.1", "ch:20.4"])
        #expect(first[1].items.count == 6)

        try await source.refresh()
        #expect(device.fetchCount == 1)  // fresh enough
        try await source.refresh(force: true)
        #expect(device.fetchCount == 2)
        #expect(await source.publishCount == 1)  // unchanged: nothing published

        var changed = try LineupFixture.antennaA()
        changed.channels.removeAll { $0.guideNumber == "2.1" }
        device.script([.success(changed)])
        try await source.refresh(force: true)
        #expect(await source.publishCount == 2)
        let secondUpdate = await updates.next()
        let second = try #require(secondUpdate)
        #expect(second[0].items.map(\.key) == ["ch:4.1", "ch:20.4"])
    }

    @Test func aTileHoldsItsOwnSlotAndTheRoutesCarryTheModel() async throws {
        let tuner = FakeTuner()
        var lineup = try LineupFixture.antennaA()
        lineup.modelNumber = "HDFX-4K"
        let source = Self.source([FixtureLineupProvider(lineup)], tuner: tuner)
        let tileID = UUID()
        let player = try await source.playback(for: Self.item("9.1"), request: PlaybackRequest())
        let tile = try await source.playback(
            for: Self.item("2.1"), request: PlaybackRequest(purpose: .tile, tileID: tileID, prefersSharedTuner: true))
        guard case .liveTuner(let playerLease) = player.transport, case .liveTuner(let tileLease) = tile.transport
        else {
            Issue.record("Expected live tuner transports")
            return
        }
        // The tile didn't replace the player's subscription.
        #expect(tuner.upstreams.count == 2)
        #expect(tuner.upstreams.allSatisfy { !$0.isCancelled })
        #expect(playerLease.reconnectSlot == .player)
        #expect(tileLease.reconnectSlot == .tile(tileID))
        #expect(tileLease.reconnectRequest?.purpose == .tile)
        #expect(tileLease.reconnectRequest?.prefersMultiplex == true)
        #expect(tileLease.reconnectRequest?.routes.map(\.modelNumber) == ["HDFX-4K"])
        await player.lease?.release()
        await tile.lease?.release()
        #expect(tuner.upstreams.allSatisfy { $0.isCancelled })
    }
}
