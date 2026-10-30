@testable import HTTPMPEG2Kit

/// Builds synthetic discover replies shaped like the FLEX 4K's (tag order: type, multi-type, ID, auth, base URL,
/// tuner count, lineup URL), with the fixture DeviceID, documentation addresses and a fake auth token.
enum SyntheticDiscoveryReply {
    static let deviceID: UInt32 = 0x1234_ABC2
    static let authToken = "SYNTHETIC-auth-token-0123"
    static let baseURL = "http://192.0.2.10:80"
    static let lineupURL = "http://192.0.2.10:80/lineup.json"

    /// One TLV, built through the codec under test.
    static func tlv(_ tag: UInt8, _ value: [UInt8]) throws -> [UInt8] {
        try TunerDiscoveryPacket.tlv(tag: tag, value: value)
    }

    static func tlv(_ tag: TunerDiscoveryPacket.Tag, _ value: [UInt8]) throws -> [UInt8] {
        try tlv(tag.rawValue, value)
    }

    static func tlv(_ tag: TunerDiscoveryPacket.Tag, _ text: String) throws -> [UInt8] {
        try tlv(tag.rawValue, Array(text.utf8))
    }

    /// The payload of a tuner reply. `multiType` adds the `MULTI_TYPE` tag, as the device's second reply does.
    static func payload(
        deviceID: UInt32 = deviceID,
        multiType: Bool = false,
        deviceType: UInt32 = TunerDiscoveryPacket.tunerDeviceType,
        tunerCount: UInt8 = 4,
        baseURL: String = baseURL,
        lineupURL: String = lineupURL
    ) throws -> [UInt8] {
        var payload = try tlv(.deviceType, TunerDiscoveryPacket.bigEndianBytes(deviceType))
        if multiType {
            payload += try tlv(.multiType, TunerDiscoveryPacket.bigEndianBytes(deviceType))
        }
        payload += try tlv(.deviceID, TunerDiscoveryPacket.bigEndianBytes(deviceID))
        payload += try tlv(.deviceAuth, authToken)
        payload += try tlv(.baseURL, baseURL)
        payload += try tlv(.tunerCount, [tunerCount])
        payload += try tlv(.lineupURL, lineupURL)
        return payload
    }

    /// A complete reply packet with a valid CRC.
    static func packet(multiType: Bool = false) throws -> [UInt8] {
        try TunerDiscoveryPacket.frame(type: TunerDiscoveryPacket.replyType, payload: payload(multiType: multiType))
    }

    /// Frames `payload` as a reply with a valid CRC.
    static func packet(payload: [UInt8]) throws -> [UInt8] {
        try TunerDiscoveryPacket.frame(type: TunerDiscoveryPacket.replyType, payload: payload)
    }

    /// Replaces the CRC trailer of `packet` with a freshly computed one.
    static func recomputingCRC(_ packet: [UInt8]) -> [UInt8] {
        let body = Array(packet.dropLast(4))
        let crc = CRC32.checksum(body)
        return body + [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
    }

    static func bytes(hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return result
    }
}
