import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Testing
@testable import Consolation

/// "Go" on a Home card: cached lineups first and only uncached tuners read (all at once), the player opened only
/// in a window that stayed on Home, the latest press winning, and a card no source has said so. Also the panes'
/// refresh delay. Fake tuners and engines: nothing leaves the process.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HomeGoTests {
    static let deadHost = "192.0.2.11"
    static let otherDeadHost = "192.0.2.12"

    static func channel(_ guideNumber: String) -> MediaItemID {
        MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: guideNumber))
    }

    static func makeShell() -> ShellModel {
        let defaults = TestDefaults.make()
        let shell = ShellModel(settings: PillSettings(defaults: defaults), defaults: defaults)
        shell.selection = .home
        return shell
    }

    @Test func goReadsCachedLineupsFirstAndOnlyUncachedTunersAtOnce() async {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna])
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)
        world.addTuner(Self.deadHost, lineupSource: "Antenna")
        await world.home.appear()
        #expect(tuners.lineupRequests.count == 2)

        // The answering tuner's lineup is cached: "go" asks no tuner, dead or alive.
        let target = await world.home.playbackTarget(for: Self.channel("9.1"))
        guard case let .channel(channel, list) = target else {
            Issue.record("Expected a channel, got \(String(describing: target))")
            return
        }
        #expect(channel.guideNumber == "9.1")
        #expect(list.map(\.guideNumber) == ["2.1", "4.1", "9.1", "20.4"])
        #expect(tuners.lineupRequests.count == 2)

        // A channel the cached lineups don't list: only the tuner without a cached lineup is read.
        #expect(await world.home.playbackTarget(for: Self.channel("55.5")) == nil)
        #expect(tuners.lineupRequests.dropFirst(2) == [Self.deadHost])
        #expect(tuners.streamRequests == 0)
    }

    @Test func uncachedTunersAreReadTogether() async {
        let tuners = FakeTuners([:], latency: .milliseconds(200))
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(Self.deadHost)
        world.addTuner(Self.otherDeadHost)

        #expect(await world.home.playbackTarget(for: Self.channel("9.1")) == nil)
        #expect(tuners.lineupRequests.sorted() == [Self.deadHost, Self.otherDeadHost])
        #expect(tuners.maxConcurrentLineupRequests == 2)
    }

    @Test func goOpensThePlayerInTheWindowThatStayedOnHome() async {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        let shell = Self.makeShell()
        let session = PlayerSession.fake()

        #expect(await world.home.go(to: Self.channel("9.1"), in: shell, session: session) == .opened)
        #expect(session.currentChannel?.guideNumber == "9.1")
        #expect(shell.selection == .nowPlaying)
        session.stop()
    }

    @Test func goPlaysWithoutOpeningThePlayerWhenTheWindowMovedOn() async {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna], latency: .milliseconds(300))
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)
        let shell = Self.makeShell()
        let session = PlayerSession.fake()

        let press = Task { await world.home.go(to: Self.channel("9.1"), in: shell, session: session) }
        #expect(await waitUntil { tuners.lineupRequests.count == 1 })
        shell.selection = .liveTV
        #expect(await press.value == .playing)
        #expect(session.currentChannel?.guideNumber == "9.1")
        #expect(shell.selection == .liveTV)
        session.stop()
    }

    @Test func theLatestGoWins() async {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna], latency: .milliseconds(300))
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)
        let shell = Self.makeShell()
        let session = PlayerSession.fake()

        let first = Task { await world.home.go(to: Self.channel("9.1"), in: shell, session: session) }
        #expect(await waitUntil { tuners.lineupRequests.count == 1 })
        let second = await world.home.go(to: Self.channel("4.1"), in: shell, session: session)
        #expect(await first.value == .superseded)
        #expect(second == .opened)
        #expect(session.currentChannel?.guideNumber == "4.1")
        session.stop()
    }

    @Test func playbackStartedElsewhereWinsOverALateGo() async {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna], latency: .milliseconds(300))
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)
        let shell = Self.makeShell()
        let session = PlayerSession.fake()

        let late = Task { await world.home.go(to: Self.channel("20.4"), in: shell, session: session) }
        #expect(await waitUntil { tuners.lineupRequests.count == 1 })
        let url = URL(fileURLWithPath: "/dev/null")
        session.play(url)
        #expect(await late.value == .superseded)
        #expect(session.item == .url(url))
        #expect(shell.selection == .home)
        session.stop()
    }

    @Test func aCardNoSourceHasSaysSo() async {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        let shell = Self.makeShell()
        let session = PlayerSession.fake()

        // 7.1 is DRM: no source can play it.
        #expect(await world.home.go(to: Self.channel("7.1"), in: shell, session: session) == .unavailable)
        #expect(!session.isActive)
        #expect(shell.selection == .home)
        #expect(world.tuners.streamRequests == 0)
    }

    // MARK: - Refresh delay

    @Test func homeRefreshesOnlyAfterItStayedSelected() async {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna])
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)

        // Moving on (the pane's task is cancelled) before the delay passes reads nothing.
        let passing = Task { await world.home.appear(after: .seconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        passing.cancel()
        await passing.value
        world.home.disappear()
        #expect(tuners.networkRequests == 0)

        let staying = Task { await world.home.appear(after: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(tuners.networkRequests == 0)
        await staying.value
        #expect(tuners.lineupRequests == [TunerFixture.antennaHost])
        #expect(world.composer.shelf(.liveChannels)?.keys == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:20.4"])
    }

    @Test func theLiveTVPaneRefreshesOnlyAfterItStayedSelected() async {
        let tuners = FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna])
        let world = SourcesWorld(tuners: tuners)
        world.addTuner(TunerFixture.antennaHost)

        let passing = Task { await world.liveTV.paneAppeared(after: .seconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        passing.cancel()
        await passing.value
        #expect(tuners.networkRequests == 0)

        await world.liveTV.paneAppeared(after: .milliseconds(50))
        await world.liveTV.waitForRefresh()
        #expect(tuners.lineupRequests == [TunerFixture.antennaHost])
        #expect(await waitUntil { !tuners.statusRequests.isEmpty })
        world.liveTV.stopTunerStatus()
    }

    @Test func onlyAppleTVWaitsBeforeRefreshing() {
        #if os(tvOS)
        #expect(ShellModel.paneRefreshDelay == .milliseconds(500))
        #else
        #expect(ShellModel.paneRefreshDelay == .zero)
        #endif
    }
}
