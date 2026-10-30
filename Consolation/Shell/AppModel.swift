//
//  AppModel.swift
//  Consolation
//
//  Owns the app's long-lived models and injects them into the view hierarchy.
//

import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Observation
import PlaybackKit
import SwiftUI

@Observable
final class AppModel {
    /// Hidden sidebar items, for every window. Each window has its own `ShellModel` (`AppWindow`).
    let pillSettings = PillSettings()
    let preferences = PlaybackPreferences()
    let history = QuickPlayHistory()
    let sources = SourceStore()
    let favorites = AppFavorites()
    /// Resume positions of on-demand playback, for Continue Watching.
    let resumePositions = ResumeStore()
    let homeSettings = HomeSettings()
    /// Explains Local Network access before the system's prompt (adding a tuner, a local Quick Play URL).
    let localNetwork = LocalNetworkGate()
    /// Where Home was (the Active Shelf and each shelf's card), restored in every window on the next launch.
    let homePositions = HomePositionStore()
    /// Tuner lineups, shared by the Live TV pane and Home's sources so neither doubles the other's requests.
    let lineups = LineupCache()
    let liveTV: LiveTVModel
    let session: PlayerSession
    let nowPlayingInfo: NowPlayingInfoController
    /// The single owner of tuner connections; idle (no network) until a channel is played.
    let tunerBroker = TunerBroker(fetchStatus: TunerStatusReader.status(of:))
    /// Home's shelves: every source's contributions, local favorites and resume positions, in Settings › Home order.
    /// Idle until Home appears (`HomeModel.appear()`).
    let homeShelves: HomeShelfComposer
    /// The configured sources (MediaSourceKit) and their status. Builds them without connecting.
    let registry: SourceRegistry
    let home: HomeModel
    /// The one owner of game-controller handlers (iPhone, iPad, Mac). Attaches nothing until `start()`.
    let controllers = GameControllers()
    #if !os(tvOS)
    /// The capture card viewer's session (Mac and iPad show it in the Capture Card pane).
    let capture = CaptureSessionManager()
    #endif

    init() {
        // Time-shift files of a run that was killed mid-stream.
        TransportStreamEngine.removeLeftoverTimeShiftFiles()
        liveTV = LiveTVModel(sources: sources, favorites: favorites, lineups: lineups, broker: tunerBroker)
        homeShelves = HomeShelfComposer(configuration: homeSettings.configuration,
                                        snapshotStore: FileHomeSnapshotStore(fileURL: Self.homeSnapshotURL))
        registry = SourceRegistry(store: sources, history: history, lineups: lineups, broker: tunerBroker,
                                  composer: homeShelves, favorites: favorites, resumePositions: resumePositions)
        home = HomeModel(composer: homeShelves, registry: registry, favorites: favorites,
                         resumePositions: resumePositions, settings: homeSettings)
        let factory = EngineFactory(preferences: preferences, broker: tunerBroker)
        session = PlayerSession(preferences: preferences,
                                capacity: TunerTileCapacity(broker: tunerBroker)) { item, tile, isAdded in
            factory.makeEngine(for: item, tile: tile, isAdded: isAdded)
        }
        session.resumeRecorder = ResumeRecorder(store: resumePositions, history: history)
        nowPlayingInfo = NowPlayingInfoController(session: session)
    }

    /// Settings › Multi-view's tuner rules, for the broker (at launch and whenever they change).
    func applyTunerSettings() {
        let reserve = preferences.tunerReserve
        let policy: MultiplexPolicy = switch preferences.multiplexSharing {
        case .never: .never
        case .whenTunersAreShort: .whenTunersAreShort
        case .always: .always
        }
        let broker = tunerBroker
        Task {
            await broker.setReserve(reserve)
            await broker.setMultiplexPolicy(policy)
        }
    }

    /// Caches/<bundle ID>/home-snapshot.json: Home renders from it at launch. The system may purge it.
    static var homeSnapshotURL: URL {
        URL.cachesDirectory.appending(path: AppIdentifier.bundleID, directoryHint: .isDirectory)
            .appending(path: "home-snapshot.json", directoryHint: .notDirectory)
    }
}

extension View {
    /// Injects every app model into the environment.
    func appEnvironment(_ app: AppModel) -> some View {
        environment(app.pillSettings)
            .environment(app.preferences)
            .environment(app.history)
            .environment(app.sources)
            .environment(app.favorites)
            .environment(app.liveTV)
            .environment(app.session)
            .environment(app.registry)
            .environment(app.localNetwork)
            .environment(app.home)
            .environment(app.homeSettings)
            .environment(app.controllers)
            .captureEnvironment(app)
    }

    @ViewBuilder
    fileprivate func captureEnvironment(_ app: AppModel) -> some View {
        #if os(tvOS)
        self
        #else
        environment(app.capture)
        #endif
    }
}

/// Reads a tuner's `status.json` for the broker's free-tuner checks. Runs only while a channel is being tuned.
nonisolated enum TunerStatusReader {
    static func status(of ref: DeviceChannelRef) async throws(HDHomeRunClientError) -> [TunerStatus] {
        guard let host = ref.url.host() else { throw .invalidHost(ref.url.absoluteString) }
        return try await HDHomeRunClient(host: host).status()
    }
}
