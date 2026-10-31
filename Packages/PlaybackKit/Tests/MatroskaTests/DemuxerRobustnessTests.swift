//
//  DemuxerRobustnessTests.swift
//  MatroskaTests
//
//  What isn't a well-formed Matroska file: other formats, missing tracks, encodings, oversized elements, and a
//  seeded run of damaged and random input that must never trap (every byte comes from a file or the network).
//

import Foundation
@testable import Matroska
import MatroskaTestSupport
import Testing

struct DemuxerRobustnessTests {
    @Test func otherFormatsAreNotMatroska() {
        let transportStream: [UInt8] = [0x47, 0x40, 0x00, 0x10] + [UInt8](repeating: 0xFF, count: 184)
        let mp4: [UInt8] = [0, 0, 0, 0x18] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 12)
        var otherDocType = DemuxFixture.file()
        otherDocType.docType = "notmatroska"
        otherDocType.write()
        for bytes in [transportStream, mp4, otherDocType.bytes] {
            let log = DemuxLog.demux(bytes, chunk: 64)
            #expect(log.demuxer.failure == .notMatroska)
            #expect(log.segment == nil && log.frames.isEmpty)
        }
        var webm = DemuxFixture.file()
        webm.docType = "webm"
        webm.write()
        #expect(DemuxLog.demux(webm.bytes).demuxer.failure == nil)
    }

    @Test func aClusterBeforeAnyTracksFails() {
        var file = MatroskaTestFile(tracks: [], frames: [MatroskaTestFrame(track: 1, timestamp: 0, isKeyframe: true,
                                                                            data: [1])])
        file.write()
        #expect(DemuxLog.demux(file.bytes).demuxer.failure == .missingTracks)
    }

    @Test func aLargeElementCanBeJumpedOver() throws {
        var file = DemuxFixture.file()
        file.attachmentBytes = 6 << 20
        file.write()
        var log = DemuxLog()
        // Feed up to a little way into the Attachments, as a reader would before it sees how large they are.
        let headerEnd = file.clusters[0].offset - (6 << 20)
        log.feed(Array(file.bytes[..<headerEnd]), chunk: 4_096)
        let target = try #require(log.demuxer.pendingSkip(atLeast: 4 << 20))
        #expect(target == Int64(file.clusters[0].offset))
        #expect(log.demuxer.pendingSkip(atLeast: 8 << 20) == nil)
        log.demuxer.skipInput(to: target)
        log.feed(file.bytes, chunk: 4_096, from: file.clusters[0].offset)
        #expect(log.frames == DemuxFixture.expected(file.frames))
    }

    @Test func oversizedBlocksAreDroppedNotBuffered() {
        var frames = DemuxFixture.frames()
        frames[3].data = [UInt8](repeating: 1, count: MatroskaDemuxer.maximumBlockSize + 8_192)
        var file = MatroskaTestFile(tracks: [DemuxFixture.video, DemuxFixture.audio], frames: frames)
        file.write()
        let log = DemuxLog.demux(file.bytes, chunk: 1 << 20)
        #expect(log.demuxer.statistics.droppedBlocks == 1)
        #expect(log.frames.count == frames.count - 1)
    }

    @Test func encodingsAreReadFromTheTrack() throws {
        // ContentEncodings: one header-stripping encoding (algorithm 3) with settings 0B 77.
        let stripping: [UInt8] = [0x6D, 0x80, 0x8F, 0x62, 0x40, 0x8C, 0x50, 0x34, 0x89,
                                  0x42, 0x54, 0x81, 0x03, 0x42, 0x55, 0x82, 0x0B, 0x77]
        let compressed: [UInt8] = [0x6D, 0x80, 0x89, 0x62, 0x40, 0x86, 0x50, 0x34, 0x83, 0x42, 0x54, 0x80]
        let entry = { (extra: [UInt8]) -> [UInt8] in
            let body: [UInt8] = [0xD7, 0x81, 0x01, 0x83, 0x81, 0x02, 0x86, 0x85] + Array("A_AC3".utf8) + extra
            return [0xAE, 0x80 | UInt8(body.count)] + body
        }
        let stripped = try #require(entry(stripping).withUnsafeBufferPointer { MatroskaTrack.tracks(in: $0) }.first)
        #expect(stripped.strippedHeader == Data([0x0B, 0x77]) && !stripped.hasUnsupportedEncoding)
        let zlib = try #require(entry(compressed).withUnsafeBufferPointer { MatroskaTrack.tracks(in: $0) }.first)
        #expect(zlib.strippedHeader == nil && zlib.hasUnsupportedEncoding)
    }

    @Test func cueLookup() {
        let cues = MatroskaCues(points: [
            MatroskaCuePoint(time: 2_000, track: 1, clusterOffset: 300),
            MatroskaCuePoint(time: 0, track: 1, clusterOffset: 100),
            MatroskaCuePoint(time: 1_000, track: 1, clusterOffset: 200),
            MatroskaCuePoint(time: 500, track: 2, clusterOffset: 150)
        ])
        #expect(cues.point(atOrBefore: 1_500, track: 1)?.clusterOffset == 200)
        #expect(cues.point(atOrBefore: 2_000, track: 1)?.clusterOffset == 300)
        #expect(cues.point(atOrBefore: -5, track: 1)?.clusterOffset == 100)
        #expect(cues.point(atOrBefore: 700, track: 2)?.clusterOffset == 150)
        // A track without cues of its own uses everyone's.
        #expect(cues.point(atOrBefore: 600, track: 9)?.clusterOffset == 150)
        #expect(cues.lastTime == 2_000)
    }

    /// Flipped bytes, cut-short files and random noise, fed in random pieces: nothing traps and nothing loops.
    @Test func damagedInputNeverTraps() {
        let file = DemuxFixture.file(cues: .front)
        var random = SeededRandom(seed: 0x4D4B_5600)
        for round in 0..<300 {
            var bytes = file.bytes
            switch round % 3 {
            case 0:
                for _ in 0..<Int.random(in: 1...40, using: &random) {
                    bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
                }
            case 1:
                bytes = Array(bytes[..<Int.random(in: 0..<bytes.count, using: &random)])
            default:
                let header = Array(bytes[..<Int.random(in: 0..<200, using: &random)])
                bytes = header + (0..<4_000).map { _ in UInt8.random(in: 0...255, using: &random) }
            }
            var log = DemuxLog()
            var position = 0
            while position < bytes.count {
                let chunk = Int.random(in: 1...3_000, using: &random)
                log.feed(Array(bytes[position..<min(position + chunk, bytes.count)]), chunk: chunk)
                position += chunk
            }
            #expect(log.frames.count <= file.frames.count + 1_000)
        }
    }
}

/// SplitMix64, for repeatable damage.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
