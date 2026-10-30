//
//  MalformedInputTests.swift
//  MPEGTSTests
//
//  Hostile and damaged input with fixed seeds: nothing may trap, and buffers stay bounded.
//

import Foundation
import Testing
import MPEGTS

struct MalformedInputTests {
    private static let stream = StreamBuilder.broadcast(pictures: StreamBuilder.gops(2, captions: true))

    private struct Counts {
        var events: Int
        var units: Int
        var frames: Int
    }

    /// Demuxes and frames everything, the way the engine would.
    @discardableResult
    private func pipeline(_ bytes: [UInt8], chunks: [Int]) -> Counts {
        var demuxer = TSDemuxer()
        var video = MPEG2Framer()
        var audio = AC3Framer()
        var units = 0
        var frames = 0
        let events = demux(bytes, chunks: chunks, demuxer: &demuxer)
        for packet in events.packets {
            if packet.pid == StreamBuilder.videoPID {
                units += video.append(packet).count
            } else {
                frames += audio.append(packet).count
            }
        }
        units += video.flush().count
        return Counts(events: events.count, units: units, frames: frames)
    }

    @Test func randomBytesNeverTrap() {
        for seed: UInt64 in 1...8 {
            var random = SeededGenerator(seed: seed)
            let bytes = random.bytes(50_000)
            pipeline(bytes, chunks: [Int.random(in: 1...4000, using: &random)])
        }
    }

    @Test func randomPacketsWithValidSyncNeverTrap() {
        var random = SeededGenerator(seed: 99)
        var bytes: [UInt8] = []
        for _ in 0..<2000 {
            var packet = random.bytes(188)
            packet[0] = 0x47
            // Steer most packets at the PSI and elementary PIDs so the parsers see hostile sections and PES.
            let pid = [0x00, 0x30, 0x31, 0x34, 0x35, 0x1FFF].randomElement(using: &random) ?? 0
            packet[1] = (packet[1] & 0xE0) | UInt8(pid >> 8)
            packet[2] = UInt8(pid & 0xFF)
            bytes += packet
        }
        var prefix = TSWriter()
        prefix.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        prefix.section(pid: 0x30, PSIFixtures.pmt(program: 1, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams()))
        pipeline(prefix.bytes + bytes, chunks: [188 * 7 + 3])
    }

    @Test func corruptedValidStreamNeverTraps() {
        for seed: UInt64 in 1...6 {
            var random = SeededGenerator(seed: seed)
            var bytes = Self.stream
            // Leave the first three packets (sync, PAT, PMT) intact; damage the rest.
            for _ in 0..<60 {
                let index = Int.random(in: (188 * 3)..<bytes.count, using: &random)
                bytes[index] = UInt8.random(in: 0...255, using: &random)
            }
            let result = pipeline(bytes, chunks: [1316])
            #expect(result.events > 0)
        }
    }

    @Test func truncatedPacketsNeverTrap() {
        var bytes: [UInt8] = []
        var offset = 0
        var random = SeededGenerator(seed: 5)
        while offset < Self.stream.count {
            let keep = Int.random(in: 1...188, using: &random)
            bytes += Self.stream[offset..<min(Self.stream.count, offset + keep)]
            offset += 188
        }
        pipeline(bytes, chunks: [500])
    }

    @Test func framersSurviveRandomPayloads() {
        var random = SeededGenerator(seed: 77)
        var video = MPEG2Framer()
        var audio = AC3Framer()
        for index in 0..<300 {
            var payload = random.bytes(Int.random(in: 0...5000, using: &random))
            if index % 3 == 0, payload.count > 12 {
                // Plant start codes and syncwords so the header parsers run on garbage.
                payload.replaceSubrange(0..<4, with: [0, 0, 1, [0xB3, 0xB5, 0x00, 0xB8, 0xB2][index % 5]])
                payload.replaceSubrange(8..<10, with: [0x0B, 0x77])
            }
            let packet = PESPacket(pid: 1, streamID: 0xE0, pts: Int64(index) * 3003, payload: Data(payload))
            _ = video.append(packet)
            _ = audio.append(packet)
        }
        _ = video.flush()
    }

    @Test func videoWithoutStartCodesStaysBounded() {
        var framer = MPEG2Framer()
        let chunk = [UInt8](repeating: 0x5A, count: 1 << 20)
        for _ in 0..<6 {
            #expect(framer.append(videoPES(chunk, pts: 1)).isEmpty)
        }
        #expect(framer.flush().isEmpty)
    }

    @Test func headersAloneAreNeverEmitted() {
        var random = SeededGenerator(seed: 3)
        let headers = MPEG2Fixtures.sequenceHeader(.hd1080i) + MPEG2Fixtures.gop(closed: false)
        var framer = MPEG2Framer()
        var units = framer.append(videoPES(headers + headers, pts: 1))
        units += framer.append(videoPES(MPEG2Fixtures.picture(PictureSpec(type: 1, temporalReference: 0),
                                                                slices: &random), pts: 2))
        units += framer.flush()
        #expect(units.count == 1)
        #expect(units.first?.hasSequenceHeader == true)
        #expect(units.first?.pts == 2)
    }

    @Test func absurdSectionAndPESLengths() {
        var writer = TSWriter()
        var pat = PSIFixtures.pat(programs: [(1, 0x30)])
        pat[2] = 0xFF  // section_length 0x0FF: longer than the data, never completes
        writer.section(pid: 0, pat)
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams()))
        var pes = PSIFixtures.pes(streamID: 0xBD, pts: 1, payload: [1, 2], bounded: true)
        pes[4] = 0
        pes[5] = 1  // PES_packet_length shorter than its own header
        writer.packetize(pid: 0x34, payload: pes)
        writer.packetize(pid: 0x34, payload: [0, 0, 1, 0xBD, 0xFF, 0xFF, 0x80, 0xC0, 0xFF])
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 3, payload: [3], bounded: true))
        var demuxer = TSDemuxer()
        let events = demux(writer.bytes, chunks: [100], demuxer: &demuxer)
        #expect(events.programLists.count == 1)
        #expect(events.packets.map(\.pts) == [3])
        #expect(demuxer.statistics.malformedPES == 2)
    }

    @Test func adaptationFieldLengthTooLongIsDropped() {
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams()))
        var packet = [UInt8](repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = 0x40
        packet[2] = 0x34
        packet[3] = 0x30
        packet[4] = 190
        writer.raw(packet)
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 3, payload: [3], bounded: true))
        var demuxer = TSDemuxer()
        let events = demux(writer.bytes, demuxer: &demuxer)
        #expect(events.packets.count == 1)
        #expect(demuxer.statistics.malformed == 1)
    }
}
