import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("Discovery packet codec")
struct DiscoveryPacketTests {
    private typealias Packet = TunerDiscoveryPacket
    private typealias Reply = SyntheticDiscoveryReply

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([UInt8]()) == 0)
    }

    @Test func discoverRequestIsTheWildcardRequest() {
        // type 0x0002, length 12, DEVICE_TYPE = wildcard, DEVICE_ID = wildcard, CRC-32 little-endian.
        let expected = Reply.bytes(hex: "0002000c0104ffffffff0204ffffffff73cc7d8f")
        #expect(Packet.discoverRequest() == expected)
    }

    @Test func discoverRequestCanTargetOneDevice() throws {
        let request = Packet.discoverRequest(deviceID: Reply.deviceID)
        let (type, payload) = try Packet.unframe(request)
        #expect(type == Packet.requestType)
        let items = try Packet.tlvs(in: payload)
        #expect(items.map(\.tag) == [0x01, 0x02])
        #expect(Array(items[1].value) == [0x12, 0x34, 0xAB, 0xC2])
    }

    @Test(arguments: [
        (0, [0x00]), (1, [0x01]), (127, [0x7F]), (128, [0x80, 0x01]), (300, [0xAC, 0x02]), (0x7FFF, [0xFF, 0xFF])
    ] as [(Int, [UInt8])])
    func tlvLengthsUseOneOrTwoBytes(length: Int, encoded: [UInt8]) throws {
        let value = [UInt8](repeating: 0x41, count: length)
        let tlv = try Packet.tlv(tag: 0x7E, value: value)
        #expect(Array(tlv[1..<(1 + encoded.count)]) == encoded)
        #expect(tlv.count == 1 + encoded.count + length)
        let decoded = try Packet.tlvs(in: tlv[...])
        #expect(decoded.count == 1)
        #expect(decoded.first?.tag == 0x7E)
        #expect(decoded.first.map { Array($0.value) } == value)
    }

    @Test func oversizedValuesAndPayloadsAreRefused() {
        #expect(throws: TunerDiscoveryPacketError.oversized) {
            try Packet.tlv(tag: 0x2A, value: [UInt8](repeating: 0, count: 0x8000))
        }
        #expect(throws: TunerDiscoveryPacketError.oversized) {
            try Packet.frame(type: Packet.replyType, payload: [UInt8](repeating: 0, count: 3_067))
        }
        #expect(throws: Never.self) {
            try Packet.frame(type: Packet.replyType, payload: [UInt8](repeating: 0, count: 3_066))
        }
    }

    @Test func legacyReplyParses() throws {
        let reply = try Packet.parseReply(Reply.packet())
        #expect(reply.deviceTypes == [Packet.tunerDeviceType])
        #expect(reply.isTuner)
        #expect(reply.deviceID?.rawValue == "1234ABC2")
        #expect(reply.tunerCount == 4)
        #expect(reply.baseURL == URL(string: Reply.baseURL))
        #expect(reply.lineupURL == URL(string: Reply.lineupURL))
    }

    @Test func multiTypeReplyParsesToTheSameDevice() throws {
        let legacy = try Packet.parseReply(Reply.packet())
        let multi = try Packet.parseReply(Reply.packet(multiType: true))
        #expect(multi == legacy)
    }

    @Test func multiTypeListsEveryType() throws {
        let payload = try Reply.tlv(.multiType, Reply.bytes(hex: "0000000500000001"))
            + Reply.tlv(.deviceID, Packet.bigEndianBytes(Reply.deviceID))
        let reply = try Packet.parseReply(Reply.packet(payload: payload))
        #expect(reply.deviceTypes == [5, 1])
        #expect(reply.isTuner)
    }

    @Test func twoByteLengthValuesParse() throws {
        let longLineup = Reply.baseURL + "/lineup.json?show=found&tuning=1&" + String(repeating: "x", count: 150)
        let payload = try Reply.payload(lineupURL: longLineup)
        let reply = try Packet.parseReply(Reply.packet(payload: payload))
        #expect(reply.lineupURL?.absoluteString == longLineup)
        #expect(reply.tunerCount == 4)
    }

    @Test func unknownTagsAreSkipped() throws {
        let payload = try Reply.tlv(0x7E, [1, 2, 3]) + Reply.payload() + Reply.tlv(0x28, Array("http://x".utf8))
            + Reply.tlv(0x05, Array(String(repeating: "e", count: 200).utf8))
        let reply = try Packet.parseReply(Reply.packet(payload: payload))
        #expect(reply == (try Packet.parseReply(Reply.packet())))
    }

    @Test func theAuthTokenIsNeverExposed() throws {
        let reply = try Packet.parseReply(Reply.packet(multiType: true))
        var collector = DiscoveredTunerCollector()
        collector.add(reply, from: "192.0.2.10", interfaceName: "en0")
        let tuner = try #require(collector.tuners.first)
        for text in [String(reflecting: reply), String(describing: reply), String(reflecting: tuner)] {
            #expect(!text.contains(Reply.authToken))
            #expect(!text.contains("SYNTHETIC"))
        }
        let labels = Mirror(reflecting: reply).children.compactMap(\.label)
            + Mirror(reflecting: tuner).children.compactMap(\.label)
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("auth") })
    }

    @Test func badChecksumsAreRejected() throws {
        let packet = try Reply.packet()
        for index in packet.indices {
            var corrupted = packet
            corrupted[index] ^= 0x01
            #expect(throws: TunerDiscoveryPacketError.self) { try Packet.parseReply(corrupted) }
        }
        var flippedPayload = packet
        flippedPayload[10] ^= 0x20
        #expect(throws: TunerDiscoveryPacketError.badChecksum) { try Packet.parseReply(flippedPayload) }
        var flippedTrailer = packet
        flippedTrailer[packet.count - 1] ^= 0xFF
        #expect(throws: TunerDiscoveryPacketError.badChecksum) { try Packet.parseReply(flippedTrailer) }
    }

    @Test func truncatedPacketsAreRejected() throws {
        let packet = try Reply.packet()
        for length in 0..<packet.count {
            let prefix = Array(packet.prefix(length))
            #expect(throws: TunerDiscoveryPacketError.truncated) { try Packet.parseReply(prefix) }
        }
    }

    @Test func extraBytesAndOversizedDatagramsAreRejected() throws {
        let packet = try Reply.packet()
        #expect(throws: TunerDiscoveryPacketError.lengthMismatch) { try Packet.parseReply(packet + [0]) }
        let huge = [UInt8](repeating: 0, count: Packet.maximumPacketSize + 1)
        #expect(throws: TunerDiscoveryPacketError.oversized) { try Packet.parseReply(huge) }
        // A header claiming a 65535-byte payload in a short datagram.
        let lying = Reply.recomputingCRC([0x00, 0x03, 0xFF, 0xFF] + Array(packet.dropFirst(4)))
        #expect(throws: TunerDiscoveryPacketError.truncated) { try Packet.parseReply(lying) }
    }

    @Test func requestsAreNotReplies() {
        #expect(throws: TunerDiscoveryPacketError.unexpectedType(0x0002)) {
            try Packet.parseReply(Packet.discoverRequest())
        }
    }

    @Test(arguments: [
        "2a", // tag with no length byte
        "2a05414243", // length 5, three bytes of value
        "2a80", // two-byte length missing its second byte
        "2a8101" + String(repeating: "41", count: 100), // length 129, 100 bytes of value
        "0203123456", // DEVICE_ID of three bytes
        "0105ffffffffff", // DEVICE_TYPE of five bytes
        "2d050000000100", // MULTI_TYPE not a multiple of four
        "2d00", // empty MULTI_TYPE
        "1000", // empty TUNER_COUNT
        "10050000000004" // TUNER_COUNT of five bytes
    ])
    func malformedTLVsAreRejected(payloadHex: String) throws {
        let packet = try Reply.packet(payload: Reply.bytes(hex: payloadHex))
        #expect(throws: TunerDiscoveryPacketError.malformedTLV) { try Packet.parseReply(packet) }
    }

    @Test func wildcardAndMissingDeviceIDsReadAsAbsent() throws {
        let wildcard = try Packet.parseReply(Reply.packet(payload: Reply.payload(deviceID: Packet.wildcard)))
        #expect(wildcard.deviceID == nil)
        let missing = try Packet.parseReply(Reply.packet(payload: Reply.tlv(.deviceType, [0, 0, 0, 1])))
        #expect(missing.deviceID == nil)
        #expect(missing.isTuner)
    }

    @Test func storageDevicesAreNotTuners() throws {
        let reply = try Packet.parseReply(Reply.packet(payload: Reply.payload(deviceType: 5)))
        #expect(!reply.isTuner)
    }

    @Test(arguments: ["ftp://192.0.2.10/", "not a url", "http://", "", "javascript:alert(1)"])
    func unusableURLsReadAsAbsent(text: String) throws {
        let reply = try Packet.parseReply(Reply.packet(payload: Reply.payload(baseURL: text, lineupURL: text)))
        #expect(reply.baseURL == nil)
        #expect(reply.lineupURL == nil)
        #expect(reply.deviceID != nil)
    }

    @Test func invalidUTF8URLsReadAsAbsent() throws {
        let payload = try Reply.tlv(.deviceID, Packet.bigEndianBytes(Reply.deviceID))
            + Reply.tlv(.baseURL, [0x68, 0x74, 0xFF, 0xFE])
        #expect(try Packet.parseReply(Reply.packet(payload: payload)).baseURL == nil)
    }
}
