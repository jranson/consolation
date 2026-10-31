//
//  EBML.swift
//  Matroska
//
//  EBML (RFC 8794), the binary format Matroska is built on: variable-length integers for element IDs and sizes, and
//  the value types elements carry. Every read is bounds-checked and returns nil (or `.invalid`) rather than trapping,
//  since every byte comes from a file or the network.
//

import Foundation

/// An element's ID and payload size, read from its header.
nonisolated public struct EBMLElementHeader: Equatable, Sendable {
    /// The ID with its length marker kept, as the Matroska specification writes it (the Segment is 0x18538067).
    public var id: UInt32
    /// The payload's size in bytes, or nil for an unknown size (a Segment or Cluster written while streaming).
    public var size: Int64?
    /// Bytes taken by the ID and the size.
    public var headerLength: Int

    public init(id: UInt32, size: Int64?, headerLength: Int) {
        self.id = id
        self.size = size
        self.headerLength = headerLength
    }
}

nonisolated enum EBML {
    /// The outcome of reading a header from bytes that may stop short.
    enum HeaderRead: Equatable {
        case header(EBMLElementHeader)
        /// More bytes are needed.
        case incomplete
        /// Not an element header: an ID or a size longer than EBML allows.
        case invalid
    }

    /// Matroska's limits (EBMLMaxIDLength 4, EBMLMaxSizeLength 8).
    static let maximumIDLength = 4
    static let maximumSizeLength = 8

    /// A variable-length integer: its value without the length marker, its length, and whether every value bit is
    /// set (the reserved "unknown" value for a size).
    struct VariableInteger: Equatable {
        var value: UInt64
        var length: Int
        var isAllOnes: Bool
    }

    /// Reads a variable-length integer at `offset`: nil when it runs past the end of `bytes`, or when its first byte
    /// is zero (a length beyond eight bytes).
    static func variableInteger(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> VariableInteger? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let first = bytes[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= bytes.count - offset else { return nil }
        let marker = UInt8(0xFF) >> length
        var value = UInt64(first & marker)
        var allOnes = (first & marker) == marker
        for index in 1..<length {
            let byte = bytes[offset + index]
            value = appending(byte, to: value)
            allOnes = allOnes && byte == 0xFF
        }
        return VariableInteger(value: value, length: length, isAllOnes: allOnes)
    }

    /// A signed variable-length integer (EBML lacing's size differences): the unsigned value less half its range.
    static func signedVariableInteger(_ bytes: UnsafeBufferPointer<UInt8>,
                                      at offset: Int) -> (value: Int64, length: Int)? {
        guard let unsigned = variableInteger(bytes, at: offset) else { return nil }
        let bias = (Int64(1) << (7 * unsigned.length - 1)) - 1
        return (Int64(unsigned.value) - bias, unsigned.length)
    }

    /// Reads an element header (ID, then size) at `offset`.
    static func header(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> HeaderRead {
        guard offset >= 0, offset < bytes.count else { return .incomplete }
        let first = bytes[offset]
        let idLength = first.leadingZeroBitCount + 1
        guard first != 0, idLength <= maximumIDLength else { return .invalid }
        guard idLength < bytes.count - offset else { return .incomplete }
        var id: UInt32 = 0
        for index in 0..<idLength {
            id = UInt32(truncatingIfNeeded: appending(bytes[offset + index], to: UInt64(id)))
        }
        let sizeOffset = offset + idLength
        guard bytes[sizeOffset] != 0 else { return .invalid }
        guard let size = variableInteger(bytes, at: sizeOffset) else { return .incomplete }
        let header = EBMLElementHeader(id: id, size: size.isAllOnes ? nil : Int64(size.value),
                                       headerLength: idLength + size.length)
        return .header(header)
    }

    // MARK: - Values

    /// An unsigned integer of up to eight bytes (an empty element is zero).
    static func unsigned(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard bytes.count <= 8 else { return nil }
        return bytes.reduce(UInt64(0)) { appending($1, to: $0) }
    }

    /// A two's complement signed integer of up to eight bytes.
    static func signed(_ bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard let unsigned = unsigned(bytes) else { return nil }
        guard let first = bytes.first, bytes.count < 8, (first & 0x80) != 0 else {
            return Int64(bitPattern: unsigned)
        }
        // Sign-extend from the element's width.
        let width = UInt64(bytes.count * 8)
        return Int64(bitPattern: unsigned | (UInt64.max << width))
    }

    /// An IEEE 754 float of four or eight bytes (an empty element is zero).
    static func float(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard let bits = unsigned(bytes) else { return nil }
        switch bytes.count {
        case 0: return 0
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        default: return nil
        }
    }

    /// An ASCII or UTF-8 string, ending at the first zero byte (strings may be padded with zeros).
    static func string(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        let text = UnsafeBufferPointer(rebasing: bytes[..<(bytes.firstIndex(of: 0) ?? bytes.count)])
        // Not UTF-8 (a damaged or old file): every byte is a Latin-1 character.
        return String(bytes: text, encoding: .utf8) ?? String(bytes: text, encoding: .isoLatin1) ?? ""
    }

    /// `value` shifted up a byte with `byte` below it.
    private static func appending(_ byte: UInt8, to value: UInt64) -> UInt64 {
        (value << 8) | UInt64(byte)
    }
}

/// The children of a master element whose payload is wholly in memory, in order. Iteration stops at the first child
/// that doesn't fit or has an unknown size, so a damaged element yields what came before the damage.
nonisolated struct EBMLChildren: Sequence, IteratorProtocol {
    struct Child {
        let id: UInt32
        let payload: UnsafeBufferPointer<UInt8>
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private var offset = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func next() -> Child? {
        guard case .header(let header) = EBML.header(bytes, at: offset), let size = header.size else { return nil }
        let start = offset + header.headerLength
        guard size <= Int64(bytes.count - start) else { return nil }
        let end = start + Int(size)
        offset = end
        return Child(id: header.id, payload: UnsafeBufferPointer(rebasing: bytes[start..<end]))
    }
}

extension EBMLChildren.Child {
    var unsigned: UInt64? { EBML.unsigned(payload) }
    var signed: Int64? { EBML.signed(payload) }
    var float: Double? { EBML.float(payload) }
    var string: String { EBML.string(payload) }
    var data: Data { Data(buffer: payload) }
    /// An unsigned value as an `Int`, when it fits.
    var int: Int? { unsigned.flatMap { Int(exactly: $0) } }
    var flag: Bool? { unsigned.map { $0 != 0 } }
}
