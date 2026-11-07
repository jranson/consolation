//
//  StreamSnifferTests.swift
//  PlaybackKitTests
//
//  What a URL whose path names no container streams, from its first bytes: transport packets from mid-packet,
//  Matroska, HLS and DASH manifests, MP4 boxes; and the probe that reads them, which gives up on a silent server.
//

import Foundation
import Testing
@testable import PlaybackKit

struct StreamSnifferTests {
    private static func packets(_ count: Int, startingAt skip: Int = 0) -> Data {
        var bytes: [UInt8] = []
        for index in 0..<count {
            bytes += [0x47, 0x01, 0x00, UInt8(0x10 | (index & 0x0F))] + [UInt8](repeating: 0xFF, count: 184)
        }
        return Data(bytes.dropFirst(skip))
    }

    @Test func containersFromTheirFirstBytes() {
        // A live stream joined partway through a packet.
        #expect(StreamSniffer.kind(of: Self.packets(8, startingAt: 124)) == .transportStream)
        #expect(StreamSniffer.kind(of: Self.packets(3)) == .unknown, "three packets could be chance")
        #expect(StreamSniffer.kind(of: Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81])) == .matroska)
        #expect(StreamSniffer.kind(of: Data("\u{FEFF}#EXTM3U\n#EXT-X-VERSION:3\n".utf8)) == .hls)
        #expect(StreamSniffer.kind(of: Data("  \n#EXTM3U\n".utf8)) == .hls)
        let mpd = "<?xml version=\"1.0\"?>\n<!-- made -->\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">"
        #expect(StreamSniffer.kind(of: Data(mpd.utf8)) == .dash)
        let mp4: [UInt8] = [0, 0, 0, 0x20] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 20)
        #expect(StreamSniffer.kind(of: Data(mp4)) == .progressive)
        #expect(StreamSniffer.kind(of: Data("<html><body>Not found</body></html>".utf8)) == .unknown)
        #expect(StreamSniffer.kind(of: Data()) == .unknown)
    }

    @Test func theProbeReadsAFewKilobytesAndCloses() async {
        let source = ScriptedSource(chunks: (0..<64).map { _ in Self.packets(4) })
        #expect(await StreamSniffer.probe(source, timeout: .seconds(5)) == .transportStream)
        #expect(source.wasCancelled)
        // A playlist shorter than the prefix: the stream's end decides.
        let playlist = ScriptedSource(chunks: [Data("#EXTM3U\n".utf8), Data("#EXTINF:6,\na.ts\n".utf8)])
        #expect(await StreamSniffer.probe(playlist, timeout: .seconds(5)) == .hls)
    }

    /// Gives up rather than waiting forever (the time limit catches a hang; a loaded test run delays the timer).
    @Test(.timeLimit(.minutes(1)))
    func aSilentServerTimesOut() async {
        let silent = ScriptedSource(chunks: [], staysOpen: true)
        #expect(await StreamSniffer.probe(silent, timeout: .milliseconds(200)) == nil)
        #expect(silent.wasCancelled)
    }
}

/// Delivers `chunks`, then ends, or with `staysOpen` waits until cancelled (a server that never answers).
nonisolated final class ScriptedSource: ByteSource, @unchecked Sendable {
    // @unchecked: `continuation` and `cancelled` are only touched under `lock`.
    private let chunks: [Data]
    private let staysOpen: Bool
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var cancelled = false

    init(chunks: [Data], staysOpen: Bool = false) {
        self.chunks = chunks
        self.staysOpen = staysOpen
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        for chunk in chunks { continuation.yield(chunk) }
        if staysOpen {
            lock.withLock { self.continuation = continuation }
        } else {
            continuation.finish()
        }
        return stream
    }

    func cancel() {
        let continuation = lock.withLock {
            cancelled = true
            return self.continuation
        }
        continuation?.finish()
    }
}
