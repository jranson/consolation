import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("Discovery de-duplication, interfaces and device IDs")
struct DiscoveryCollectorTests {
    private typealias Reply = SyntheticDiscoveryReply

    private static func reply(
        deviceID: UInt32 = Reply.deviceID,
        tunerCount: Int? = 4,
        baseURL: String? = Reply.baseURL,
        types: [UInt32] = [1]
    ) -> TunerDiscoveryReply {
        var reply = TunerDiscoveryReply()
        reply.deviceTypes = types
        reply.deviceID = deviceID == TunerDiscoveryPacket.wildcard ? nil : TunerDeviceID(numericValue: deviceID)
        reply.tunerCount = tunerCount
        reply.baseURL = baseURL.flatMap(URL.init(string:))
        return reply
    }

    // MARK: De-duplication

    @Test func theLegacyAndMultiTypeRepliesCollapse() throws {
        var collector = DiscoveredTunerCollector()
        let legacy = try TunerDiscoveryPacket.parseReply(Reply.packet())
        let multi = try TunerDiscoveryPacket.parseReply(Reply.packet(multiType: true))
        let added = [legacy, multi, legacy].map { collector.add($0, from: "192.0.2.10", interfaceName: "en0") }
        #expect(added == [true, false, false])
        #expect(collector.tuners.count == 1)
        let tuner = try #require(collector.tuners.first)
        #expect(tuner.deviceID.rawValue == "1234ABC2")
        #expect(tuner.id == tuner.deviceID)
        #expect(tuner.tunerCount == 4)
        #expect(tuner.baseURL?.absoluteString == Reply.baseURL)
        #expect(tuner.lineupURL?.absoluteString == Reply.lineupURL)
        #expect(tuner.ipv4 == "192.0.2.10")
        #expect(tuner.interfaceName == "en0")
    }

    @Test func theFirstInterfaceToAnswerWins() {
        var collector = DiscoveredTunerCollector()
        collector.add(Self.reply(), from: "192.0.2.10", interfaceName: "en7")
        collector.add(Self.reply(), from: "198.51.100.10", interfaceName: "en0")
        #expect(collector.tuners.map(\.ipv4) == ["192.0.2.10"])
        #expect(collector.tuners.map(\.interfaceName) == ["en7"])
    }

    @Test func laterRepliesFillMissingFields() {
        var collector = DiscoveredTunerCollector()
        collector.add(Self.reply(tunerCount: nil, baseURL: nil), from: "192.0.2.10", interfaceName: nil)
        collector.add(Self.reply(tunerCount: 2, baseURL: "http://192.0.2.99:80"), from: "192.0.2.10",
                      interfaceName: "en0")
        collector.add(Self.reply(tunerCount: 3), from: "192.0.2.10", interfaceName: "en0")
        #expect(collector.tuners.count == 1)
        #expect(collector.tuners.first?.tunerCount == 2)
        #expect(collector.tuners.first?.baseURL?.absoluteString == "http://192.0.2.99:80")
        #expect(collector.tuners.first?.interfaceName == nil)
    }

    @Test func devicesKeepTheirFirstSeenOrder() {
        var collector = DiscoveredTunerCollector()
        collector.add(Self.reply(deviceID: 0x1234_ABC2), from: "192.0.2.10", interfaceName: "en0")
        collector.add(Self.reply(deviceID: 0x0000_0000), from: "192.0.2.11", interfaceName: "en0")
        collector.add(Self.reply(deviceID: 0x1234_ABC2), from: "192.0.2.10", interfaceName: "en0")
        #expect(collector.tuners.map(\.deviceID.rawValue) == ["1234ABC2", "00000000"])
    }

    @Test func nonTunersAndRepliesWithoutAnIDAreIgnored() {
        var collector = DiscoveredTunerCollector()
        let replies = [
            Self.reply(types: [5]), Self.reply(types: []), Self.reply(deviceID: TunerDiscoveryPacket.wildcard)
        ]
        let added = replies.map { collector.add($0, from: "192.0.2.10", interfaceName: "en0") }
        #expect(added == [false, false, false])
        #expect(collector.tuners.isEmpty)
    }

    // MARK: Interface address math

    @Test(arguments: [
        ("192.0.2.10", "255.255.255.0", "192.0.2.255"),
        ("10.1.2.3", "255.0.0.0", "10.255.255.255"),
        ("172.16.5.4", "255.240.0.0", "172.31.255.255"),
        ("198.51.100.77", "255.255.255.240", "198.51.100.79"),
        ("203.0.113.1", "255.255.255.252", "203.0.113.3")
    ])
    func directedBroadcastIsAddressOrInverseMask(address: String, netmask: String, broadcast: String) throws {
        let entry = IPv4InterfaceAddress(
            name: "en0",
            index: 4,
            address: try #require(IPv4InterfaceAddress.parse(address)),
            netmask: try #require(IPv4InterfaceAddress.parse(netmask))
        )
        #expect(entry.hasDirectedBroadcast)
        #expect(IPv4InterfaceAddress.dottedQuad(entry.directedBroadcast) == broadcast)
    }

    @Test(arguments: ["255.255.255.255", "255.255.255.254", "0.0.0.0"])
    func pointToPointAndZeroMasksHaveNoBroadcast(netmask: String) throws {
        let entry = IPv4InterfaceAddress(
            name: "utun0", index: 9, address: 0xC000_020A, netmask: try #require(IPv4InterfaceAddress.parse(netmask)))
        #expect(!entry.hasDirectedBroadcast)
    }

    @Test func dottedQuadsRoundTrip() {
        #expect(IPv4InterfaceAddress.parse("192.0.2.10") == 0xC000_020A)
        #expect(IPv4InterfaceAddress.dottedQuad(0xC000_020A) == "192.0.2.10")
        #expect(IPv4InterfaceAddress.dottedQuad(IPv4InterfaceAddress.limitedBroadcast) == "255.255.255.255")
        for text in ["", "1.2.3", "1.2.3.4.5", "256.0.0.1", "1..2.3", "a.b.c.d", "1.2.3.-4", "1.2.3.0004"] {
            #expect(IPv4InterfaceAddress.parse(text) == nil)
        }
    }

    @Test func broadcastTargetsGroupByInterface() {
        let addresses = [
            IPv4InterfaceAddress(name: "en0", index: 4, address: 0xC000_020A, netmask: 0xFFFF_FF00),
            IPv4InterfaceAddress(name: "en1", index: 5, address: 0xC633_644D, netmask: 0xFFFF_FFF0),
            IPv4InterfaceAddress(name: "en0", index: 4, address: 0xC000_020B, netmask: 0xFFFF_FF00),
            IPv4InterfaceAddress(name: "en0", index: 4, address: 0xCB00_7101, netmask: 0xFFFF_FF00),
            IPv4InterfaceAddress(name: "utun3", index: 9, address: 0x0A00_0001, netmask: 0xFFFF_FFFF)
        ]
        let targets = IPv4InterfaceAddress.broadcastTargets(for: addresses)
        #expect(targets.map(\.name) == ["en0", "en1"])
        #expect(targets.map(\.index) == [4, 5])
        #expect(targets.first?.broadcasts.map(IPv4InterfaceAddress.dottedQuad) == ["192.0.2.255", "203.0.113.255"])
        #expect(targets.last?.broadcasts.map(IPv4InterfaceAddress.dottedQuad) == ["198.51.100.79"])
    }

    @Test func currentInterfacesExcludeLoopback() {
        // Reads the interface list only (getifaddrs); sends nothing.
        let current = IPv4InterfaceAddress.current()
        #expect(!current.contains { $0.name.hasPrefix("lo") })
        #expect(current.allSatisfy { $0.index > 0 })
    }

    // MARK: Device IDs

    @Test func deviceIDChecksums() throws {
        #expect(try #require(TunerDeviceID(rawValue: "1234ABC2")).isValidChecksum)
        #expect(try #require(TunerDeviceID(rawValue: "00000001")).isValidChecksum == false)
        // Exactly one final digit completes any seven-digit prefix.
        let valid = (0..<16).filter { digit in
            TunerDeviceID(rawValue: "1234ABC" + String(digit, radix: 16))?.isValidChecksum == true
        }
        #expect(valid == [2])
    }

    @Test func deviceIDsConvertToAndFromNumbers() throws {
        let deviceID = TunerDeviceID(numericValue: 0x1234_ABC2)
        #expect(deviceID.rawValue == "1234ABC2")
        #expect(deviceID.numericValue == 0x1234_ABC2)
        #expect(TunerDeviceID(numericValue: 0x0A).rawValue == "0000000A")
        #expect(try #require(TunerDeviceID(rawValue: "1234abc2")).numericValue == 0x1234_ABC2)
    }
}
