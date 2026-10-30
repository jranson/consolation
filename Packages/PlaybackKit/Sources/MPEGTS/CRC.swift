//
//  CRC.swift
//  MPEGTS
//
//  Table-driven CRCs: CRC-32/MPEG-2 for PSI sections and CRC-16 (polynomial 0x8005) for AC-3/E-AC-3 frames.
//

/// CRC-32/MPEG-2: polynomial 0x04C11DB7, initial value 0xFFFFFFFF, not reflected, no final XOR.
/// Running it over a whole PSI section, including its trailing CRC_32 field, yields 0 for an intact section.
nonisolated enum CRC32MPEG2 {
    static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0..<8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>, initial: UInt32 = 0xFFFF_FFFF) -> UInt32 {
        var crc = initial
        table.withUnsafeBufferPointer { lookup in
            for byte in bytes {
                crc = (crc << 8) ^ lookup[Int(UInt8(truncatingIfNeeded: crc >> 24) ^ byte)]
            }
        }
        return crc
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { checksum($0) }
    }
}

/// CRC-16 with polynomial 0x8005, initial value 0, not reflected (as used by AC-3 `crc1`/`crc2` and E-AC-3).
/// Running it over an AC-3 or E-AC-3 syncframe after the 16-bit syncword yields 0 for an intact frame.
nonisolated enum CRC16AC3 {
    /// Eight 256-entry tables for slicing-by-8: table k maps a byte to the CRC of that byte followed by k zero bytes.
    /// The byte-at-a-time loop is latency-bound at about 0.4 GB/s; eight independent lookups per step are not.
    static let tables: [UInt16] = {
        var result = [UInt16](repeating: 0, count: 8 * 256)
        for index in 0..<256 {
            var crc = UInt16(index) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x8005 : crc << 1
            }
            result[index] = crc
        }
        for slice in 1..<8 {
            for index in 0..<256 {
                let previous = result[(slice - 1) * 256 + index]
                result[slice * 256 + index] = (previous << 8) ^ result[Int(previous >> 8)]
            }
        }
        return result
    }()

    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        tables.withUnsafeBufferPointer { lookup in
            var index = 0
            let count = bytes.count
            while index + 8 <= count {
                let high = Int(UInt8(truncatingIfNeeded: crc >> 8) ^ bytes[index])
                let low = Int(UInt8(truncatingIfNeeded: crc) ^ bytes[index + 1])
                crc = lookup[7 * 256 + high] ^ lookup[6 * 256 + low]
                    ^ lookup[5 * 256 + Int(bytes[index + 2])] ^ lookup[4 * 256 + Int(bytes[index + 3])]
                    ^ lookup[3 * 256 + Int(bytes[index + 4])] ^ lookup[2 * 256 + Int(bytes[index + 5])]
                    ^ lookup[256 + Int(bytes[index + 6])] ^ lookup[Int(bytes[index + 7])]
                index += 8
            }
            while index < count {
                crc = (crc << 8) ^ lookup[Int(UInt8(truncatingIfNeeded: crc >> 8) ^ bytes[index])]
                index += 1
            }
        }
        return crc
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        bytes.withUnsafeBufferPointer { checksum($0) }
    }
}
