//
//  MultiViewState.swift
//  PlayerKit
//
//  The multi-view state machine as a value: the tiles in grid order, the mode, the overlay back stack, and which tile
//  audio is on. Pure, so every transition is unit-tested; the session applies the result to the engines.
//

import Foundation

nonisolated public struct MultiViewState: Hashable, Sendable {
    /// Tiles in grid (reading) order. Never empty.
    public internal(set) var tiles: [TileID]
    public internal(set) var mode: MultiViewMode
    /// Overlays over the tiles; the last is the innermost (Back pops it first).
    public internal(set) var overlays: [PlayerOverlay] = []
    /// The last tile shown alone or in front. With "Audio follows focus" off, grid audio stays on it.
    public internal(set) var lastForeground: TileID
    /// The grid tile audio has followed to (the session commits it after the focus dwell).
    public internal(set) var audioFocus: TileID

    /// A one-tile state: the tile fills the player.
    public init(tile: TileID) {
        tiles = [tile]
        mode = .single(tile)
        lastForeground = tile
        audioFocus = tile
    }

    public var focusedTile: TileID { mode.tile }
    public var isMultiView: Bool { tiles.count > 1 }
    public var topOverlay: PlayerOverlay? { overlays.last }

    /// The tile whose audio plays. Single and foreground: that tile. Grid: the focused tile once audio has followed
    /// it (after the dwell), or, with "Audio follows focus" off, the last foreground tile.
    public func audibleTile(followsFocus: Bool) -> TileID {
        switch mode {
        case .single(let tile), .foreground(let tile): tile
        case .grid: followsFocus ? audioFocus : lastForeground
        }
    }

    public func index(of tile: TileID) -> Int? {
        tiles.firstIndex(of: tile)
    }

    // MARK: - Focus and selection

    /// Grid: moves focus to `tile`. False in other modes or for an unknown tile.
    @discardableResult
    public mutating func focus(_ tile: TileID) -> Bool {
        guard mode.isGrid, tiles.contains(tile), mode.tile != tile else { return false }
        mode = .grid(focused: tile)
        return true
    }

    /// A direction from the d-pad, a swipe or the arrow keys. Grid: focus moves to the neighbor in the layout, with
    /// no wrap at the edges. Foreground: ← and → cycle the tile in front in reading order; ↑ returns to the grid.
    /// False when nothing changed (an edge, ↓ in front, or a single tile), so the host can use the key.
    @discardableResult
    public mutating func move(_ direction: TileDirection, shape: GridShape) -> Bool {
        switch mode {
        case .single:
            return false
        case .grid(let focused):
            guard let index = index(of: focused),
                  let next = MultiViewGeometry.neighbor(of: index, toward: direction, count: tiles.count,
                                                        shape: shape) else { return false }
            mode = .grid(focused: tiles[next])
            return true
        case .foreground(let front):
            switch direction {
            case .leftward: return cycleForeground(forward: false)
            case .rightward: return cycleForeground(forward: true)
            case .upward:
                mode = .grid(focused: front)
                return true
            case .downward: return false
            }
        }
    }

    /// Foreground: brings the next (or previous) tile in reading order to the front, wrapping around.
    @discardableResult
    public mutating func cycleForeground(forward: Bool) -> Bool {
        guard case .foreground(let front) = mode, tiles.count > 1, let index = index(of: front) else { return false }
        let next = (index + (forward ? 1 : -1) + tiles.count) % tiles.count
        setMode(.foreground(tiles[next]))
        return true
    }

    /// One click, Select, tap or Return on `tile`. Grid: it comes forward. Foreground or single: the controls.
    @discardableResult
    public mutating func select(_ tile: TileID) -> SelectOutcome {
        guard tiles.contains(tile) else { return .ignored }
        switch mode {
        case .grid:
            setMode(.foreground(tile))
            return .broughtForward
        case .foreground(let front) where front != tile:
            setMode(.foreground(tile))
            return .broughtForward
        case .foreground, .single:
            present(.controls)
            return .showControls
        }
    }

    /// Pops the innermost layer: an overlay, then the foreground tile (back to the grid). False when nothing is
    /// left to pop; the host then leaves the player.
    public mutating func back() -> Bool {
        if !overlays.isEmpty {
            overlays.removeLast()
            return true
        }
        if case .foreground(let front) = mode {
            mode = .grid(focused: front)
            return true
        }
        return false
    }

    // MARK: - Overlays

    /// Shows `overlay` as the innermost layer (moving it to the top if it is already shown).
    public mutating func present(_ overlay: PlayerOverlay) {
        overlays.removeAll { $0 == overlay }
        overlays.append(overlay)
    }

    public mutating func dismiss(_ overlay: PlayerOverlay) {
        overlays.removeAll { $0 == overlay }
    }

    // MARK: - Audio

    /// Records that grid audio followed focus to `tile` (after the dwell).
    public mutating func commitAudioFocus(_ tile: TileID) {
        guard tiles.contains(tile) else { return }
        audioFocus = tile
    }

    /// Sets the mode, keeping the audio bookkeeping in step: a tile alone or in front is audible.
    mutating func setMode(_ newMode: MultiViewMode) {
        mode = newMode
        switch newMode {
        case .single(let tile), .foreground(let tile):
            lastForeground = tile
            audioFocus = tile
        case .grid:
            break
        }
    }
}
