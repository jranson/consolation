import Foundation
import Observation

/// Fills Home: merges every source's shelf contributions with local favorites and resume points, orders the shelves
/// as Settings › Home says, and keeps a snapshot so Home renders at once on the next launch.
///
/// - `start()` renders from the snapshot first, then refreshes. A refresh listens to every source's
///   `shelfContributions()` and returns once each source has answered or missed its soft timeout (about 2 s). A
///   late source keeps its snapshot contributions and marks its shelves `isUpdating`; its answer is applied
///   whenever it arrives, and so is every later batch (a lineup change, for example), until `stop()`.
/// - A source that answers with a failure (unreachable, Local Network access off) isn't late: its empty shelves say
///   why, and the snapshot keeps its last good contributions.
/// - It knows nothing about cards or EtagereKit: the app maps `shelves` through its `VideoCard` factories.
/// - The snapshot holds MediaItems only, for the shelves that are shown, with artwork URLs that could carry a token
///   removed. It is written only once the composer knows its sources and has read the previous snapshot, and a
///   source that hasn't answered keeps its cached entry.
@MainActor
@Observable
public final class HomeShelfComposer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The shelves to show, in order.
    public private(set) var shelves: [HomeShelf] = []
    /// A refresh is waiting for sources (at most the soft timeout).
    public private(set) var isRefreshing = false
    /// Settings › Home: order and per-shelf switches. A shelf turned off also leaves the snapshot.
    public var configuration: HomeShelfConfiguration {
        didSet {
            recompose()
            if configuration != oldValue { scheduleSave() }
        }
    }
    /// Local favorites and resume points.
    public var localState: LocalHomeState {
        didSet {
            recompose()
            resolveLocalItemsEverywhere()
        }
    }
    @ObservationIgnored public let messages: HomeShelfMessages

    private enum Phase {
        /// From the snapshot (or nothing yet); no refresh running.
        case cached
        /// A refresh is waiting for its first batch, still within the soft timeout.
        case pending
        /// The soft timeout passed without a batch.
        case late
        /// Answered during the current refresh.
        case fresh
    }

    private struct Entry {
        var capabilities: SourceCapabilities?
        /// The source's status when it last delivered contributions.
        var status: SourceStatus?
        var contributions: [ShelfContribution] = []
        var resolvedItems: [MediaItem] = []
        var phase = Phase.cached
        /// Local IDs already looked up during this refresh.
        var lookedUp: Set<MediaItemID> = []
        /// `contributions` came from the source (or were discarded on request), not from the snapshot, so they
        /// replace the snapshot's.
        var isFromSource = false
    }

    @ObservationIgnored private var sources: [any MediaSource] = []
    @ObservationIgnored private var entries: [SourceID: Entry] = [:]
    @ObservationIgnored private var cachedSnapshot: [SourceID: SourceSnapshot] = [:]
    @ObservationIgnored private var hasLoadedSnapshot = false
    /// Until `setSources(_:)` (or `init` with sources) the composer doesn't know which sources are configured, so
    /// it writes no snapshot.
    @ObservationIgnored private var knowsSources: Bool
    /// Between `refresh()` and `stop()`: sources added or replaced meanwhile are listened to at once.
    @ObservationIgnored private var isListening = false
    @ObservationIgnored private var listeners: [SourceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private let snapshotStore: (any HomeSnapshotStore)?
    @ObservationIgnored private let softTimeout: Duration
    @ObservationIgnored private let sleep: Sleep

    /// - Parameters:
    ///   - snapshotStore: a file in Caches in the app; nil keeps no snapshot.
    ///   - softTimeout: how long a refresh waits for each source before it shows that source's shelves as updating.
    ///   - sleep: waits out the soft timeout; tests inject a controllable one.
    public init(sources: [any MediaSource] = [], configuration: HomeShelfConfiguration = .default,
                localState: LocalHomeState = LocalHomeState(), snapshotStore: (any HomeSnapshotStore)? = nil,
                messages: HomeShelfMessages = HomeShelfMessages(), softTimeout: Duration = .seconds(2),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.configuration = configuration
        self.localState = localState
        self.messages = messages
        self.snapshotStore = snapshotStore
        self.softTimeout = softTimeout
        self.sleep = sleep
        knowsSources = !sources.isEmpty
        replaceSources(sources)
        recompose()
    }

    isolated deinit {
        for task in listeners.values { task.cancel() }
    }

    /// The composed shelf of this kind, if it is shown.
    public func shelf(_ kind: HomeShelfKind) -> HomeShelf? {
        shelves.first { $0.kind == kind }
    }

    /// Renders from the snapshot, then refreshes.
    public func start() async {
        await loadSnapshot()
        await refresh()
    }

    /// Replaces the configured sources. A removed source's cards go at once, and leave the snapshot. An added
    /// source shows its snapshot until it answers; a new instance under a known ID (the registry rebuilt a source
    /// after a device was added, for example) keeps the old instance's cards until it answers. Between `refresh()`
    /// and `stop()` both are listened to at once; otherwise from the next `refresh()`.
    public func setSources(_ newSources: [any MediaSource]) {
        knowsSources = true
        replaceSources(newSources)
        recompose()
        scheduleSave()
    }

    /// Loads the snapshot and shows it for every source that hasn't answered yet.
    public func loadSnapshot() async {
        guard let snapshotStore else { return }
        adoptSnapshot(await snapshotStore.loadSnapshot())
        for source in sources { seedFromSnapshot(source.id) }
        recompose()
    }

    /// Listens to every source again and waits for each one's first batch, at most the soft timeout per source.
    public func refresh() async {
        generation &+= 1
        let token = generation
        cancelListeners()
        isListening = true
        isRefreshing = true
        var waits: [(SourceID, AsyncStream<Void>)] = []
        for source in sources {
            entries[source.id]?.phase = .pending
            entries[source.id]?.lookedUp = []
            waits.append((source.id, listen(to: source, token: token)))
        }
        recompose()
        let late = await HomeSoftTimeout.lateSources(waits, timeout: softTimeout, sleep: sleep)
        guard token == generation else { return }
        for id in late where entries[id]?.phase == .pending { entries[id]?.phase = .late }
        isRefreshing = false
        recompose()
    }

    /// Stops listening (Home is hidden). Shelves keep what they show.
    public func stop() {
        generation &+= 1
        cancelListeners()
        isListening = false
        isRefreshing = false
        for id in Array(entries.keys) where entries[id]?.phase != .fresh { entries[id]?.phase = .cached }
        recompose()
    }

    /// Forgets what Home shows and caches for a source until it answers again. For example, call it after the user
    /// clears the Quick Play history while Home is hidden, so the cleared items never return from the snapshot.
    public func discardContributions(from id: SourceID) {
        cachedSnapshot[id] = nil
        if entries[id] != nil {
            entries[id]?.contributions = []
            entries[id]?.resolvedItems = []
            entries[id]?.status = nil
            entries[id]?.isFromSource = true
        }
        recompose()
        scheduleSave()
    }

    /// Waits until the latest snapshot is written.
    public func flushSnapshot() async {
        while let saveTask { await saveTask.value }
    }

    // MARK: - Listening

    private func listen(to source: any MediaSource, token: UInt64) -> AsyncStream<Void> {
        let (arrived, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        listeners[source.id] = Task { [weak self] in
            defer { signal.finish() }
            let capabilities = await source.capabilities()
            // A cancelled listener (a replaced instance, an earlier refresh) never touches the state again.
            guard !Task.isCancelled, self?.accept(capabilities, from: source.id, token: token) == true else { return }
            var received = false
            for await batch in await source.shelfContributions() {
                let status = await source.status()
                guard !Task.isCancelled,
                      self?.accept(batch, status: status, from: source.id, token: token) == true else { return }
                received = true
                signal.yield()
                // Lookups run beside the stream, so a slow one never holds up the next batch.
                Task { [weak self] in await self?.resolveLocalItems(from: source, token: token) }
            }
            // A stream that ends without a batch means the source has nothing for Home.
            if !received, !Task.isCancelled { self?.accept([], status: nil, from: source.id, token: token) }
        }
        return arrived
    }

    @discardableResult
    private func accept(_ capabilities: SourceCapabilities, from id: SourceID, token: UInt64) -> Bool {
        guard token == generation, entries[id] != nil else { return false }
        entries[id]?.capabilities = capabilities
        recompose()
        return true
    }

    @discardableResult
    private func accept(_ batch: [ShelfContribution], status: SourceStatus?, from id: SourceID,
                        token: UInt64) -> Bool {
        guard token == generation, entries[id] != nil else { return false }
        entries[id]?.contributions = batch
        entries[id]?.status = status
        entries[id]?.phase = .fresh
        entries[id]?.isFromSource = true
        recompose()
        scheduleSave()
        return true
    }

    /// Looks up local favorites and resume points of this source that no contribution carries. Skipped for a
    /// source that just failed, so a down server isn't asked once per item.
    private func resolveLocalItems(from source: any MediaSource, token: UInt64) async {
        guard isCurrent(source), let entry = entries[source.id], entry.status?.isFailure != true else { return }
        let contributed = Set(entries.values.flatMap { $0.contributions.flatMap(\.items).map(\.id) })
        let wanted = (localState.favorites + localState.resumePoints.map(\.item)).filter {
            $0.source == source.id && !contributed.contains($0) && !entry.lookedUp.contains($0)
        }
        guard !wanted.isEmpty else { return }
        entries[source.id]?.lookedUp.formUnion(wanted)
        var found: [MediaItem] = []
        for id in wanted {
            if let item = try? await source.item(id) { found.append(item) }
        }
        guard token == generation, isCurrent(source), let current = entries[source.id] else { return }
        var resolved = Dictionary(current.resolvedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in found { resolved[item.id] = item }
        let localIDs = Set(localState.favorites + localState.resumePoints.map(\.item))
        entries[source.id]?.resolvedItems = resolved.values.filter { localIDs.contains($0.id) }
            .sorted { $0.cardID < $1.cardID }
        recompose()
        scheduleSave()
    }

    private func resolveLocalItemsEverywhere() {
        let token = generation
        let ready = sources.filter { entries[$0.id]?.phase == .fresh }
        guard !ready.isEmpty else { return }
        Task { [weak self] in
            for source in ready { await self?.resolveLocalItems(from: source, token: token) }
        }
    }

    private func cancelListeners() {
        for task in listeners.values { task.cancel() }
        listeners = [:]
    }

    /// Whether `source` is the configured instance for its ID, not one that `setSources(_:)` replaced.
    private func isCurrent(_ source: any MediaSource) -> Bool {
        sources.contains { $0 === source }
    }

    // MARK: - State

    private func replaceSources(_ newSources: [any MediaSource]) {
        var seen: Set<SourceID> = []
        let unique = newSources.filter { seen.insert($0.id).inserted }
        let previous = sources
        // Added sources, and new instances under a known ID: no listener follows either of them yet.
        let arrivals = unique.filter { source in !previous.contains { $0 === source } }
        let arrivalIDs = Set(arrivals.map(\.id))
        for (id, task) in listeners where !seen.contains(id) || arrivalIDs.contains(id) {
            task.cancel()
            listeners[id] = nil
        }
        entries = entries.filter { seen.contains($0.key) }
        sources = unique
        for source in arrivals {
            if entries[source.id] == nil {
                entries[source.id] = Entry()
                seedFromSnapshot(source.id)
            }
            entries[source.id]?.lookedUp = []
            entries[source.id]?.phase = isListening ? .pending : .cached
            if isListening { _ = listen(to: source, token: generation) }
        }
    }

    private func seedFromSnapshot(_ id: SourceID) {
        guard let cached = cachedSnapshot[id], var entry = entries[id], !entry.isFromSource else { return }
        entry.capabilities = entry.capabilities ?? cached.capabilities
        entry.contributions = cached.contributions
        entry.resolvedItems = cached.resolvedItems
        entries[id] = entry
    }

    private func mergeStates() -> [HomeShelfMerge.SourceState] {
        sources.compactMap { source in
            guard let entry = entries[source.id] else { return nil }
            return HomeShelfMerge.SourceState(id: source.id, capabilities: entry.capabilities,
                                              contributions: entry.contributions,
                                              resolvedItems: entry.resolvedItems, isLate: entry.phase == .late,
                                              status: entry.status)
        }
    }

    private func recompose() {
        let composed = HomeShelfMerge.compose(sources: mergeStates(), configuration: configuration,
                                              local: localState, messages: messages)
        if composed != shelves { shelves = composed }
    }

    // MARK: - Snapshot

    private func adoptSnapshot(_ snapshot: HomeSnapshot?) {
        hasLoadedSnapshot = true
        cachedSnapshot = Dictionary((snapshot?.sources ?? []).map { ($0.source, $0) },
                                    uniquingKeysWith: { first, _ in first })
    }

    /// Writes the snapshot soon. Saves asked for while one is being written fold into one more write.
    private func scheduleSave() {
        guard snapshotStore != nil, knowsSources else { return }
        needsSave = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in await self?.writeSnapshot() }
    }

    private func writeSnapshot() async {
        defer { saveTask = nil }
        guard let snapshotStore else { return }
        // Read the stored snapshot before replacing it, so sources that haven't answered keep their entries.
        if !hasLoadedSnapshot { adoptSnapshot(await snapshotStore.loadSnapshot()) }
        while needsSave {
            needsSave = false
            await snapshotStore.saveSnapshot(currentSnapshot())
        }
    }

    /// Per configured source, what it delivered; or its cached entry while it hasn't answered or answered with a
    /// failure, so a slow or unreachable source never wipes its part. Only shown shelves are kept.
    private func currentSnapshot() -> HomeSnapshot {
        let shown = Set(configuration.shelves.filter(\.isEnabled).map(\.kind))
        return HomeSnapshot(sources: sources.compactMap { source -> SourceSnapshot? in
            guard let entry = entries[source.id] else { return nil }
            guard entry.isFromSource, entry.status?.isFailure != true else {
                return cachedSnapshot[source.id]?.cacheable(showing: shown)
            }
            return SourceSnapshot(source: source.id, capabilities: entry.capabilities,
                                  contributions: entry.contributions, resolvedItems: entry.resolvedItems)
                .cacheable(showing: shown)
        })
    }
}
