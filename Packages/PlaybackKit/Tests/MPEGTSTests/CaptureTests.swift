//
//  CaptureTests.swift
//  MPEGTSTests
//
//  Opt-in checks against a real HDHomeRun capture. The capture lives in the gitignored `localdata/captures` and is
//  never committed, so these tests are skipped (not failed) wherever it is absent, such as CI.
//

import Foundation
import Testing
import MPEGTS

struct CaptureTests {
    static let capture91 = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MPEGTSTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // PlaybackKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("localdata/captures/hdhr-9.1.ts")

    static var hasCapture91: Bool {
        FileManager.default.fileExists(atPath: capture91.path)
    }

    private struct Result {
        var programs: [ProgramMap] = []
        var units: [MPEG2AccessUnit] = []
        var audio: [UInt16: [AC3Frame]] = [:]
    }

    /// Demuxes and frames the capture in 64 KiB chunks, as a network source would deliver it.
    private static func run(_ data: Data) -> Result {
        var result = Result()
        var demuxer = TSDemuxer()
        var video = MPEG2Framer()
        var audio: [UInt16: AC3Framer] = [:]
        func handle(_ events: [TSDemuxEvent]) {
            for event in events {
                switch event {
                case .programs(let programs):
                    result.programs = programs
                    for stream in programs.flatMap(\.streams) where stream.kind == .ac3 && audio[stream.pid] == nil {
                        audio[stream.pid] = AC3Framer()
                    }
                case .pes(let packet):
                    if packet.pid == result.programs.first?.videoStream?.pid {
                        result.units += video.append(packet)
                    } else if audio[packet.pid] != nil {
                        result.audio[packet.pid, default: []] += audio[packet.pid]?.append(packet) ?? []
                    }
                case .discontinuity:
                    break
                }
            }
        }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 65_536)
            handle(demuxer.feed(data.subdata(in: offset..<end)))
            offset = end
        }
        handle(demuxer.flush())
        result.units += video.flush()
        return result
    }

    @Test(.enabled(if: CaptureTests.hasCapture91, "needs localdata/captures/hdhr-9.1.ts"))
    func hdhr91() throws {
        let data = try Data(contentsOf: Self.capture91)
        let result = Self.run(data)

        #expect(result.programs.count == 1)
        let program = try #require(result.programs.first)
        let video = try #require(program.videoStream)
        #expect(video.kind == .mpeg2Video)
        let audio = program.audioStreams
        #expect(audio.map(\.kind) == [.ac3, .ac3])
        #expect(audio.map(\.language) == ["eng", "spa"])

        #expect(result.units.count > 300)
        let first = try #require(result.units.first)
        #expect(first.isKeyframe)
        #expect(first.sequence.width == 1920)
        #expect(first.sequence.height == 1080)
        #expect(!first.sequence.progressiveSequence)
        #expect(first.sequence.frameRate == MPEG2Rational(30000, 1001))
        #expect(first.topFieldFirst)
        let dts = result.units.map(\.dts)
        #expect(zip(dts, dts.dropFirst()).allSatisfy { $0 < $1 })
        #expect(result.units.allSatisfy { $0.captionData?.count == 60 })

        let english = try #require(result.audio[audio[0].pid])
        let spanish = try #require(result.audio[audio[1].pid])
        #expect(english.first?.channelCount == 6)
        #expect(spanish.first?.channelCount == 2)
        #expect(Set(zip(english, english.dropFirst()).map { $1.pts - $0.pts }) == [2880])

        // Throughput: demux plus video and both audio framers, best of five runs.
        var best = Duration.seconds(1_000)
        for _ in 0..<5 {
            let elapsed = ContinuousClock().measure { _ = Self.run(data) }
            best = min(best, elapsed)
        }
        let seconds = Double(best.components.seconds) + Double(best.components.attoseconds) / 1e18
        let megabytes = Double(data.count) / 1_000_000
        // Audio spans the whole capture; video output only starts at the first sequence header and I picture.
        let content = Double((english.last?.pts ?? 0) - (english.first?.pts ?? 0) + 2880) / 90_000
        print(String(format: "hdhr-9.1: %.1f MB demuxed and framed in %.2f ms = %.0f MB/s; %.4f%% of one core for "
                     + "%.1f s of content", megabytes, seconds * 1000, megabytes / seconds,
                     seconds / content * 100, content))
    }
}
