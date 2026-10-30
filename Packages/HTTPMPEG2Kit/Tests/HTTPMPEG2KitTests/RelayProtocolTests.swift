import Foundation
import Network
import Testing
@testable import HTTPMPEG2Kit

@Suite("Relay protocol")
struct RelayProtocolTests {
    static let news = ChannelKey(source: "Antenna", guideNumber: "9.1")
    static let cable = ChannelKey(source: "Cable TV", guideNumber: "702")

    // MARK: - TXT record

    @Test func advertisementRoundTrips() throws {
        let advertisement = RelayAdvertisement(instanceID: "4B1C7E9A-0000-4000-8000-000000000001",
                                               channels: [Self.news, Self.cable])
        let entries = advertisement.txtEntries
        #expect(entries == ["v": "1", "id": "4B1C7E9A-0000-4000-8000-000000000001",
                            "c0": "tvch:Antenna:9.1", "c1": "tvch:Cable TV:702"])
        #expect(RelayAdvertisement(txtEntries: entries) == advertisement)
        let record = NWTXTRecord(entries)
        #expect(RelayAdvertisement(txtEntries: record.dictionary) == advertisement)
    }

    @Test func advertisementCarriesNoAddressesOrDeviceIDs() {
        let entries = RelayAdvertisement(instanceID: "test", channels: [Self.news]).txtEntries
        #expect(Set(entries.keys) == ["v", "id", "c0"])
        #expect(!entries.values.contains { $0.contains("192.") || $0.contains("hdhr") })
    }

    @Test func advertisementCapsItsChannels() {
        let channels = (1...30).map { ChannelKey(source: "Antenna", guideNumber: "\($0).1") }
        let entries = RelayAdvertisement(instanceID: "test", channels: channels).txtEntries
        #expect(entries.count == 2 + RelayAdvertisement.maxChannels)
        #expect(RelayAdvertisement(txtEntries: entries)?.channels == Array(channels.prefix(16)))
    }

    @Test func advertisementRejectsOtherVersionsAndBadEntries() {
        #expect(RelayAdvertisement(txtEntries: ["v": "2", "id": "x", "c0": "tvch:Antenna:9.1"]) == nil)
        #expect(RelayAdvertisement(txtEntries: ["id": "x"]) == nil)
        #expect(RelayAdvertisement(txtEntries: ["v": "1"]) == nil)
        #expect(RelayAdvertisement(txtEntries: ["v": "1", "id": String(repeating: "x", count: 65)]) == nil)
        let lenient = RelayAdvertisement(txtEntries: ["v": "1", "id": "x", "c0": "garbage", "c1": "tvch:Antenna:9.1",
                                                      "c3": "tvch:Antenna:2.1"])
        #expect(lenient?.channels == [Self.news])
    }

    // MARK: - Requests

    static func parse(_ text: String) -> RelayRequest.Parsed {
        RelayRequest.parse(Data(text.utf8))
    }

    @Test func streamPathsRoundTrip() {
        for channel in [Self.news, Self.cable, ChannelKey(source: "A/B?", guideNumber: "7-1")] {
            let path = RelayRequest.streamPath(for: channel)
            #expect(!path.dropFirst(RelayRequest.streamPathPrefix.count).contains("/"))
            #expect(Self.parse("GET \(path) HTTP/1.1\r\nHost: relay\r\n\r\n") == .request(.stream(channel)))
        }
        #expect(RelayRequest.streamPath(for: Self.news) == "/v1/stream/tvch%3AAntenna%3A9.1")
    }

    @Test func parsesInfoAndIgnoresQueriesAndHeaders() {
        #expect(Self.parse("GET /v1/info HTTP/1.1\r\nHost: relay\r\nX-Other: 1\r\n\r\n") == .request(.info))
        #expect(Self.parse("GET /v1/info?x=1 HTTP/1.0\r\n\r\n") == .request(.info))
        #expect(Self.parse("GET /v1/stream/tvch:Antenna:9.1 HTTP/1.1\r\n\r\n") == .request(.stream(Self.news)))
    }

    @Test func waitsForTheWholeHead() {
        #expect(Self.parse("GET /v1/info HTTP/1.1\r\nHost: re") == .incomplete)
        #expect(Self.parse("") == .incomplete)
    }

    @Test func rejectsEverythingElse() {
        #expect(Self.parse("POST /v1/info HTTP/1.1\r\n\r\n") == .rejected(.methodNotAllowed))
        #expect(Self.parse("HEAD /v1/info HTTP/1.1\r\n\r\n") == .rejected(.methodNotAllowed))
        #expect(Self.parse("GET /v1/info\r\n\r\n") == .rejected(.badRequest))
        #expect(Self.parse("GET /v1/info SPDY/3\r\n\r\n") == .rejected(.badRequest))
        #expect(Self.parse("GET  /v1/info HTTP/1.1\r\n\r\n") == .rejected(.badRequest))
        #expect(Self.parse("GET /auto/v9.1 HTTP/1.1\r\n\r\n") == .rejected(.notFound))
        #expect(Self.parse("GET /v1/stream/garbage HTTP/1.1\r\n\r\n") == .rejected(.notFound))
        #expect(Self.parse("GET /v1/stream/tvch:Antenna:9.1/x HTTP/1.1\r\n\r\n") == .rejected(.notFound))
        #expect(Self.parse("GET /v1/stream/%ZZ HTTP/1.1\r\n\r\n") == .rejected(.notFound))
        #expect(RelayRequest.parse(Data([0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])) == .rejected(.badRequest))
    }

    @Test func boundsTheHead() {
        let endless = Data(repeating: 0x41, count: RelayRequest.maxHeadBytes + 1)
        #expect(RelayRequest.parse(endless) == .rejected(.headTooLarge))
        let long = "GET /v1/info HTTP/1.1\r\nX: " + String(repeating: "a", count: 9_000) + "\r\n\r\n"
        #expect(Self.parse(long) == .rejected(.headTooLarge))
    }

    @Test func infoBodyIsStableJSON() throws {
        let body = RelayInfo(channels: [Self.news]).encoded()
        #expect(String(data: body, encoding: .utf8) == #"{"channels":["tvch:Antenna:9.1"],"version":1}"#)
        #expect(try JSONDecoder().decode(RelayInfo.self, from: body).channels == ["tvch:Antenna:9.1"])
    }

    // MARK: - Peers

    @Test(arguments: ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.20", "169.254.3.4", "127.0.0.1",
                      "::1", "fe80::1", "fd12:3456::1", "::ffff:192.168.1.20"])
    func localPeersAreServed(_ address: String) {
        #expect(RelayPeerPolicy.isLocal(.hostPort(host: NWEndpoint.Host(address), port: 5000)))
    }

    @Test(arguments: ["8.8.8.8", "172.32.0.1", "100.64.0.1", "192.0.2.10", "2001:db8::1", "::ffff:8.8.8.8"])
    func otherPeersAreRefused(_ address: String) {
        #expect(!RelayPeerPolicy.isLocal(.hostPort(host: NWEndpoint.Host(address), port: 5000)))
    }

    @Test func namesAndServicesAreRefused() {
        #expect(!RelayPeerPolicy.isLocal(.hostPort(host: "example.local", port: 5000)))
        #expect(!RelayPeerPolicy.isLocal(.service(name: "x", type: "_x._tcp", domain: "local", interface: nil)))
    }

    // MARK: - Directory

    static func host(_ name: String, _ instance: String, _ channels: [ChannelKey]) -> RelayHost {
        RelayHost(name: name, endpoint: .hostPort(host: "127.0.0.1", port: 5000),
                  advertisement: RelayAdvertisement(instanceID: instance, channels: channels))
    }

    @Test func directoryFindsAHostAndSkipsItself() {
        let directory = RelayDirectory(ownInstanceID: "me")
        directory.replace([Self.host("Zed", "z", [Self.news]), Self.host("Self", "me", [Self.news, Self.cable]),
                           Self.host("Amy", "a", [Self.news])])
        #expect(directory.hosts.map(\.name) == ["Amy", "Zed"])
        #expect(directory.host(serving: Self.news)?.name == "Amy")
        #expect(directory.host(serving: Self.cable) == nil)
    }

    @Test func anUnreachableHostIsSkippedForAWhile() async throws {
        let directory = RelayDirectory(ownInstanceID: "me")
        let amy = Self.host("Amy", "a", [Self.news])
        directory.replace([amy, Self.host("Zed", "z", [Self.news])])
        directory.markUnreachable(amy, for: .milliseconds(100))
        #expect(directory.host(serving: Self.news)?.name == "Zed")
        directory.replace([amy])
        #expect(directory.host(serving: Self.news) == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(directory.host(serving: Self.news)?.name == "Amy")
    }
}
