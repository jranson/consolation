//
//  LiveTVModel.swift
//  Consolation
//
//  Loads the lineup from the user's HDHomeRuns and turns it into the app's channel list. Never touches the
//  network unless a source was added (privacy promise), and never tunes a channel (only JSON requests). Lineups
//  come through the shared `LineupCache`, so Home's sources and this pane never both ask a tuner within a minute.
//

import Foundation
import HTTPMPEG2Kit
import Observation

@Observable
final class LiveTVModel {
    /// Reads one tuner's `status.json`.
    typealias StatusReader = @Sendable () async throws(HDHomeRunClientError) -> [TunerStatus]
    /// A status reader for a host, or nil when it isn't one. Making it connects nowhere.
    typealias StatusReaderFactory = (String) -> StatusReader?

    /// Lineup refresh interval while the pane is visible.
    static let refreshInterval: TimeInterval = 600

    private let sources: SourceStore
    private let favorites: AppFavorites
    private let lineupCache: LineupCache
    private let broker: TunerBroker?
    private let makeStatusReader: StatusReaderFactory

    private(set) var status: LiveTVSourceStatus = .notConfigured
    /// Every playable channel of every configured tuner, sorted by channel number. A channel several tuners carry
    /// is listed once, with each of them as a route.
    private(set) var channels: [LiveChannel] = []
    /// What each configured tuner is doing, refreshed every few seconds while the Live TV pane is visible.
    private(set) var devices: [DeviceTuners] = []
    /// The tuners carrying our own streams (`X-HDHomeRun-Resource`), by device.
    private(set) var ourTuners: [TunerDeviceID?: Set<String>] = [:]

    /// Settings › Live TV › Show ATSC 3.0 channels.
    var showsATSC3 = false {
        didSet { if showsATSC3 != oldValue { remark() } }
    }

    /// Every tuner of every device, for the free-tuner count.
    var tuners: [TunerStatus] { devices.flatMap(\.tuners) }

    static let statusInterval: Duration = .seconds(5)
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    var viewMode: LiveTVViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: LiveTVViewMode.storageKey) }
    }

    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Raw lineup per source, kept so favorites can be re-marked without a network round trip.
    @ObservationIgnored private var lineups: [LoadedLineup] = []

    /// - Parameters:
    ///   - lineups: shared with Home's sources.
    ///   - makeStatusReader: reads `status.json`; tests inject fakes.
    init(sources: SourceStore, favorites: AppFavorites, lineups: LineupCache = LineupCache(),
         broker: TunerBroker? = nil, makeStatusReader: @escaping StatusReaderFactory = LiveTVModel.statusReader) {
        self.sources = sources
        self.favorites = favorites
        lineupCache = lineups
        self.broker = broker
        self.makeStatusReader = makeStatusReader
        let saved = UserDefaults.standard.string(forKey: LiveTVViewMode.storageKey)
        viewMode = saved.flatMap(LiveTVViewMode.init(rawValue:)) ?? LiveTVViewMode.defaultMode
    }

    var visibleChannels: [LiveChannel] { viewMode.apply(to: channels) }

    /// One client per reader, created without connecting.
    nonisolated static func statusReader(host: String) -> StatusReader? {
        guard let client = try? HDHomeRunClient(host: host) else { return nil }
        return { () async throws(HDHomeRunClientError) -> [TunerStatus] in try await client.status() }
    }

    /// Reloads the lineup unless it was loaded recently. `force` reloads now.
    func refresh(force: Bool = false) {
        let configs = sources.hdHomeRuns
        guard !configs.isEmpty else {
            refreshTask?.cancel()
            status = .notConfigured
            channels = []
            lineups = []
            return
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval,
           !channels.isEmpty {
            return
        }
        refreshTask?.cancel()
        if channels.isEmpty { status = .loading }
        refreshTask = Task { await load(configs, force: force) }
    }

    /// The Live TV pane appeared (call it from its `.task`): once it has stayed selected for `delay`
    /// (`ShellModel.paneRefreshDelay`), the lineup is refreshed and the tuners' status polled until
    /// `stopTunerStatus()`. Cancelling the task meanwhile (the selection moved on) skips both.
    func paneAppeared(after delay: Duration = .zero) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !Task.isCancelled else { return }
        refresh()
        startTunerStatus()
    }

    /// Waits for the refresh that is running, if any (tests).
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Polls every tuner's status while the pane is visible; call `stopTunerStatus()` when it disappears.
    func startTunerStatus() {
        let readers = sources.hdHomeRuns.compactMap { config in
            makeStatusReader(config.host).map { (config, $0) }
        }
        guard statusTask == nil, !readers.isEmpty else { return }
        let broker = broker
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                var read: [DeviceTuners] = []
                for (config, readStatus) in readers {
                    if let status = try? await readStatus() { read.append(DeviceTuners(config, tuners: status)) }
                }
                if !read.isEmpty {
                    let routes = await broker?.openRoutes ?? []
                    self?.ourTuners = Dictionary(grouping: routes, by: \.deviceID)
                        .mapValues { Set($0.compactMap(\.resource)) }
                    self?.updateTuners(read)
                }
                try? await Task.sleep(for: Self.statusInterval)
            }
        }
    }

    func stopTunerStatus() {
        statusTask?.cancel()
        statusTask = nil
    }

    /// The tuners `ourTuners` says carry our streams on `device`.
    func ours(on device: DeviceTuners) -> Set<String> {
        ourTuners[device.deviceID] ?? ourTuners[nil] ?? []
    }

    private func updateTuners(_ read: [DeviceTuners]) {
        devices = read
        if case .ready = status {
            status = .ready(freeTuners: tuners.filter { !$0.isInUse }.count, totalTuners: tuners.count)
        }
    }

    func toggleFavorite(_ channel: LiveChannel) {
        guard channel.favorite != .device else { return }
        favorites.toggle(channel.key)
        remark()
    }

    /// Reads every tuner's lineup (a fresh one when forced; otherwise one Home read within the last minute will do),
    /// then their status. A tuner that doesn't answer leaves the others' channels in place.
    private func load(_ configs: [HDHomeRunSourceConfig], force: Bool) async {
        var loaded: [LoadedLineup] = []
        var read: [DeviceTuners] = []
        var firstError: HDHomeRunClientError?
        var totalTuners = 0
        for config in configs {
            do throws(HDHomeRunClientError) {
                let device = try await lineupCache.lineup(host: config.host, expecting: config.tunerDeviceID,
                                                          maxAge: force ? .zero : LineupCache.sharingWindow,
                                                          origin: .liveTVPane)
                guard !Task.isCancelled else { return }
                let updated = config.recording(device)
                if updated != config { sources.update(updated) }
                if let status = try? await makeStatusReader(config.host)?() {
                    read.append(DeviceTuners(updated, tuners: status))
                } else {
                    totalTuners += device.discovery.tunerCount ?? 0
                }
                loaded.append(LoadedLineup(source: device.lineupSource ?? config.lineupSourceName,
                                           deviceID: device.discovery.deviceID,
                                           modelNumber: device.discovery.modelNumber, channels: device.channels))
            } catch {
                guard !Task.isCancelled, error != .cancelled else { return }
                firstError = firstError ?? error
            }
        }
        guard !Task.isCancelled else { return }
        if loaded.isEmpty, let firstError {
            status = .unavailable(firstError.message)
            return
        }
        if !read.isEmpty { devices = read }
        lineups = loaded
        lastRefresh = Date()
        let deviceFavorites = loaded.flatMap { lineup in
            lineup.channels.filter(\.isFavorite).map { $0.channelKey(source: lineup.source).stringValue }
        }
        favorites.reconcile(deviceFavorites: Set(deviceFavorites))
        remark()
        let free = read.isEmpty ? nil : tuners.filter { !$0.isInUse }.count
        let total = tuners.count + totalTuners
        status = channels.isEmpty ? .noChannels : .ready(freeTuners: free, totalTuners: total > 0 ? total : nil)
    }

    /// Rebuilds `channels` from the cached lineup with current favorite marks.
    private func remark() {
        let favorites = favorites
        let includesATSC3 = showsATSC3
        channels = LiveChannel.merging(lineups.map { lineup in
            LiveChannel.channels(from: lineup.channels, lineupSource: lineup.source, deviceID: lineup.deviceID,
                                 modelNumber: lineup.modelNumber, includesATSC3: includesATSC3) {
                favorites.mark(for: $0, isDeviceFavorite: $1)
            }
        })
    }
}

/// One tuner's raw lineup, kept so favorites can be re-marked without a network round trip.
private struct LoadedLineup {
    let source: String
    let deviceID: TunerDeviceID
    let modelNumber: String?
    let channels: [LineupChannel]
}

/// One configured tuner's `status.json`, for the tuner usage panel.
struct DeviceTuners: Identifiable, Hashable {
    let id: String
    let deviceID: TunerDeviceID?
    /// The tuner's friendly name, or its host.
    let name: String
    let tuners: [TunerStatus]

    init(_ config: HDHomeRunSourceConfig, tuners: [TunerStatus]) {
        id = config.host
        deviceID = config.tunerDeviceID
        name = config.friendlyName ?? config.host
        self.tuners = tuners
    }
}
