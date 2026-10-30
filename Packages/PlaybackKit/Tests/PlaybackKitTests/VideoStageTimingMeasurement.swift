import CoreMedia
import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
/// Opt-in (PLAYBACKKIT_PERF=1, like PerformanceHarness): plays a capture's pictures through `VideoFrameStage` at the
/// broadcast picture rate and prints where the decode thread's time goes each second (`VideoStageTimings`), for
/// VideoToolbox and for libavcodec (the iPad, iPhone and Apple TV path).
struct VideoStageTimingMeasurement {
    static let seconds = 6

    @Test(.enabled(if: PerformanceHarness.isEnabled), .timeLimit(.minutes(5)))
    func stageSplit() async throws {
        let pictures = SyntheticVideoFixture.pictures(in: try Data(contentsOf: PerformanceHarness.capture))
        try #require(pictures.count > 30)
        for (name, preference) in PerformanceHarness.decoders {
            let stage = VideoFrameStage(preference: preference)
            let clock = ContinuousClock()
            let start = clock.now
            var index = 0
            var lines: [String] = []
            for second in 0..<Self.seconds {
                // About 29.97 pictures a second, like the pipeline decodes a 1080i or 480i stream.
                for _ in 0..<30 {
                    let picture = pictures[index % pictures.count]
                    index += 1
                    if index % pictures.count == 0 { stage.reset() }
                    _ = try stage.process(picture.sample, info: picture.info)
                    try await Task.sleep(until: start + .seconds(Double(index) / 29.97), clock: clock)
                }
                let timings = stage.takeTimings()
                if second > 0 { lines.append("\(name): " + timings.summary) }
            }
            print("VideoStageTimingMeasurement\n" + lines.joined(separator: "\n"))
        }
    }
}
#endif
