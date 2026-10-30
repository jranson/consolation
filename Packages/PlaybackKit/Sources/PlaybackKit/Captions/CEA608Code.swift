//
//  CEA608Code.swift
//  PlaybackKit
//
//  Classifies one CEA-608 byte pair (parity already checked and stripped) into the code it carries. Written from
//  CEA-608-E: control codes have a first byte of 0x10-0x1F, where bit 3 selects data channel 2.
//

import Foundation

/// Miscellaneous control codes (first byte 0x14/0x1C, or 0x15/0x1D in field 2; second byte 0x20-0x2F).
nonisolated enum CEA608Command: UInt8, Sendable {
    case resumeCaptionLoading = 0x20  // RCL
    case backspace = 0x21  // BS
    case alarmOff = 0x22  // AOF (reserved)
    case alarmOn = 0x23  // AON (reserved)
    case deleteToEndOfRow = 0x24  // DER
    case rollUp2 = 0x25  // RU2
    case rollUp3 = 0x26  // RU3
    case rollUp4 = 0x27  // RU4
    case flashOn = 0x28  // FON
    case resumeDirectCaptioning = 0x29  // RDC
    case textRestart = 0x2A  // TR
    case resumeTextDisplay = 0x2B  // RTD
    case eraseDisplayedMemory = 0x2C  // EDM
    case carriageReturn = 0x2D  // CR
    case eraseNonDisplayedMemory = 0x2E  // ENM
    case endOfCaption = 0x2F  // EOC
}

/// A preamble address code's position and pen.
nonisolated struct CEA608Preamble: Sendable, Equatable {
    /// 0-based row (0...14).
    var row: Int
    /// 0-based indent column (0, 4, ... 28).
    var column: Int
    var style: CaptionStyle
}

nonisolated enum CEA608Code: Sendable, Equatable {
    /// One or two basic characters (a second byte of 0x00 is padding and is left out).
    case characters([Character])
    case command(channel: Int, CEA608Command)
    case preamble(channel: Int, CEA608Preamble)
    case midRow(channel: Int, CaptionStyle)
    /// A special character; nil is the transparent space.
    case special(channel: Int, Character?)
    /// An extended character, which replaces the basic-set fallback character sent just before it.
    case extended(channel: Int, Character)
    case tabOffset(channel: Int, columns: Int)
    /// A valid but unsupported control code (background and font attributes); it still selects the channel.
    case unsupported(channel: Int)
    /// Start or continuation of an XDS packet (field 2, first byte 0x01-0x0E).
    case xdsStart
    /// End of an XDS packet (first byte 0x0F; the second byte is its checksum).
    case xdsEnd
    /// Null padding or bytes that mean nothing.
    case ignored

    /// Whether the code is a two-byte control code, which CEA-608 transmits twice in a row.
    var isControl: Bool {
        switch self {
        case .characters, .xdsStart, .xdsEnd, .ignored: false
        default: true
        }
    }

    /// PAC rows (1-based) for first bytes 0x10-0x17 with the second byte's 0x20 bit clear.
    private static let preambleRows = [11, 1, 3, 12, 14, 5, 7, 9]

    /// Whether `byte` has odd parity, as every CEA-608 byte must.
    static func hasOddParity(_ byte: UInt8) -> Bool {
        byte.nonzeroBitCount % 2 == 1
    }

    /// Classifies a pair. `first` and `second` must already have their parity bit stripped.
    static func classify(_ first: UInt8, _ second: UInt8) -> CEA608Code {
        switch first {
        case 0x00:
            return characters(second, 0)
        case 0x01...0x0E:
            return .xdsStart
        case 0x0F:
            return .xdsEnd
        case 0x10...0x1F:
            return control(first, second)
        default:
            return characters(first, second)
        }
    }

    private static func characters(_ first: UInt8, _ second: UInt8) -> CEA608Code {
        let mapped = [first, second].compactMap(CEA608CharacterSet.basic)
        return mapped.isEmpty ? .ignored : .characters(mapped)
    }

    private static func control(_ first: UInt8, _ second: UInt8) -> CEA608Code {
        let channel = first & 0x08 == 0 ? 1 : 2
        let base = first & 0x77
        if (0x40...0x7F).contains(second) {
            return .preamble(channel: channel, preamble(base, second))
        }
        guard (0x20...0x3F).contains(second) else { return .ignored }
        switch base {
        case 0x10:
            // Background attribute codes (optional in CEA-608-E).
            return second <= 0x2F ? .unsupported(channel: channel) : .ignored
        case 0x11:
            if second >= 0x30, let special = CEA608CharacterSet.special(second) {
                return .special(channel: channel, special)
            }
            return .midRow(channel: channel, midRowStyle(second))
        case 0x12, 0x13:
            guard let character = CEA608CharacterSet.extended(set: Int(base - 0x12), second) else { return .ignored }
            return .extended(channel: channel, character)
        case 0x14, 0x15:
            guard let command = CEA608Command(rawValue: second) else { return .ignored }
            return .command(channel: channel, command)
        case 0x17:
            return tabOrAttribute(channel: channel, second)
        default:
            return .ignored
        }
    }

    private static func tabOrAttribute(channel: Int, _ second: UInt8) -> CEA608Code {
        switch second {
        case 0x21...0x23: .tabOffset(channel: channel, columns: Int(second - 0x20))
        case 0x24...0x2F: .unsupported(channel: channel)
        default: .ignored
        }
    }

    /// Bits 1-3 of a PAC or mid-row second byte: 0-6 are colors, 7 is italics (white for a PAC).
    private static func midRowStyle(_ second: UInt8) -> CaptionStyle {
        let attribute = Int((second & 0x0E) >> 1)
        let underline = second & 0x01 != 0
        if attribute == 7 {
            return CaptionStyle(color: .white, italic: true, underline: underline)
        }
        return CaptionStyle(color: CaptionColor(rawValue: attribute) ?? .white, italic: false, underline: underline)
    }

    private static func preamble(_ base: UInt8, _ second: UInt8) -> CEA608Preamble {
        var row = preambleRows[Int(base & 0x07)]
        if base != 0x10, second & 0x20 != 0 {
            row += 1
        }
        let attribute = Int((second & 0x1E) >> 1)
        let underline = second & 0x01 != 0
        if attribute >= 8 {
            return CEA608Preamble(row: row - 1, column: (attribute - 8) * 4, style: CaptionStyle(underline: underline))
        }
        return CEA608Preamble(row: row - 1, column: 0, style: midRowStyle(second))
    }
}
