import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Testing
@testable import Consolation

/// The source registry over fake tuners: no network until a tuner is added (and then only when Home or the Live TV
/// pane asks), one logical source per lineup Source, one lineup request shared by Home and the Live TV pane, and
/// "go" resolving a card to what the player plays. Nothing leaves the process.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SourceRegistryTests {
    static let antenna = SourceID.hdhomerunLive(lineupSource: "Antenna")
    static let cable = SourceID.hdhomerunLive(lineupSource: "Cable")

    static func channel(_ guideNumber: String, _ source: String = "Antenna") -> MediaItemID {
        MediaItemID(channel: ChannelKey(source: source, guideNumber: guideNumber))
    }

    @Test func noTunerMeansNoNetwork() async {
        let world = SourcesWorld()
        await world.home.appear()
        await world.home.appear()
        await world.registry.refreshLineups(force: true)
        await world.registry.updateStatuses()
        world.liveTV.refresh(force: true)
        world.liveTV.startTunerStatus()
        #expect(await world.registry.playbackTarget(for: Self.channel("9.1")) == nil)

        #expect(world.tuners.networkRequests == 0)
        #expect(await world.lineups.fetchCount == 0)
        #expect(world.registry.liveSources.isEmpty)
        #expect(!world.registry.hasLiveTVSource)
        #expect(world.registry.liveTVStatus == .unconfigured)
        #expect(world.registry.status(of: .quickPlay) == .ready)
        #expect(world.liveTV.status == .notConfigured)
        #expect(world.composer.shelf(.favorites)?.emptyMessage == "No Live TV source configured")
        #expect(world.composer.shelf(.liveChannels)?.emptyMessage == "No Live TV source configured")
        world.liveTV.stopTunerStatus()
    }

    @Test func addingTunersConnectsNowhereUntilHomeAppears() async throws {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        #expect(world.registry.liveSources.map(\.id) == [Self.antenna])
        #expect(world.registry.hasLiveTVSource)
        await world.registry.updateStatuses()
        #expect(world.tuners.networkRequests == 0)

        await world.home.appear()
        #expect(world.tuners.lineupRequests == [TunerFixture.antennaHost])
        #expect(world.composer.shelf(.liveChannels)?.keys == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:20.4"])
        #expect(world.composer.shelf(.favorites)?.keys == ["ch:2.1"])
        #expect(world.registry.status(of: Self.antenna) == .ready)
        // Nothing tunes to fill Home.
        #expect(world.tuners.streamRequests == 0)
        // The first answer fills in the tuner's record.
        #expect(await waitUntil { world.sources.hdHomeRuns.first?.deviceID == "1A2B3C4D" })
        #expect(world.sources.hdHomeRuns.first?.lineupSource == "Antenna")
    }

    @Test func oneLogicalSourcePerLineupSource() {
        let world = SourcesWorld()
        world.addTuner(TunerFixture.antennaHost)
        let cable = world.addTuner(TunerFixture.cableHost, lineupSource: "Cable")
        world.addTuner("192.0.2.11", lineupSource: "Antenna")
        #expect(world.registry.liveSources.map(\.id) == [Self.antenna, Self.cable])
        #expect(world.registry.hostsBySource[Self.antenna] == [TunerFixture.antennaHost, "192.0.2.11"])
        let antennaSource = world.registry.liveSources[0]

        world.registry.syncSources()
        #expect(world.registry.liveSources[0] === antennaSource)
        if let cable { world.sources.remove(cable) }
        world.registry.syncSources()
        #expect(world.registry.liveSources.map(\.id) == [Self.antenna])
        #expect(world.registry.liveSources[0] === antennaSource)
        #expect(world.tuners.networkRequests == 0)
    }

    @Test func aTunerThatReportsAnotherLineupSourceMovesToItsSource() async {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.cableHost: TunerFixture.cable]))
        world.addTuner(TunerFixture.cableHost)
        #expect(world.registry.liveSources.map(\.id) == [Self.antenna])
        await world.home.appear()
        #expect(await waitUntil { world.registry.liveSources.map(\.id) == [Self.cable] })
        #expect(await waitUntil { world.composer.shelf(.liveChannels)?.keys == ["ch:702"] })
        // The rebuilt source read the lineup the first answer left in the cache.
        #expect(world.tuners.lineupRequests == [TunerFixture.cableHost])
    }

    @Test func homeAndTheLiveTVPaneShareOneLineupRequest() async {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        world.liveTV.refresh()
        await world.liveTV.waitForRefresh()
        #expect(world.liveTV.channels.map(\.guideNumber) == ["2.1", "4.1", "9.1", "20.4"])
        #expect(world.liveTV.status == .ready(freeTuners: 1, totalTuners: 2))

        await world.home.appear()
        #expect(world.composer.shelf(.liveChannels)?.keys == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:20.4"])
        #expect(world.tuners.lineupRequests == [TunerFixture.antennaHost])
        // status.json is the pane's own (tuner usage); Home never reads it.
        #expect(world.tuners.statusRequests == [TunerFixture.antennaHost])

        // Home's lineup serves the pane too, and a forced refresh still asks the tuner.
        world.liveTV.refresh(force: true)
        await world.liveTV.waitForRefresh()
        #expect(world.tuners.lineupRequests.count == 2)
    }

    @Test func goResolvesChannelsAndQuickPlayItems() async throws {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        world.favorites.toggle("tvch:Antenna:9.1")

        let target = await world.home.playbackTarget(for: Self.channel("9.1"))
        guard case let .channel(channel, list) = target else {
            Issue.record("Expected a channel, got \(String(describing: target))")
            return
        }
        #expect(channel.key == "tvch:Antenna:9.1")
        #expect(channel.streamURL == TunerFixture.url(TunerFixture.antennaHost, "9.1"))
        #expect(channel.favorite == .app)
        #expect(list.map(\.guideNumber) == ["2.1", "4.1", "9.1", "20.4"])
        #expect(list.first?.favorite == .device)
        _ = await world.home.playbackTarget(for: Self.channel("2.1"))
        #expect(world.tuners.lineupRequests == [TunerFixture.antennaHost])
        #expect(await world.home.playbackTarget(for: Self.channel("7.1")) == nil)
        #expect(await world.home.playbackTarget(for: Self.channel("702", "Cable")) == nil)

        let url = try #require(URL(string: "https://streams.example.com/vod/movie.mp4?token=abc"))
        world.history.record(url)
        let item = try #require(ResumeRecorder.itemID(for: .url(url)))
        #expect(await world.home.playbackTarget(for: item) == .url(url))
        #expect(await world.home.playbackTarget(for: MediaItemID(source: .quickPlay, key: "url:00")) == nil)
        #expect(world.tuners.streamRequests == 0)
    }

    @Test func quickPlayHistoryFollowsTheHistoryAndClearingDiscardsHomeCards() async throws {
        let world = SourcesWorld()
        world.settings.setEnabled(.quickPlayHistory, true)
        world.home.apply()
        let movie = try #require(URL(string: "https://streams.example.com/vod/movie.mp4"))
        let live = try #require(URL(string: "https://streams.example.com/live/master.m3u8?token=s3cr3t"))
        world.history.record(movie, at: Date(timeIntervalSince1970: 100))
        world.history.record(live, at: Date(timeIntervalSince1970: 200))
        await world.registry.syncHistory().value
        let movieID = try #require(ResumeRecorder.itemID(for: .url(movie)))
        world.resumePositions.record(movieID, position: .seconds(60), duration: .seconds(600))
        world.home.apply()

        await world.home.appear()
        #expect(world.composer.shelf(.quickPlayHistory)?.items.map(\.title) == ["master.m3u8", "movie.mp4"])
        #expect(world.composer.shelf(.continueWatching)?.items.map(\.id) == [movieID])
        await world.composer.flushSnapshot()
        let cached = await world.snapshots.snapshot?.sources.first { $0.source == .quickPlay }
        #expect(cached?.contributions.flatMap(\.items).count == 2)
        let encoded = try #require(String(bytes: JSONEncoder().encode(world.composer.shelves.flatMap(\.items)),
                                          encoding: .utf8))
        #expect(!encoded.contains("s3cr3t"))

        world.home.disappear()
        world.history.clear()
        await world.registry.syncHistory().value
        world.home.apply()
        // The shelf is on, so it stays with its placeholder; Continue Watching hides while empty.
        #expect(world.composer.shelf(.quickPlayHistory)?.items.isEmpty == true)
        #expect(world.composer.shelf(.quickPlayHistory)?.emptyMessage == "No Quick Play history yet")
        #expect(world.composer.shelf(.continueWatching) == nil)
        #expect(world.resumePositions.points.isEmpty)
        await world.composer.flushSnapshot()
        let afterClear = await world.snapshots.snapshot?.sources.first { $0.source == .quickPlay }
        #expect(afterClear?.contributions.flatMap(\.items).isEmpty ?? true)
        #expect(world.tuners.networkRequests == 0)
    }

    // MARK: - Device records and favorites

    @Test func everyLineupLoadReconcilesAppFavoritesPerLineupSource() async {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        // 2.1 is a favorite on the Antenna tuner; the Cable lineup's 2.1 is another channel.
        for key in ["tvch:Antenna:2.1", "tvch:Antenna:9.1", "tvch:Cable:2.1"] { world.favorites.toggle(key) }

        // Home's own read (not the Live TV pane's) reconciles too.
        await world.home.appear()
        #expect(await waitUntil { world.favorites.keys == ["tvch:Antenna:9.1", "tvch:Cable:2.1"] })
        #expect(await waitUntil { world.composer.shelf(.favorites)?.keys == ["ch:2.1", "ch:9.1"] })
        #expect(world.tuners.statusRequests.isEmpty)
    }

    @Test func aDifferentTunerAtARecordedAddressIsRefused() async throws {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.cable]))
        var config = try #require(world.addTuner(TunerFixture.antennaHost))
        config.deviceID = "1A2B3C4D"
        config.friendlyName = "Test Tuner"
        world.sources.update(config)
        world.registry.syncSources()
        let mismatch = HDHomeRunClientError.deviceMismatch(
            expected: TunerDeviceID(numericValue: 0x1A2B_3C4D), found: TunerDeviceID(numericValue: 0x0C0F_FEE0)
        ).message

        world.liveTV.refresh()
        await world.liveTV.waitForRefresh()
        #expect(world.liveTV.status == .unavailable(mismatch))
        #expect(world.liveTV.channels.isEmpty)
        await world.home.appear()
        #expect(world.registry.status(of: Self.antenna) == .unreachable(mismatch))
        #expect(world.composer.shelf(.liveChannels)?.emptyMessage == mismatch)
        #expect(await world.home.playbackTarget(for: Self.channel("702", "Cable")) == nil)
        // Every request asked for the recorded tuner, and the other tuner's answer changed nothing on record.
        #expect(world.tuners.expectedDeviceIDs.allSatisfy { $0 == TunerDeviceID(numericValue: 0x1A2B_3C4D) })
        #expect(world.sources.hdHomeRuns == [config])
        #expect(world.tuners.streamRequests == 0)
    }

    @Test func aTunerIsExpectedToAnswerAsItDidBefore() async throws {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna])
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)
        world.liveTV.refresh()
        await world.liveTV.waitForRefresh()
        #expect(tuners.expectedDeviceIDs == [nil])
        #expect(await waitUntil { world.sources.hdHomeRuns.first?.deviceID == "1A2B3C4D" })

        // Another device takes the address over: it is refused, not recorded.
        tuners.setLineup(TunerFixture.cable, for: TunerFixture.antennaHost)
        world.liveTV.refresh(force: true)
        await world.liveTV.waitForRefresh()
        #expect(tuners.expectedDeviceIDs.last == TunerDeviceID(numericValue: 0x1A2B_3C4D))
        guard case .unavailable = world.liveTV.status else {
            Issue.record("Expected the pane to say the tuner is unavailable, got \(world.liveTV.status)")
            return
        }
        #expect(world.sources.hdHomeRuns.first?.deviceID == "1A2B3C4D")
        #expect(world.sources.hdHomeRuns.first?.lineupSource == "Antenna")
    }
}
