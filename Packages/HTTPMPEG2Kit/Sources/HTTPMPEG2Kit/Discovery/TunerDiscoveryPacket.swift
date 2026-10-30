import Foundation

/// Why a datagram was not accepted as a discovery reply. Such datagrams are skipped, never fatal.
nonisolated enum TunerDiscoveryPacketError: Error, Sendable, Hashable {
    /// Shorter than a header and trailer, or shorter than the payload length in its header.
    case truncated
    /// Longer than the payload length in its header says.
    case lengthMismatch
    /// Larger than the protocol allows (the datagram, the payload or one TLV value).
    case oversized
    /// The CRC-32 trailer does not match.
    case badChecksum
    /// Not the packet type that was expected.
    case unexpectedType(UInt16)
    /// A TLV runs past the end of the payload, or a known tag has a value of the wrong size.
    case malformedTLV
}

/// The wire format of the tuner discovery protocol on UDP port 65001.
///
/// A packet is `u16 type (big-endian) | u16 payload length (big-endian) | TLVs | u32 CRC-32 (little-endian)`.
/// Each TLV is a one-byte tag, a length of one byte (up to 127) or two bytes (`0x80 | len & 0x7F`, then
/// `len >> 7`), and the value. The CRC covers the header and the payload.
nonisolated enum TunerDiscoveryPacket {
    static let port: UInt16 = 65_001
    static let requestType: UInt16 = 0x0002
    static let replyType: UInt16 = 0x0003
    /// Matches any device type or any device ID.
    static let wildcard: UInt32 = 0xFFFF_FFFF
    static let tunerDeviceType: UInt32 = 0x0000_0001
    /// The largest datagram the protocol uses; anything bigger is rejected unread.
    static let maximumPacketSize = 3_074
    static let headerSize = 4
    static let trailerSize = 4
    /// The largest value a two-byte TLV length can express.
    static let maximumValueLength = 0x7FFF

    enum Tag: UInt8 {
        case deviceType = 0x01
        case deviceID = 0x02
        case tunerCount = 0x10
        case lineupURL = 0x27
        /// Deprecated binary form of the device's auth token. Recognised only so it is skipped.
        case deviceAuthBinary = 0x29
        case baseURL = 0x2A
        /// The device's auth token. Recognised only so it is skipped: it is never stored or exposed.
        case deviceAuth = 0x2B
        case multiType = 0x2D
    }

    typealias Frame = (type: UInt16, payload: ArraySlice<UInt8>)

    struct TLV: Hashable {
        let tag: UInt8
        let value: ArraySlice<UInt8>
    }

    // MARK: Encoding

    /// A discover request: device type and device ID both wildcards, so every device on the link answers.
    static func discoverRequest(deviceType: UInt32 = wildcard, deviceID: UInt32 = wildcard) -> [UInt8] {
        let payload = [Tag.deviceType.rawValue, 4] + bigEndianBytes(deviceType)
            + [Tag.deviceID.rawValue, 4] + bigEndianBytes(deviceID)
        return (try? frame(type: requestType, payload: payload)) ?? []
    }

    /// One TLV: tag, one- or two-byte length, value.
    static func tlv(tag: UInt8, value: [UInt8]) throws(TunerDiscoveryPacketError) -> [UInt8] {
        guard value.count <= maximumValueLength else { throw .oversized }
        let length: [UInt8] = value.count <= 0x7F
            ? [UInt8(value.count)]
            : [UInt8(0x80 | (value.count & 0x7F)), UInt8(value.count >> 7)]
        return [tag] + length + value
    }

    /// Header, payload and CRC-32 trailer.
    static func frame(type: UInt16, payload: [UInt8]) throws(TunerDiscoveryPacketError) -> [UInt8] {
        guard payload.count <= maximumPacketSize - headerSize - trailerSize else { throw .oversized }
        var packet = bigEndianBytes(type) + bigEndianBytes(UInt16(payload.count)) + payload
        let crc = CRC32.checksum(packet)
        packet += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        return packet
    }

    // MARK: Decoding

    /// Checks the size, length field and CRC, and returns the packet type and payload.
    static func unframe(_ bytes: [UInt8]) throws(TunerDiscoveryPacketError) -> Frame {
        guard bytes.count <= maximumPacketSize else { throw .oversized }
        guard bytes.count >= headerSize + trailerSize else { throw .truncated }
        let type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        let expected = headerSize + length + trailerSize
        guard bytes.count >= expected else { throw .truncated }
        guard bytes.count == expected else { throw .lengthMismatch }
        let crcStart = headerSize + length
        let stored = UInt32(bytes[crcStart]) | UInt32(bytes[crcStart + 1]) << 8
            | UInt32(bytes[crcStart + 2]) << 16 | UInt32(bytes[crcStart + 3]) << 24
        guard stored == CRC32.checksum(bytes[0..<crcStart]) else { throw .badChecksum }
        return (type, bytes[headerSize..<crcStart])
    }

    /// Splits a payload into TLVs, in order. Unknown tags are kept; callers skip what they don't know.
    static func tlvs(in payload: ArraySlice<UInt8>) throws(TunerDiscoveryPacketError) -> [TLV] {
        var result: [TLV] = []
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            let tag = payload[cursor]
            cursor += 1
            guard cursor < payload.endIndex else { throw .malformedTLV }
            var length = Int(payload[cursor])
            cursor += 1
            if length & 0x80 != 0 {
                guard cursor < payload.endIndex else { throw .malformedTLV }
                length = (length & 0x7F) | Int(payload[cursor]) << 7
                cursor += 1
            }
            guard length <= payload.endIndex - cursor else { throw .malformedTLV }
            result.append(TLV(tag: tag, value: payload[cursor..<(cursor + length)]))
            cursor += length
        }
        return result
    }

    /// Parses a discover reply. Throws for anything that is not a well-formed reply with a valid CRC.
    static func parseReply(_ bytes: [UInt8]) throws(TunerDiscoveryPacketError) -> TunerDiscoveryReply {
        let (type, payload) = try unframe(bytes)
        guard type == replyType else { throw .unexpectedType(type) }
        var reply = TunerDiscoveryReply()
        for item in try tlvs(in: payload) {
            try reply.apply(item)
        }
        return reply
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// A big-endian unsigned integer of 1 to 4 bytes, or nil for any other size.
    static func bigEndianInteger(_ bytes: ArraySlice<UInt8>) -> UInt32? {
        guard (1...4).contains(bytes.count) else { return nil }
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

/// The fields of one discover reply that HTTPMPEG2Kit uses.
///
/// The device's auth token (tags `0x29` and `0x2B`) is deliberately not represented: it is a rotating,
/// credential-like value that must never reach storage, logs or the host app.
nonisolated struct TunerDiscoveryReply: Sendable, Hashable {
    /// From `DEVICE_TYPE` (legacy replies) or `MULTI_TYPE`.
    var deviceTypes: [UInt32] = []
    var deviceID: TunerDeviceID?
    var tunerCount: Int?
    var baseURL: URL?
    var lineupURL: URL?

    var isTuner: Bool { deviceTypes.contains(TunerDiscoveryPacket.tunerDeviceType) }

    /// Applies one TLV. The first occurrence of a tag wins; unknown tags and the auth token are skipped.
    mutating func apply(_ item: TunerDiscoveryPacket.TLV) throws(TunerDiscoveryPacketError) {
        guard let tag = TunerDiscoveryPacket.Tag(rawValue: item.tag) else { return }
        switch tag {
        case .deviceType:
            try addTypes(item.value, single: true)
        case .multiType:
            try addTypes(item.value, single: false)
        case .deviceID:
            guard item.value.count == 4, let raw = TunerDiscoveryPacket.bigEndianInteger(item.value) else {
                throw .malformedTLV
            }
            if deviceID == nil, raw != TunerDiscoveryPacket.wildcard {
                deviceID = TunerDeviceID(numericValue: raw)
            }
        case .tunerCount:
            guard let count = TunerDiscoveryPacket.bigEndianInteger(item.value) else { throw .malformedTLV }
            if tunerCount == nil { tunerCount = Int(count) }
        case .baseURL:
            if baseURL == nil { baseURL = Self.httpURL(item.value) }
        case .lineupURL:
            if lineupURL == nil { lineupURL = Self.httpURL(item.value) }
        case .deviceAuth, .deviceAuthBinary:
            return
        }
    }

    /// `DEVICE_TYPE` holds exactly one 32-bit type; `MULTI_TYPE` holds one or more.
    private mutating func addTypes(_ value: ArraySlice<UInt8>, single: Bool) throws(TunerDiscoveryPacketError) {
        guard !value.isEmpty, value.count.isMultiple(of: 4), !single || value.count == 4 else {
            throw .malformedTLV
        }
        for offset in stride(from: value.startIndex, to: value.endIndex, by: 4) {
            let type = TunerDiscoveryPacket.bigEndianInteger(value[offset..<(offset + 4)]) ?? 0
            if !deviceTypes.contains(type) { deviceTypes.append(type) }
        }
    }

    /// An `http` or `https` URL from UTF-8 bytes, or nil (a bad URL is ignored, not fatal).
    private static func httpURL(_ bytes: ArraySlice<UInt8>) -> URL? {
        guard let text = String(validating: bytes, as: UTF8.self),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }
}
