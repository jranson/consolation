import Foundation

/// Builds Home's shelves from what each source contributed and what only this device knows. Pure, so the merge
/// rules are tested without sources or timing.
nonisolated enum HomeShelfMerge {
    /// One source as the composer last saw it.
    struct SourceState: Sendable {
        var id: SourceID
        /// Nil until the source (or the snapshot) reported them.
        var capabilities: SourceCapabilities?
        var contributions: [ShelfContribution]
        var resolvedItems: [MediaItem]
        /// It missed the soft timeout of the current refresh and hasn't delivered fresh contributions since.
        var isLate: Bool
        /// Its status when it last delivered contributions; nil when unknown (from the snapshot, or not asked).
        var status: SourceStatus?
    }

    /// The enabled shelves in the configured order. Per shelf, contributions merge by rank (then source order) and
    /// de-duplicate by `MediaItemID`; Favorites adds the local favorites after the device's, Continue Watching
    /// puts local resume points first (newest first). The transient shelves are left out while empty.
    static func compose(sources: [SourceState], configuration: HomeShelfConfiguration, local: LocalHomeState,
                        messages: HomeShelfMessages) -> [HomeShelf] {
        let index = itemIndex(sources)
        var seen: Set<HomeShelfKind> = []
        var shelves: [HomeShelf] = []
        for setting in configuration.shelves where setting.isEnabled && seen.insert(setting.kind).inserted {
            let kind = setting.kind
            let items = items(for: kind, sources: sources, local: local, index: index)
            if items.isEmpty && kind.isHiddenWhenEmpty { continue }
            shelves.append(HomeShelf(
                kind: kind,
                title: title(for: kind, sources: sources, messages: messages),
                items: items,
                emptyMessage: items.isEmpty ? emptyMessage(for: kind, sources: sources, messages: messages) : nil,
                isUpdating: isUpdating(kind, sources: sources)
            ))
        }
        return shelves
    }

    static func items(for kind: HomeShelfKind, sources: [SourceState], local: LocalHomeState,
                      index: [MediaItemID: MediaItem]) -> [MediaItem] {
        let contributed = contributedItems(kind, sources: sources)
        switch kind {
        case .favorites:
            return unique(contributed + local.favorites.compactMap { index[$0] })
        case .continueWatching:
            return unique(resumeItems(local, index: index) + contributed)
        default:
            return unique(contributed)
        }
    }

    /// Every item any source contributed or resolved, first occurrence wins.
    static func itemIndex(_ sources: [SourceState]) -> [MediaItemID: MediaItem] {
        var index: [MediaItemID: MediaItem] = [:]
        for source in sources {
            for item in source.contributions.flatMap(\.items) + source.resolvedItems where index[item.id] == nil {
                index[item.id] = item
            }
        }
        return index
    }

    /// The IDs local state names that no source has contributed or resolved yet.
    static func unresolvedLocalIDs(_ local: LocalHomeState, index: [MediaItemID: MediaItem]) -> [MediaItemID] {
        unique(local.favorites + local.resumePoints.map(\.item)) { $0 }.filter { index[$0] == nil }
    }

    private struct Ranked {
        let rank: Double
        let source: Int
        let order: Int
        let items: [MediaItem]
    }

    private static func contributedItems(_ kind: HomeShelfKind, sources: [SourceState]) -> [MediaItem] {
        var ranked: [Ranked] = []
        for (sourceIndex, source) in sources.enumerated() {
            for (order, contribution) in source.contributions.enumerated() where contribution.shelf == kind {
                ranked.append(Ranked(rank: contribution.rank, source: sourceIndex, order: order,
                                     items: contribution.items))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            return lhs.order < rhs.order
        }
        return ranked.flatMap(\.items)
    }

    private static func resumeItems(_ local: LocalHomeState, index: [MediaItemID: MediaItem]) -> [MediaItem] {
        local.resumePoints
            .filter { !$0.progress.isFinished }
            .sorted { $0.progress.updatedAt > $1.progress.updatedAt }
            .compactMap { point in
                guard var item = index[point.item] else { return nil }
                item.progress = point.progress
                return item
            }
    }

    private static func unique(_ items: [MediaItem]) -> [MediaItem] {
        unique(items, by: \.id)
    }

    private static func unique<Element, Key: Hashable>(_ elements: [Element], by key: (Element) -> Key)
        -> [Element] {
        var seen: Set<Key> = []
        return elements.filter { seen.insert(key($0)).inserted }
    }

    private static func title(for kind: HomeShelfKind, sources: [SourceState], messages: HomeShelfMessages)
        -> String {
        guard case .library = kind else { return messages.title(for: kind) }
        let titled = sources.lazy.flatMap(\.contributions).first { $0.shelf == kind && $0.title != nil }
        return titled?.title ?? messages.libraryTitle
    }

    /// Favorites and Live TV Channels say whether a live TV source exists; Recent Recordings whether a DVR does.
    /// When every source that could feed the shelf failed, the shelf says why instead (Local Network access off,
    /// unreachable, signed out). While a source's capabilities are still unknown, no placeholder is shown. Quick
    /// Play History and library shelves always have one; a library's says why when its source failed. The
    /// transient shelves are hidden instead.
    private static func emptyMessage(for kind: HomeShelfKind, sources: [SourceState],
                                     messages: HomeShelfMessages) -> String? {
        switch kind {
        case .favorites:
            providerMessage(.liveTV, sources: sources, messages: messages, present: messages.noFavorites,
                            absent: messages.noLiveTVSource)
        case .liveChannels:
            providerMessage(.liveTV, sources: sources, messages: messages, present: messages.noChannels,
                            absent: messages.noLiveTVSource)
        case .recentRecordings:
            providerMessage(.recordings, sources: sources, messages: messages, present: messages.noRecordings,
                            absent: messages.noDVRSource)
        case .quickPlayHistory:
            messages.noQuickPlayHistory
        case .library(let owner, _):
            libraryMessage(owner: owner, sources: sources, messages: messages)
        case .recordingNow, .continueWatching:
            nil
        }
    }

    private static func libraryMessage(owner: SourceID, sources: [SourceState],
                                       messages: HomeShelfMessages) -> String {
        if let status = sources.first(where: { $0.id == owner })?.status, status.isFailure {
            return failureMessage(status, messages: messages)
        }
        return messages.emptyLibrary
    }

    private static func providerMessage(_ capability: SourceCapabilities, sources: [SourceState],
                                        messages: HomeShelfMessages, present: String, absent: String) -> String? {
        let providers = sources.filter { $0.capabilities?.contains(capability) == true }
        if let failed = providers.first, providers.allSatisfy({ $0.status?.isFailure == true }) {
            return failureMessage(failed.status, messages: messages)
        }
        if !providers.isEmpty { return present }
        if sources.contains(where: { $0.capabilities == nil }) { return nil }
        return absent
    }

    private static func failureMessage(_ status: SourceStatus?, messages: HomeShelfMessages) -> String {
        switch status {
        case .localNetworkDenied: messages.localNetworkDenied
        case .authRequired: messages.signInRequired
        case .unreachable(let reason) where !reason.isEmpty: reason
        default: messages.sourceUnreachable
        }
    }

    /// A late source marks the shelves it fed before, and the shelves its capabilities say it could feed.
    private static func isUpdating(_ kind: HomeShelfKind, sources: [SourceState]) -> Bool {
        sources.contains { source in
            guard source.isLate else { return false }
            if source.contributions.contains(where: { $0.shelf == kind }) { return true }
            if case .library(let owner, _) = kind { return owner == source.id }
            guard let requirement = requirement(for: kind) else { return false }
            return source.capabilities?.contains(requirement) ?? true
        }
    }

    private static func requirement(for kind: HomeShelfKind) -> SourceCapabilities? {
        switch kind {
        case .favorites, .liveChannels: .liveTV
        case .recordingNow: .inProgressRecordings
        case .recentRecordings: .recordings
        case .continueWatching, .quickPlayHistory, .library: nil
        }
    }
}

nonisolated extension SourceStatus {
    /// The source answered but can't deliver: unreachable, Local Network access off, or signed out.
    var isFailure: Bool {
        switch self {
        case .unreachable, .localNetworkDenied, .authRequired: true
        case .unconfigured, .connecting, .ready, .degraded: false
        }
    }
}
