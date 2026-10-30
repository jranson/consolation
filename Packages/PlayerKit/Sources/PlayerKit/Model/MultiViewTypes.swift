//
//  MultiViewTypes.swift
//  PlayerKit
//
//  The small value types of multi-view: tile identity, the three modes, the overlays on the back stack, directions and
//  how the player is presented.
//

import Foundation

/// One tile's identity for its whole life. A tile keeps its ID when its item is replaced, so its view (and the
/// hosted video) never changes identity.
nonisolated public struct TileID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { "tile-\(rawValue.uuidString.prefix(8))" }
}

/// What the player shows.
nonisolated public enum MultiViewMode: Hashable, Sendable {
    /// Exactly one tile: it fills the player with no inset, corners or dimming.
    case single(TileID)
    /// Two or more tiles, all playing in their cells; one has focus.
    case grid(focused: TileID)
    /// Two or more tiles, one brought forward over the dimmed grid.
    case foreground(TileID)

    /// The single, focused or foreground tile.
    public var tile: TileID {
        switch self {
        case .single(let tile), .grid(focused: let tile), .foreground(let tile): tile
        }
    }

    public var isGrid: Bool {
        if case .grid = self { true } else { false }
    }

    public var isSingle: Bool {
        if case .single = self { true } else { false }
    }

    /// The tile in front, if one is.
    public var foregroundTile: TileID? {
        if case .foreground(let tile) = self { tile } else { nil }
    }
}

/// Layers over the tiles. Back pops the innermost one first.
nonisolated public enum PlayerOverlay: Hashable, Sendable {
    case controls
    case arrangement
    case channelPanel
    case numberEntry
}

/// A d-pad, swipe or arrow-key direction.
nonisolated public enum TileDirection: Hashable, Sendable, CaseIterable {
    case upward
    case downward
    case leftward
    case rightward
}

/// How big the player is on screen. Roles follow it: a mini or hidden player shows (and decodes) only the audible
/// tile.
nonisolated public enum PlayerPresentation: Hashable, Sendable {
    /// The full player area.
    case full
    /// The small player in a corner: the audible tile fills it, the others are hosted but invisible.
    case mini
    /// Not on screen here (another window shows the video, or nothing visible). Draws nothing.
    case hidden
}

/// What a select (click, Select, tap, Return) did.
nonisolated public enum SelectOutcome: Hashable, Sendable {
    /// The tile came forward from the grid (or replaced the foreground tile).
    case broughtForward
    /// The tile was already in front (or the only one): the host shows its controls.
    case showControls
    /// Nothing: the tile is unknown.
    case ignored
}

/// The grid's columns and rows.
nonisolated public struct GridShape: Hashable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }
}
