//
//  PESTests.swift
//  MPEGTSTests
//
//  PES reassembly: PUSI-based boundaries, header offsets, timestamps, continuity and size limits.
//

import Foundation
import Testing
@testable import MPEGTS

struct PESTests {
    /// A writer that already carries the 9.1-style PAT and PMT.
    private func broadcastWriter() -> TSWriter {
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams()))
        return writer
    }

    @Test func pesBoundariesComeFromPUSINotStartCodes() throws {
        var writer = broadcastWriter()
        // 184 − 14 header bytes fill the first packet, so the continuation packet's payload starts with 00 00 01 01.
        let firstPacketPayload = [UInt8](repeating: 0x55, count: 184 - 14 - 4)
        let elementary: [UInt8] = [0, 0, 1, 0x00] + firstPacketPayload + [0, 0, 1, 0x01]
            + [UInt8](repeating: 0x66, count: 300)
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 1000, payload: elementary,
                                                              bounded: false))
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 4003, payload: [0, 0, 1, 0xB3],
                                                              bounded: false))
        let packets = demux(writer.bytes).packets(pid: 0x31)
        #expect(packets.count == 2)
        let first = try #require(packets.first)
        #expect(Array(first.payload) == elementary)
        #expect(first.pts == 1000)
        #expect(first.dts == nil)
        #expect(first.streamID == 0xE0)
    }

    @Test func headerOffsetsAndTimestamps() throws {
        var writer = broadcastWriter()
        let pes = PSIFixtures.pes(streamID: 0xE0, pts: 8_078_718_683, dts: 8_078_709_674, payload: [9, 8, 7],
                                  bounded: true)
        #expect(pes[7] == 0xC0)
        #expect(pes[8] == 10)
        writer.packetize(pid: 0x31, payload: pes, flags: AdaptationFlags(randomAccess: true))
        let packet = try #require(demux(writer.bytes).packets.first)
        #expect(packet.pts == 8_078_718_683)
        #expect(packet.dts == 8_078_709_674)
        #expect(Array(packet.payload) == [9, 8, 7])
        #expect(packet.isRandomAccess)
        #expect(!packet.isDiscontinuity)
        pes.withUnsafeBufferPointer { bytes in
            #expect(PESHeader.parse(bytes)?.payloadRange == 19..<22)
        }
    }

    @Test func boundedPESIsEmittedWithoutWaitingForTheNextStart() throws {
        var writer = broadcastWriter()
        let audio = [UInt8](repeating: 1, count: 400)
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 500, payload: audio, bounded: true))
        var demuxer = TSDemuxer()
        var events = demuxer.feed(Data(writer.bytes))
        #expect(events.packets.count == 1)
        events = demuxer.flush()
        #expect(events.isEmpty)
    }

    @Test func ptsUnwrapsAcross33Bits() {
        var writer = broadcastWriter()
        let period: Int64 = 1 << 33
        let raw: [Int64] = [period - 6006, period - 3003, 0, 3003, 6006]
        for value in raw {
            writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: value, payload: [1],
                                                                  bounded: true))
        }
        let pts = demux(writer.bytes).packets.compactMap(\.pts)
        #expect(pts == [period - 6006, period - 3003, period, period + 3003, period + 6006])
    }

    @Test func timestampsAreTrackedPerPID() {
        var writer = broadcastWriter()
        let period: Int64 = 1 << 33
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: period - 1000, payload: [1],
                                                              bounded: true))
        // The audio PID starts just after the wrap; it is anchored near the program's video timeline.
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 2000, payload: [1], bounded: true))
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: period - 100, payload: [1],
                                                              bounded: true))
        let packets = demux(writer.bytes).packets
        #expect(packets.map(\.pts) == [period - 1000, period + 2000, period - 100])
    }

    @Test func continuityGapMarksDiscontinuity() throws {
        var demuxer = TSDemuxer()
        var writer = broadcastWriter()
        let big = PSIFixtures.pes(streamID: 0xE0, pts: 1, payload: [UInt8](repeating: 7, count: 1000), bounded: false)
        writer.packetize(pid: 0x31, payload: big)
        writer.losePacket(pid: 0x31)
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 3004, payload: [1], bounded: false))
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 6007, payload: [2], bounded: false))
        let events = demux(writer.bytes, demuxer: &demuxer)
        #expect(events.discontinuities == [0x31])
        #expect(demuxer.statistics.continuityErrors == 1)
        let packets = events.packets
        #expect(packets.map(\.isDiscontinuity) == [true, true, false])
    }

    @Test func discontinuityIndicatorIsNotAContinuityError() {
        var demuxer = TSDemuxer()
        var writer = broadcastWriter()
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 10, payload: [1], bounded: true))
        writer.losePacket(pid: 0x34)
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 99_999, payload: [2], bounded: true),
                         flags: AdaptationFlags(discontinuity: true))
        let events = demux(writer.bytes, demuxer: &demuxer)
        #expect(demuxer.statistics.continuityErrors == 0)
        #expect(events.discontinuities == [0x34])
        #expect(events.packets.map(\.isDiscontinuity) == [false, true])
    }

    @Test func continuationBeforeFirstHeaderIsDropped() throws {
        var writer = broadcastWriter()
        let pes = PSIFixtures.pes(streamID: 0xE0, pts: 1, payload: [UInt8](repeating: 3, count: 500), bounded: false)
        var orphan = TSWriter()
        orphan.packetize(pid: 0x31, payload: pes)
        // Keep only the continuation packets of a PES whose start was "missed" at tune-in.
        let continuation = Array(orphan.bytes[188...])
        writer.raw(continuation)
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 99, payload: [4, 4], bounded: false))
        let packets = demux(writer.bytes).packets
        #expect(packets.count == 1)
        #expect(packets.first?.pts == 99)
    }

    @Test func duplicateAndErrorPacketsAreIgnored() {
        var demuxer = TSDemuxer()
        var writer = broadcastWriter()
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 10, payload: [1], bounded: true))
        let duplicate = Array(writer.bytes.suffix(188))
        writer.raw(duplicate)
        var errored = duplicate
        errored[1] |= 0x80
        writer.raw(errored)
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 20, payload: [2], bounded: true))
        let events = demux(writer.bytes, demuxer: &demuxer)
        #expect(events.packets.map(\.pts) == [10, 20])
        #expect(demuxer.statistics.transportErrors == 1)
        #expect(demuxer.statistics.continuityErrors == 0)
    }

    @Test func oversizedPESIsDroppedAndNextIsFlagged() {
        var demuxer = TSDemuxer()
        var writer = broadcastWriter()
        let huge = [UInt8](repeating: 0x42, count: TSDemuxer.maximumPESSize + 1000)
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 1, payload: huge, bounded: false))
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 2, payload: [1], bounded: false))
        let events = demux(writer.bytes, demuxer: &demuxer)
        #expect(demuxer.statistics.oversizedPES == 1)
        #expect(events.packets.map(\.pts) == [2])
        #expect(events.packets.first?.isDiscontinuity == true)
    }

    @Test func declaredLengthLongerThanDataIsEmittedAtNextStart() {
        var writer = broadcastWriter()
        var pes = PSIFixtures.pes(streamID: 0xBD, pts: 5, payload: [1, 2, 3], bounded: true)
        pes[4] = 0xFF
        pes[5] = 0xFF
        writer.packetize(pid: 0x34, payload: pes)
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 6, payload: [4], bounded: true))
        let packets = demux(writer.bytes).packets
        #expect(packets.map(\.pts) == [5, 6])
        #expect(Array(packets[0].payload) == [1, 2, 3])
    }

    @Test func malformedHeadersAreCountedNotEmitted() {
        var demuxer = TSDemuxer()
        var writer = broadcastWriter()
        var badLength = PSIFixtures.pes(streamID: 0xBD, pts: 5, payload: [1, 2, 3], bounded: true)
        badLength[8] = 200
        writer.packetize(pid: 0x34, payload: badLength)
        writer.packetize(pid: 0x34, payload: [0, 0, 2, 0xBD, 0, 3, 1, 2, 3])
        writer.packetize(pid: 0x34, payload: PSIFixtures.pes(streamID: 0xBD, pts: 7, payload: [4], bounded: true))
        let packets = demux(writer.bytes, demuxer: &demuxer).packets
        #expect(packets.map(\.pts) == [7])
        #expect(demuxer.statistics.malformedPES == 2)
    }

    @Test func pcrIsRecorded() {
        var writer = broadcastWriter()
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 1, payload: [1], bounded: true),
                         flags: AdaptationFlags(pcr: 27_000_000))
        var demuxer = TSDemuxer()
        _ = demux(writer.bytes, demuxer: &demuxer)
        #expect(demuxer.lastPCR(pid: 0x31) == 27_000_000)
        #expect(demuxer.lastPCR(pid: 0x34) == nil)
    }
}
