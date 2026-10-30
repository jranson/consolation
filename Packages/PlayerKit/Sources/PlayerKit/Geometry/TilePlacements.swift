//
//  TilePlacements.swift
//  PlayerKit
//
//  Where every tile goes for a state and presentation. Tiles never change identity; only these frames, z-order, corners
//  and dimming change, and the view animates them.
//

import CoreGraphics

nonisolated public extension MultiViewGeometry {
    /// Placements for every tile.
    /// - Single: the tile fills the container (no inset, corners, dimming or focus ring).
    /// - Grid: each tile in its cell; the last foreground tile stays above the others so it shrinks back on top.
    /// - Foreground: the front tile in the inset foreground frame above the dimmed grid; only it is interactive.
    /// - Mini: the audible tile fills the container; the others stay hosted but invisible.
    /// - Hidden: nothing is visible or interactive.
    static func placements(for state: MultiViewState, presentation: PlayerPresentation = .full,
                           audibleTile: TileID? = nil, in container: CGSize,
                           metrics: MultiViewMetrics) -> [TileID: TilePlacement] {
        let full = CGRect(origin: .zero, size: container)
        switch presentation {
        case .mini, .hidden:
            let shown = audibleTile ?? state.focusedTile
            let visible = presentation == .mini
            return Dictionary(uniqueKeysWithValues: state.tiles.map { tile in
                (tile, TilePlacement(frame: full, zIndex: tile == shown ? 1 : 0, isInteractive: false,
                                     isVisible: visible && tile == shown))
            })
        case .full:
            break
        }
        switch state.mode {
        case .single(let tile):
            return [tile: TilePlacement(frame: full)]
        case .grid:
            let cells = cellFrames(count: state.tiles.count, in: container, metrics: metrics)
            return Dictionary(uniqueKeysWithValues: zip(state.tiles, cells).map { tile, cell in
                (tile, TilePlacement(frame: cell, zIndex: tile == state.lastForeground ? 0.5 : 0,
                                     cornerRadius: metrics.gridCornerRadius))
            })
        case .foreground(let front):
            let cells = cellFrames(count: state.tiles.count, in: container, metrics: metrics)
            let frontFrame = foregroundFrame(in: container, metrics: metrics)
            return Dictionary(uniqueKeysWithValues: zip(state.tiles, cells).map { tile, cell in
                if tile == front {
                    return (tile, TilePlacement(frame: frontFrame, zIndex: 1,
                                                cornerRadius: metrics.foregroundCornerRadius, isForeground: true))
                }
                return (tile, TilePlacement(frame: cell, isDimmed: true, cornerRadius: metrics.gridCornerRadius,
                                            isInteractive: false))
            })
        }
    }
}
