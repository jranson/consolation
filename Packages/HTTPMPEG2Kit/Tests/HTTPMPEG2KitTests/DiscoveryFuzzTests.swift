import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Random and mutated datagrams must be rejected or parsed into sane values, never trap.
@Suite("Discovery packet fuzzing")
struct DiscoveryFuzzTests {
    private typealias Packet = TunerDiscoveryPacket

    private static func randomBytes(count: Int, using generator: inout SplitMix64) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// A parsed reply's fields are always within what the wire format can carry.
    private static func isSane(_ reply: TunerDiscoveryReply) -> Bool {
        let countOK = reply.tunerCount.map { (0...Int(UInt32.max)).contains($0) } ?? true
        let urlsOK = [reply.baseURL, reply.lineupURL].allSatisfy { url in
            url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? true
        }
        return countOK && urlsOK && reply.deviceID.map { $0.rawValue.count == 8 } ?? true
    }

    @Test func randomDatagramsAreRejected() {
        var generator = SplitMix64(seed: 0x0FDA_0001)
        for _ in 0..<2_000 {
            let bytes = Self.randomBytes(count: Int.random(in: 0...400, using: &generator), using: &generator)
            // A random four-byte CRC matches with probability 2^-32; with a fixed seed it never does here.
            #expect(throws: TunerDiscoveryPacketError.self) { try Packet.parseReply(bytes) }
        }
    }

    @Test func randomPayloadsWithValidFramingNeverTrap() throws {
        var generator = SplitMix64(seed: 0x0FDA_0002)
        var parsed = 0
        for _ in 0..<2_000 {
            let payload = Self.randomBytes(count: Int.random(in: 0...300, using: &generator), using: &generator)
            let packet = try Packet.frame(type: Packet.replyType, payload: payload)
            guard let reply = try? Packet.parseReply(packet) else { continue }
            parsed += 1
            #expect(Self.isSane(reply))
        }
        // Empty and lucky payloads parse; most random TLV streams do not.
        #expect(parsed > 0)
        #expect(parsed < 2_000)
    }

    @Test func mutatedRepliesNeverTrap() throws {
        var generator = SplitMix64(seed: 0x0FDA_0003)
        let original = try SyntheticDiscoveryReply.packet(multiType: true)
        for _ in 0..<3_000 {
            var mutated = original
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let index = Int.random(in: Packet.headerSize..<(mutated.count - Packet.trailerSize), using: &generator)
                mutated[index] = UInt8.random(in: 0...255, using: &generator)
            }
            // Recompute the CRC so the TLV parser, not the checksum, sees the damage.
            let packet = SyntheticDiscoveryReply.recomputingCRC(mutated)
            if let reply = try? Packet.parseReply(packet) {
                #expect(Self.isSane(reply))
            }
            var collector = DiscoveredTunerCollector()
            if let reply = try? Packet.parseReply(packet) {
                collector.add(reply, from: "192.0.2.10", interfaceName: "en0")
            }
            #expect(collector.tuners.count <= 1)
        }
    }

    @Test func randomTLVStreamsNeverTrap() {
        var generator = SplitMix64(seed: 0x0FDA_0004)
        for _ in 0..<2_000 {
            let payload = Self.randomBytes(count: Int.random(in: 0...64, using: &generator), using: &generator)
            if let items = try? Packet.tlvs(in: payload[...]) {
                #expect(items.reduce(0) { $0 + $1.value.count } <= payload.count)
            }
        }
    }
}
