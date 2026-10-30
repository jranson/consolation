//
//  ChunkingTests.swift
//  MPEGTSTests
//
//  Arbitrary chunk boundaries, sync acquisition and resync after garbage or loss.
//

import Foundation
import Testing
import MPEGTS

struct ChunkingTests {
    private static let stream = StreamBuilder.broadcast(pictures: StreamBuilder.gops(2, captions: true))

    @Test func byteByByteMatchesOneChunk() {
        let whole = demux(Self.stream)
        #expect(whole.packets.count > 20)
        let bytewise = demux(Self.stream, chunks: [1])
        #expect(bytewise == whole)
    }

    @Test func randomChunkSizesMatchOneChunk() {
        let whole = demux(Self.stream)
        for seed: UInt64 in [1, 2, 3, 42] {
            var random = SeededGenerator(seed: seed)
            let sizes = (0..<64).map { _ in Int.random(in: 1...2000, using: &random) }
            #expect(demux(Self.stream, chunks: sizes) == whole)
        }
        #expect(demux(Self.stream, chunks: [187, 189, 376, 565, 3]) == whole)
    }

    @Test func leadingGarbageIsSkipped() {
        var random = SeededGenerator(seed: 7)
        let garbage = random.bytes(1000).map { $0 == 0x47 ? 0x46 : $0 }
        var demuxer = TSDemuxer()
        let events = demux(garbage + Self.stream, chunks: [333], demuxer: &demuxer)
        #expect(events == demux(Self.stream))
        #expect(demuxer.statistics.skippedBytes == 1000)
        #expect(demuxer.statistics.syncLosses == 0)
    }

    @Test func resyncAfterGarbageAtALargeOffset() {
        var random = SeededGenerator(seed: 11)
        let cut = (Self.stream.count / 188 / 2) * 188 + 188 * 3
        let garbage = random.bytes(777)  // may contain 0x47 bytes
        let damaged = Array(Self.stream[..<cut]) + garbage + Array(Self.stream[cut...])
        var demuxer = TSDemuxer()
        let events = demux(damaged, chunks: [4096, 17], demuxer: &demuxer)
        #expect(demuxer.statistics.syncLosses == 1)
        #expect(demuxer.statistics.skippedBytes >= 777)
        // Everything still arrives: the garbage sits between whole packets.
        #expect(events.packets.count == demux(Self.stream).packets.count)
    }

    @Test func resyncAfterLostBytesMidPacket() {
        let cut = 188 * 40 + 77
        let damaged = Array(Self.stream[..<cut]) + Array(Self.stream[(cut + 100)...])
        var demuxer = TSDemuxer()
        let events = demux(damaged, chunks: [1000], demuxer: &demuxer)
        #expect(demuxer.statistics.syncLosses == 1)
        #expect(demuxer.statistics.continuityErrors >= 1)
        #expect(!events.discontinuities.isEmpty)
        let units = frameVideo(events.packets(pid: StreamBuilder.videoPID))
        #expect(!units.isEmpty)
    }

    @Test func truncatedFinalPacketIsHeld() {
        let truncated = Array(Self.stream.dropLast(50))
        var demuxer = TSDemuxer()
        let events = demux(truncated, chunks: [999], demuxer: &demuxer)
        #expect(events.packets.count >= demux(Self.stream).packets.count - 2)
        #expect(demuxer.statistics.malformed == 0)
    }

    @Test func resetForgetsEverything() {
        var demuxer = TSDemuxer()
        _ = demux(Self.stream, demuxer: &demuxer)
        #expect(!demuxer.programs.isEmpty)
        demuxer.reset()
        #expect(demuxer.programs.isEmpty)
        #expect(demuxer.statistics == TSDemuxStatistics())
        #expect(demux(Self.stream, demuxer: &demuxer) == demux(Self.stream))
    }
}
