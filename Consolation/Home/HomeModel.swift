//
//  HomeModel.swift
//  Consolation
//
//  Home's data in the app: feeds the shelf composer what only this device knows (local favorites, resume
//  positions, Settings › Home), and gives the Home pane its lifecycle and "go". The sources come from
//  SourceRegistry; HomeView shows the shelves on each window's Etagere (HomeEtagere).
//

import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Observation

@Observable
final class HomeModel {
    /// Home's shelves (`composer.shelves`), in Settings › Home order.
    let composer: HomeShelfComposer
    let settings: HomeSettings
    private let registry: SourceRegistry
    private let favorites: AppFavorites
    private let resumePositions: ResumeStore
    @ObservationIgnored private var hasStarted = false
    /// Windows showing Home now (Mac and iPad can show it in several).
    @ObservationIgnored private var visibleCount = 0
    /// Counts "go" presses, so only the latest one plays.
    @ObservationIgnored private var goCount = 0

    init(composer: HomeShelfComposer, registry: SourceRegistry, favorites: AppFavorites,
         resumePositions: ResumeStore, settings: HomeSettings) {
        self.composer = composer
        self.registry = registry
        self.favorites = favorites
        self.resumePositions = resumePositions
        self.settings = settings
        apply()
        track()
    }

    /// The shelves to show, in order.
    var shelves: [HomeShelf] { composer.shelves }

    /// Home appeared (call it from the pane's `.task`): the snapshot first (on the first appearance), then, once the
    /// pane has stayed selected for `delay` (`ShellModel.paneRefreshDelay`), every source's latest, and lineups
    /// older than 10 minutes and library servers' shelves are reread. Cancelling the task meanwhile (the selection
    /// moved on) skips the refresh. With no source added this reads no network.
    func appear(after delay: Duration = .zero) async {
        visibleCount += 1
        if !hasStarted {
            hasStarted = true
            await composer.loadSnapshot()
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !Task.isCancelled else { return }
        let registry = registry
        async let lineups: Void = registry.refreshLineups()
        async let libraries: Void = registry.refreshLibraries()
        await composer.refresh()
        await lineups
        await libraries
    }

    /// Home was hidden (call it from `.onDisappear`). Once no window shows it, the composer stops listening; the
    /// shelves keep what they show.
    func disappear() {
        visibleCount = max(visibleCount - 1, 0)
        if visibleCount == 0 { composer.stop() }
    }

    /// What to play for a card, through the registry; play it with `PlayerSession.play(_:)`.
    func playbackTarget(for id: MediaItemID) async -> PlaybackTarget? {
        let favorites = favorites
        return await registry.playbackTarget(for: id) { favorites.mark(for: $0, isDeviceFavorite: $1) }
    }

    /// "Go" on a card: resolves it, plays it, and opens the player in `shell`'s window, unless that window moved to
    /// another pane while the card resolved (then the mini player shows it there). A later "go", or playback started
    /// anywhere else meanwhile, wins: this one then does nothing.
    func go(to id: MediaItemID, in shell: ShellModel, session: PlayerSession) async -> GoResult {
        goCount += 1
        let press = goCount
        let selection = shell.selection
        let playing = session.item
        let target = await playbackTarget(for: id)
        guard press == goCount, session.item == playing else { return .superseded }
        guard let target else { return .unavailable }
        session.play(target)
        guard shell.selection == selection else { return .playing }
        shell.selection = .nowPlaying
        return .opened
    }

    /// "Add to Multi-view" on a card: resolves it and adds it as a tile (or plays it, with nothing playing).
    /// Returns false when no configured source has the item now.
    func addToMultiView(_ id: MediaItemID, session: PlayerSession) async -> Bool {
        guard let target = await playbackTarget(for: id) else { return false }
        switch target {
        case let .channel(channel, list): await session.addToMultiView(.channel(channel), channels: list)
        case .url(let url): await session.addToMultiView(.url(url))
        case .media(let media): await session.addToMultiView(.media(media))
        }
        return true
    }

    /// What "go" on an empty shelf's placeholder does now, from the sources' state.
    func emptyShelfAction(for shelfID: String) -> EmptyShelfAction {
        EmptyShelfAction.forShelf(shelfID, hasLiveTVSource: registry.hasLiveTVSource,
                                  liveTVStatus: registry.liveTVStatus)
    }

    /// Hands the composer the current settings, local favorites and resume positions.
    func apply() {
        let configuration = settings.configuration
        if composer.configuration != configuration { composer.configuration = configuration }
        let local = LocalHomeState(
            favorites: Self.localFavorites(favorites.keys),
            resumePoints: Self.continueWatching(resumePositions.unfinished,
                                                showsQuickPlay: settings.isEnabled(.quickPlayHistory)))
        if composer.localState != local { composer.localState = local }
    }

    /// The resume positions Continue Watching may show. Videos played from Quick Play stay out unless the Quick
    /// Play History shelf is on: Home is the screen others see most, and their names come from URLs that can carry
    /// tokens (the same reason that shelf is off by default).
    static func continueWatching(_ points: [ResumePoint], showsQuickPlay: Bool) -> [ResumePoint] {
        showsQuickPlay ? points : points.filter { $0.item.source != .quickPlay }
    }

    /// App favorites are channel keys (`tvch:Antenna:9.1`); Home knows them as live items, in channel order.
    static func localFavorites(_ keys: Set<String>) -> [MediaItemID] {
        keys.compactMap(ChannelKey.init(stringValue:)).sorted().map(MediaItemID.init(channel:))
    }

    private func track() {
        withObservationTracking {
            _ = settings.shelves
            _ = favorites.keys
            _ = resumePositions.points
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.track()
            }
        }
    }
}
