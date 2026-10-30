//
//  PSITests.swift
//  MPEGTSTests
//
//  PAT/PMT parsing through the demuxer: CRC, versions, multi-program PATs, descriptors and stream kinds.
//

import Foundation
import Testing
@testable import MPEGTS

struct PSITests {
    /// PAT + PMTs followed by null packets, so three sync bytes are visible however few tables there are.
    private func tables(pat: [UInt8], pmts: [(UInt16, [UInt8])]) -> [UInt8] {
        var writer = TSWriter()
        writer.section(pid: 0, pat)
        for (pid, section) in pmts {
            writer.section(pid: pid, section)
        }
        for _ in 0..<2 {
            writer.packetize(pid: 0x1FFF, payload: [UInt8](repeating: 0xFF, count: 184), unitStart: false)
        }
        return writer.bytes
    }

    @Test func singleProgramPATAndPMT() throws {
        let pat = PSIFixtures.pat(programs: [(1, 0x30)])
        #expect(Array(pat.prefix(3)) == [0x00, 0xB0, 0x0D])
        let pmt = PSIFixtures.pmt(program: 1, pcrPID: 0x31, programInfo: PSIFixtures.registration("GA94"),
                                  streams: PSIFixtures.broadcastStreams())
        let events = demux(tables(pat: pat, pmts: [(0x30, pmt)]))
        let lists = events.programLists
        #expect(lists.count == 1)
        let program = try #require(lists.first?.first)
        #expect(program.programNumber == 1)
        #expect(program.pmtPID == 0x30)
        #expect(program.pcrPID == 0x31)
        #expect(program.streams.map(\.pid) == [0x31, 0x34, 0x35])
        #expect(program.streams.map(\.kind) == [.mpeg2Video, .ac3, .ac3])
        #expect(program.streams.map(\.language) == [nil, "eng", "spa"])
        #expect(program.streams.map(\.audioChannelsHint) == [nil, 5, 2])
        #expect(program.videoStream?.pid == 0x31)
        #expect(program.audioStreams.count == 2)
    }

    @Test func parsesPATSectionDirectly() throws {
        let pat = PSIFixtures.pat(programs: [(3, 0x30)])
        try pat.withUnsafeBufferPointer { bytes in
            guard case .valid(let header) = PSIParser.check(bytes) else {
                Issue.record("PAT should validate")
                return
            }
            #expect(header.sectionLength == 13)
            let parsed = try #require(PSIParser.parsePAT(bytes, header: header))
            #expect(parsed.entries == [PATEntry(programNumber: 3, pmtPID: 0x30)])
        }
    }

    @Test func badCRCIsRejected() {
        var pat = PSIFixtures.pat(programs: [(1, 0x30)])
        pat[9] ^= 0x01
        let pmt = PSIFixtures.pmt(program: 1, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams())
        var demuxer = TSDemuxer()
        let events = demux(tables(pat: pat, pmts: [(0x30, pmt)]), demuxer: &demuxer)
        #expect(events.programLists.isEmpty)
        #expect(demuxer.statistics.crcErrors == 1)
        pat.withUnsafeBufferPointer { #expect(PSIParser.check($0) == .badCRC) }
    }

    @Test func badSectionLengthIsMalformed() {
        var pat = PSIFixtures.pat(programs: [(1, 0x30)])
        pat[1] = 0xBF
        pat[2] = 0xFF
        var demuxer = TSDemuxer()
        let events = demux(tables(pat: pat, pmts: []), demuxer: &demuxer)
        #expect(events.programLists.isEmpty)
        #expect(demuxer.statistics.malformed >= 1)
        pat.withUnsafeBufferPointer { #expect(PSIParser.check($0) == .malformed) }
    }

    @Test func versionChangesAreTracked() {
        let streamsV0 = [StreamSpec(streamType: 0x02, pid: 0x31), StreamSpec(streamType: 0x81, pid: 0x34)]
        let streamsV1 = streamsV0 + [StreamSpec(streamType: 0x81, pid: 0x35)]
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, version: 0, pcrPID: 0x31, streams: streamsV0))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, version: 0, pcrPID: 0x31, streams: streamsV0))
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, version: 1, pcrPID: 0x31, streams: streamsV1))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, version: 1, pcrPID: 0x31, streams: streamsV1))
        // A section that is not yet current is ignored.
        let next = PSIFixtures.longSection(tableID: 0x02, tableIDExtension: 1, version: 2, current: false, body: [])
        writer.section(pid: 0x30, next)
        let lists = demux(writer.bytes).programLists
        #expect(lists.count == 2)
        #expect(lists.first?.first?.streams.count == 2)
        #expect(lists.last?.first?.streams.count == 3)
    }

    @Test func multiProgramPAT() throws {
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(0, 0x10), (3, 0x30), (4, 0x40)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 3, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams()))
        writer.section(pid: 0x40, PSIFixtures.pmt(program: 4, pcrPID: 0x41, streams: [
            StreamSpec(streamType: 0x02, pid: 0x41),
            StreamSpec(streamType: 0x81, pid: 0x44, descriptors: PSIFixtures.language("eng"))
        ]))
        writer.packetize(pid: 0x41, payload: PSIFixtures.pes(streamID: 0xE0, pts: 1000, payload: [1, 2, 3],
                                                              bounded: true))
        writer.packetize(pid: 0x31, payload: PSIFixtures.pes(streamID: 0xE0, pts: 2000, payload: [4, 5],
                                                              bounded: true))
        let events = demux(writer.bytes)
        let programs = try #require(events.programLists.last)
        #expect(programs.map(\.programNumber) == [3, 4])
        #expect(programs.map(\.pmtPID) == [0x30, 0x40])
        #expect(programs[1].streams.map(\.pid) == [0x41, 0x44])
        #expect(events.packets.map(\.pid) == [0x41, 0x31])
    }

    @Test func multiSectionPATIsMerged() throws {
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)], sectionNumber: 0, lastSectionNumber: 1))
        writer.section(pid: 0, PSIFixtures.pat(programs: [(2, 0x40)], sectionNumber: 1, lastSectionNumber: 1))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, pcrPID: 0x31,
                                                  streams: [StreamSpec(streamType: 2, pid: 0x31)]))
        writer.section(pid: 0x40, PSIFixtures.pmt(program: 2, pcrPID: 0x41,
                                                  streams: [StreamSpec(streamType: 2, pid: 0x41)]))
        let programs = try #require(demux(writer.bytes).programLists.last)
        #expect(programs.map(\.programNumber) == [1, 2])
    }

    @Test func sectionSpanningPackets() throws {
        var streams: [StreamSpec] = []
        for index in 0..<20 {
            let descriptors = PSIFixtures.language(index.isMultiple(of: 2) ? "eng" : "fra")
                + PSIFixtures.atscAC3(numChannels: 2)
            streams.append(StreamSpec(streamType: 0x81, pid: UInt16(0x100 + index), descriptors: descriptors))
        }
        let pmt = PSIFixtures.pmt(program: 7, pcrPID: 0x100, streams: streams)
        #expect(pmt.count > 184)
        let programs = try #require(demux(tables(pat: PSIFixtures.pat(programs: [(7, 0x50)]),
                                                 pmts: [(0x50, pmt)])).programLists.last)
        #expect(programs.first?.streams.count == 20)
        #expect(programs.first?.streams.last?.language == "fra")
    }

    @Test func streamKindsAndAudioDescriptors() throws {
        let streams = [
            StreamSpec(streamType: 0x81, pid: 0x101),
            StreamSpec(streamType: 0x06, pid: 0x102, descriptors: [0x6A, 0x01, 0x00]),
            StreamSpec(streamType: 0x06, pid: 0x103, descriptors: [0x7A, 0x01, 0x00]),
            StreamSpec(streamType: 0x87, pid: 0x104),
            StreamSpec(streamType: 0x06, pid: 0x105, descriptors: PSIFixtures.registration("AC-3")),
            StreamSpec(streamType: 0x06, pid: 0x106, descriptors: PSIFixtures.registration("EAC3")),
            StreamSpec(streamType: 0x0F, pid: 0x107),
            StreamSpec(streamType: 0x11, pid: 0x108),
            StreamSpec(streamType: 0x03, pid: 0x109),
            StreamSpec(streamType: 0x1B, pid: 0x10A),
            StreamSpec(streamType: 0x24, pid: 0x10B),
            StreamSpec(streamType: 0x06, pid: 0x10C),
            StreamSpec(streamType: 0x81, pid: 0x10D, descriptors: PSIFixtures.atscAC3(numChannels: 13)
                       + PSIFixtures.language("SPA", audioType: 3))
        ]
        let pmt = PSIFixtures.pmt(program: 2, pcrPID: 0x101, streams: streams)
        let program = try #require(demux(tables(pat: PSIFixtures.pat(programs: [(2, 0x60)]),
                                                pmts: [(0x60, pmt)])).programLists.last?.first)
        let expected: [StreamKind] = [.ac3, .ac3, .eac3, .eac3, .ac3, .eac3, .aac, .other(0x11), .mpegAudio, .h264,
                                      .hevc, .other(0x06), .ac3]
        #expect(program.streams.map(\.kind) == expected)
        #expect(program.streams.last?.language == "spa")
        #expect(program.streams.last?.audioChannelsHint == 6)
        #expect(PSIParser.channelCount(atscCode: 0) == 2)
        #expect(PSIParser.channelCount(atscCode: 14) == nil)
    }

    @Test func pmtForUnlistedProgramIsIgnored() {
        let pmt = PSIFixtures.pmt(program: 9, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams())
        let events = demux(tables(pat: PSIFixtures.pat(programs: [(1, 0x30)]), pmts: [(0x30, pmt)]))
        #expect(events.programLists.isEmpty)
    }

    @Test func pesFilterDropsOtherPIDs() {
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, 0x30)]))
        writer.section(pid: 0x30, PSIFixtures.pmt(program: 1, pcrPID: 0x31, streams: PSIFixtures.broadcastStreams()))
        for pid: UInt16 in [0x31, 0x34, 0x35] {
            writer.packetize(pid: pid, payload: PSIFixtures.pes(streamID: 0xBD, pts: 9, payload: [1], bounded: true))
        }
        var demuxer = TSDemuxer()
        demuxer.setPESFilter([0x31])
        let events = demux(writer.bytes, demuxer: &demuxer)
        #expect(events.packets.map(\.pid) == [0x31])
        #expect(demuxer.pesFilter == [0x31])
    }

    /// AC-4 (ATSC 3.0 audio) is recognized from the DVB AC-4 descriptor or an `AC-4` registration, and counts as audio.
    @Test func recognizesAC4() {
        let dvb: [UInt8] = [0x7F, 0x02, 0x15, 0x00] + PSIFixtures.language("eng")
        let registered = PSIFixtures.registration("AC-4")
        for (type, descriptors) in [(UInt8(0x06), dvb), (0x06, registered), (0x88, registered)] {
            let stream = descriptors.withUnsafeBufferPointer { pointer in
                PSIParser.describe(streamType: type, pid: 0x44, section: pointer, descriptors: 0..<pointer.count)
            }
            #expect(stream.kind == .ac4)
            #expect(stream.kind.isAudio)
        }
        let plain = [UInt8]().withUnsafeBufferPointer { pointer in
            PSIParser.describe(streamType: 0x06, pid: 0x44, section: pointer, descriptors: 0..<0)
        }
        #expect(plain.kind == .other(0x06))
    }
}
