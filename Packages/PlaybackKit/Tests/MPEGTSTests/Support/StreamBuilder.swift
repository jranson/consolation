//
//  StreamBuilder.swift
//  MPEGTSTests
//
//  Builds whole synthetic broadcasts (PAT, PMT, MPEG-2 video and AC-3 audio) shaped like the HDHomeRun captures,
//  and helpers to run them through the demuxer and framers.
//

import Foundation
import MPEGTS

struct CodedPicture {
    var spec: PictureSpec
    var pts: Int64
    var dts: Int64?
    var startsGOP: Bool
}

enum StreamBuilder {
    static let pmtPID: UInt16 = 0x30
    static let videoPID: UInt16 = 0x31
    static let audioPID: UInt16 = 0x34

    /// `count` GOPs of I B B P B B P B B in coded order (temporal references 2 0 1 5 3 4 8 6 7), timestamped like
    /// 9.1: PTS = base + ticks × (display index + 1), DTS = base + ticks × decode index, DTS coded only when it
    /// differs from PTS.
    static func gops(_ count: Int, base: Int64 = 900_000, ticks: Int64 = 3003, interlaced: Bool = true,
                     captions: Bool = false) -> [CodedPicture] {
        let pattern: [(type: Int, reference: Int)] = [
            (1, 2), (3, 0), (3, 1), (2, 5), (3, 3), (3, 4), (2, 8), (3, 6), (3, 7)
        ]
        var pictures: [CodedPicture] = []
        for gop in 0..<count {
            for (index, entry) in pattern.enumerated() {
                let decodeIndex = Int64(gop * pattern.count + index)
                let displayIndex = Int64(gop * pattern.count + entry.reference)
                let pts = base + ticks * (displayIndex + 1)
                let dts = base + ticks * decodeIndex
                var spec = PictureSpec(type: entry.type, temporalReference: entry.reference)
                spec.topFieldFirst = interlaced
                spec.progressiveFrame = !interlaced
                if captions {
                    spec.captions = MPEG2Fixtures.captionTriplets(seed: UInt8(truncatingIfNeeded: decodeIndex))
                }
                pictures.append(CodedPicture(spec: spec, pts: pts, dts: dts == pts ? nil : dts, startsGOP: index == 0))
            }
        }
        return pictures
    }

    /// The elementary-stream bytes of one picture, with sequence and GOP headers when it starts a GOP.
    static func pictureBytes(_ picture: CodedPicture, sequence: SequenceSpec, closedGOP: Bool = false,
                             random: inout SeededGenerator) -> [UInt8] {
        var bytes: [UInt8] = []
        if picture.startsGOP {
            bytes += MPEG2Fixtures.sequenceHeader(sequence) + MPEG2Fixtures.gop(closed: closedGOP)
        }
        return bytes + MPEG2Fixtures.picture(picture.spec, slices: &random)
    }

    /// PAT + PMT + one unbounded video PES per picture + an AC-3 PES (bounded, six frames) every third picture.
    static func broadcast(
        pictures: [CodedPicture],
        sequence: SequenceSpec = .hd1080i,
        closedGOP: Bool = false,
        seed: UInt64 = 1
    ) -> [UInt8] {
        var random = SeededGenerator(seed: seed)
        var writer = TSWriter()
        writer.section(pid: 0, PSIFixtures.pat(programs: [(1, pmtPID)]))
        writer.section(pid: pmtPID, PSIFixtures.pmt(program: 1, pcrPID: videoPID,
                                                     streams: PSIFixtures.broadcastStreams()))
        var audioPTS = (pictures.first?.pts ?? 0) - 9000
        for (index, picture) in pictures.enumerated() {
            let elementary = pictureBytes(picture, sequence: sequence, closedGOP: closedGOP, random: &random)
            let pes = PSIFixtures.pes(streamID: 0xE0, pts: picture.pts, dts: picture.dts, payload: elementary,
                                      bounded: false)
            var flags = AdaptationFlags(randomAccess: picture.startsGOP)
            flags.pcr = (picture.dts ?? picture.pts) * 300
            writer.packetize(pid: videoPID, payload: pes, flags: flags)
            if index % 3 == 0 {
                var frames: [UInt8] = []
                for _ in 0..<6 {
                    frames += AC3Fixtures.frame(random: &random)
                }
                writer.packetize(pid: audioPID, payload: PSIFixtures.pes(streamID: 0xBD, pts: audioPTS,
                                                                          payload: frames, bounded: true))
                audioPTS += 6 * 2880
            }
        }
        return writer.bytes
    }
}

/// Runs bytes through a demuxer in the given chunk sizes (cycled), then flushes.
func demux(_ bytes: [UInt8], chunks: [Int] = [], demuxer: inout TSDemuxer) -> [TSDemuxEvent] {
    var events: [TSDemuxEvent] = []
    var offset = 0
    var index = 0
    while offset < bytes.count {
        let size = chunks.isEmpty ? bytes.count : max(1, chunks[index % chunks.count])
        let end = min(bytes.count, offset + size)
        events += demuxer.feed(Data(bytes[offset..<end]))
        offset = end
        index += 1
    }
    return events + demuxer.flush()
}

func demux(_ bytes: [UInt8], chunks: [Int] = []) -> [TSDemuxEvent] {
    var demuxer = TSDemuxer()
    return demux(bytes, chunks: chunks, demuxer: &demuxer)
}

extension Array where Element == TSDemuxEvent {
    var packets: [PESPacket] {
        compactMap { event in
            if case .pes(let packet) = event { return packet }
            return nil
        }
    }

    func packets(pid: UInt16) -> [PESPacket] {
        packets.filter { $0.pid == pid }
    }

    var programLists: [[ProgramMap]] {
        compactMap { event in
            if case .programs(let programs) = event { return programs }
            return nil
        }
    }

    var discontinuities: [UInt16] {
        compactMap { event in
            if case .discontinuity(let pid) = event { return pid }
            return nil
        }
    }
}

func frameVideo(_ packets: [PESPacket]) -> [MPEG2AccessUnit] {
    var framer = MPEG2Framer()
    var units: [MPEG2AccessUnit] = []
    for packet in packets {
        units += framer.append(packet)
    }
    return units + framer.flush()
}

func frameAudio(_ packets: [PESPacket]) -> [AC3Frame] {
    var framer = AC3Framer()
    var frames: [AC3Frame] = []
    for packet in packets {
        frames += framer.append(packet)
    }
    return frames
}

/// Wraps elementary-stream bytes as a PES packet value for framer tests.
func videoPES(_ bytes: [UInt8], pts: Int64? = nil, dts: Int64? = nil, discontinuity: Bool = false) -> PESPacket {
    PESPacket(pid: StreamBuilder.videoPID, streamID: 0xE0, pts: pts, dts: dts, payload: Data(bytes),
              isDiscontinuity: discontinuity)
}
