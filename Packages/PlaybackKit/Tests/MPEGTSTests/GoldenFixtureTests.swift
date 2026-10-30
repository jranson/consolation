//
//  GoldenFixtureTests.swift
//  MPEGTSTests
//
//  The committed synthetic streams from scripts/make-test-fixtures.sh: real encoder output (FFmpeg's MPEG-2 and
//  AC-3 encoders and TS muxer) of flat colors and silence, so the demuxer and framers are checked against bitstreams
//  they didn't write themselves.
//

import Foundation
import Testing
import MPEGTS

struct GoldenFixtureTests {
    static let wrap: Int64 = 1 << 33

    @Test func interlaced1080iWithOpenGOPsAndTwoAudioTracks() throws {
        let stream = try GoldenStream.load("golden-1080i")
        let program = try #require(stream.programs.first)
        #expect(stream.programs.count == 1)
        #expect(program.videoStream?.kind == .mpeg2Video)
        #expect(program.audioStreams.map(\.kind) == [.ac3, .ac3])
        #expect(program.audioStreams.map(\.language) == ["eng", "spa"])

        let units = stream.mainVideo
        #expect(units.count == 14)
        let first = try #require(units.first)
        #expect(first.isKeyframe)
        #expect(first.sequence.width == 1920)
        #expect(first.sequence.height == 1080)
        #expect(first.sequence.frameRate == MPEG2Rational(30000, 1001))
        #expect(!first.sequence.progressiveSequence)
        #expect(units.allSatisfy { $0.topFieldFirst && !$0.progressiveFrame && $0.duration == 3003 })
        let shown = units.displayOrder.map(\.pts)
        #expect(Set(zip(shown, shown.dropFirst()).map { $1 - $0 }) == [3003])
        #expect(zip(units, units.dropFirst()).allSatisfy { $0.dts < $1.dts })

        // The second GOP is open: its I picture is followed by B pictures shown before it.
        let open = try #require(units.openGOPStarts.first)
        #expect(units[open].closedGOP == false)

        let english = try #require(stream.audio[program.audioStreams[0].pid])
        let spanish = try #require(stream.audio[program.audioStreams[1].pid])
        #expect(english.allSatisfy { $0.channelCount == 6 && $0.hasLFE && $0.sampleRate == 48_000 })
        #expect(spanish.allSatisfy { $0.channelCount == 2 && !$0.hasLFE })
        #expect(Set(zip(english, english.dropFirst()).map { $1.pts - $0.pts }) == [2880])
        #expect(english.count >= 10)
    }

    /// A/53 cc_data travels in coded order; read in display order, CC1 spells a pop-on caption.
    @Test func a53CaptionsReadInDisplayOrder() throws {
        let units = try GoldenStream.load("golden-1080i").mainVideo
        #expect(units.allSatisfy { $0.captionData?.count == 60 })
        let displayed = Self.cc1Text(units.displayOrder)
        #expect(displayed == "GOLDEN 608")
        #expect(Self.cc1Text(units) != displayed)
    }

    @Test func progressive720pWithOpenGOPs() throws {
        let stream = try GoldenStream.load("golden-720p")
        let units = stream.mainVideo
        #expect(units.count == 12)
        let first = try #require(units.first)
        #expect(first.isKeyframe)
        #expect(first.sequence.width == 1280)
        #expect(first.sequence.height == 720)
        #expect(first.sequence.frameRate == MPEG2Rational(60000, 1001))
        #expect(first.sequence.progressiveSequence)
        #expect(units.allSatisfy { $0.progressiveFrame && $0.duration == 1501 })
        #expect(!units.openGOPStarts.isEmpty)
    }

    /// Joining mid-GOP: output starts at the next sequence header and I picture, and that open GOP's leading B
    /// pictures (which reference a GOP never received) are dropped.
    @Test func startingInTheMiddleOfAGOP() throws {
        let full = try GoldenStream.load("golden-720p").mainVideo
        let cut = try GoldenStream.load("golden-720p-mid-gop").mainVideo
        let first = try #require(cut.first)
        #expect(first.isKeyframe)
        let start = try #require(full.firstIndex { $0.isKeyframe && $0.pts == first.pts })
        #expect(start > 0)
        #expect(full.openGOPStarts.contains(start))
        #expect(cut.allSatisfy { $0.pts >= first.pts })
        let leading = full[(start + 1)...].filter { $0.pts < first.pts }
        #expect(!leading.isEmpty)
        #expect(cut.count == full.count - start - leading.count)
    }

    @Test func timestampsUnwrapPast2To33() throws {
        let stream = try GoldenStream.load("golden-pts-wrap")
        let program = try #require(stream.programs.first)
        let units = stream.mainVideo
        #expect(units.count == 20)
        #expect(zip(units, units.dropFirst()).allSatisfy { $0.dts < $1.dts })
        let shown = units.displayOrder.map(\.pts)
        #expect(Set(zip(shown, shown.dropFirst()).map { $1 - $0 }) == [3003])
        // The raw 33-bit timestamps wrapped: the unwrapped span crosses a multiple of 2^33.
        let low = try #require(shown.first)
        let high = try #require(shown.last)
        #expect(low / Self.wrap < high / Self.wrap)
        let audio = try #require(stream.audio[program.audioStreams[0].pid])
        #expect(Set(zip(audio, audio.dropFirst()).map { $1.pts - $0.pts }) == [2880])
        #expect(stream.discontinuities.isEmpty)
    }

    /// Two segments spliced with discontinuity_indicator set and a +60 s timestamp jump.
    @Test func signalledDiscontinuity() throws {
        let stream = try GoldenStream.load("golden-discontinuity")
        let program = try #require(stream.programs.first)
        let video = try #require(program.videoStream)
        #expect(stream.discontinuities.contains(video.pid))
        let units = stream.mainVideo
        #expect(units.count == 20)
        let splice = try #require(units.firstIndex { $0.isDiscontinuity })
        #expect(splice == 10)
        #expect(units[splice].isKeyframe)
        let jump = units[splice].dts - units[splice - 1].dts
        #expect(abs(jump - 60 * 90_000) < 10 * 3003)
        #expect(units[..<splice].allSatisfy { !$0.isDiscontinuity })
    }

    @Test func twoProgramsInOnePAT() throws {
        let stream = try GoldenStream.load("golden-two-programs")
        #expect(stream.programs.map(\.programNumber) == [3, 4])
        #expect(Set(stream.programs.map(\.pmtPID)).count == 2)
        for (program, language) in zip(stream.programs, ["eng", "spa"]) {
            let video = try #require(program.videoStream)
            #expect(program.audioStreams.map(\.language) == [language])
            let units = try #require(stream.video[video.pid])
            #expect(units.count == 6)
            #expect(units.first?.sequence.width == 352)
            #expect(units.first?.sequence.height == 240)
        }
    }

    /// A tile playing one program of a multiplex: the PAT lists both, and with the PES filter set to the second
    /// program's video and audio only those PIDs are reassembled.
    @Test func pesFilterKeepsOneProgramOfTwo() throws {
        let url = try #require(GoldenStream.url("golden-two-programs"))
        let data = try Data(contentsOf: url)
        var demuxer = TSDemuxer()
        var programs: [ProgramMap] = []
        var pids: Set<UInt16> = []
        for offset in stride(from: 0, to: data.count, by: 1_880) {
            // PES completed in the same chunk as the PMT came before the filter.
            let filtered = demuxer.pesFilter != nil
            for event in demuxer.feed(data.subdata(in: offset..<min(offset + 1_880, data.count))) {
                switch event {
                case .programs(let list):
                    programs = list
                    if let second = list.first(where: { $0.programNumber == 4 }) {
                        demuxer.setPESFilter(Set(second.streams.map(\.pid)))
                    }
                case .pes(let pes) where filtered:
                    pids.insert(pes.pid)
                default:
                    break
                }
            }
        }
        #expect(demuxer.listedProgramNumbers == [3, 4])
        let second = try #require(programs.first { $0.programNumber == 4 })
        let first = try #require(programs.first { $0.programNumber == 3 })
        #expect(pids == Set(second.streams.map(\.pid)))
        #expect(pids.isDisjoint(with: first.streams.map(\.pid)))
    }

    /// CC1 characters (cc_type 0, valid), parity stripped, control pairs and nulls skipped.
    static func cc1Text(_ units: [MPEG2AccessUnit]) -> String {
        var text: [UInt8] = []
        for unit in units {
            let bytes = [UInt8](unit.captionData ?? Data())
            for triplet in stride(from: 0, to: bytes.count - 2, by: 3) where bytes[triplet] & 0x07 == 0x04 {
                let pair = [bytes[triplet + 1] & 0x7F, bytes[triplet + 2] & 0x7F]
                guard pair[0] >= 0x20 else { continue }
                text += pair.filter { $0 >= 0x20 }
            }
        }
        return String(bytes: text, encoding: .ascii) ?? ""
    }
}
