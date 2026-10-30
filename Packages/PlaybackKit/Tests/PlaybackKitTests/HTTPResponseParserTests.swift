import Foundation
import Testing
@testable import PlaybackKit

struct HTTPResponseParserTests {
    private struct Collected {
        var status: Int?
        var body = Data()
        var ended = false
    }

    private func collect(_ chunks: [String]) throws -> Collected {
        var parser = HTTPResponseParser()
        var status: Int?
        var body = Data()
        var ended = false
        for chunk in chunks {
            for output in try parser.feed(Data(chunk.utf8)) {
                switch output {
                case .head(let code, _): status = code
                case .body(let data): body.append(data)
                case .end: ended = true
                }
            }
        }
        return Collected(status: status, body: body, ended: ended)
    }

    @Test func closeDelimitedBodyStreams() throws {
        let result = try collect(["HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n", "\r\nabc", "def"])
        #expect(result.status == 200)
        #expect(result.body == Data("abcdef".utf8))
        #expect(!result.ended)
    }

    @Test func contentLengthEnds() throws {
        let result = try collect(["HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nwxyz"])
        #expect(result.body == Data("wxyz".utf8))
        #expect(result.ended)
    }

    @Test func chunkedBodyAcrossArbitrarySplits() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX: y\r\n\r\n"
        for split in 1..<raw.count {
            let index = raw.index(raw.startIndex, offsetBy: split)
            let result = try collect([String(raw[..<index]), String(raw[index...])])
            #expect(result.body == Data("Wikipedia".utf8))
            #expect(result.ended)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: HTTPResponseParser.ParseError.self) {
            try collect(["NOT HTTP\r\n\r\n"])
        }
        #expect(throws: HTTPResponseParser.ParseError.self) {
            try collect(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"])
        }
        #expect(throws: HTTPResponseParser.ParseError.self) {
            try collect([String(repeating: "A", count: HTTPResponseParser.maxHeaderBytes + 10)])
        }
    }

    @Test func localHostDetection() {
        #expect(RawHTTPByteSource.isLocalHost("hdhomerun.local"))
        #expect(RawHTTPByteSource.isLocalHost("192.168.1.20"))
        #expect(RawHTTPByteSource.isLocalHost("10.0.0.5"))
        #expect(RawHTTPByteSource.isLocalHost("172.20.1.1"))
        #expect(!RawHTTPByteSource.isLocalHost("172.32.1.1"))
        #expect(!RawHTTPByteSource.isLocalHost("example.com"))
        #expect(RawHTTPByteSource.isNeeded(for: URL(string: "http://example.com/live.ts")!))
        #expect(!RawHTTPByteSource.isNeeded(for: URL(string: "https://example.com/live.ts")!))
        #expect(!RawHTTPByteSource.isNeeded(for: URL(string: "http://192.168.0.9:5004/auto/v2.1")!))
    }
}
