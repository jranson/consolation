//
//  BitReader.swift
//  MPEGTS
//
//  Bounds-checked bit and byte helpers. Every multi-byte field in this module is read through these helpers, never
//  through inline `<<`/`|`/`&` expressions, whose precedence is easy to get wrong: `(b1 << 8) | b2 & 0x0FFF` masks only
//  `b2` and turns a PAT section_length of 13 into 45069.
//

/// Reads big-endian bit fields from a byte buffer. Reading past the end never traps: it returns zero bits and sets
/// `isOverrun`, so parsers read a whole header and check `isOverrun` once at the end.
nonisolated struct BitReader {
    private let bytes: UnsafeBufferPointer<UInt8>
    private let endBit: Int
    private(set) var bitPosition: Int
    private(set) var isOverrun = false

    /// Reads `bytes[offset ..< offset + count]` (clamped to the buffer).
    init(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int = 0, count: Int? = nil) {
        self.bytes = bytes
        let start = max(0, min(offset, bytes.count))
        let length = max(0, min(count ?? bytes.count - start, bytes.count - start))
        bitPosition = start * 8
        endBit = (start + length) * 8
    }

    var remainingBits: Int { max(0, endBit - bitPosition) }
    var remainingBytes: Int { remainingBits / 8 }
    /// The byte index of the next unread bit, rounded down.
    var byteOffset: Int { bitPosition / 8 }

    /// Reads up to 32 bits as an unsigned value. Returns 0 and sets `isOverrun` if fewer bits remain.
    mutating func bits(_ count: Int) -> UInt32 {
        guard count > 0, count <= 32 else { return 0 }
        guard count <= remainingBits else {
            isOverrun = true
            bitPosition = endBit
            return 0
        }
        var value: UInt32 = 0
        var left = count
        while left > 0 {
            let byte = UInt32(bytes[bitPosition >> 3])
            let bitInByte = bitPosition & 7
            let available = 8 - bitInByte
            let take = min(available, left)
            let shifted = byte >> UInt32(available - take)
            let mask: UInt32 = (1 << UInt32(take)) - 1
            value = (value << UInt32(take)) | (shifted & mask)
            left -= take
            bitPosition += take
        }
        return value
    }

    mutating func int(_ count: Int) -> Int { Int(bits(count)) }

    mutating func flag() -> Bool { bits(1) != 0 }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: bits(8)) }

    mutating func skip(_ count: Int) {
        guard count > 0 else { return }
        if count > remainingBits {
            isOverrun = true
            bitPosition = endBit
        } else {
            bitPosition += count
        }
    }

    mutating func skipBytes(_ count: Int) { skip(count * 8) }

    /// ue(v), an unsigned Exp-Golomb code (H.264 §9.1). More than 31 leading zeros can't be a valid field: that
    /// sets `isOverrun` and returns 0, like reading past the end.
    mutating func golomb() -> Int {
        var zeros = 0
        while !isOverrun, bits(1) == 0 {
            zeros += 1
            if zeros > 31 {
                isOverrun = true
                bitPosition = endBit
                return 0
            }
        }
        guard !isOverrun else { return 0 }
        return (1 << zeros) - 1 + Int(bits(zeros))
    }

    /// se(v), a signed Exp-Golomb code: 1, −1, 2, −2, … for codes 1, 2, 3, 4, ….
    mutating func signedGolomb() -> Int {
        let code = golomb()
        return code % 2 == 1 ? (code + 1) / 2 : -(code / 2)
    }
}

/// Fixed-width field helpers with the masks applied before the shift-or, so precedence cannot bite.
nonisolated enum ByteField {
    /// The low 12 bits of a big-endian 16-bit field (section_length, program_info_length, ES_info_length).
    @inline(__always)
    static func u12(_ high: UInt8, _ low: UInt8) -> Int {
        (Int(high & 0x0F) << 8) | Int(low)
    }

    /// The low 13 bits of a big-endian 16-bit field (PID, PCR_PID, program_map_PID).
    @inline(__always)
    static func u13(_ high: UInt8, _ low: UInt8) -> UInt16 {
        (UInt16(high & 0x1F) << 8) | UInt16(low)
    }

    @inline(__always)
    static func u16(_ high: UInt8, _ low: UInt8) -> Int {
        (Int(high) << 8) | Int(low)
    }

    /// Reads a 33-bit PES timestamp (PTS or DTS) from the five bytes at `offset`; nil if they are not all present.
    /// Layout: `xxxx b32 b31 b30 1 | b29…b22 | b21…b15 1 | b14…b7 | b6…b0 1`. Marker bits are not enforced because
    /// some encoders get them wrong; the value is always within 0 ..< 2^33.
    static func timestamp(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int64? {
        guard offset >= 0, offset + 5 <= bytes.count else { return nil }
        let top = Int64((bytes[offset] >> 1) & 0x07) << 30
        let upper = Int64(bytes[offset + 1]) << 22
        let middle = Int64(bytes[offset + 2] >> 1) << 15
        let lower = Int64(bytes[offset + 3]) << 7
        let bottom = Int64(bytes[offset + 4] >> 1)
        return top | upper | middle | lower | bottom
    }

    /// Reads a PCR (6 bytes: 33-bit base, 6 reserved bits, 9-bit extension) as a 27 MHz count.
    static func pcr(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int64? {
        guard offset >= 0, offset + 6 <= bytes.count else { return nil }
        var base: Int64 = 0
        for index in 0..<4 {
            base = (base << 8) | Int64(bytes[offset + index])
        }
        base = (base << 1) | Int64(bytes[offset + 4] >> 7)
        let ext = (Int64(bytes[offset + 4] & 0x01) << 8) | Int64(bytes[offset + 5])
        return base * 300 + ext
    }
}
