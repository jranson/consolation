import CoreMedia
import Darwin
import Foundation
import Testing
@testable import PlaybackKit

#if os(macOS)
/// Opt-in: measures CPU time per picture for each MPEG-2 decoder on a local transport stream. Not part of the CI
/// gate. Run it alone, ideally in release, for example:
///
///     PLAYBACKKIT_MEASURE_TS=/path/to/1080i.ts swift test -c release -Xswiftc -enable-testing \
///         --filter DecoderCostMeasurement
///
/// VideoToolbox decodes MPEG-2 in an XPC service, so its row adds that service's CPU time to the test process's.
@Suite(.serialized)
struct DecoderCostMeasurement {
    private nonisolated static let path = ProcessInfo.processInfo.environment["PLAYBACKKIT_MEASURE_TS"]
    /// Each decoder decodes the whole file this many times; the figures are per picture over all passes.
    private static let passes = 5

    @Test(.enabled(if: path != nil))
    func cpuPerPicture() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.path ?? ""))
        let pictures = SyntheticVideoFixture.pictures(in: data)
        #expect(!pictures.isEmpty)
        // Demuxing, framing and packaging into sample buffers, which run before any decoder.
        let demuxStart = Self.processCPU()
        for _ in 0..<Self.passes { _ = SyntheticVideoFixture.pictures(in: data) }
        print(String(format: "Demux, frame and package: %.3f ms CPU per picture",
                     (Self.processCPU() - demuxStart) / Double(pictures.count * Self.passes) * 1_000))
        let zeroCopy = LibavVideoDecoder()
        let decoders: [(String, any VideoDecoding)] = [
            ("libavcodec + CPU NV12 copy", LibavVideoDecoder(output: .cpuPixelBuffers)),
            ("libavcodec + Metal (zero-copy)", zeroCopy),
            ("VideoToolbox", VTVideoDecoder())
        ]
        for (name, decoder) in decoders {
            _ = try SyntheticVideoFixture.decode(Array(pictures.prefix(30)), with: decoder)
            decoder.invalidate()
            let gpuBefore = zeroCopy.gpuSeconds
            let start = Self.processCPU()
            let serviceStart = ServiceCPU.seconds(named: "VTDecoderXPCService")
            let wall = Date()
            var frames = 0
            var first: DecodedFrame?
            for _ in 0..<Self.passes {
                // Frames are dropped as they come, like the player does, so the output pool recycles its buffers.
                for picture in pictures {
                    for frame in try decoder.decode(picture.sample, info: picture.info) {
                        first = first ?? frame
                        frames += 1
                    }
                }
                frames += try decoder.drain().count
                decoder.invalidate()
            }
            let cpu = Self.processCPU() - start
            let service = ServiceCPU.seconds(named: "VTDecoderXPCService") - serviceStart
            let count = Double(max(frames, 1))
            let size = first.map { "\($0.size.width)x\($0.size.height)" } ?? "?"
            print(String(format: "%@: %d pictures %@ x%d, %.3f ms CPU per picture in process, %.3f ms in the "
                         + "VideoToolbox XPC service, %.3f ms GPU, %.2f s wall", name, frames / Self.passes, size,
                         Self.passes, cpu / count * 1_000, service / count * 1_000,
                         (zeroCopy.gpuSeconds - gpuBefore) / count * 1_000, Date().timeIntervalSince(wall)))
        }
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// CPU time of other processes by name (the VideoToolbox decoder service), from `proc_pid_rusage`.
nonisolated enum ServiceCPU {
    static func seconds(named name: String) -> Double {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var total = 0.0
        for pid in pids.prefix(max(count, 0)) where pid > 0 && processName(pid) == name {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }
            // Mach absolute time units.
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            total += ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        }
        return total
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }
}
#endif
