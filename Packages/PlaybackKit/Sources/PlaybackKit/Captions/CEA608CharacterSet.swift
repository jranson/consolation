//
//  CEA608CharacterSet.swift
//  PlaybackKit
//
//  CEA-608 character repertoire mapped to Unicode: the basic set (one byte, mostly ASCII), the special characters
//  (0x11/0x19 0x30-0x3F) and the two extended sets (0x12/0x1A and 0x13/0x1B 0x20-0x3F).
//

import Foundation

nonisolated enum CEA608CharacterSet {
    /// The basic set differs from ASCII in ten positions.
    private static let basicExceptions: [UInt8: Character] = [
        0x2A: "á", 0x5C: "é", 0x5E: "í", 0x5F: "ó", 0x60: "ú",
        0x7B: "ç", 0x7C: "÷", 0x7D: "Ñ", 0x7E: "ñ", 0x7F: "█"
    ]

    /// Special characters, indexed by the second byte minus 0x30. Index 9 is the transparent space (nil).
    private static let special: [Character?] = [
        "®", "°", "½", "¿", "™", "¢", "£", "♪",
        "à", nil, "è", "â", "ê", "î", "ô", "û"
    ]

    /// Extended Spanish, miscellaneous and French characters (first byte 0x12), indexed by the second byte minus 0x20.
    private static let extendedSpanishFrench: [Character] = [
        "Á", "É", "Ó", "Ú", "Ü", "ü", "\u{2018}", "¡",
        "*", "'", "—", "©", "℠", "•", "\u{201C}", "\u{201D}",
        "À", "Â", "Ç", "È", "Ê", "Ë", "ë", "Î",
        "Ï", "ï", "Ô", "Ù", "ù", "Û", "«", "»"
    ]

    /// Extended Portuguese, German and Danish characters (first byte 0x13), indexed by the second byte minus 0x20.
    private static let extendedPortugueseGerman: [Character] = [
        "Ã", "ã", "Í", "Ì", "ì", "Ò", "ò", "Õ",
        "õ", "{", "}", "\\", "^", "_", "|", "~",
        "Ä", "ä", "Ö", "ö", "ß", "¥", "¤", "│",
        "Å", "å", "Ø", "ø", "┌", "┐", "└", "┘"
    ]

    /// A basic character (0x20-0x7F, parity stripped), or nil outside that range.
    static func basic(_ byte: UInt8) -> Character? {
        guard (0x20...0x7F).contains(byte) else { return nil }
        if let exception = basicExceptions[byte] { return exception }
        return Character(Unicode.Scalar(byte))
    }

    /// A special character for a second byte in 0x30-0x3F. Returns `.some(nil)` for the transparent space.
    static func special(_ byte: UInt8) -> Character?? {
        guard (0x30...0x3F).contains(byte) else { return nil }
        return .some(special[Int(byte - 0x30)])
    }

    /// An extended character: `set` is 0 for first byte 0x12 and 1 for 0x13; `byte` is 0x20-0x3F.
    static func extended(set: Int, _ byte: UInt8) -> Character? {
        guard (0x20...0x3F).contains(byte) else { return nil }
        let table = set == 0 ? extendedSpanishFrench : extendedPortugueseGerman
        return table[Int(byte - 0x20)]
    }
}
