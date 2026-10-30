//
//  CaptionMemory.swift
//  PlaybackKit
//
//  One CEA-608 caption memory (displayed or non-displayed): a 15 × 32 grid of optional cells.
//

import Foundation

nonisolated struct CaptionMemory: Sendable, Equatable {
    static let rows = CaptionScreen.rowCount
    static let columns = CaptionScreen.columnCount

    private(set) var cells = [CaptionCell?](repeating: nil, count: rows * columns)

    var isEmpty: Bool { cells.allSatisfy { $0 == nil } }

    var screen: CaptionScreen { CaptionScreen(cells: cells) }

    subscript(row: Int, column: Int) -> CaptionCell? {
        get {
            guard Self.contains(row: row, column: column) else { return nil }
            return cells[row * Self.columns + column]
        }
        set {
            guard Self.contains(row: row, column: column) else { return }
            cells[row * Self.columns + column] = newValue
        }
    }

    static func contains(row: Int, column: Int) -> Bool {
        (0..<rows).contains(row) && (0..<columns).contains(column)
    }

    mutating func clear() {
        cells = [CaptionCell?](repeating: nil, count: Self.rows * Self.columns)
    }

    /// Clears `row` from `column` to its end.
    mutating func clear(row: Int, from column: Int = 0) {
        guard (0..<Self.rows).contains(row) else { return }
        for index in max(0, column)..<Self.columns {
            cells[row * Self.columns + index] = nil
        }
    }

    /// Clears every row outside `range`.
    mutating func clear(outside range: ClosedRange<Int>) {
        for row in 0..<Self.rows where !range.contains(row) {
            clear(row: row)
        }
    }

    /// Copies row `source` over row `destination`.
    mutating func copy(row source: Int, to destination: Int) {
        guard (0..<Self.rows).contains(source), (0..<Self.rows).contains(destination), source != destination else {
            return
        }
        for column in 0..<Self.columns {
            cells[destination * Self.columns + column] = cells[source * Self.columns + column]
        }
    }

    /// Moves the `depth` rows ending at `oldBase` so they end at `newBase`, clearing every other row.
    mutating func moveWindow(depth: Int, from oldBase: Int, to newBase: Int) {
        guard oldBase != newBase else { return }
        let offset = newBase - oldBase
        // Copy in the direction that never overwrites a row before it has been read.
        let sources = Array((oldBase - depth + 1)...oldBase)
        for source in offset > 0 ? sources.reversed() : sources {
            copy(row: source, to: source + offset)
        }
        clear(outside: (newBase - depth + 1)...newBase)
    }

    /// Scrolls the `depth` rows ending at `base` up by one row and clears the base row.
    mutating func rollUp(depth: Int, base: Int) {
        let top = base - depth + 1
        if top < base {
            for row in top..<base {
                copy(row: row + 1, to: row)
            }
        }
        clear(row: base)
        clear(outside: top...base)
    }
}
