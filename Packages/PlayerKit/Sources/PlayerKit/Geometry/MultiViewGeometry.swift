//
//  MultiViewGeometry.swift
//  PlayerKit
//
//  The grid: a near-square grid of 16:9 cells, centered and letterboxed, with columns = ⌈√n⌉ and rows = ⌈n / columns⌉;
//  two tiles sit side by side, or stacked when that gives bigger cells (a portrait or narrow container). A short last
//  row is centered. The foreground frame is the container inset by 5% (at least 24 pt) on every side, fitted to 16:9.
//  Neighbors come from the cell frames, with no wrap at the edges.
//

import CoreGraphics

nonisolated public enum MultiViewGeometry {
    /// Cells and the foreground frame are 16:9; video aspect-fits inside them.
    public static let cellAspect: CGFloat = 16 / 9

    /// Columns and rows for `count` tiles in `container`.
    public static func shape(count: Int, container: CGSize) -> GridShape {
        guard count > 1 else { return GridShape(columns: 1, rows: 1) }
        if count == 2 {
            // Stack only when stacked cells are strictly bigger (ties stay side by side).
            let sideBySide = cellWidth(columns: 2, rows: 1, in: container, spacing: 0)
            let stacked = cellWidth(columns: 1, rows: 2, in: container, spacing: 0)
            return stacked > sideBySide ? GridShape(columns: 1, rows: 2) : GridShape(columns: 2, rows: 1)
        }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        return GridShape(columns: columns, rows: rows)
    }

    /// The grid cells for `count` tiles, in reading order.
    public static func cellFrames(count: Int, in container: CGSize, metrics: MultiViewMetrics) -> [CGRect] {
        let area = CGRect(origin: .zero, size: container).insetBy(dx: metrics.padding, dy: metrics.padding)
        return cellFrames(count: count, shape: shape(count: count, container: container), in: area,
                          spacing: metrics.spacing)
    }

    /// The cells for `count` tiles in `shape`, centered in `area`.
    public static func cellFrames(count: Int, shape: GridShape, in area: CGRect, spacing: CGFloat) -> [CGRect] {
        guard count > 0, area.width > 0, area.height > 0 else {
            return Array(repeating: .zero, count: max(count, 0))
        }
        let width = cellWidth(columns: shape.columns, rows: shape.rows, in: area.size, spacing: spacing)
        let height = width / cellAspect
        let gridHeight = height * CGFloat(shape.rows) + spacing * CGFloat(shape.rows - 1)
        let top = area.midY - gridHeight / 2
        return (0..<count).map { index in
            let row = index / shape.columns
            let column = index % shape.columns
            let inRow = min(shape.columns, count - row * shape.columns)
            let rowWidth = width * CGFloat(inRow) + spacing * CGFloat(inRow - 1)
            let left = area.midX - rowWidth / 2
            return CGRect(x: left + CGFloat(column) * (width + spacing), y: top + CGFloat(row) * (height + spacing),
                          width: width, height: height)
        }
    }

    /// The tile brought forward: the container inset by 5% (at least 24 pt) on every side, fitted to 16:9.
    public static func foregroundFrame(in container: CGSize, metrics: MultiViewMetrics) -> CGRect {
        let insetX = max(container.width * metrics.foregroundInsetFraction, metrics.minimumForegroundInset)
        let insetY = max(container.height * metrics.foregroundInsetFraction, metrics.minimumForegroundInset)
        let area = CGRect(origin: .zero, size: container).insetBy(dx: insetX, dy: insetY)
        guard area.width > 0, area.height > 0 else { return .zero }
        return aspectFit(cellAspect, in: area)
    }

    /// The largest rect of `aspect` (width / height) centered in `rect`.
    public static func aspectFit(_ aspect: CGFloat, in rect: CGRect) -> CGRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return .zero }
        let width = min(rect.width, rect.height * aspect)
        let height = width / aspect
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The tile next to tile `index` in `direction`: the nearest cell that overlaps it across the direction (same
    /// row for ← and →, overlapping columns for ↑ and ↓). Nil at the edges; there is no wrap.
    public static func neighbor(of index: Int, toward direction: TileDirection, count: Int,
                                shape: GridShape) -> Int? {
        guard count > 1, (0..<count).contains(index) else { return nil }
        let area = CGRect(x: 0, y: 0, width: CGFloat(shape.columns) * cellAspect * 9, height: CGFloat(shape.rows) * 9)
        let frames = cellFrames(count: count, shape: shape, in: area, spacing: 0)
        let current = frames[index]
        let epsilon: CGFloat = 0.001
        var best: (index: Int, relation: CellRelation)?
        for (candidate, frame) in frames.enumerated() where candidate != index {
            let relation = CellRelation(from: current, to: frame, direction: direction)
            guard relation.gap > -epsilon, relation.overlap > epsilon else { continue }
            if let best, (best.relation.gap, best.relation.offset) <= (relation.gap, relation.offset) { continue }
            best = (candidate, relation)
        }
        return best?.index
    }

    private static func cellWidth(columns: Int, rows: Int, in size: CGSize, spacing: CGFloat) -> CGFloat {
        let byWidth = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let byHeight = (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows) * cellAspect
        return max(min(byWidth, byHeight), 0)
    }
}

/// How one cell sits relative to another in a direction: the gap along it, the overlap across it, and the distance
/// between their centers across it.
nonisolated private struct CellRelation {
    let gap: CGFloat
    let overlap: CGFloat
    let offset: CGFloat

    init(from current: CGRect, to frame: CGRect, direction: TileDirection) {
        switch direction {
        case .leftward, .rightward:
            gap = direction == .rightward ? frame.minX - current.maxX : current.minX - frame.maxX
            overlap = min(current.maxY, frame.maxY) - max(current.minY, frame.minY)
            offset = abs(frame.midY - current.midY)
        case .upward, .downward:
            gap = direction == .downward ? frame.minY - current.maxY : current.minY - frame.maxY
            overlap = min(current.maxX, frame.maxX) - max(current.minX, frame.minX)
            offset = abs(frame.midX - current.midX)
        }
    }
}
