//
//  CaptionScreen.swift
//  PlaybackKit
//
//  The value a caption overlay renders: the displayed CEA-608 memory as rows of styled runs on the classic
//  15-row × 32-column grid.
//

import Foundation

/// A caption service carried in ATSC A/53 `cc_data`: CC1 and CC2 are the two data channels of field 1, CC3 and CC4
/// the two data channels of field 2.
nonisolated public enum CaptionService: Int, Sendable, Hashable, CaseIterable {
    case cc1 = 1
    case cc2 = 2
    case cc3 = 3
    case cc4 = 4

    /// 1 or 2: the NTSC field whose `cc_data` pairs carry the service (`cc_type` 0 or 1).
    public var field: Int { rawValue <= 2 ? 1 : 2 }

    /// 1 or 2: the data channel within the field.
    public var dataChannel: Int { rawValue % 2 == 1 ? 1 : 2 }
}

/// The CEA-608 foreground colors (preamble address and mid-row codes).
nonisolated public enum CaptionColor: Int, Sendable, Hashable, CaseIterable {
    case white
    case green
    case blue
    case cyan
    case red
    case yellow
    case magenta
}

/// The pen attributes of one character cell.
nonisolated public struct CaptionStyle: Sendable, Hashable {
    public var color: CaptionColor
    public var italic: Bool
    public var underline: Bool

    public init(color: CaptionColor = .white, italic: Bool = false, underline: Bool = false) {
        self.color = color
        self.italic = italic
        self.underline = underline
    }

    public static let plain = CaptionStyle()
}

/// One occupied cell of caption memory. Unoccupied cells are transparent (no background box).
nonisolated public struct CaptionCell: Sendable, Hashable {
    public var character: Character
    public var style: CaptionStyle

    public init(character: Character, style: CaptionStyle = .plain) {
        self.character = character
        self.style = style
    }
}

/// A run of adjacent occupied cells in one row that share a style.
nonisolated public struct CaptionRun: Sendable, Hashable {
    /// 0-based column (0...31) of the run's first character.
    public var column: Int
    public var text: String
    public var style: CaptionStyle

    public init(column: Int, text: String, style: CaptionStyle = .plain) {
        self.column = column
        self.text = text
        self.style = style
    }

    /// Number of grid columns the run covers.
    public var length: Int { text.count }
}

/// One non-empty row of the caption grid.
nonisolated public struct CaptionRow: Sendable, Hashable, Identifiable {
    /// 0-based row (0...14); CEA-608 calls these rows 1 to 15.
    public var row: Int
    /// Runs in column order; gaps between runs are transparent cells.
    public var runs: [CaptionRun]

    public init(row: Int, runs: [CaptionRun]) {
        self.row = row
        self.runs = runs
    }

    public var id: Int { row }

    /// The row's characters from its first occupied column, with transparent gaps as spaces.
    public var text: String {
        guard let first = runs.first else { return "" }
        var result = ""
        var column = first.column
        for run in runs {
            result += String(repeating: " ", count: max(0, run.column - column)) + run.text
            column = run.column + run.length
        }
        return result
    }
}

/// What a CEA-608 decoder currently displays.
nonisolated public struct CaptionScreen: Sendable, Hashable {
    public static let rowCount = 15
    public static let columnCount = 32
    public static let empty = CaptionScreen(rows: [])

    /// Non-empty rows, top to bottom.
    public var rows: [CaptionRow]

    public init(rows: [CaptionRow]) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// Each non-empty row's text, top to bottom (handy for logging and tests).
    public var lines: [String] { rows.map(\.text) }

    /// Builds a screen from a row-major grid of `rowCount × columnCount` cells (nil = transparent).
    public init(cells: [CaptionCell?]) {
        var rows: [CaptionRow] = []
        let columns = Self.columnCount
        for row in 0..<Self.rowCount where row * columns + columns <= cells.count {
            var runs: [CaptionRun] = []
            for column in 0..<columns {
                guard let cell = cells[row * columns + column] else { continue }
                if var last = runs.last, last.style == cell.style, last.column + last.length == column {
                    last.text.append(cell.character)
                    runs[runs.count - 1] = last
                } else {
                    runs.append(CaptionRun(column: column, text: String(cell.character), style: cell.style))
                }
            }
            if !runs.isEmpty {
                rows.append(CaptionRow(row: row, runs: runs))
            }
        }
        self.rows = rows
    }
}
