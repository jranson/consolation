//
//  SourceRegistry.swift
//  Consolation
//
//  The configured sources as MediaSourceKit sources: one HDHomeRun live source per lineup Source, built from the
//  tuners in SourceStore, one source per library server (Bullpen, Plex), and the Quick Play history. Settings, the
//  Live TV pane and the "no source" banners read them and their status here, and Home's composer hears of every
//  change. Building sources connects nowhere; with no source added nothing here ever touches the network (privacy
//  promise).
//

import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Observation

@Observable
final class SourceRegistry {
    /// How a source reads one configured tuner.
    typealias ProviderFactory = (HDHomeRunSourceConfig) -> any TunerLineupProviding

    /// HDHomeRun live TV, one source per lineup Source (`hdhr-live:Antenna`), in order of that name.
    private(set) var liveSources: [HDHomeRunSource] = []
    /// Library servers (Bullpen, then Plex), in the order they were added.
    private(set) var librarySources: [any LibraryServerSource] = []
    /// Each source's last known status. Reading it never connects.
    private(set) var statuses: [SourceID: SourceStatus] = [:]
    /// The Quick Play history as a source. It never connects.
    let quickPlay: QuickPlaySource
    /// Lineups shared with the Live TV pane.
    let lineups: LineupCache

    let store: SourceStore
    let history: QuickPlayHistory
    private let broker: TunerBroker
    private let composer: HomeShelfComposer
    private let favorites: AppFavorites?
    private let resumePositions: ResumeStore?
    private let makeProvider: ProviderFactory
    let credentials: SourceCredentials
    /// The hosts behind each live source, so only a source whose tuners changed is rebuilt.
    @ObservationIgnored private(set) var hostsBySource: [SourceID: [String]] = [:]
    /// The address behind each library source, so only a server whose address changed is rebuilt.
    @ObservationIgnored private var addressesBySource: [SourceID: String] = [:]
    @ObservationIgnored private var historyWasEmpty: Bool
    @ObservationIgnored private var historyPush: Task<Void, Never>?
    @ObservationIgnored private var fetchesTask: Task<Void, Never>?

    /// - Parameters:
    ///   - composer: Home's composer; told the sources now and after every change.
    ///   - favorites: the app's favorites, reconciled with the tuners' own on every lineup a tuner sends.
    ///   - resumePositions: Quick Play positions follow the history (cleared with it).
    ///   - makeProvider: reads a tuner; by default through `lineups`. Tests inject fixtures.
    init(store: SourceStore, history: QuickPlayHistory, lineups: LineupCache, broker: TunerBroker,
         composer: HomeShelfComposer, favorites: AppFavorites? = nil, resumePositions: ResumeStore? = nil,
         credentials: SourceCredentials = SourceCredentials(), makeProvider: ProviderFactory? = nil) {
        self.credentials = credentials
        self.store = store
        self.history = history
        self.lineups = lineups
        self.broker = broker
        self.composer = composer
        self.favorites = favorites
        self.resumePositions = resumePositions
        self.makeProvider = makeProvider ?? { config in
            let host = config.host
            return CachedLineupProvider(host: host, expectedDeviceID: { store.recordedDeviceID(host: host) },
                                        cache: lineups)
        }
        let entries = Self.historyEntries(history)
        quickPlay = QuickPlaySource(history: entries)
        historyWasEmpty = entries.isEmpty
        syncLibraries()
        syncSources(tellingComposer: true)
        if entries.isEmpty {
            // Cleared while Home was last cached: its cards never come back from the snapshot.
            composer.discardContributions(from: quickPlay.id)
        }
        trackStore()
        trackHistory()
        fetchesTask = Task { [weak self, lineups] in
            for await fetch in lineups.fetches { self?.lineupFetched(fetch) }
        }
    }

    isolated deinit {
        fetchesTask?.cancel()
        historyPush?.cancel()
    }

    /// Every source, live TV first, then the library servers.
    var allSources: [any MediaSource] { liveSources + librarySources + [quickPlay] }

    /// At least one library server is added.
    var hasLibrarySource: Bool { !librarySources.isEmpty }

    /// The library source with `id`, if one is configured.
    func librarySource(_ id: SourceID) -> (any LibraryServerSource)? {
        librarySources.first { $0.id == id }
    }

    /// At least one tuner is added. Without one, Live TV and Home show their "no source" banners.
    var hasLiveTVSource: Bool { !liveSources.isEmpty }

    func status(of id: SourceID) -> SourceStatus {
        statuses[id] ?? .unconfigured
    }

    /// Live TV as one status for banners: unconfigured without a tuner, otherwise the best any lineup has.
    var liveTVStatus: SourceStatus {
        guard !liveSources.isEmpty else { return .unconfigured }
        let known = liveSources.map { status(of: $0.id) }
        if known.contains(.ready) { return .ready }
        return known.first { if case .degraded = $0 { true } else { false } }
            ?? known.first { $0 == .connecting }
            ?? known.first ?? .ready
    }

    /// Rereads every lineup older than its source's limit (10 minutes), or all of them with `force`, then the
    /// statuses. With no tuner added it does nothing.
    func refreshLineups(force: Bool = false) async {
        let sources = liveSources
        guard !sources.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { try? await source.refresh(force: force) }
            }
        }
        await updateStatuses()
    }

    /// Reads every source's status (no network).
    func updateStatuses() async {
        let sources = allSources
        var read: [SourceID: SourceStatus] = [:]
        for source in sources { read[source.id] = await source.status() }
        let current = Set(allSources.map(\.id))
        let next = read.filter { current.contains($0.key) }
        if next != statuses { statuses = next }
    }

    // MARK: - Tuners

    /// Rebuilds the live sources from the stored tuners: one per lineup Source, kept as is while its tuners stay
    /// the same. Tells the composer when the list changed, and forgets removed tuners' lineups.
    func syncSources(tellingComposer force: Bool = false) {
        let groups = Dictionary(grouping: store.hdHomeRuns) { $0.lineupSourceName }
        var next: [HDHomeRunSource] = []
        var nextHosts: [SourceID: [String]] = [:]
        for name in groups.keys.sorted() {
            let configs = groups[name] ?? []
            let id = SourceID.hdhomerunLive(lineupSource: name)
            let hosts = configs.map { $0.host.lowercased() }
            nextHosts[id] = hosts
            if let existing = liveSources.first(where: { $0.id == id }), hostsBySource[id] == hosts {
                next.append(existing)
            } else {
                next.append(HDHomeRunSource(lineupSource: name, devices: configs.map(makeProvider), broker: broker))
            }
        }
        let removedHosts = Set(hostsBySource.values.joined()).subtracting(nextHosts.values.joined())
        hostsBySource = nextHosts
        let changed = next.count != liveSources.count || zip(next, liveSources).contains { $0 !== $1 }
        guard changed || force else { return }
        liveSources = next
        composer.setSources(allSources)
        let lineups = lineups
        Task {
            for host in removedHosts { await lineups.forget(host: host) }
            await updateStatuses()
        }
    }

    /// A tuner answered: keep its record current (its lineup Source decides which live source it feeds), drop app
    /// favorites the tuner now marks itself (whoever asked: Home, "go" or the Live TV pane), and, when the Live TV
    /// pane asked, let Home's source reread it from the cache so both show the same lineup.
    private func lineupFetched(_ fetch: LineupFetch) {
        let host = fetch.host.lowercased()
        let config = store.hdHomeRuns.first { $0.host.lowercased() == host }
        if let config {
            let updated = config.recording(fetch.lineup)
            if updated != config { store.update(updated) }
        }
        let sourceName = fetch.lineup.lineupSource ?? config?.lineupSourceName
            ?? HDHomeRunSourceConfig.defaultLineupSource
        favorites?.reconcile(deviceFavorites: Set(fetch.lineup.channels.filter(\.isFavorite).map {
            $0.channelKey(source: sourceName).stringValue
        }))
        guard fetch.origin == .liveTVPane else { return }
        for source in liveSources where hostsBySource[source.id]?.contains(host) == true {
            Task { [weak self] in
                try? await source.refresh(force: true)
                await self?.updateStatuses()
            }
        }
    }

    private func trackStore() {
        withObservationTracking {
            _ = store.hdHomeRuns
            _ = store.bullpens
            _ = store.plexServers
        } onChange: { [weak self] in
            Task { @MainActor in
                let librariesChanged = self?.syncLibraries() ?? false
                self?.syncSources(tellingComposer: librariesChanged)
                self?.trackStore()
            }
        }
    }

    // MARK: - Library servers

    /// Rebuilds the library sources from the stored servers, keeping each one whose address is unchanged. Returns
    /// whether the list changed (the caller tells the composer). Building a source connects nowhere.
    @discardableResult
    func syncLibraries() -> Bool {
        var next: [any LibraryServerSource] = []
        var nextAddresses: [SourceID: String] = [:]
        // A server is rebuilt only when how it is reached changed (its address, or whether it uses a token).
        func reuse(_ id: SourceID, reachedAs address: String, make: () -> (any LibraryServerSource)?) {
            nextAddresses[id] = address
            if let existing = librarySources.first(where: { $0.id == id }), addressesBySource[id] == address {
                next.append(existing)
            } else if let made = make() {
                next.append(made)
            }
        }
        for config in store.bullpens {
            reuse(config.sourceID, reachedAs: config.address) {
                guard let base = URL(string: config.address) else { return nil }
                let fetcher = RemoteDocumentFetcher(userAgent: "\(AppIdentifier.name)/\(BuildInfo.version)")
                return BullpenSource(id: config.sourceID, name: config.name,
                                     client: BullpenClient(baseURL: base, fetcher: fetcher))
            }
        }
        for config in store.plexServers {
            reuse(config.sourceID, reachedAs: "\(config.address) token:\(config.usesToken)") {
                guard let base = URL(string: config.address) else { return nil }
                let token = config.usesToken ? credentials.token(for: config.sourceID) : nil
                return PlexSource(id: config.sourceID, name: config.name,
                                  client: PlexClient(baseURL: base, token: token, client: SourceCredentials.plexClient))
            }
        }
        addressesBySource = nextAddresses
        let changed = next.count != librarySources.count || zip(next, librarySources).contains { $0 !== $1 }
        if changed { librarySources = next }
        return changed
    }

    /// Builds the library source with `id` again (its token changed), keeping its place.
    func rebuildLibrary(_ id: SourceID) {
        addressesBySource[id] = nil
        syncSources(tellingComposer: syncLibraries())
    }

    /// Rereads every library server's Home shelves (Home appeared). With no server added it does nothing.
    func refreshLibraries() async {
        let sources = librarySources
        await withTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { await source.refresh() } }
        }
    }

    // MARK: - Quick Play history

    /// Hands the history to the Quick Play source. When it became empty (cleared, or turned off), Home's Quick Play
    /// cards are discarded too, so they never return from the snapshot; positions of videos no longer in the
    /// history go with them.
    @discardableResult
    func syncHistory() -> Task<Void, Never> {
        let entries = Self.historyEntries(history)
        let isCleared = entries.isEmpty && !historyWasEmpty
        historyWasEmpty = entries.isEmpty
        resumePositions?.retain(source: quickPlay.id,
                                keys: Set(entries.map { QuickPlaySource.itemKey(for: $0.url) }))
        let previous = historyPush
        let source = quickPlay
        let composer = composer
        let push = Task {
            await previous?.value
            await source.setHistory(entries)
            if isCleared { composer.discardContributions(from: source.id) }
        }
        historyPush = push
        return push
    }

    private func trackHistory() {
        withObservationTracking { _ = history.entries } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncHistory()
                self?.trackHistory()
            }
        }
    }

    private static func historyEntries(_ history: QuickPlayHistory) -> [QuickPlayHistoryEntry] {
        history.entries.map { QuickPlayHistoryEntry(url: $0.url, lastPlayed: $0.lastPlayed) }
    }
}
