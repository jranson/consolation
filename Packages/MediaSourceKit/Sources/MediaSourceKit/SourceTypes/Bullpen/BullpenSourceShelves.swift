import Foundation

/// Home shelves from the library root: its "recording now" group feeds Recording Now, the recordings feed's first
/// page Recent Recordings, and its other groups become library shelves the user can pin.
extension BullpenSource {
    /// The recordings feed (`/opds/recordings.json`); with `state=recording`, the recordings in progress.
    static let recordingsFeedSuffix = "/opds/recordings.json"
    /// How many finished recordings Recent Recordings shows.
    static let recentLimit = 30

    /// Now when the shelves were read before, otherwise once the first read (started by this call) finishes, then
    /// after every `refresh()`.
    public func shelfContributions() async -> AsyncStream<[ShelfContribution]> {
        let (stream, continuation) = ContributionObservers.makeStream()
        let observerID = observers.add(continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        if let lastContributions {
            continuation.yield(lastContributions)
        } else if shelfTask == nil {
            Task { await self.refreshShelves() }
        }
        return stream
    }

    /// Reads the shelves again (Home appeared, or Recording Now is on screen) and publishes them.
    public func refresh() async {
        await refreshShelves()
    }

    func removeObserver(_ observerID: UInt64) {
        observers.remove(observerID)
    }

    /// One read at a time; callers that arrive while one runs wait for it. A source whose first read fails
    /// publishes empty shelves, so Home reads why from `status()` instead of waiting.
    func refreshShelves() async {
        if let shelfTask { return await shelfTask.value }
        let task = Task { await self.readShelves() }
        shelfTask = task
        await task.value
        shelfTask = nil
    }

    private func readShelves() async {
        do {
            let catalog = try await currentCatalog()
            guard let root = catalog.url(BullpenVocabulary.library),
                  !catalog.has(BullpenVocabulary.oidcIssuer) else { return publish([]) }
            let feed = try await client.feed(at: root)
            var contributions = groupShelves(feed, base: root)
            if !contributions.contains(where: { $0.shelf == .recentRecordings }),
               let recordings = feed.navigation.first(where: { Self.shelf(for: $0, base: root) == .recentRecordings }),
               let url = recordings.url(relativeTo: root) {
                let page = try await client.feed(at: url)
                let finished = remember(page.publications, base: url).filter { !$0.isInProgress }
                contributions.append(ShelfContribution(shelf: .recentRecordings,
                                                       items: Array(finished.prefix(Self.recentLimit)),
                                                       freshness: Date()))
            }
            publish(contributions)
        } catch {
            if lastContributions == nil { publish([]) }
        }
    }

    private func groupShelves(_ feed: OPDSFeed, base: URL) -> [ShelfContribution] {
        feed.groups.compactMap { group in
            let items = remember(group.publications, base: base)
            let feedURL = group.selfLink?.url(relativeTo: base)
            switch group.selfLink.flatMap({ Self.shelf(for: $0, base: base) }) {
            case .recordingNow:
                return ShelfContribution(shelf: .recordingNow, items: items.filter(\.isInProgress), freshness: Date())
            case .recentRecordings:
                return ShelfContribution(shelf: .recentRecordings, items: items.filter { !$0.isInProgress },
                                         freshness: Date())
            default:
                guard let feedURL, !items.isEmpty else { return nil }
                return ShelfContribution(shelf: .library(id, sectionKey: OPDSItems.key(forFeed: feedURL)),
                                         items: items, freshness: Date(), title: group.title)
            }
        }
    }

    private func publish(_ contributions: [ShelfContribution]) {
        lastContributions = contributions
        observers.yield(contributions)
    }

    /// Which built-in shelf a recordings feed link feeds, or nil for any other feed.
    static func shelf(for link: OPDSLink, base: URL) -> HomeShelfKind? {
        guard let url = link.url(relativeTo: base), url.path(percentEncoded: false).hasSuffix(recordingsFeedSuffix)
        else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.isEmpty { return .recentRecordings }
        if items.count == 1, items[0].name == "state", items[0].value == "recording" { return .recordingNow }
        return nil
    }
}

extension MediaItem {
    /// A recording still being written.
    var isInProgress: Bool {
        if case .recording(_, _, let inProgress, _) = kind { return inProgress }
        return false
    }
}
