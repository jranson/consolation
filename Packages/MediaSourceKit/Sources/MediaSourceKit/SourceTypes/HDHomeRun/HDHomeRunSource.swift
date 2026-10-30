import Foundation
import HTTPMPEG2Kit

/// HDHomeRun live TV as a `MediaSource`: one logical source per lineup Source (`hdhr-live:Antenna`), backed by every
/// configured device with that Source.
///
/// - Items are `ch:<GuideNumber>`, a 1:1 mapping of `ChannelKey`; DeviceIDs pick devices inside the broker and never
///   appear in an item ID. Two devices that both list 7.1 give one item with two broker routes.
/// - `children(of: nil)` lists playable channels (a URL, subscribed, no DRM, not ATSC 3.0) in numeric guide order;
///   `isFavorite` comes from `"Favorite":1` (or `favorite` in the legacy `Tags`) on any device.
/// - `playback(for:)` subscribes through the `TunerBroker`; one `TunerLease` is both the transport and the lease,
///   and follows the engine's reconnects. Nothing tunes until the user plays a channel, and no thumbnail ever tunes.
/// - No network until a method that needs the lineup is called (`id`, `kind`, `capabilities()` and `status()` never
///   connect). Shelf contributions (Favorites, Live TV Channels) are published when the lineup changes, never on a
///   timer; the app calls `refresh()` when the lineup may have changed (the Live TV pane appears, for example).
///   While no lineup has ever loaded, every failed load publishes empty shelves, so Home learns that the source
///   answered and reads why from `status()` instead of waiting for it.
public actor HDHomeRunSource: MediaSource {
    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.hdhomerun
    /// The lineup Source this logical source stands for, for example `Antenna`.
    public nonisolated let lineupSource: String

    private let devices: [any TunerLineupProviding]
    private let broker: TunerBroker
    private let maxLineupAge: Duration

    private var lineup: LiveLineup?
    private var loadedAt: ContinuousClock.Instant?
    private var loadedDate = Date.distantPast
    private var loading: Task<[Result<TunerLineup, HDHomeRunClientError>], Never>?
    private var lastLoadError: HDHomeRunClientError?
    private var currentStatus: SourceStatus
    private var observers = ContributionObservers()
    private var publishedItems: [MediaItem]?
    /// How many times the channels changed and were published (tests check that unchanged lineups publish nothing).
    private(set) var publishCount = 0

    /// - Parameters:
    ///   - lineupSource: the lineup Source (`Antenna`, `Cable`). Devices that report another Source are skipped.
    ///   - devices: every configured device with that Source, in order of preference.
    ///   - broker: the app's single tuner broker.
    ///   - maxLineupAge: `refresh()` reloads a lineup older than this.
    public init(lineupSource: String, devices: [any TunerLineupProviding], broker: TunerBroker,
                maxLineupAge: Duration = .seconds(600)) {
        id = .hdhomerunLive(lineupSource: lineupSource)
        self.lineupSource = lineupSource
        self.devices = devices
        self.broker = broker
        self.maxLineupAge = maxLineupAge
        currentStatus = devices.isEmpty ? .unconfigured : .ready
    }

    public func capabilities() -> SourceCapabilities {
        [.browse, .liveTV, .tunerAccounting, .directPlay]
    }

    public func status() -> SourceStatus {
        currentStatus
    }

    /// Reloads the lineup when it is older than `maxLineupAge`, or always with `force`. Publishes new shelf
    /// contributions when the channels changed. Throws when no device answered.
    public func refresh(force: Bool = false) async throws {
        if !force, lineup != nil, let loadedAt, ContinuousClock.now - loadedAt < maxLineupAge { return }
        try await load()
    }

    public func children(of parent: MediaItemID?, page: PageRequest) async throws -> Page<MediaItem> {
        guard let parent else {
            return Page(slicing: try await currentLineup().items(source: id), with: page)
        }
        // A channel has no children; anything else is not ours.
        _ = try await channel(for: parent)
        return Page(items: [], total: 0)
    }

    public func item(_ itemID: MediaItemID) async throws -> MediaItem {
        try await channel(for: itemID).item(source: id)
    }

    /// Subscribes to the channel through the broker and returns `.liveTuner`, live, starting at the live edge (a
    /// live channel has no other start). Its `TunerLease` is also the descriptor's lease. Throws the device's
    /// `HDHomeRunClientError` (805, 807, …) when every device that carries the channel refused it.
    public func playback(for itemID: MediaItemID, request: PlaybackRequest) async throws -> PlaybackDescriptor {
        let channel = try await channel(for: itemID)
        let tune = TuneRequest(channel: ChannelKey(source: lineupSource, guideNumber: channel.entry.guideNumber),
                               routes: channel.routes, purpose: request.purpose == .tile ? .tile : .watch,
                               prefersMultiplex: request.prefersSharedTuner)
        let slot = request.tileID.map(SubscriberSlot.tile) ?? .player
        let lease = TunerLease(subscription: try await broker.subscribe(tune, slot: slot), broker: broker,
                               request: tune, slot: slot)
        return PlaybackDescriptor(
            transport: .liveTuner(lease),
            container: .mpegTS,
            codecs: channel.item(source: id).technical,
            isLive: true,
            start: .liveEdge,
            lease: lease
        )
    }

    /// Favorites and Live TV Channels: now when the lineup is loaded, otherwise once the first load (started by
    /// this call) finishes, then whenever the channels change. A first load that fails publishes them empty.
    public func shelfContributions() async -> AsyncStream<[ShelfContribution]> {
        let (stream, continuation) = ContributionObservers.makeStream()
        let observerID = observers.add(continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        if let publishedItems {
            continuation.yield(contributions(publishedItems))
        } else if devices.isEmpty {
            continuation.yield(contributions([]))
        } else if loading == nil {
            Task { try? await self.refresh() }
        }
        return stream
    }

    // MARK: - Lineup

    private func removeObserver(_ observerID: UInt64) {
        observers.remove(observerID)
    }

    private func channel(for itemID: MediaItemID) async throws -> LiveLineup.Channel {
        guard itemID.source == id else { throw MediaSourceError.wrongSource(itemID) }
        guard itemID.key.hasPrefix(MediaItemID.channelKeyPrefix),
              let channel = try await currentLineup().channel(
                guideNumber: String(itemID.key.dropFirst(MediaItemID.channelKeyPrefix.count))) else {
            throw MediaSourceError.notFound(itemID)
        }
        return channel
    }

    private func currentLineup() async throws -> LiveLineup {
        if let lineup { return lineup }
        return try await load()
    }

    /// Fetches every device's lineup once, however many callers wait for it.
    @discardableResult
    private func load() async throws -> LiveLineup {
        guard !devices.isEmpty else { throw MediaSourceError.unconfigured }
        let task: Task<[Result<TunerLineup, HDHomeRunClientError>], Never>
        if let loading {
            task = loading
        } else {
            let devices = devices
            task = Task { await Self.fetchAll(devices) }
            loading = task
            if lineup == nil { currentStatus = .connecting }
        }
        let results = await task.value
        if loading == task {
            loading = nil
            return try apply(results)
        }
        guard let lineup else { throw lastLoadError ?? MediaSourceError.unconfigured }
        return lineup
    }

    private func apply(_ results: [Result<TunerLineup, HDHomeRunClientError>]) throws -> LiveLineup {
        var lineups: [TunerLineup] = []
        var errors: [HDHomeRunClientError] = []
        for result in results {
            switch result {
            case .success(let lineup): lineups.append(lineup)
            case .failure(let error): errors.append(error)
            }
        }
        guard !lineups.isEmpty else {
            let error = errors.first ?? .invalidResponse
            lastLoadError = error
            currentStatus = Self.status(for: error)
            // Nothing loaded yet: answer Home anyway, so its shelves say why instead of waiting. A source that
            // loaded before keeps what it published.
            if lineup == nil { observers.yield(contributions([])) }
            throw error
        }
        let merged = LiveLineup.merge(lineups, lineupSource: lineupSource)
        lineup = merged
        loadedAt = .now
        loadedDate = Date()
        lastLoadError = nil
        currentStatus = errors.isEmpty ? .ready : .degraded("\(errors.count) of \(results.count) tuners didn't answer.")
        publishIfChanged(merged)
        return merged
    }

    private func publishIfChanged(_ merged: LiveLineup) {
        let items = merged.items(source: id)
        guard items != publishedItems else { return }
        publishedItems = items
        publishCount += 1
        observers.yield(contributions(items))
    }

    private func contributions(_ items: [MediaItem]) -> [ShelfContribution] {
        [
            ShelfContribution(shelf: .favorites, items: items.filter(\.isDeviceFavorite), freshness: loadedDate),
            ShelfContribution(shelf: .liveChannels, items: items, freshness: loadedDate)
        ]
    }

    private static func status(for error: HDHomeRunClientError) -> SourceStatus {
        switch error {
        case .localNetworkUnavailable: .localNetworkDenied
        default: .unreachable(error.message)
        }
    }

    /// Every device at once, off the actor; results keep the devices' order.
    @concurrent
    private static func fetchAll(_ devices: [any TunerLineupProviding])
        async -> [Result<TunerLineup, HDHomeRunClientError>] {
        await withTaskGroup(of: (Int, Result<TunerLineup, HDHomeRunClientError>).self) { group in
            for (index, device) in devices.enumerated() {
                group.addTask {
                    do throws(HDHomeRunClientError) {
                        return (index, .success(try await device.fetchLineup()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<TunerLineup, HDHomeRunClientError>](
                repeating: .failure(.cancelled), count: devices.count)
            for await (index, result) in group { results[index] = result }
            return results
        }
    }
}
