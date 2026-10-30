//
//  AllocationMeasurement.swift
//  PlaybackKitTests
//
//  Opt-in: heap allocations and peak live memory per picture for ingest (reading the ring, demuxing, framing video
//  and audio, packaging sample buffers and queueing pictures), the way `TransportStreamPipeline.pump()` does it but
//  without decoding or rendering. Not part of the CI gate. Run it alone, in release, for example:
//
//      PLAYBACKKIT_MEASURE_TS=/path/to/stream.ts swift test -c release -Xswiftc -enable-testing \
//          --filter AllocationMeasurement
//

import CoreMedia
import Darwin
import Foundation
import MPEGTS
import Testing
@testable import PlaybackKit

#if os(macOS)
@Suite(.serialized)
struct AllocationMeasurement {
    private nonisolated static let path = ProcessInfo.processInfo.environment["PLAYBACKKIT_MEASURE_TS"]
    private static let passes = 3
    private static let cpuPasses = 10

    @Test(.enabled(if: path != nil && AllocationCounter.isAvailable))
    func allocationsPerPicture() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.path ?? ""))
        let ring = MemoryByteRing(capacity: data.count)
        ring.append(data)
        var lines: [String] = []
        // CPU first, without the counter's hook: the ingest path's own cost per picture, over several passes.
        _ = IngestMirror.run(ring, from: 0)
        let cpuStart = Self.processCPU()
        var timed = 0
        for _ in 1...Self.cpuPasses { timed += IngestMirror.run(ring, from: 0).pictures }
        lines.append(String(format: "CPU: %.4f ms per picture",
                            (Self.processCPU() - cpuStart) / Double(max(timed, 1)) * 1_000))
        AllocationCounter.install()
        defer { AllocationCounter.uninstall() }
        // From a packet boundary, then from a byte that isn't one (as after a seek), which joins partial packets.
        for (name, start) in [("aligned", Int64(0)), ("unaligned", Int64(1_000))] {
            var line = ""
            for _ in 1...Self.passes {
                AllocationCounter.resetPeak()
                let before = AllocationCounter.snapshot()
                let counts = IngestMirror.run(ring, from: start)
                let after = AllocationCounter.snapshot()
                let pictures = Double(max(counts.pictures, 1))
                line = String(
                    format: "%@: %d pictures, %d audio samples; %.1f allocations and %.1f KB allocated per picture, "
                        + "peak %.2f MB live above the start",
                    name, counts.pictures, counts.audio, Double(after.allocations - before.allocations) / pictures,
                    Double(after.bytes - before.bytes) / pictures / 1_024,
                    Double(AllocationCounter.peakLive - before.live) / 1_048_576)
            }
            lines.append(line)
        }
        print("AllocationMeasurement (\(URL(fileURLWithPath: Self.path ?? "").lastPathComponent)):\n"
              + lines.joined(separator: "\n"))
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// The pipeline's ingest path (`TransportStreamPipeline.pump()` and `handle(_:)`), minus decoding and rendering:
/// queued pictures are dropped as the pipeline's decode loop would take them.
nonisolated enum IngestMirror {
    static func run(_ ring: MemoryByteRing, from start: Int64) -> (pictures: Int, audio: Int) {
        var demuxer = TSDemuxer()
        var processor = ElementaryProcessor()
        var pending = PictureQueue()
        var framed: [CompressedPicture] = []
        var pictures = 0
        var audio = 0
        var offset = start
        var buffer = [UInt8](repeating: 0, count: TransportStreamPipeline.readChunk)
        func handle(_ event: TSDemuxBorrowedEvent) {
            switch event {
            case .programs(let programs, _):
                guard let program = programs.first else { return }
                processor.select(video: TrackSelection.video(in: program),
                                 audio: TrackSelection.audio(in: program, preferredLanguage: "en"))
            case .pes(let pes, let payload) where pes.pid == processor.videoPID:
                processor.appendVideoSamples(from: pes, payload: payload, to: &framed)
                pictures += framed.count
                pending.append(contentsOf: framed)
                framed.removeAll(keepingCapacity: true)
            case .pes(let pes, let payload) where pes.pid == processor.audioPID:
                audio += processor.audioSamples(from: pes, payload: payload).count
            default:
                break
            }
        }
        while offset < ring.writeHead {
            let count = buffer.withUnsafeMutableBytes { ring.read(from: offset, into: $0) }
            guard count > 0 else { break }
            offset += Int64(count)
            buffer.withUnsafeBytes { demuxer.feed(UnsafeRawBufferPointer(rebasing: $0[..<count]), handle) }
            while pending.popFirst() != nil {}
        }
        return (pictures, audio)
    }
}
#endif
