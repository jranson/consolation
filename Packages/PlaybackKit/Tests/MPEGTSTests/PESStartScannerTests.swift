//
//  PESStartScannerTests.swift
//  MPEGTSTests
//
//  The time-shift index's scanner: every video PES start with its offset and timestamps, the same in any chunking,
//  random-access points from the adaptation field or the payload, and timestamps unwrapped across 2^33.
//

import Foundation
import Testing
@testable import MPEGTS

struct PESStartScannerTests {
    private static func scan(_ bytes: [UInt8], chunks: [Int] = [], kind: StreamKind = .mpeg2Video) -> [PESStart] {
        var scanner = PESStartScanner()
        scanner.select(pid: StreamBuilder.videoPID, kind: kind)
        var found: [PESStart] = []
        var offset = 0
        var index = 0
        while offset < bytes.count {
            let size = chunks.isEmpty ? bytes.count : max(1, chunks[index % chunks.count])
            let end = min(bytes.count, offset + size)
            found += scanner.scan(Data(bytes[offset..<end]), at: Int64(offset))
            offset = end
            index += 1
        }
        return found
    }

    @Test func findsEveryVideoPESStartWithItsTimestamps() throws {
        let pictures = StreamBuilder.gops(3)
        let bytes = StreamBuilder.broadcast(pictures: pictures)
        let starts = Self.scan(bytes)
        try #require(starts.count == pictures.count)
        for (start, picture) in zip(starts, pictures) {
            #expect(start.pts == picture.pts)
            #expect(start.dts == picture.dts)
            #expect(start.isRandomAccess == picture.startsGOP)
            let packet = Int(start.offset)
            #expect(bytes[packet] == 0x47)
            #expect(bytes[packet + 1] & 0x40 != 0)
            #expect((UInt16(bytes[packet + 1] & 0x1F) << 8 | UInt16(bytes[packet + 2])) == StreamBuilder.videoPID)
        }
    }

    @Test(arguments: [[1], [7, 300], [188], [1_000, 5, 187], [189]])
    func findsTheSameInAnyChunking(chunks: [Int]) {
        let bytes = StreamBuilder.broadcast(pictures: StreamBuilder.gops(2))
        #expect(Self.scan(bytes, chunks: chunks) == Self.scan(bytes))
    }

    @Test func reportsNothingUntilAPIDIsSelected() {
        var scanner = PESStartScanner()
        #expect(scanner.scan(Data(StreamBuilder.broadcast(pictures: StreamBuilder.gops(1))), at: 0).isEmpty)
    }

    @Test func unwrapsTimestampsAcrossTheWrap() {
        let base = Timestamp33.period - 6 * 3_003
        let pictures = StreamBuilder.gops(2, base: base)
        let starts = Self.scan(StreamBuilder.broadcast(pictures: pictures))
        #expect(starts.map(\.pts) == pictures.map(\.pts))
        #expect(starts.last.flatMap(\.pts).map { $0 > Timestamp33.period } == true)
        #expect(Timestamp33.ticks(from: Timestamp33.period - 10, to: 20) == 30)
        #expect(Timestamp33.ticks(from: 20, to: Timestamp33.period - 10) == -30)
    }

    @Test func recognisesRandomAccessPointsInThePayload() {
        func check(_ bytes: [UInt8], _ kind: StreamKind) -> Bool {
            bytes.withUnsafeBufferPointer { PESStartScanner.startsRandomAccess($0, kind: kind) }
        }
        // MPEG-2: a sequence header, or an I picture header (picture_coding_type 1); a P picture isn't.
        #expect(check([0, 0, 1, 0xB3, 0x78, 0x04], .mpeg2Video))
        #expect(check([0, 0, 1, 0x00, 0x00, 0x0F, 0xFF, 0xF8], .mpeg2Video))
        #expect(!check([0, 0, 1, 0x00, 0x00, 0x17, 0xFF, 0xF8], .mpeg2Video))
        // H.264: delimiter then SPS, or an IDR slice; a delimiter then a non-IDR slice isn't.
        #expect(check([0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 0x64], .h264))
        #expect(check([0, 0, 1, 0x65, 0x88], .h264))
        #expect(!check([0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x41, 0x9A], .h264))
        // HEVC: delimiter then VPS, or a CRA picture; a trailing picture isn't.
        #expect(check([0, 0, 1, 0x46, 0x01, 0x50, 0, 0, 1, 0x40, 0x01], .hevc))
        #expect(check([0, 0, 1, 0x2A, 0x01], .hevc))
        #expect(!check([0, 0, 1, 0x02, 0x01], .hevc))
        #expect(!check([0, 0, 1, 0xB3], .ac3))
    }

    /// Input that doesn't continue where the last ended (a reopened file) drops the partial packet held.
    @Test func dropsAPartialPacketAtAGap() {
        let bytes = StreamBuilder.broadcast(pictures: StreamBuilder.gops(1))
        var scanner = PESStartScanner()
        scanner.select(pid: StreamBuilder.videoPID, kind: .mpeg2Video)
        _ = scanner.scan(Data(bytes[0..<100]), at: 0)
        let later = 188 * 10
        let found = scanner.scan(Data(bytes[later...]), at: Int64(later))
        #expect(found == Self.scan(bytes).filter { $0.offset >= Int64(later) })
    }
}
