//
//  MultiViewStateEditing.swift
//  PlayerKit
//
//  Adding, removing, replacing and moving tiles, Exit Multi-view, and restoring an arrangement.
//

import Foundation

nonisolated public extension MultiViewState {
    /// Adds `tile` at the end of the grid and focuses it (single → grid). Audio stays where it was until the session
    /// moves it (after the new tile's first frame and the focus dwell). False if the tile is already there.
    @discardableResult
    mutating func add(_ tile: TileID) -> Bool {
        guard !tiles.contains(tile) else { return false }
        tiles.append(tile)
        setMode(.grid(focused: tile))
        return true
    }

    /// Removes `tile`. Focus (and audio, if it was on the tile) moves to the tile now in its place, or the one
    /// before it; when one tile remains it fills the player. False for an unknown tile or the last one.
    @discardableResult
    mutating func remove(_ tile: TileID) -> Bool {
        guard tiles.count > 1, let index = index(of: tile) else { return false }
        tiles.remove(at: index)
        let neighbor = tiles[min(index, tiles.count - 1)]
        if tiles.count == 1 {
            setMode(.single(neighbor))
            overlays.removeAll { $0 == .controls }
            return true
        }
        switch mode {
        case .grid(let focused) where focused == tile: mode = .grid(focused: neighbor)
        case .foreground(let front) where front == tile: mode = .grid(focused: neighbor)
        default: break
        }
        if lastForeground == tile { lastForeground = mode.tile }
        if audioFocus == tile { audioFocus = mode.tile }
        return true
    }

    /// Puts `newTile` where `old` is, keeping its position, focus and audio.
    @discardableResult
    mutating func replace(_ old: TileID, with newTile: TileID) -> Bool {
        guard let index = index(of: old), !tiles.contains(newTile) else { return false }
        tiles[index] = newTile
        switch mode {
        case .single(let tile) where tile == old: mode = .single(newTile)
        case .grid(let tile) where tile == old: mode = .grid(focused: newTile)
        case .foreground(let tile) where tile == old: mode = .foreground(newTile)
        default: break
        }
        if lastForeground == old { lastForeground = newTile }
        if audioFocus == old { audioFocus = newTile }
        return true
    }

    /// Swaps `tile` with its neighbor in reading order (`offset` -1 is Move ←, +1 is Move →).
    @discardableResult
    mutating func moveTile(_ tile: TileID, by offset: Int) -> Bool {
        guard let index = index(of: tile) else { return false }
        let target = index + offset
        guard offset != 0, tiles.indices.contains(target) else { return false }
        tiles.swapAt(index, target)
        return true
    }

    /// Exit Multi-view: keeps `keeping` (default: the foreground or focused tile) alone and returns the tiles to
    /// stop. Every overlay closes.
    @discardableResult
    mutating func exitMultiView(keeping: TileID? = nil) -> [TileID] {
        let keep = keeping.flatMap { tiles.contains($0) ? $0 : nil } ?? focusedTile
        let removed = tiles.filter { $0 != keep }
        tiles = [keep]
        setMode(.single(keep))
        overlays.removeAll()
        return removed
    }

    /// Puts the tiles in `order` (a permutation of the current tiles). False otherwise.
    @discardableResult
    mutating func reorder(_ order: [TileID]) -> Bool {
        guard order.count == tiles.count, Set(order) == Set(tiles) else { return false }
        tiles = order
        return true
    }

    /// Shows `newMode` if it fits the tiles (single for one tile, grid or foreground for several).
    @discardableResult
    mutating func show(_ newMode: MultiViewMode) -> Bool {
        guard tiles.contains(newMode.tile), newMode.isSingle == (tiles.count == 1) else { return false }
        setMode(newMode)
        return true
    }
}
