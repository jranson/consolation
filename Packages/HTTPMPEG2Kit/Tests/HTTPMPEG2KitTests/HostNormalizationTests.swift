import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("Host string to base URL")
struct HostNormalizationTests {
    static let accepted: [(input: String, expected: String)] = [
        ("hdhomerun.local", "http://hdhomerun.local"),
        ("hdhr-1234abc2.local", "http://hdhr-1234abc2.local"),
        ("HDHR-1234ABC2.LOCAL", "http://hdhr-1234abc2.local"),
        ("1234abc2.local", "http://1234abc2.local"),
        ("192.0.2.10", "http://192.0.2.10"),
        ("  192.0.2.10 \n", "http://192.0.2.10"),
        ("192.0.2.10:8080", "http://192.0.2.10:8080"),
        ("192.0.2.10:80", "http://192.0.2.10"),
        ("http://192.0.2.10", "http://192.0.2.10"),
        ("http://192.0.2.10/", "http://192.0.2.10"),
        ("HTTP://hdhomerun.local/discover.json?show=all#top", "http://hdhomerun.local"),
        ("http://192.0.2.10:5004/auto/v2.1", "http://192.0.2.10:5004"),
        ("https://hdhomerun.local", "https://hdhomerun.local"),
        ("hdhomerun.local/lineup.json", "http://hdhomerun.local"),
        ("[2001:db8::10]", "http://[2001:db8::10]"),
        ("2001:db8::10", "http://[2001:db8::10]"),
        ("[2001:DB8::10]:8080", "http://[2001:db8::10]:8080"),
        ("http://[2001:db8::10]:80/discover.json", "http://[2001:db8::10]"),
        ("fe80::1%en0", "http://[fe80::1%25en0]")
    ]

    static let rejected = [
        "", "   ", "http://", "ftp://hdhomerun.local", "hd homerun.local", "user:secret@192.0.2.10",
        "http://user@hdhomerun.local", "192.0.2.10:0", "192.0.2.10:65536", "192.0.2.10:http", "host..local",
        "[2001:db8::10", "[not-ipv6]", "[2001:db8::10]x", "hdhomerun.local:", "http://:80"
    ]

    @Test(arguments: zip(accepted.map(\.input), accepted.map(\.expected)))
    func acceptsHostsIPsAndURLs(input: String, expected: String) {
        #expect(TunerHost.baseURL(for: input)?.absoluteString == expected)
    }

    @Test(arguments: rejected)
    func rejectsEverythingElse(input: String) {
        #expect(TunerHost.baseURL(for: input) == nil)
    }

    @Test func recognizesIPv4Literals() {
        #expect(TunerHost.isIPv4Literal("192.0.2.10"))
        #expect(TunerHost.isIPv4Literal("0.0.0.0"))
        #expect(!TunerHost.isIPv4Literal("256.0.2.10"))
        #expect(!TunerHost.isIPv4Literal("192.0.2"))
        #expect(!TunerHost.isIPv4Literal("192.0.2.10.5"))
        #expect(!TunerHost.isIPv4Literal("hdhomerun.local"))
        #expect(!TunerHost.isIPv4Literal("192.0.2.1a"))
    }

    @Test func clientAcceptsTypedHosts() throws {
        let client = try HDHomeRunClient(host: "192.0.2.10")
        #expect(client.baseURL.absoluteString == "http://192.0.2.10")
        #expect(throws: HDHomeRunClientError.invalidHost("not a host")) {
            try HDHomeRunClient(host: "not a host")
        }
    }

    @Test func buildsEndpointURLsWithoutRewritingTheHost() throws {
        let client = try HDHomeRunClient(host: "hdhomerun.local")
        #expect(client.endpointURL("discover.json").absoluteString == "http://hdhomerun.local/discover.json")
        let query = [URLQueryItem(name: "show", value: "all"), URLQueryItem(name: "tuning", value: nil)]
        #expect(client.endpointURL("lineup.json", query: query).absoluteString
            == "http://hdhomerun.local/lineup.json?show=all&tuning")
    }
}
