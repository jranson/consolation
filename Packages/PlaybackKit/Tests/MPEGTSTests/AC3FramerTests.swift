//
//  AC3FramerTests.swift
//  MPEGTSTests
//
//  AC-3 and E-AC-3 framing across PES boundaries, timestamps, channel layouts and CRC checks.
//

import Foundation
import Testing
import MPEGTS

struct AC3FramerTests {
    private func audioPES(_ bytes: [UInt8], pts: Int64?) -> PESPacket {
        PESPacket(pid: StreamBuilder.audioPID, streamID: 0xBD, pts: pts, payload: Data(bytes))
    }

    @Test func framesSplitAcrossPESBoundaries() {
        var random = SeededGenerator(seed: 21)
        var frames: [[UInt8]] = []
        for _ in 0..<12 {
            frames.append(AC3Fixtures.frame(random: &random))
        }
        #expect(frames[0].count == 1536)
        let stream = frames.flatMap { $0 }
        // PES boundaries at odd offsets; each PES's PTS belongs to the first frame that starts inside it.
        let cuts = [0, 1000, 2500, 7000, 7100, stream.count]
        var packets: [PESPacket] = []
        for index in 0..<(cuts.count - 1) {
            let firstFrameStart = ((cuts[index] + 1535) / 1536) * 1536
            let pts = Int64(firstFrameStart / 1536) * 2880 + 10_000
            packets.append(audioPES(Array(stream[cuts[index]..<cuts[index + 1]]), pts: pts))
        }
        let output = frameAudio(packets)
        #expect(output.count == 12)
        #expect(output.map { Array($0.data) } == frames)
        #expect(output.map(\.pts) == (0..<12).map { Int64($0) * 2880 + 10_000 })
        #expect(output.allSatisfy { $0.sampleRate == 48_000 && $0.samplesPerFrame == 1536 && !$0.isEAC3 })
        #expect(output.first?.channelCount == 6)
        #expect(output.first?.acmod == 7)
        #expect(output.first?.hasLFE == true)
    }

    @Test func laterFramesAdvanceBySampleCount() {
        var random = SeededGenerator(seed: 22)
        var stream: [UInt8] = []
        for _ in 0..<6 {
            stream += AC3Fixtures.frame(frmsizecod: 20, acmod: 2, lfe: false, random: &random)
        }
        let output = frameAudio([audioPES(stream, pts: 90_000)])
        #expect(output.map(\.pts) == [90_000, 92_880, 95_760, 98_640, 101_520, 104_400])
        #expect(output.first?.channelCount == 2)
        #expect(output.first?.data.count == 768)
    }

    @Test func sampleRatesAndFrameSizes() {
        var random = SeededGenerator(seed: 23)
        let odd = AC3Fixtures.frame(fscod: 1, frmsizecod: 29, acmod: 1, lfe: false, random: &random)
        let even = AC3Fixtures.frame(fscod: 1, frmsizecod: 28, acmod: 1, lfe: false, random: &random)
        let slow = AC3Fixtures.frame(fscod: 2, frmsizecod: 10, acmod: 3, lfe: true, random: &random)
        #expect(odd.count == 1672)
        #expect(even.count == 1670)
        #expect(slow.count == 480)
        let output = frameAudio([audioPES(odd + even + slow, pts: 0)])
        #expect(output.map(\.sampleRate) == [44_100, 44_100, 32_000])
        #expect(output.map(\.channelCount) == [1, 1, 4])
        // 1536 samples at 44.1 kHz is 3134.69 ticks; positions come from the running sample count.
        #expect(output.map(\.pts) == [0, 3134, 6269])
    }

    @Test func eac3DependentSubstreamsJoinTheirAccessUnit() throws {
        var random = SeededGenerator(seed: 24)
        let independent = AC3Fixtures.eac3Frame(size: 1000, random: &random)
        let dependent = AC3Fixtures.eac3Frame(streamType: 1, size: 400, acmod: 2, lfe: false, random: &random)
        let next = AC3Fixtures.eac3Frame(size: 1000, random: &random)
        let reduced = AC3Fixtures.eac3Frame(size: 500, fscod: 3, blocksCode: 1, acmod: 2, lfe: false,
                                            random: &random)
        let short = AC3Fixtures.eac3Frame(size: 300, blocksCode: 1, acmod: 1, lfe: false, random: &random)
        let output = frameAudio([audioPES(independent + dependent + next + reduced + short, pts: 5000)])
        #expect(output.count == 4)
        let first = try #require(output.first)
        #expect(first.isEAC3)
        #expect(Array(first.data) == independent + dependent)
        #expect(first.channelCount == 6)
        #expect(first.samplesPerFrame == 1536)
        #expect(output[2].sampleRate == 22_050)
        #expect(output[2].samplesPerFrame == 1536)
        #expect(output[3].samplesPerFrame == 512)
        #expect(output.map(\.pts) == [5000, 7880, 10_760, 17_029])
    }

    @Test func corruptedFrameIsDroppedAndSyncRecovers() {
        var random = SeededGenerator(seed: 25)
        var frames: [[UInt8]] = []
        for _ in 0..<4 {
            frames.append(AC3Fixtures.frame(random: &random))
        }
        frames[1][700] ^= 0x10
        let garbage: [UInt8] = [0x0B, 0x77, 0x12, 0x34, 0x1C, 0x40, 0xFF, 0x00, 0x0B]
        var framer = AC3Framer()
        let output = framer.append(audioPES(garbage + frames.flatMap { $0 }, pts: 0))
        #expect(output.count == 3)
        #expect(output.map { Array($0.data) } == [frames[0], frames[2], frames[3]])
        // The damaged frame was due where it sat, so its 2880 ticks stay in the timeline.
        #expect(output.map(\.pts) == [0, 5760, 8640])
        #expect(framer.crcErrors >= 1)
    }

    @Test func framesBeforeTheFirstPTSAreDropped() {
        var random = SeededGenerator(seed: 26)
        let first = AC3Fixtures.frame(random: &random)
        let second = AC3Fixtures.frame(random: &random)
        var framer = AC3Framer()
        #expect(framer.append(audioPES(first, pts: nil)).isEmpty)
        #expect(framer.droppedFrames == 1)
        let output = framer.append(audioPES(second, pts: 777))
        #expect(output.map(\.pts) == [777])
        framer.reset()
        #expect(framer.droppedFrames == 0)
    }

    @Test func demuxedBroadcastAudio() {
        let events = demux(StreamBuilder.broadcast(pictures: StreamBuilder.gops(2)))
        let output = frameAudio(events.packets(pid: StreamBuilder.audioPID))
        #expect(output.count == 6 * 6)
        let steps = Set(zip(output, output.dropFirst()).map { $1.pts - $0.pts })
        #expect(steps == [2880])
    }
}
