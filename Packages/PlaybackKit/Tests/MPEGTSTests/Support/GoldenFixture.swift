//
//  GoldenFixture.swift
//  MPEGTSTests
//
//  Loads the committed fixtures made by scripts/make-test-fixtures.sh (synthetic FFmpeg streams and header-only
//  capture excerpts) and runs them through the demuxer and framers the way a network source would deliver them.
//

import Foundation
import MPEGTS

struct GoldenStream {
    enum FixtureError: Error {
        case missing(String)
    }

    /// The last program list the demuxer announced.
    var programs: [ProgramMap] = []
    var events: [TSDemuxEvent] = []
    /// Access units per video PID, in decode order.
    var video: [UInt16: [MPEG2AccessUnit]] = [:]
    /// AC-3 frames per audio PID.
    var audio: [UInt16: [AC3Frame]] = [:]
    /// The last PCR per PCR PID, in 27 MHz ticks.
    var lastPCR: [UInt16: Int64] = [:]

    static func url(_ name: String, subdirectory: String? = nil) -> URL? {
        let folder = subdirectory.map { "Fixtures/\($0)" } ?? "Fixtures"
        return Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: folder)
    }

    static func exists(_ name: String, subdirectory: String? = nil) -> Bool {
        url(name, subdirectory: subdirectory) != nil
    }

    static func load(_ name: String, subdirectory: String? = nil) throws -> GoldenStream {
        guard let url = url(name, subdirectory: subdirectory) else { throw FixtureError.missing(name) }
        return run(try Data(contentsOf: url))
    }

    /// Demuxes in 7 KiB chunks (deliberately not a multiple of 188) and frames every video and AC-3 stream.
    static func run(_ data: Data, chunk: Int = 7 * 1024) -> GoldenStream {
        var result = GoldenStream()
        var demuxer = TSDemuxer()
        var framers: [UInt16: MPEG2Framer] = [:]
        var audioFramers: [UInt16: AC3Framer] = [:]
        func handle(_ events: [TSDemuxEvent]) {
            result.events += events
            for event in events {
                switch event {
                case .programs(let programs):
                    result.programs = programs
                    for stream in programs.flatMap(\.streams) {
                        if stream.kind == .mpeg2Video, framers[stream.pid] == nil {
                            framers[stream.pid] = MPEG2Framer()
                        } else if stream.kind == .ac3, audioFramers[stream.pid] == nil {
                            audioFramers[stream.pid] = AC3Framer()
                        }
                    }
                case .pes(let packet):
                    if framers[packet.pid] != nil {
                        result.video[packet.pid, default: []] += framers[packet.pid]?.append(packet) ?? []
                    } else if audioFramers[packet.pid] != nil {
                        result.audio[packet.pid, default: []] += audioFramers[packet.pid]?.append(packet) ?? []
                    }
                case .discontinuity:
                    break
                }
            }
        }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunk)
            handle(demuxer.feed(data.subdata(in: offset..<end)))
            offset = end
        }
        handle(demuxer.flush())
        for (pid, var framer) in framers {
            result.video[pid, default: []] += framer.flush()
        }
        for program in result.programs {
            result.lastPCR[program.pcrPID] = demuxer.lastPCR(pid: program.pcrPID)
        }
        return result
    }

    /// The first program's video access units.
    var mainVideo: [MPEG2AccessUnit] {
        programs.first?.videoStream.map { video[$0.pid] ?? [] } ?? []
    }

    func pes(pid: UInt16) -> [PESPacket] {
        events.packets(pid: pid)
    }

    var discontinuities: [UInt16] {
        events.discontinuities
    }
}

extension MPEG2AccessUnit {
    /// closed_gop from the GOP header in this unit, if it has one.
    var closedGOP: Bool? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        for index in 0..<(bytes.count - 7) where bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            && bytes[index + 3] == 0xB8 {
            return (bytes[index + 7] & 0x40) != 0
        }
        return nil
    }
}

extension Array where Element == MPEG2AccessUnit {
    /// Display order: by PTS.
    var displayOrder: [MPEG2AccessUnit] { sorted { $0.pts < $1.pts } }

    /// Indexes of I pictures (after the first unit) that are followed in coded order by B pictures shown before them:
    /// the leading pictures of an open GOP.
    var openGOPStarts: [Int] {
        indices.dropFirst().filter { index in
            self[index].pictureType == .intra && index + 1 < count
                && self[index + 1].pictureType == .bidirectional && self[index + 1].pts < self[index].pts
        }
    }
}
