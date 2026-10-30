import Foundation

/// Which of the app's own players a subscription belongs to. Each slot holds at most one subscription: a slot's
/// next `subscribe` (a channel change or the engine's reconnect) replaces its previous one first, so one slot never
/// holds two tuners, while the slots themselves are independent (a tile's subscribe never cancels the player's).
public nonisolated enum SubscriberSlot: Hashable, Sendable, CustomStringConvertible {
    /// The full-screen, single-view player.
    case player
    /// A multi-view tile, by the tile's stable identity.
    case tile(UUID)

    public var description: String {
        switch self {
        case .player: "player"
        case .tile(let id): "tile-\(id.uuidString.prefix(8))"
        }
    }
}

/// When the broker shares one tuner between channels of the same RF multiplex (`/tuner<N>/ch<frequency>`, about
/// 19.4 Mbps instead of 6–10 Mbps per program). ATSC 1.0 only.
public nonisolated enum MultiplexPolicy: String, Hashable, Sendable, CaseIterable, Codable {
    /// Every channel gets a program stream; channels already open are still shared.
    case never
    /// Share only when distinct channels exceed the free tuners: the planner groups them, and a second channel on a
    /// program stream's frequency with no tuner free is offered a re-tune onto the multiplex.
    case whenTunersAreShort
    /// Open every tile on a shareable channel as a multiplex, so later channels on its frequency join for free.
    /// The single-view player still opens program streams.
    case always
}

/// What the broker knows about tuner models.
public nonisolated enum TunerModelTable {
    /// The tuner indices that can receive ATSC 3.0 for a `discover.json` `ModelNumber`, or nil when unknown (then every
    /// tuner may be, and errors decide). FLEX 4K (`HDFX-4K`): tuners 0 and 1.
    public static func atsc3CapableTuners(modelNumber: String?) -> Set<Int>? {
        switch modelNumber?.uppercased() {
        case "HDFX-4K": [0, 1]
        default: nil
        }
    }

    /// `3` for `tuner3`; nil when the resource is not of the form `tuner<N>`.
    public static func tunerIndex(_ resource: String) -> Int? {
        TunerStatus(resource: resource).tunerIndex
    }
}
