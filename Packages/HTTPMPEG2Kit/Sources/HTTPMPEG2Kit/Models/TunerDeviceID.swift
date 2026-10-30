import Foundation

/// The stable identity of an HDHomeRun tuner: eight hexadecimal digits, stored uppercased (`"1234ABC2"`).
///
/// This is the primary key for device records and routing. It never appears in a `ChannelKey`.
public nonisolated struct TunerDeviceID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    public let rawValue: String

    /// Accepts eight hexadecimal digits in any case, with surrounding whitespace trimmed.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 8, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = trimmed
    }

    /// The ID for a 32-bit number, as it travels in discovery packets (`0x1234ABC2` → `"1234ABC2"`).
    public init(numericValue: UInt32) {
        rawValue = String(format: "%08X", numericValue)
    }

    public var description: String { rawValue }

    /// The mDNS name the device answers to, for example `hdhr-1234abc2.local`.
    public var hostname: String { "hdhr-\(rawValue.lowercased()).local" }

    /// The ID as a 32-bit number, as it travels in discovery packets.
    public var numericValue: UInt32 { UInt32(rawValue, radix: 16) ?? 0 }

    /// Whether the ID carries a valid check digit.
    ///
    /// Device IDs are self-checking: substitute the 1st, 3rd, 5th and 7th hex digits (counting from the left)
    /// through a fixed 16-entry table, XOR them with the 2nd, 4th, 6th and 8th digits as they are, and a valid
    /// ID gives zero. A failed check usually means a typo in a manually entered ID.
    public var isValidChecksum: Bool {
        let substitution: [UInt32] = [0xA, 0x5, 0xF, 0x6, 0x7, 0xC, 0x1, 0xB, 0x9, 0x2, 0x8, 0xD, 0x4, 0x3, 0xE, 0x0]
        let value = numericValue
        var check: UInt32 = 0
        for position in 0..<8 {
            let digit = (value >> UInt32(28 - position * 4)) & 0xF
            check ^= position.isMultiple(of: 2) ? substitution[Int(digit)] : digit
        }
        return check == 0
    }
}
