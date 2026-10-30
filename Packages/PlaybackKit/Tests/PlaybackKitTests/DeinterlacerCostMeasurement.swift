import CoreMedia
import Darwin
import Foundation
import Testing
@testable import PlaybackKit

#if os(macOS)
/// Opt-in: measures the Metal deinterlacer on a local interlaced transport stream (GPU time per output field from
/// the command buffers, process CPU and wall time around `push`). Not part of the CI gate. For example:
///
///     PLAYBACKKIT_MEASURE_TS=/path/to/1080i.ts swift test -c release -Xswiftc -enable-testing \
///         --filter DeinterlacerCostMeasurement
@Suite(.serialized)
struct DeinterlacerCostMeasurement {
    private nonisolated static let path = ProcessInfo.processInfo.environment["PLAYBACKKIT_MEASURE_TS"]

    @Test(.enabled(if: path != nil))
    func costPerField() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.path ?? ""))
        let pictures = SyntheticVideoFixture.pictures(in: data)
        let decoder = VTVideoDecoder()
        var reorder = FrameReorderBuffer()
        let deinterlacer = try #require(MetalDeinterlacer())
        var fields = 0
        var cpu = 0.0
        var wall = 0.0
        var gpu = 0.0
        for (index, picture) in pictures.enumerated() {
            for frame in try decoder.decode(picture.sample, info: picture.info).flatMap({ reorder.push($0) }) {
                let cpuStart = Self.processCPU()
                let wallStart = Date()
                let gpuStart = deinterlacer.gpuSeconds
                let output = deinterlacer.push(frame).map { $0.finished() }
                // The first 30 pictures warm up the pipeline and pools.
                if index >= 30 {
                    cpu += Self.processCPU() - cpuStart
                    wall += Date().timeIntervalSince(wallStart)
                    gpu += deinterlacer.gpuSeconds - gpuStart
                    fields += output.count
                }
            }
        }
        #expect(fields > 0)
        let count = Double(max(fields, 1))
        print(String(format: "Deinterlacer: %d fields, %.3f ms GPU, %.3f ms CPU, %.3f ms wall per field", fields,
                     gpu / count * 1_000, cpu / count * 1_000, wall / count * 1_000))
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
#endif
