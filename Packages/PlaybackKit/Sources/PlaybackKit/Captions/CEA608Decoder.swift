//
//  CEA608Decoder.swift
//  PlaybackKit
//
//  A clean-room CEA-608 line 21 caption decoder for one caption service (CC1-CC4), written from CEA-608-E and
//  ATSC A/53 Part 4. Feed it `cc_data` in presentation order; it keeps the displayed and non-displayed memories and
//  reports when what is displayed changes.
//

import Foundation

nonisolated public struct CEA608Decoder: Sendable {
    /// How captions are being drawn on the selected channel.
    enum Mode: Equatable {
        /// No caption mode command has arrived yet; characters are dropped.
        case none
        /// RCL: characters build the non-displayed memory; EOC swaps it onto the screen.
        case popOn
        /// RDC: characters appear on screen as they arrive.
        case paintOn
        /// RU2/RU3/RU4: a window of `depth` rows ending at the base row, scrolled by CR.
        case rollUp(depth: Int)
        /// TR/RTD: the channel carries a text service, not captions.
        case text
    }

    /// The default stale-caption timeout: 16 seconds of 90 kHz ticks.
    public static let defaultStaleTimeout: Int64 = 16 * 90_000

    public let service: CaptionService
    /// A non-empty caption that has not changed for this many 90 kHz ticks is erased. Zero or less disables it.
    public var staleTimeout: Int64

    var displayed = CaptionMemory()
    var nonDisplayed = CaptionMemory()
    var mode = Mode.none
    var cursorRow = CaptionMemory.rows - 1
    /// 0...32; 32 means "just wrote the last column", so the next character overwrites column 31.
    var cursorColumn = 0
    var pen = CaptionStyle.plain
    var rollUpBase = CaptionMemory.rows - 1
    /// The data channel (1 or 2) that the most recent control code in this field addressed.
    private var activeChannel = 1
    private var inXDS = false
    /// The previous control code, to drop its redundant second transmission.
    private var lastControl: UInt16?
    private var lastChange: Int64?

    public init(service: CaptionService = .cc1, staleTimeout: Int64 = CEA608Decoder.defaultStaleTimeout) {
        self.service = service
        self.staleTimeout = staleTimeout
    }

    /// What is on screen now.
    public var screen: CaptionScreen { displayed.screen }

    /// Forgets all state, as after a discontinuity or a channel change.
    public mutating func reset() {
        self = CEA608Decoder(service: service, staleTimeout: staleTimeout)
    }

    /// Decodes one picture's `cc_data` triplets (`cc_valid`/`cc_type` byte plus two data bytes each), keeping only
    /// valid pairs for this service's field. `pts` is the picture's presentation time in 90 kHz ticks. Returns
    /// whether the displayed caption changed (including a stale caption being erased).
    @discardableResult
    public mutating func decode(ccData: Data, pts: Int64) -> Bool {
        var changed = expire(at: pts)
        let before = displayed
        let fieldType = UInt8(service.field - 1)
        ccData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 3 <= raw.count {
                let header = raw[offset]
                if header & 0x04 != 0, header & 0x03 == fieldType {
                    handle(raw[offset + 1], raw[offset + 2])
                }
                offset += 3
            }
        }
        if displayed != before {
            changed = true
            lastChange = pts
        }
        return changed
    }

    /// Decodes one byte pair of this service's field, with parity bits still present. Returns whether the
    /// displayed caption changed.
    @discardableResult
    public mutating func decode(pair first: UInt8, _ second: UInt8, pts: Int64) -> Bool {
        var changed = expire(at: pts)
        let before = displayed
        handle(first, second)
        if displayed != before {
            changed = true
            lastChange = pts
        }
        return changed
    }

    /// Erases a displayed caption that has not changed for `staleTimeout`. Returns whether it erased one.
    @discardableResult
    public mutating func expire(at pts: Int64) -> Bool {
        guard let last = lastChange else { return false }
        if pts < last {
            // The timeline went backwards; restart the clock rather than erase early or never.
            lastChange = pts
            return false
        }
        guard staleTimeout > 0, pts - last >= staleTimeout, !displayed.isEmpty else { return false }
        displayed.clear()
        lastChange = pts
        return true
    }

    // MARK: - Byte pairs

    private mutating func handle(_ rawFirst: UInt8, _ rawSecond: UInt8) {
        let first = rawFirst & 0x7F
        let second = rawSecond & 0x7F
        // Null padding between the two transmissions of a control code does not separate them.
        guard first != 0 || second != 0 else { return }
        let firstValid = CEA608Code.hasOddParity(rawFirst)
        let secondValid = CEA608Code.hasOddParity(rawSecond)
        let code: CEA608Code
        if (0x10...0x1F).contains(first) {
            // A control code with a parity error is ignored; its redundant copy, if intact, still applies.
            guard firstValid, secondValid else {
                lastControl = nil
                return
            }
            code = CEA608Code.classify(first, second)
        } else {
            // A character with a parity error is dropped on its own.
            code = CEA608Code.classify(firstValid ? first : 0, secondValid ? second : 0)
        }
        if code.isControl {
            let key = UInt16(first) << 8 | UInt16(second)
            if lastControl == key {
                lastControl = nil
                return
            }
            lastControl = key
        } else {
            lastControl = nil
        }
        apply(code)
    }

    private mutating func apply(_ code: CEA608Code) {
        switch code {
        case .xdsStart:
            inXDS = true
        case .xdsEnd:
            inXDS = false
        case .ignored:
            break
        case .characters(let characters):
            guard !inXDS, activeChannel == service.dataChannel else { return }
            for character in characters {
                write(character)
            }
        default:
            applyControl(code)
        }
    }

    private mutating func applyControl(_ code: CEA608Code) {
        inXDS = false
        guard let channel = code.channel else { return }
        activeChannel = channel
        guard channel == service.dataChannel else { return }
        switch code {
        case .command(_, let command):
            apply(command)
        case .preamble(_, let preamble):
            apply(preamble)
        case .midRow(_, let style):
            applyMidRow(style)
        case .special(_, let character):
            write(character)
        case .extended(_, let character):
            if cursorColumn > 0 {
                cursorColumn -= 1
            }
            write(character)
        case .tabOffset(_, let columns):
            cursorColumn = min(cursorColumn + columns, CaptionMemory.columns - 1)
        default:
            break
        }
    }

    // MARK: - Writing

    /// Whether characters currently land anywhere.
    private var isWritable: Bool {
        switch mode {
        case .popOn, .paintOn, .rollUp: true
        case .none, .text: false
        }
    }

    /// Runs `body` on the memory that characters and edits currently address.
    mutating func editTarget(_ body: (inout CaptionMemory) -> Void) {
        if mode == .popOn {
            body(&nonDisplayed)
        } else {
            body(&displayed)
        }
    }

    /// Writes a character (nil: a transparent space) at the cursor and advances it.
    private mutating func write(_ character: Character?) {
        guard isWritable else { return }
        let column = min(cursorColumn, CaptionMemory.columns - 1)
        let row = cursorRow
        let cell = character.map { CaptionCell(character: $0, style: pen) }
        editTarget { $0[row, column] = cell }
        cursorColumn = min(column + 1, CaptionMemory.columns)
    }

    private mutating func applyMidRow(_ style: CaptionStyle) {
        var newPen = pen
        if style.italic {
            // Italics keep the current color.
            newPen.italic = true
        } else {
            newPen.color = style.color
            newPen.italic = false
        }
        newPen.underline = style.underline
        pen = newPen
        // A mid-row code occupies one column, shown as a space in the new attributes.
        write(" ")
    }
}

nonisolated extension CEA608Code {
    /// The data channel a control code addresses, or nil for characters, XDS and padding.
    var channel: Int? {
        switch self {
        case .command(let channel, _), .preamble(let channel, _), .midRow(let channel, _),
             .special(let channel, _), .extended(let channel, _), .tabOffset(let channel, _),
             .unsupported(let channel):
            channel
        case .characters, .xdsStart, .xdsEnd, .ignored:
            nil
        }
    }
}
