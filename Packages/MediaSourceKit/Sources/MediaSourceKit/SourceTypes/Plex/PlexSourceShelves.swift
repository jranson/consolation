import Foundation

/// Home shelves from the DVR: Recent Recordings, the newest finished recordings in the sections its rules record
/// into. Recording Now waits until an in-progress recording can be played over HTTP.
extension PlexSource {
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
            Task { await self.refresh() }
        }
        return stream
    }

    /// One read at a time; callers that arrive while one runs wait for it. A first read that fails publishes
    /// empty shelves, so Home reads why from `status()` instead of waiting.
    public func refresh() async {
        if let shelfTask { return await shelfTask.value }
        let task = Task { await self.readShelves() }
        shelfTask = task
        await task.value
        shelfTask = nil
    }

    func removeObserver(_ observerID: UInt64) {
        observers.remove(observerID)
    }

    private func readShelves() async {
        do {
            let rules = try await tracking { try await client.subscriptions() }
            let sections = Set(rules.compactMap(\.targetLibrarySectionID)).sorted()
            var recent: [MediaItem] = []
            for section in sections {
                let added = try await tracking {
                    try await client.recentlyAdded(inSection: String(section), size: Self.recentLimit)
                }
                recent += remember(added).filter { item in
                    if case .recording(_, _, let inProgress, _) = item.kind { return !inProgress }
                    return false
                }
            }
            recent.sort { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            publish([ShelfContribution(shelf: .recentRecordings, items: Array(recent.prefix(Self.recentLimit)),
                                       freshness: Date())])
        } catch {
            if lastContributions == nil { publish([]) }
        }
    }

    private func publish(_ contributions: [ShelfContribution]) {
        lastContributions = contributions
        observers.yield(contributions)
    }
}
