//
//  ISOBMFFReader.swift
//  PlaybackKit
//
//  A small, bounds-checked ISO base media file format (MP4/fMP4) box reader for untrusted input: init segments and
//  the first bytes of media segments. Every read returns nil instead of trapping when the data is short or a size
//  field lies.
//

import Foundation

/// One box: its four-character type and the byte range of its payload in the reader's buffer.
nonisolated struct ISOBox: Equatable, Sendable {
    let type: String
    let payload: Range<Int>
    /// True when the box's declared size runs past the available bytes (for example a ranged GET of a segment head).
    let isTruncated: Bool
}

nonisolated struct ISOBMFFReader: Sendable {
    /// Upper bound on sibling boxes read at one level, so a crafted file can't make us spin.
    static let maxBoxesPerLevel = 4_096

    let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var fullRange: Range<Int> { 0..<bytes.count }

    /// Sibling boxes inside `range`. Stops at the first malformed header. A box whose size runs past the end of
    /// `range` is clamped and marked truncated.
    func boxes(in range: Range<Int>) -> [ISOBox] {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return [] }
        var result: [ISOBox] = []
        var offset = range.lowerBound
        while range.upperBound - offset >= 8, result.count < Self.maxBoxesPerLevel {
            guard let size32 = uint32(at: offset), let type = fourCC(at: offset + 4) else { break }
            var headerSize = 8
            var size: Int
            switch size32 {
            case 0:
                size = range.upperBound - offset
            case 1:
                guard let large = uint64(at: offset + 8), large <= UInt64(Int.max) else { return result }
                size = Int(large)
                headerSize = 16
            default:
                size = Int(size32)
            }
            guard size >= headerSize, range.upperBound - offset >= headerSize else { break }
            let (end, overflow) = offset.addingReportingOverflow(size)
            let isTruncated = overflow || end > range.upperBound
            let payloadEnd = isTruncated ? range.upperBound : end
            result.append(ISOBox(type: type, payload: (offset + headerSize)..<payloadEnd, isTruncated: isTruncated))
            if isTruncated { break }
            offset = end
        }
        return result
    }

    /// The first child of `range` with the given type.
    func firstBox(_ type: String, in range: Range<Int>) -> ISOBox? {
        boxes(in: range).first { $0.type == type }
    }

    /// Follows a path of box types from `range`, taking the first match at each level.
    func box(path: [String], in range: Range<Int>) -> ISOBox? {
        var current: ISOBox?
        var searchRange = range
        for type in path {
            guard let next = firstBox(type, in: searchRange) else { return nil }
            current = next
            searchRange = next.payload
        }
        return current
    }

    /// A sub-range of `range` starting `offset` bytes in, or nil when that is past its end.
    func subrange(of range: Range<Int>, from offset: Int) -> Range<Int>? {
        guard offset >= 0, range.count >= offset else { return nil }
        return (range.lowerBound + offset)..<range.upperBound
    }

    func slice(_ range: Range<Int>) -> ArraySlice<UInt8>? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        return bytes[range]
    }

    func uint8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, bytes.count - offset >= 2 else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, bytes.count - offset >= 4 else { return nil }
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            value = value << 8 | UInt32(bytes[index])
        }
        return value
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, bytes.count - offset >= 8 else { return nil }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = value << 8 | UInt64(bytes[index])
        }
        return value
    }

    /// A four-character code as text. Non-printable bytes become "?" so the result is always four characters.
    func fourCC(at offset: Int) -> String? {
        guard offset >= 0, bytes.count - offset >= 4 else { return nil }
        let scalars = bytes[offset..<(offset + 4)].map { byte -> Character in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(scalars)
    }

    /// Version and flags of a full box whose payload starts at `offset`.
    func fullBoxHeader(at offset: Int) -> (version: UInt8, flags: UInt32)? {
        guard let word = uint32(at: offset) else { return nil }
        return (UInt8(word >> 24), word & 0x00FF_FFFF)
    }
}
