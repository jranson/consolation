//
//  TileBudget.swift
//  PlayerKit
//
//  How many tiles the device may play. Every tile counts toward a CPU cap; compact containers add at most two. The caps
//  limit adding tiles and never close one: folding an iPhone Duo with four tiles running keeps all four. Tuner capacity
//  is separate (`TileCapacityProviding`).
//

import CoreGraphics

nonisolated public struct TileBudget: Hashable, Sendable {
    /// The CPU cap: 4 on Apple TV and iPad, 6 on Apple-silicon Macs to start (measure on device before raising).
    public var maximumTiles: Int
    /// The most tiles the grid lays out.
    public var gridLimit: Int
    /// The cap when the player is narrower than `compactWidth`.
    public var compactMaximumTiles: Int
    public var compactWidth: CGFloat

    public init(maximumTiles: Int, gridLimit: Int = 9, compactMaximumTiles: Int = 2, compactWidth: CGFloat = 500) {
        self.maximumTiles = maximumTiles
        self.gridLimit = gridLimit
        self.compactMaximumTiles = compactMaximumTiles
        self.compactWidth = compactWidth
    }

    /// Starting caps for this platform.
    public static var platformDefault: TileBudget {
        #if os(macOS)
        TileBudget(maximumTiles: 6)
        #else
        TileBudget(maximumTiles: 4)
        #endif
    }

    /// The most tiles allowed in a player `containerWidth` points wide (nil: not laid out yet).
    public func limit(containerWidth: CGFloat?) -> Int {
        var limit = max(min(maximumTiles, gridLimit), 1)
        if let containerWidth, containerWidth > 0, containerWidth < compactWidth {
            limit = min(limit, compactMaximumTiles)
        }
        return limit
    }

    /// Whether one more tile fits next to `tileCount` playing ones.
    public func admitsTile(after tileCount: Int, containerWidth: CGFloat?) -> Bool {
        tileCount < limit(containerWidth: containerWidth)
    }
}
