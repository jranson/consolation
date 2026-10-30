import Foundation
import MediaSourceKit
import Testing
@testable import Consolation

/// What Home's placeholders and the remote's Play/Pause do, and the Mac pill's arrows. Pure rules: no views, no
/// network.
@MainActor
struct HomeActionsTests {
    static let library = HomeShelfKind.library(SourceID(raw: "plex:0f0e0d0c"), sectionKey: "1").stableID

    @Test func liveShelvesSendTheUserWhereTheFixIs() {
        for shelf in ["favorites", "liveChannels"] {
            #expect(EmptyShelfAction.forShelf(shelf, hasLiveTVSource: false, liveTVStatus: .unconfigured)
                    == .settings(.sources), "no Live TV source: Settings › Sources")
            #expect(EmptyShelfAction.forShelf(shelf, hasLiveTVSource: true, liveTVStatus: .localNetworkDenied)
                    == .localNetworkSettings, "Local Network access off: the system's setting")
            for status in [SourceStatus.ready, .connecting, .degraded("1 of 2 tuners didn't answer."),
                           .unreachable("Can't reach the HDHomeRun at tuner.local.")] {
                #expect(EmptyShelfAction.forShelf(shelf, hasLiveTVSource: true, liveTVStatus: status)
                        == .pane(.liveTV), "a tuner is added: the Live TV pane (\(status))")
            }
        }
    }

    @Test func otherShelvesOpenSettingsOrQuickPlay() {
        #expect(EmptyShelfAction.forShelf("quickPlayHistory", hasLiveTVSource: true, liveTVStatus: .ready)
                == .pane(.quickPlay))
        for shelf in ["recentRecordings", "recordingNow", "continueWatching", Self.library, "not-a-shelf"] {
            for hasSource in [false, true] {
                #expect(EmptyShelfAction.forShelf(shelf, hasLiveTVSource: hasSource, liveTVStatus: .ready)
                        == .settings(.sources), "\(shelf): no DVR or library source yet")
            }
        }
    }

    @Test func homeReadsTheRegistryForItsPlaceholders() async {
        let world = SourcesWorld()
        #expect(world.home.emptyShelfAction(for: "favorites") == .settings(.sources))
        world.addTuner(TunerFixture.antennaHost)
        await world.registry.updateStatuses()
        #expect(world.home.emptyShelfAction(for: "favorites") == .pane(.liveTV))
        #expect(world.tuners.networkRequests == 0)
    }

    @Test func playPauseDismissesTheMiniPlayerOnlyWhileSomethingPlays() {
        for pane in ShellItem.allCases where pane != .nowPlaying {
            #expect(ShellModel.playPauseDismissesMiniPlayer(isPlaying: true, selection: pane))
            #expect(!ShellModel.playPauseDismissesMiniPlayer(isPlaying: false, selection: pane),
                    "nothing plays: Home plays the Active ShelfCard")
        }
        #expect(!ShellModel.playPauseDismissesMiniPlayer(isPlaying: true, selection: .nowPlaying))
    }

    @Test func thePillsArrowsMoveTheSelectionWithoutWrapping() {
        let defaults = TestDefaults.make()
        let settings = PillSettings(defaults: defaults)
        settings.setHidden(.library, true)
        let shell = ShellModel(settings: settings, defaults: defaults)
        shell.selection = .home
        shell.selectAdjacentItem(by: -1)
        #expect(shell.selection == .home)
        var visited: [ShellItem] = [shell.selection]
        for _ in 0..<6 {
            shell.selectAdjacentItem(by: 1)
            visited.append(shell.selection)
        }
        // The tests run on the Mac, which has the Capture Card item just above Settings.
        #expect(visited == [.home, .liveTV, .quickPlay, .nowPlaying, .captureCard, .settings, .settings])
        shell.selectAdjacentItem(by: -1)
        #expect(shell.selection == .captureCard)

        let requests = (shell.pillFocusRequest, shell.contentFocusRequest)
        shell.focusPill()
        shell.focusContent()
        #expect(shell.pillFocusRequest == requests.0 + 1)
        #expect(shell.contentFocusRequest == requests.1 + 1)
    }
}
