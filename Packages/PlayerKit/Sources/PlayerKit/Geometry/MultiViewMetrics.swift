//
//  MultiViewMetrics.swift
//  PlayerKit
//
//  Sizes for the grid and the foreground tile.
//

import CoreGraphics

nonisolated public struct MultiViewMetrics: Hashable, Sendable {
    /// Gap between grid cells.
    public var spacing: CGFloat
    /// Margin around the grid.
    public var padding: CGFloat
    /// The foreground frame is the container inset by this fraction of its size on every side...
    public var foregroundInsetFraction: CGFloat
    /// ...but at least this many points.
    public var minimumForegroundInset: CGFloat
    /// Corners of the foreground tile's video layer (continuous).
    public var foregroundCornerRadius: CGFloat
    /// Corners of grid tiles' video layers.
    public var gridCornerRadius: CGFloat
    /// Opacity of the black layer over tiles behind the foreground tile.
    public var dimming: Double
    /// Width of the focus ring on the focused grid tile.
    public var focusRingWidth: CGFloat

    public init(spacing: CGFloat = 16, padding: CGFloat = 16, foregroundInsetFraction: CGFloat = 0.05,
                minimumForegroundInset: CGFloat = 24, foregroundCornerRadius: CGFloat = 18,
                gridCornerRadius: CGFloat = 12, dimming: Double = 0.35, focusRingWidth: CGFloat = 4) {
        self.spacing = spacing
        self.padding = padding
        self.foregroundInsetFraction = foregroundInsetFraction
        self.minimumForegroundInset = minimumForegroundInset
        self.foregroundCornerRadius = foregroundCornerRadius
        self.gridCornerRadius = gridCornerRadius
        self.dimming = dimming
        self.focusRingWidth = focusRingWidth
    }

    /// Starting values per platform (tune on device): roomier on the TV.
    public static var standard: MultiViewMetrics {
        #if os(tvOS)
        MultiViewMetrics(spacing: 40, padding: 60, focusRingWidth: 6)
        #else
        MultiViewMetrics()
        #endif
    }
}

/// Where one tile goes and how it looks, for the current mode.
nonisolated public struct TilePlacement: Hashable, Sendable {
    public var frame: CGRect
    public var zIndex: Double
    /// Behind the foreground tile: a black layer darkens it.
    public var isDimmed: Bool
    public var cornerRadius: CGFloat
    public var isForeground: Bool
    /// Takes focus, clicks and taps (false behind the foreground tile, in the mini player and when hidden).
    public var isInteractive: Bool
    /// Drawn at all (false for the tiles other than the audible one in the mini player).
    public var isVisible: Bool

    public init(frame: CGRect, zIndex: Double = 0, isDimmed: Bool = false, cornerRadius: CGFloat = 0,
                isForeground: Bool = false, isInteractive: Bool = true, isVisible: Bool = true) {
        self.frame = frame
        self.zIndex = zIndex
        self.isDimmed = isDimmed
        self.cornerRadius = cornerRadius
        self.isForeground = isForeground
        self.isInteractive = isInteractive
        self.isVisible = isVisible
    }
}
