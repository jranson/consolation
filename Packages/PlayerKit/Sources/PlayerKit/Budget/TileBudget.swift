//
//  TileBudget.swift
//  PlayerKit
//
//  How many tiles the device may play, and when the grid gives way to the stack. Every tile counts toward a CPU cap,
//  whatever the player's size. A small player (a phone, a narrow window) shows three or more tiles as the stack only:
//  one tile in front, the next and previous one a swipe away. Tuner capacity is separate (`TileCapacityProviding`).
//

import CoreGraphics

nonisolated public struct TileBudget: Hashable, Sendable {
    /// The CPU cap: 4 on Apple TV, iPad and iPhone, 6 on Apple-silicon Macs to start (measure on device before
    /// raising).
    public var maximumTiles: Int
    /// The most tiles the grid lays out.
    public var gridLimit: Int
    /// From this many tiles on, a small player shows the stack only.
    public var stackOnlyTiles: Int
    /// A player whose shorter side is under this many points is small.
    public var smallPlayerSide: CGFloat

    public init(maximumTiles: Int, gridLimit: Int = 9, stackOnlyTiles: Int = 3, smallPlayerSide: CGFloat = 500) {
        self.maximumTiles = maximumTiles
        self.gridLimit = gridLimit
        self.stackOnlyTiles = stackOnlyTiles
        self.smallPlayerSide = smallPlayerSide
    }

    /// Starting caps for this platform.
    public static var platformDefault: TileBudget {
        #if os(macOS)
        TileBudget(maximumTiles: 6)
        #else
        TileBudget(maximumTiles: 4)
        #endif
    }

    /// The most tiles allowed.
    public var limit: Int { max(min(maximumTiles, gridLimit), 1) }

    /// Whether one more tile fits next to `tileCount` playing ones.
    public func admitsTile(after tileCount: Int) -> Bool {
        tileCount < limit
    }

    /// Whether `tileCount` tiles in a full player of `size` show as the stack only: the grid's cells would be too
    /// small to watch. False for a size that is not known yet.
    public func showsStackOnly(tileCount: Int, in size: CGSize) -> Bool {
        guard tileCount >= stackOnlyTiles, size.width > 0, size.height > 0 else { return false }
        return min(size.width, size.height) < smallPlayerSide
    }
}
