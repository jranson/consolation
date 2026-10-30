//
//  CEA608DecoderCommands.swift
//  PlaybackKit
//
//  The miscellaneous control codes and preamble address codes: caption modes, memory commands, roll-up windows and
//  cursor positioning.
//

import Foundation

nonisolated extension CEA608Decoder {
    mutating func apply(_ command: CEA608Command) {
        switch command {
        case .resumeCaptionLoading, .resumeDirectCaptioning, .rollUp2, .rollUp3, .rollUp4, .textRestart,
             .resumeTextDisplay:
            changeMode(command)
        case .endOfCaption, .eraseDisplayedMemory, .eraseNonDisplayedMemory:
            applyMemoryCommand(command)
        case .backspace, .deleteToEndOfRow, .carriageReturn:
            applyEditCommand(command)
        case .alarmOff, .alarmOn, .flashOn:
            break
        }
    }

    mutating func apply(_ preamble: CEA608Preamble) {
        if case .rollUp(let depth) = mode {
            // In roll-up mode a PAC's row becomes the base row; the window moves with its contents.
            let newBase = max(preamble.row, depth - 1)
            displayed.moveWindow(depth: depth, from: rollUpBase, to: newBase)
            rollUpBase = newBase
            cursorRow = newBase
        } else {
            cursorRow = preamble.row
        }
        cursorColumn = preamble.column
        pen = preamble.style
    }

    private mutating func changeMode(_ command: CEA608Command) {
        switch command {
        case .resumeCaptionLoading:
            mode = .popOn
        case .resumeDirectCaptioning:
            if case .rollUp = mode {
                displayed.clear()
            }
            mode = .paintOn
        case .rollUp2:
            startRollUp(depth: 2)
        case .rollUp3:
            startRollUp(depth: 3)
        case .rollUp4:
            startRollUp(depth: 4)
        default:
            mode = .text
        }
    }

    private mutating func startRollUp(depth: Int) {
        if case .rollUp = mode {
            // Changing the depth keeps the base row and what is on it.
            let base = max(rollUpBase, depth - 1)
            displayed.moveWindow(depth: depth, from: rollUpBase, to: base)
            rollUpBase = base
            displayed.clear(outside: (base - depth + 1)...base)
        } else {
            // Entering roll-up from another mode erases both memories and starts at the bottom row.
            displayed.clear()
            nonDisplayed.clear()
            rollUpBase = CaptionMemory.rows - 1
            cursorRow = rollUpBase
            cursorColumn = 0
            pen = .plain
        }
        mode = .rollUp(depth: depth)
    }

    private mutating func applyMemoryCommand(_ command: CEA608Command) {
        switch command {
        case .endOfCaption:
            swap(&displayed, &nonDisplayed)
            mode = .popOn
        case .eraseDisplayedMemory:
            displayed.clear()
        default:
            nonDisplayed.clear()
        }
    }

    private mutating func applyEditCommand(_ command: CEA608Command) {
        let row = cursorRow
        switch command {
        case .backspace:
            guard cursorColumn > 0 else { return }
            cursorColumn -= 1
            let column = cursorColumn
            editTarget { $0[row, column] = nil }
        case .deleteToEndOfRow:
            let column = min(cursorColumn, CaptionMemory.columns - 1)
            editTarget { $0.clear(row: row, from: column) }
        default:
            guard case .rollUp(let depth) = mode else { return }
            displayed.rollUp(depth: depth, base: rollUpBase)
            cursorRow = rollUpBase
            cursorColumn = 0
        }
    }
}
