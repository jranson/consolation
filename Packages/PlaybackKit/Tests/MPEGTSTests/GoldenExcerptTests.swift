//
//  GoldenExcerptTests.swift
//  MPEGTSTests
//
//  Header-only excerpts of real captures (scripts/ts-fixture-tool.swift `excerpt`): the broadcasters' PAT, PMT,
//  PCR, PES timestamps and MPEG-2 / AC-3 headers, with every picture, sound and caption byte zeroed. They pin the
//  parsers to real-world header values without committing broadcast content.
//

import Foundation
import Testing
@testable import MPEGTS

struct GoldenExcerptTests {
    private static func load(_ name: String) throws -> GoldenStream {
        try GoldenStream.load(name, subdirectory: "excerpts")
    }

    /// The AC-3 sync info at the start of each audio PES.
    private static func syncInfo(_ packets: [PESPacket]) -> [AC3SyncInfo] {
        packets.compactMap { packet in
            packet.payload.withUnsafeBytes { raw in AC3SyncInfo.parse(raw.bindMemory(to: UInt8.self), at: 0) }
        }
    }

    @Test(.enabled(if: GoldenStream.exists("excerpt-1080i", subdirectory: "excerpts")))
    func interlacedProgramHeaders() throws {
        let stream = try Self.load("excerpt-1080i")
        let program = try #require(stream.programs.first)
        #expect(stream.programs.count == 1)
        let video = try #require(program.videoStream)
        #expect(video.kind == .mpeg2Video)
        #expect(program.audioStreams.map(\.kind) == [.ac3, .ac3])
        #expect(program.audioStreams.map(\.language) == ["eng", "spa"])

        let units = stream.mainVideo
        let first = try #require(units.first)
        #expect(first.isKeyframe)
        #expect(first.sequence.width == 1920)
        #expect(first.sequence.height == 1080)
        #expect(!first.sequence.progressiveSequence)
        #expect(first.sequence.frameRate == MPEG2Rational(30000, 1001))
        #expect(units.allSatisfy { $0.topFieldFirst })
        #expect(units.allSatisfy { $0.captionData == nil })
        let decode = stream.pes(pid: video.pid).compactMap { $0.dts ?? $0.pts }
        #expect(Set(zip(decode, decode.dropFirst()).map { $1 - $0 }) == [3003])

        let english = Self.syncInfo(stream.pes(pid: program.audioStreams[0].pid))
        let spanish = Self.syncInfo(stream.pes(pid: program.audioStreams[1].pid))
        #expect(!english.isEmpty && english.allSatisfy { $0.acmod == 7 && $0.hasLFE && $0.sampleRate == 48_000 })
        #expect(!spanish.isEmpty && spanish.allSatisfy { $0.acmod == 2 && !$0.hasLFE })
        #expect(stream.lastPCR[program.pcrPID] != nil)
    }

    @Test(.enabled(if: GoldenStream.exists("excerpt-720p", subdirectory: "excerpts")))
    func progressiveProgramHeaders() throws {
        let stream = try Self.load("excerpt-720p")
        let program = try #require(stream.programs.first)
        let units = stream.mainVideo
        let first = try #require(units.first)
        #expect(first.sequence.width == 1280)
        #expect(first.sequence.height == 720)
        #expect(first.sequence.progressiveSequence)
        #expect(first.sequence.frameRate == MPEG2Rational(60000, 1001))
        #expect(units.allSatisfy { $0.progressiveFrame && $0.duration == 1501 })
        #expect(program.audioStreams.map(\.language) == ["eng", "spa"])
    }

    @Test(.enabled(if: GoldenStream.exists("excerpt-multiplex", subdirectory: "excerpts")))
    func fullMultiplexHasSeveralPrograms() throws {
        let stream = try Self.load("excerpt-multiplex")
        #expect(stream.programs.count >= 2)
        #expect(Set(stream.programs.map(\.programNumber)).count == stream.programs.count)
        let pids = stream.programs.flatMap(\.streams).map(\.pid)
        #expect(Set(pids).count == pids.count)
        #expect(stream.programs.allSatisfy { $0.videoStream?.kind == .mpeg2Video })
    }

    /// The excerpts keep headers only: no picture slices, no caption user data, no audio beyond the AC-3 header.
    @Test(arguments: ["excerpt-1080i", "excerpt-720p", "excerpt-multiplex"])
    func excerptsCarryNoContent(name: String) throws {
        guard GoldenStream.exists(name, subdirectory: "excerpts") else { return }
        let stream = try Self.load(name)
        for program in stream.programs {
            for audio in program.audioStreams {
                for packet in stream.pes(pid: audio.pid) {
                    #expect(packet.payload.dropFirst(AC3SyncInfo.headerSize).allSatisfy { $0 == 0 })
                }
            }
            guard let video = program.videoStream else { continue }
            for unit in stream.video[video.pid] ?? [] {
                let bytes = [UInt8](unit.data)
                let codes = bytes.indices.dropLast(3).filter {
                    bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 1
                }.map { bytes[$0 + 3] }
                #expect(codes.allSatisfy { [0x00, 0xB3, 0xB5, 0xB8].contains($0) })
            }
        }
    }
}
